use std::{env, path::PathBuf, sync::Arc};

use anyhow::{Context as _, Result, bail};
use matrix_sdk::{
    Client, Room, RoomState,
    config::SyncSettings,
    event_handler::Ctx,
    ruma::events::room::{
        member::StrippedRoomMemberEvent,
        message::{MessageType, OriginalSyncRoomMessageEvent},
    },
};
use reqwest::Client as HttpClient;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::time::{Duration, sleep};
use tracing::{error, info, warn};

const LIAM_ANSWER_KEY: &str = "com.patricklamphier.patrick_messenger.liam_answer";

#[derive(Clone)]
struct Config {
    homeserver_url: String,
    matrix_user: String,
    matrix_password: String,
    store_path: PathBuf,
    store_passphrase: String,
    liam_bridge_url: String,
}

impl Config {
    fn from_env() -> Result<Self> {
        Ok(Self {
            homeserver_url: required_env("LIAM_HOMESERVER_URL")?,
            matrix_user: required_env("LIAM_MATRIX_USER")?,
            matrix_password: required_env("LIAM_MATRIX_PASSWORD")?,
            store_path: PathBuf::from(required_env("LIAM_STORE_PATH")?),
            store_passphrase: required_env("LIAM_STORE_PASSPHRASE")?,
            liam_bridge_url: required_env("LIAM_BRIDGE_URL")?,
        })
    }
}

fn required_env(name: &str) -> Result<String> {
    let value = env::var(name).with_context(|| format!("{name} is required"))?;
    if value.trim().is_empty() {
        bail!("{name} cannot be empty");
    }
    Ok(value)
}

#[derive(Clone)]
struct Bot {
    config: Config,
    http: HttpClient,
}

#[derive(Serialize)]
struct BridgeRequest<'a> {
    room_id: &'a str,
    sender_id: &'a str,
    message: &'a str,
}

#[derive(Deserialize)]
struct BridgeResponse {
    reply: Option<String>,
    error: Option<String>,
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "patrick_messenger_liam=info,warn".into()),
        )
        .init();

    let config = Config::from_env()?;
    let client = Client::builder()
        .homeserver_url(&config.homeserver_url)
        .sqlite_store(&config.store_path, Some(&config.store_passphrase))
        .build()
        .await
        .context("building Liam's encrypted Matrix client")?;

    client
        .matrix_auth()
        .login_username(&config.matrix_user, &config.matrix_password)
        .device_id("PATRICK_MESSENGER_LIAM")
        .initial_device_display_name("Liam")
        .send()
        .await
        .context("logging Liam into Matrix")?;
    client.account().set_display_name(Some("Liam")).await?;

    let bot = Arc::new(Bot {
        config,
        http: HttpClient::builder()
            .timeout(Duration::from_secs(600))
            .build()?,
    });
    client.add_event_handler_context(bot);
    client.add_event_handler(on_invite);

    let response = client.sync_once(SyncSettings::default()).await?;
    client.add_event_handler(on_room_message);

    info!(user = %client.user_id().expect("logged-in user"), "Liam is ready");
    client
        .sync(SyncSettings::default().token(response.next_batch))
        .await?;
    Ok(())
}

async fn on_invite(event: StrippedRoomMemberEvent, client: Client, room: Room) {
    if event.state_key != client.user_id().expect("logged-in user") {
        return;
    }

    tokio::spawn(async move {
        let mut delay = 1;
        loop {
            match room.join().await {
                Ok(()) => break,
                Err(error) if delay <= 32 => {
                    warn!(room = %room.room_id(), %error, "join failed; retrying");
                    sleep(Duration::from_secs(delay)).await;
                    delay *= 2;
                }
                Err(error) => {
                    error!(room = %room.room_id(), %error, "could not join invited room");
                    return;
                }
            }
        }

        sleep(Duration::from_secs(1)).await;
        match room.latest_encryption_state().await {
            Ok(state) if state.is_encrypted() => {
                info!(room = %room.room_id(), "joined encrypted conversation");
            }
            Ok(_) => {
                warn!(room = %room.room_id(), "leaving unencrypted conversation");
                let _ = room.leave().await;
            }
            Err(error) => {
                error!(room = %room.room_id(), %error, "could not verify room encryption");
                let _ = room.leave().await;
            }
        }
    });
}

async fn on_room_message(
    event: OriginalSyncRoomMessageEvent,
    room: Room,
    client: Client,
    Ctx(bot): Ctx<Arc<Bot>>,
) {
    if room.state() != RoomState::Joined
        || event.sender == client.user_id().expect("logged-in user")
    {
        return;
    }
    let MessageType::Text(text) = &event.content.msgtype else {
        return;
    };

    if is_leave_command(&text.body) {
        info!(room = %room.room_id(), sender = %event.sender, "leaving on member request");
        let _ = send_text(&room, "Liam has left this conversation.").await;
        if let Err(error) = room.leave().await {
            error!(room = %room.room_id(), %error, "could not leave room");
        }
        return;
    }

    let Some(question) = extract_question(&text.body) else {
        return;
    };
    if question.is_empty() {
        return;
    }
    if !room
        .latest_encryption_state()
        .await
        .is_ok_and(|state| state.is_encrypted())
    {
        warn!(room = %room.room_id(), "ignored Liam request in unencrypted room");
        return;
    }

    if let Err(error) = answer_question(&bot, &room, event.sender.as_str(), &question).await {
        error!(room = %room.room_id(), %error, "Liam request failed");
        let _ = send_text(&room, "Liam could not answer right now. Please try again.").await;
    }
}

