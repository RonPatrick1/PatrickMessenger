use std::{env, path::PathBuf, sync::Arc};

use anyhow::{Context as _, Result, bail};
use matrix_sdk::{
    Client, Room, RoomState,
    attachment::AttachmentConfig,
    config::SyncSettings,
    event_handler::Ctx,
    ruma::events::room::{
        member::StrippedRoomMemberEvent,
        message::{MessageType, OriginalSyncRoomMessageEvent, TextMessageEventContent},
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
    send_liam_answer(room, &answer, &bot.http).await?;
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

struct MarkdownImage {
    alt: String,
    target: String,
}

/// Pulls every ![alt](target) out of `text`, returning the images found and
/// the leftover text with those Markdown fragments removed (so the same
/// picture doesn't show up twice — once as a real image, once as raw
/// Markdown text). Hand-rolled rather than a regex crate, since the pattern
/// is simple and this avoids a new dependency for one call site.
fn extract_and_strip_markdown_images(text: &str) -> (Vec<MarkdownImage>, String) {
    let mut images = Vec::new();
    let mut stripped = String::new();
    let mut rest = text;
    while let Some(start) = rest.find("![") {
        stripped.push_str(&rest[..start]);
        let after_bang = &rest[start + 2..];
        let Some(alt_end) = after_bang.find(']') else {
            stripped.push_str(&rest[start..]);
            rest = "";
            break;
        };
        let after_alt = &after_bang[alt_end + 1..];
        if !after_alt.starts_with('(') {
            stripped.push_str(&rest[start..start + 2]);
            rest = after_bang;
            continue;
        }
        let after_paren = &after_alt[1..];
        // A plain `find(')')` would stop at the first `)`, which can be part
        // of the URL itself (thumbor-style filters like `no_upscale()` are
        // common in image_search results) rather than the Markdown link's
        // actual closing delimiter. Track paren depth so an embedded,
        // balanced `(...)` inside the URL doesn't truncate it.
        let Some(url_end) = find_matching_close_paren(after_paren) else {
            stripped.push_str(&rest[start..]);
            rest = "";
            break;
        };
        images.push(MarkdownImage {
            alt: after_bang[..alt_end].to_owned(),
            target: after_paren[..url_end].trim().to_owned(),
        });
        rest = &after_paren[url_end + 1..];
    }
    stripped.push_str(rest);
    (images, stripped)
}

/// Finds the `)` that closes the Markdown link's opening `(`, treating any
/// balanced `(...)` pair inside `s` as part of the URL rather than the end
/// of the link.
fn find_matching_close_paren(s: &str) -> Option<usize> {
    let mut depth = 0i32;
    for (index, ch) in s.char_indices() {
        match ch {
            '(' => depth += 1,
            ')' => {
                if depth == 0 {
                    return Some(index);
                }
                depth -= 1;
            }
            _ => {}
        }
    }
    None
}

/// Matrix's plain-text messages don't render Markdown, so leftover text
/// (after images are pulled out) would otherwise show raw `[label](url)`
/// links and `*emphasis*` asterisks verbatim, as seen live with Liam's
/// "*Source: [vecteezy.com](https://www.vecteezy.com)*" attributions.
/// Convert to plain text instead: links become `label (url)`, and emphasis
/// asterisks are dropped.
fn plainify_markdown_text(text: &str) -> String {
    convert_markdown_links_to_plain(text).replace('*', "")
}

fn convert_markdown_links_to_plain(text: &str) -> String {
    let mut result = String::new();
    let mut rest = text;
    while let Some(start) = rest.find('[') {
        result.push_str(&rest[..start]);
        let after_bracket = &rest[start + 1..];
        let Some(label_end) = after_bracket.find(']') else {
            result.push_str(&rest[start..]);
            rest = "";
            break;
        };
        let after_label = &after_bracket[label_end + 1..];
        if !after_label.starts_with('(') {
            result.push('[');
            rest = after_bracket;
            continue;
        }
        let after_paren = &after_label[1..];
        let Some(url_end) = find_matching_close_paren(after_paren) else {
            result.push_str(&rest[start..]);
            rest = "";
            break;
        };
        let label = after_bracket[..label_end].trim();
        let url = after_paren[..url_end].trim();
        if label == url {
            result.push_str(url);
        } else {
            result.push_str(label);
            result.push_str(" (");
            result.push_str(url);
            result.push(')');
        }
        rest = &after_paren[url_end + 1..];
    }
    result.push_str(rest);
    result
}

fn guess_image_mime(target: &str) -> mime::Mime {
    let path = target
        .split(['?', '#'])
        .next()
        .unwrap_or(target)
        .to_ascii_lowercase();
    if path.ends_with(".jpg") || path.ends_with(".jpeg") {
        mime::IMAGE_JPEG
    } else if path.ends_with(".gif") {
        mime::IMAGE_GIF
    } else if path.ends_with(".webp") {
        "image/webp".parse().unwrap()
    } else {
        mime::IMAGE_PNG
    }
}

async fn fetch_image_bytes(http: &HttpClient, target: &str) -> Result<Vec<u8>> {
    if target.starts_with('/') {
        return std::fs::read(target)
            .with_context(|| format!("reading local generated image {target}"));
    }
    let response = http.get(target).send().await?.error_for_status()?;
    Ok(response.bytes().await?.to_vec())
}

async fn send_liam_answer(room: &Room, answer: &str, http: &HttpClient) -> Result<()> {
    let (images, stripped) = extract_and_strip_markdown_images(answer);
    let mut failed_images = 0usize;
    for image in &images {
        match fetch_image_bytes(http, &image.target).await {
            Ok(bytes) => {
                let mime = guess_image_mime(&image.target);
                let filename = std::path::Path::new(&image.target)
                    .file_name()
                    .and_then(|name| name.to_str())
                    .unwrap_or("image")
                    .to_owned();
                let caption = (!image.alt.is_empty())
                    .then(|| TextMessageEventContent::plain(image.alt.clone()));
                if let Err(error) = room
                    .send_attachment(
                        filename,
                        &mime,
                        bytes,
                        AttachmentConfig::new().caption(caption),
                    )
                    .await
                {
                    failed_images += 1;
                    warn!(target = %image.target, %error, "failed to send Liam image attachment");
                }
            }
            Err(error) => {
                failed_images += 1;
                warn!(target = %image.target, %error, "failed to fetch Liam image for Matrix upload");
            }
        }
    }

    let mut remaining = plainify_markdown_text(stripped.trim()).trim().to_owned();
    if failed_images > 0 {
        let noun = if failed_images == 1 { "image" } else { "images" };
        let notice = format!(
            "I generated the {noun}, but couldn't upload it to this conversation. Please try again."
        );
        if !remaining.is_empty() {
            remaining.push_str("\n\n");
        }
        remaining.push_str(&notice);
    }
    if !remaining.is_empty() || images.is_empty() {
        let body = if remaining.is_empty() {
            plainify_markdown_text(answer)
        } else {
            format!("Liam:\n{remaining}")
        };
        let mut content = json!({
            "msgtype": "m.text",
            "body": body,
        });
        if let Value::Object(ref mut object) = content {
            object.insert(LIAM_ANSWER_KEY.to_owned(), Value::Bool(true));
        }
        room.send_raw("m.room.message", content).await?;
    }
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

    #[test]
    fn extracts_an_image_with_surrounding_text() {
        let (images, stripped) =
            extract_and_strip_markdown_images("Here you go:\n![a cat](https://x/cat.png)\nEnjoy!");
        assert_eq!(images.len(), 1);
        assert_eq!(images[0].alt, "a cat");
        assert_eq!(images[0].target, "https://x/cat.png");
        assert_eq!(stripped, "Here you go:\n\nEnjoy!");
    }

    #[test]
    fn extracts_a_lone_image_leaving_no_text() {
        let (images, stripped) =
            extract_and_strip_markdown_images("![red barn](/var/www/LiamAgent/.liam_generated/a.png)");
        assert_eq!(images.len(), 1);
        assert_eq!(images[0].target, "/var/www/LiamAgent/.liam_generated/a.png");
        assert_eq!(stripped.trim(), "");
    }

    #[test]
    fn extracts_multiple_images() {
        let (images, _) =
            extract_and_strip_markdown_images("![a](https://x/a.png) and ![b](https://x/b.jpg)");
        assert_eq!(images.len(), 2);
        assert_eq!(images[0].target, "https://x/a.png");
        assert_eq!(images[1].target, "https://x/b.jpg");
    }

    #[test]
    fn does_not_truncate_a_url_containing_balanced_parens() {
        let (images, stripped) = extract_and_strip_markdown_images(
            "![a barn](https://x/thmb/abc=/1500x0/filters:no_upscale()/real-image.jpg) Here.",
        );
        assert_eq!(images.len(), 1);
        assert_eq!(
            images[0].target,
            "https://x/thmb/abc=/1500x0/filters:no_upscale()/real-image.jpg"
        );
        assert_eq!(stripped, " Here.");
    }

    #[test]
    fn leaves_ordinary_text_without_images_untouched() {
        let (images, stripped) = extract_and_strip_markdown_images("Just a normal answer.");
        assert!(images.is_empty());
        assert_eq!(stripped, "Just a normal answer.");
    }

    #[test]
    fn tolerates_malformed_markdown_image_syntax() {
        let (images, stripped) = extract_and_strip_markdown_images("Broken: ![alt](no closing paren");
        assert!(images.is_empty());
        assert_eq!(stripped, "Broken: ![alt](no closing paren");
    }

    #[test]
    fn guesses_mime_type_from_extension() {
        assert_eq!(guess_image_mime("https://x/a.JPG"), mime::IMAGE_JPEG);
        assert_eq!(guess_image_mime("https://x/a.gif?w=100"), mime::IMAGE_GIF);
        assert_eq!(guess_image_mime("https://x/a.webp").essence_str(), "image/webp");
        assert_eq!(guess_image_mime("/tmp/a.png"), mime::IMAGE_PNG);
        assert_eq!(guess_image_mime("/tmp/unknown"), mime::IMAGE_PNG);
    }

    #[test]
    fn plainifies_liams_real_source_attribution_lines() {
        assert_eq!(
            plainify_markdown_text(
                "*Source: [vecteezy.com](https://www.vecteezy.com)*"
            ),
            "Source: vecteezy.com (https://www.vecteezy.com)"
        );
    }

    #[test]
    fn collapses_a_link_whose_label_matches_its_url() {
        assert_eq!(
            plainify_markdown_text("See [https://x/a](https://x/a) for more."),
            "See https://x/a for more."
        );
    }

    #[test]
    fn leaves_plain_text_without_markdown_untouched() {
        assert_eq!(
            plainify_markdown_text("Just a normal answer."),
            "Just a normal answer."
        );
    }
}