async fn answer_question(
    bot: &Bot,
    room: &Room,
    sender_id: &str,
    question: &str,
) -> Result<()> {
    // The SDK's own typing notice only lasts a few seconds server-side, and
    // the bridge's real agent calls can take well over a minute, so it must
    // be refreshed periodically for the whole wait rather than sent once.
    let typing_room = room.clone();
    let typing_room_id = room.room_id().to_owned();
    let typing_task = tokio::spawn(async move {
        loop {
            match typing_room.typing_notice(true).await {
                Ok(()) => info!(room = %typing_room_id, "sent Liam typing notice"),
                Err(error) => {
                    warn!(room = %typing_room_id, %error, "Liam typing notice failed");
                    return;
                }
            }
            sleep(Duration::from_secs(3)).await;
        }
    });

    let result = request_bridge_answer(bot, room, sender_id, question).await;

    typing_task.abort();
    if let Err(error) = room.typing_notice(false).await {
        warn!(room = %room.room_id(), %error, "clearing Liam typing notice failed");
    }

    result
}

async fn request_bridge_answer(
    bot: &Bot,
    room: &Room,
    sender_id: &str,
    question: &str,
) -> Result<()> {
    let response = bot
        .http
        .post(&bot.config.liam_bridge_url)
        .json(&BridgeRequest {
            room_id: room.room_id().as_str(),
            sender_id,
            message: question,
        })
        .send()
        .await?;

    let status = response.status();
    let body: BridgeResponse = response
        .json()
        .await
        .context("parsing the Liam bridge response")?;

    if let Some(error) = body.error.filter(|error| !error.is_empty()) {
        bail!("Liam bridge returned an error: {error}");
    }
    if !status.is_success() {
        bail!("Liam bridge returned HTTP {status}");
    }

    let answer = normalize_answer(&body.reply.unwrap_or_default());
    if answer.is_empty() {
        bail!("Liam bridge returned an empty answer");
    }
    send_liam_answer(room, &answer).await?;
    Ok(())
}

fn extract_question(body: &str) -> Option<String> {
    let trimmed = body.trim_start();
    let (name, rest) = trimmed.split_once(':')?;
    name.trim()
        .eq_ignore_ascii_case("liam")
        .then(|| rest.trim().to_owned())
}

fn is_leave_command(body: &str) -> bool {
    matches!(
        body.trim().to_ascii_lowercase().as_str(),
        "!liam leave" | "liam: leave" | "liam: leave this conversation"
    )
}

async fn send_text(room: &Room, body: &str) -> Result<()> {
    room.send_raw("m.room.message", json!({"msgtype": "m.text", "body": body}))
        .await?;
    Ok(())
}

async fn send_liam_answer(room: &Room, answer: &str) -> Result<()> {
    let mut content = json!({
        "msgtype": "m.text",
        "body": format!("Liam:\n{answer}"),
    });
    if let Value::Object(ref mut object) = content {
        object.insert(LIAM_ANSWER_KEY.to_owned(), Value::Bool(true));
    }
    room.send_raw("m.room.message", content).await?;
    Ok(())
}

fn normalize_answer(raw: &str) -> String {
    let mut answer = raw.trim().to_owned();

    // Models occasionally return a JSON string literal (including escaped
    // newlines) or add their own Liam heading. Normalize either form before
    // the one canonical heading is added to the Matrix event.
    for _ in 0..4 {
        let before = answer.clone();

        if let Ok(decoded) = serde_json::from_str::<String>(&answer) {
            answer = decoded.trim().to_owned();
        }

        if let Some(without_heading) = strip_liam_heading(&answer) {
            answer = without_heading.trim().to_owned();
        }

        if answer == before {
            break;
        }
    }

    answer.trim().to_owned()
}

fn strip_liam_heading(answer: &str) -> Option<&str> {
    let mut candidate = answer.trim_start();
    if let Some(without_robot) = candidate.strip_prefix('🤖') {
        candidate = without_robot.trim_start_matches(['\u{fe0f}', ' ']);
    }
    let (heading, body) = candidate.split_once(':')?;
    heading.trim().eq_ignore_ascii_case("liam").then_some(body)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_only_a_leading_liam_prefix() {
        assert_eq!(
            extract_question(" LIAM: What happened? ").as_deref(),
            Some("What happened?")
        );
        assert_eq!(extract_question("Hello Liam: no"), None);
    }

    #[test]
    fn recognizes_explicit_leave_commands() {
        assert!(is_leave_command("Liam: leave this conversation"));
        assert!(!is_leave_command("Liam: should I leave?"));
    }

    #[test]
    fn normalizes_quoted_and_escaped_model_answers() {
        assert_eq!(
            normalize_answer(r#""Liam:\nI am here to help.""#),
            "I am here to help."
        );
    }

    #[test]
    fn removes_repeated_liam_headings() {
        assert_eq!(
            normalize_answer("Liam: 🤖 Liam:\nA useful answer."),
            "A useful answer."
        );
    }

    #[test]
    fn preserves_an_ordinary_model_answer() {
        assert_eq!(normalize_answer("A useful answer."), "A useful answer.");
    }
}
