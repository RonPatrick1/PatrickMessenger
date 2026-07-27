use std::{
    collections::HashSet,
    env, fs,
    io::Write as _,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::{Arc, Mutex},
};

use anyhow::{Context as _, Result, bail};
use matrix_sdk::{
    Client, Room, RoomState,
    config::SyncSettings,
    event_handler::{Ctx, RawEvent},
    media::{MediaFormat, MediaRequestParameters},
    ruma::events::{
        AnySyncTimelineEvent,
        room::{EncryptedFile, MediaSource, member::StrippedRoomMemberEvent},
    },
};
use rand::RngCore as _;
use rusqlite::{Connection, OptionalExtension as _, params, params_from_iter, types::Value as SqlValue};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest as _, Sha256};
use tokio::time::{Duration, sleep};
use tracing::{error, info, warn};

const RESET_EVENT: &str = "com.patricklamphier.patrick_messenger.search.reset";
const BATCH_EVENT: &str = "com.patricklamphier.patrick_messenger.search.batch";
const COMMIT_EVENT: &str = "com.patricklamphier.patrick_messenger.search.commit";
const READY_EVENT: &str = "com.patricklamphier.patrick_messenger.search.ready";
const QUERY_EVENT: &str = "com.patricklamphier.patrick_messenger.search.query";
const RESULTS_EVENT: &str = "com.patricklamphier.patrick_messenger.search.results";
const LEAVE_EVENT: &str = "com.patricklamphier.patrick_messenger.search.leave";
const ARCHIVE_OVERLAY_EVENT: &str =
    "com.patricklamphier.patrick_messenger.archive.overlay";
const MEDIA_OCR_KEY: &str = "com.patricklamphier.patrick_messenger.media_ocr";

#[derive(Clone)]
struct Config {
    homeserver_url: String,
    matrix_user: String,
    matrix_password: String,
    store_path: PathBuf,
    store_passphrase: String,
    index_path: PathBuf,
    index_key_path: PathBuf,
}

impl Config {
    fn from_env() -> Result<Self> {
        let data_path = PathBuf::from(required_env("SEARCH_DATA_PATH")?);
        Ok(Self {
            homeserver_url: required_env("SEARCH_HOMESERVER_URL")?,
            matrix_user: required_env("SEARCH_MATRIX_USER")?,
            matrix_password: required_env("SEARCH_MATRIX_PASSWORD")?,
            store_path: data_path.join("matrix-store"),
            store_passphrase: required_env("SEARCH_STORE_PASSPHRASE")?,
            index_path: data_path.join("search-index.sqlite3"),
            index_key_path: data_path.join("search-index.key"),
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

struct Bot {
    index: Arc<SearchIndex>,
    event_lock: tokio::sync::Mutex<()>,
}

struct SearchIndex {
    connection: Mutex<Connection>,
    key: [u8; 32],
}

#[derive(Clone, Debug, Deserialize)]
struct SearchDocument {
    source_id: String,
    source_kind: String,
    timestamp: i64,
    #[serde(default)]
    is_media: bool,
    #[serde(default)]
    text: String,
    #[serde(default)]
    ocr_media: Vec<OcrMediaRef>,
}

#[derive(Clone, Debug, Deserialize)]
struct OcrMediaRef {
    url: String,
    key: String,
    iv: String,
    sha256: String,
    #[serde(default)]
    name: String,
    #[serde(default)]
    mime_type: String,
}

#[derive(Debug, Serialize)]
struct SearchHit {
    source_id: String,
    source_kind: String,
    timestamp: i64,
    is_media: bool,
}

impl SearchIndex {
    fn open(database_path: &Path, key_path: &Path) -> Result<Self> {
        if let Some(parent) = database_path.parent() {
            fs::create_dir_all(parent)?;
        }
        let key = load_or_create_key(key_path)?;
        let connection = Connection::open(database_path)?;
        connection.execute_batch(
            "
            PRAGMA journal_mode=WAL;
            PRAGMA foreign_keys=ON;
            CREATE TABLE IF NOT EXISTS documents (
                room_id TEXT NOT NULL,
                source_kind TEXT NOT NULL,
                source_id TEXT NOT NULL,
                timestamp INTEGER NOT NULL,
                is_media INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (room_id, source_kind, source_id)
            ) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS tokens (
                room_id TEXT NOT NULL,
                source_kind TEXT NOT NULL,
                source_id TEXT NOT NULL,
                token_hash BLOB NOT NULL,
                PRIMARY KEY (room_id, source_kind, source_id, token_hash),
                FOREIGN KEY (room_id, source_kind, source_id)
                    REFERENCES documents(room_id, source_kind, source_id)
                    ON DELETE CASCADE
            ) WITHOUT ROWID;
            CREATE INDEX IF NOT EXISTS tokens_by_room_hash
                ON tokens(room_id, token_hash);
            CREATE INDEX IF NOT EXISTS documents_by_room_time
                ON documents(room_id, timestamp DESC);
            ",
        )?;
        Ok(Self { connection: Mutex::new(connection), key })
    }

    fn reset_room(&self, room_id: &str) -> Result<()> {
        self.connection
            .lock()
            .expect("search database mutex poisoned")
            .execute("DELETE FROM documents WHERE room_id = ?1", [room_id])?;
        Ok(())
    }

    fn count_room(&self, room_id: &str) -> Result<i64> {
        Ok(self
            .connection
            .lock()
            .expect("search database mutex poisoned")
            .query_row(
                "SELECT COUNT(*) FROM documents WHERE room_id = ?1",
                [room_id],
                |row| row.get(0),
            )?)
    }

    fn upsert_documents(&self, room_id: &str, documents: &[SearchDocument]) -> Result<()> {
        let mut connection = self.connection.lock().expect("search database mutex poisoned");
        let transaction = connection.transaction()?;
        for document in documents {
            transaction.execute(
                "INSERT INTO documents(room_id, source_kind, source_id, timestamp, is_media)
                 VALUES(?1, ?2, ?3, ?4, ?5)
                 ON CONFLICT(room_id, source_kind, source_id) DO UPDATE SET
                   timestamp = excluded.timestamp,
                   is_media = excluded.is_media",
                params![
                    room_id,
                    document.source_kind,
                    document.source_id,
                    document.timestamp,
                    i64::from(document.is_media),
                ],
            )?;
            transaction.execute(
                "DELETE FROM tokens
                 WHERE room_id = ?1 AND source_kind = ?2 AND source_id = ?3",
                params![room_id, document.source_kind, document.source_id],
            )?;
            for token in index_tokens(&document.text) {
                transaction.execute(
                    "INSERT OR IGNORE INTO tokens(
                        room_id, source_kind, source_id, token_hash
                     ) VALUES(?1, ?2, ?3, ?4)",
                    params![
                        room_id,
                        document.source_kind,
                        document.source_id,
                        self.hash_token(room_id, &token).to_vec(),
                    ],
                )?;
            }
        }
        transaction.commit()?;
        Ok(())
    }

    fn remove_document(&self, room_id: &str, source_kind: &str, source_id: &str) -> Result<()> {
        self.connection
            .lock()
            .expect("search database mutex poisoned")
            .execute(
                "DELETE FROM documents
                 WHERE room_id = ?1 AND source_kind = ?2 AND source_id = ?3",
                params![room_id, source_kind, source_id],
            )?;
        Ok(())
    }

    fn search(&self, room_id: &str, query: &str, media_only: bool, limit: usize) -> Result<Vec<SearchHit>> {
        let query_words = query_words(query);
        if query_words.is_empty() {
            return Ok(Vec::new());
        }
        let hashes = query_words
            .iter()
            .map(|word| {
                let chars = word.chars().collect::<Vec<_>>();
                let query_token = if chars.len() <= 3 {
                    format!("s:{word}")
                } else {
                    let prefix: String = chars.into_iter().take(24).collect();
                    format!("p:{prefix}")
                };
                self.hash_token(room_id, &query_token).to_vec()
            })
            .collect::<Vec<_>>();
        let placeholders = std::iter::repeat_n("?", hashes.len()).collect::<Vec<_>>().join(",");
        let media_clause = if media_only { " AND d.is_media = 1" } else { "" };
        let sql = format!(
            "SELECT d.source_id, d.source_kind, d.timestamp, d.is_media
             FROM documents d
             JOIN tokens t
               ON t.room_id = d.room_id
              AND t.source_kind = d.source_kind
              AND t.source_id = d.source_id
             WHERE d.room_id = ?
               AND t.token_hash IN ({placeholders}){media_clause}
             GROUP BY d.room_id, d.source_kind, d.source_id
             HAVING COUNT(DISTINCT t.token_hash) = ?
             ORDER BY d.timestamp DESC
             LIMIT ?"
        );
        let mut values = vec![SqlValue::Text(room_id.to_owned())];
        values.extend(hashes.into_iter().map(SqlValue::Blob));
        values.push(SqlValue::Integer(query_words.len() as i64));
        values.push(SqlValue::Integer(limit.clamp(1, 200) as i64));

        let connection = self.connection.lock().expect("search database mutex poisoned");
        let mut statement = connection.prepare(&sql)?;
        let rows = statement.query_map(params_from_iter(values), |row| {
            Ok(SearchHit {
                source_id: row.get(0)?,
                source_kind: row.get(1)?,
                timestamp: row.get(2)?,
                is_media: row.get::<_, i64>(3)? != 0,
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    fn hash_token(&self, room_id: &str, token: &str) -> [u8; 32] {
        let mut digest = Sha256::new();
        digest.update(self.key);
        digest.update(room_id.as_bytes());
        digest.update([0]);
        digest.update(token.as_bytes());
        digest.finalize().into()
    }
}

fn load_or_create_key(path: &Path) -> Result<[u8; 32]> {
    if path.exists() {
        let bytes = fs::read(path)?;
        return bytes
            .try_into()
            .map_err(|_| anyhow::anyhow!("search index key must contain exactly 32 bytes"));
    }
    let mut key = [0u8; 32];
    rand::rng().fill_bytes(&mut key);
    fs::write(path, key)?;
    Ok(key)
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "patrick_messenger_search=info,warn".into()),
        )
        .init();

    let config = Config::from_env()?;
    let index = Arc::new(SearchIndex::open(&config.index_path, &config.index_key_path)?);
    let client = Client::builder()
        .homeserver_url(&config.homeserver_url)
        .sqlite_store(&config.store_path, Some(&config.store_passphrase))
        .build()
        .await
        .context("building Search's encrypted Matrix client")?;

    client
        .matrix_auth()
        .login_username(&config.matrix_user, &config.matrix_password)
        .device_id("PATRICK_MESSENGER_SEARCH")
        .initial_device_display_name("Search")
        .send()
        .await
        .context("logging Search into Matrix")?;
    client.account().set_display_name(Some("Search")).await?;

    client.add_event_handler_context(Arc::new(Bot {
        index,
        event_lock: tokio::sync::Mutex::new(()),
    }));
    client.add_event_handler(on_invite);
    let response = client.sync_once(SyncSettings::default()).await?;
    client.add_event_handler(on_timeline_event);
    info!(user = %client.user_id().expect("logged-in user"), "Search is ready");
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
                    warn!(room = %room.room_id(), %error, "Search join failed; retrying");
                    sleep(Duration::from_secs(delay)).await;
                    delay *= 2;
                }
                Err(error) => {
                    error!(room = %room.room_id(), %error, "Search could not join invited room");
                    return;
                }
            }
        }
        sleep(Duration::from_secs(1)).await;
        if !room
            .latest_encryption_state()
            .await
            .is_ok_and(|state| state.is_encrypted())
        {
            warn!(room = %room.room_id(), "Search left an unencrypted room");
            let _ = room.leave().await;
        } else {
            info!(room = %room.room_id(), "Search joined encrypted conversation");
        }
    });
}

async fn on_timeline_event(
    _event: AnySyncTimelineEvent,
    room: Room,
    client: Client,
    Ctx(bot): Ctx<Arc<Bot>>,
    raw: RawEvent,
) {
    if room.state() != RoomState::Joined {
        return;
    }
    let Ok(value) = serde_json::from_str::<Value>(raw.get()) else {
        return;
    };
    let sender = value.get("sender").and_then(Value::as_str).unwrap_or_default();
    if sender == client.user_id().expect("logged-in user").as_str() {
        return;
    }
    let event_type = value.get("type").and_then(Value::as_str).unwrap_or_default();
    let content = value.get("content").cloned().unwrap_or_else(|| json!({}));
    let room_id = room.room_id().as_str();
    let _event_guard = bot.event_lock.lock().await;

    let result = match event_type {
        RESET_EVENT => bot.index.reset_room(room_id),
        BATCH_EVENT => process_batch(&bot.index, &client, room_id, &content).await,
        COMMIT_EVENT => process_commit(&bot.index, &room, room_id, &content).await,
        QUERY_EVENT => process_query(&bot.index, &room, room_id, &content).await,
        LEAVE_EVENT => process_leave(&bot.index, &room, room_id).await,
        "m.room.message" | "m.sticker" => {
            index_live_message(&bot.index, &client, room_id, &value).await
        }
        "m.room.redaction" => process_redaction(&bot.index, room_id, &value),
        ARCHIVE_OVERLAY_EVENT => process_archive_overlay(&bot.index, room_id, &content),
        _ => Ok(()),
    };
    if let Err(error) = result {
        error!(room = %room.room_id(), event_type, %error, "Search event failed");
    }
}

async fn process_batch(
    index: &SearchIndex,
    client: &Client,
    room_id: &str,
    content: &Value,
) -> Result<()> {
    let mut documents: Vec<SearchDocument> = serde_json::from_value(
        content.get("documents").cloned().unwrap_or_else(|| json!([])),
    )?;
    for document in &mut documents {
        append_server_ocr(client, document).await;
    }
    index.upsert_documents(room_id, &documents)
}

async fn process_commit(index: &SearchIndex, room: &Room, room_id: &str, content: &Value) -> Result<()> {
    let session_id = content.get("session_id").and_then(Value::as_str).unwrap_or_default();
    let count = index.count_room(room_id)?;
    room.send_raw(
        READY_EVENT,
        json!({"session_id": session_id, "document_count": count}),
    )
    .await?;
    info!(room = %room.room_id(), count, "Search backfill complete");
    Ok(())
}

async fn process_query(index: &SearchIndex, room: &Room, room_id: &str, content: &Value) -> Result<()> {
    let request_id = content.get("request_id").and_then(Value::as_str).unwrap_or_default();
    let query = content.get("query").and_then(Value::as_str).unwrap_or_default();
    let media_only = content.get("media_only").and_then(Value::as_bool).unwrap_or(false);
    let limit = content.get("limit").and_then(Value::as_u64).unwrap_or(100) as usize;
    let results = index.search(room_id, query, media_only, limit)?;
    room.send_raw(
        RESULTS_EVENT,
        json!({"request_id": request_id, "results": results}),
    )
    .await?;
    Ok(())
}

async fn process_leave(index: &SearchIndex, room: &Room, room_id: &str) -> Result<()> {
    index.reset_room(room_id)?;
    info!(room = %room.room_id(), "Search index deleted; leaving room");
    room.leave().await?;
    Ok(())
}

async fn index_live_message(
    index: &SearchIndex,
    client: &Client,
    room_id: &str,
    event: &Value,
) -> Result<()> {
    let content = event.get("content").cloned().unwrap_or_else(|| json!({}));
    let relation = content.get("m.relates_to");
    let replacement = relation
        .and_then(|value| value.get("rel_type"))
        .and_then(Value::as_str)
        == Some("m.replace");
    let source_id = if replacement {
        relation
            .and_then(|value| value.get("event_id"))
            .and_then(Value::as_str)
            .unwrap_or_default()
    } else {
        event.get("event_id").and_then(Value::as_str).unwrap_or_default()
    };
    if source_id.is_empty() {
        return Ok(());
    }
    let searchable_content = if replacement {
        content.get("m.new_content").unwrap_or(&content)
    } else {
        &content
    };
    let text = [
        searchable_content.get("body").and_then(Value::as_str).unwrap_or_default(),
        searchable_content.get("filename").and_then(Value::as_str).unwrap_or_default(),
        searchable_content.get(MEDIA_OCR_KEY).and_then(Value::as_str).unwrap_or_default(),
    ]
    .into_iter()
    .filter(|part| !part.trim().is_empty())
    .collect::<Vec<_>>()
    .join("\n");
    if text.is_empty() {
        return Ok(());
    }
    let msgtype = searchable_content.get("msgtype").and_then(Value::as_str).unwrap_or("m.text");
    let mut document = SearchDocument {
        source_id: source_id.to_owned(),
        source_kind: "matrix".to_owned(),
        timestamp: event
            .get("origin_server_ts")
            .and_then(Value::as_i64)
            .unwrap_or_default(),
        is_media: msgtype != "m.text",
        text,
        ocr_media: if searchable_content
            .get(MEDIA_OCR_KEY)
            .and_then(Value::as_str)
            .is_some_and(|text| !text.trim().is_empty())
        {
            Vec::new()
        } else {
            ocr_media_from_matrix_content(searchable_content).into_iter().collect()
        },
    };
    append_server_ocr(client, &mut document).await;
    index.upsert_documents(room_id, &[document])
}

fn ocr_media_from_matrix_content(content: &Value) -> Option<OcrMediaRef> {
    let file = content.get("file")?;
    let key = file.get("key")?.get("k")?.as_str()?;
    let sha256 = file.get("hashes")?.get("sha256")?.as_str()?;
    Some(OcrMediaRef {
        url: file.get("url")?.as_str()?.to_owned(),
        key: key.to_owned(),
        iv: file.get("iv")?.as_str()?.to_owned(),
        sha256: sha256.to_owned(),
        name: content.get("body").and_then(Value::as_str).unwrap_or_default().to_owned(),
        mime_type: content
            .get("info")
            .and_then(|value| value.get("mimetype"))
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned(),
    })
}

async fn append_server_ocr(client: &Client, document: &mut SearchDocument) {
    for media in &document.ocr_media {
        if !media.mime_type.is_empty() && !media.mime_type.starts_with("image/") {
            continue;
        }
        match recognize_media(client, media).await {
            Ok(Some(text)) => {
                if !document.text.is_empty() {
                    document.text.push('\n');
                }
                document.text.push_str(&text);
            }
            Ok(None) => {}
            Err(error) => warn!(file = %media.name, %error, "Server picture OCR failed"),
        }
    }
}

async fn recognize_media(client: &Client, media: &OcrMediaRef) -> Result<Option<String>> {
    let encrypted_file: EncryptedFile = serde_json::from_value(json!({
        "url": media.url,
        "key": {
            "kty": "oct",
            "key_ops": ["encrypt", "decrypt"],
            "alg": "A256CTR",
            "k": media.key,
            "ext": true
        },
        "iv": media.iv,
        "hashes": {"sha256": media.sha256},
        "v": "v2"
    }))?;
    let request = MediaRequestParameters {
        source: MediaSource::Encrypted(Box::new(encrypted_file)),
        format: MediaFormat::File,
    };
    let bytes = client.media().get_media_content(&request, false).await?;
    tokio::task::spawn_blocking(move || recognize_with_tesseract(&bytes))
        .await
        .context("joining the OCR worker")?
}

fn recognize_with_tesseract(bytes: &[u8]) -> Result<Option<String>> {
    let mut child = Command::new("tesseract")
        .args(["stdin", "stdout", "--psm", "11", "-l", "eng"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .context("starting Tesseract")?;
    child
        .stdin
        .take()
        .context("opening Tesseract input")?
        .write_all(bytes)?;
    let output = child.wait_with_output()?;
    if !output.status.success() {
        return Ok(None);
    }
    let text = String::from_utf8_lossy(&output.stdout).trim().to_owned();
    Ok((!text.is_empty()).then_some(text))
}

fn process_redaction(index: &SearchIndex, room_id: &str, event: &Value) -> Result<()> {
    if let Some(redacts) = event.get("redacts").and_then(Value::as_str) {
        index.remove_document(room_id, "matrix", redacts)?;
    }
    Ok(())
}

fn process_archive_overlay(index: &SearchIndex, room_id: &str, content: &Value) -> Result<()> {
    let Some(source_id) = content.get("archive_id").and_then(Value::as_str) else {
        return Ok(());
    };
    match content.get("action").and_then(Value::as_str) {
        Some("delete") => index.remove_document(room_id, "archive", source_id),
        Some("edit") => {
            let text = content.get("body").and_then(Value::as_str).unwrap_or_default();
            if text.is_empty() {
                return Ok(());
            }
            let timestamp = index
                .connection
                .lock()
                .expect("search database mutex poisoned")
                .query_row(
                    "SELECT timestamp FROM documents
                     WHERE room_id = ?1 AND source_kind = 'archive' AND source_id = ?2",
                    params![room_id, source_id],
                    |row| row.get(0),
                )
                .optional()?
                .unwrap_or_default();
            index.upsert_documents(
                room_id,
                &[SearchDocument {
                    source_id: source_id.to_owned(),
                    source_kind: "archive".to_owned(),
                    timestamp,
                    is_media: false,
                    text: text.to_owned(),
                    ocr_media: Vec::new(),
                }],
            )
        }
        _ => Ok(()),
    }
}

fn query_words(input: &str) -> Vec<String> {
    let normalized = normalize(input);
    let mut seen = HashSet::new();
    normalized
        .split_whitespace()
        .filter(|word| word.chars().count() >= 2)
        .filter(|word| seen.insert((*word).to_owned()))
        .map(str::to_owned)
        .collect()
}

fn index_tokens(input: &str) -> HashSet<String> {
    let mut tokens = HashSet::new();
    for word in query_words(input) {
        let chars = word.chars().collect::<Vec<_>>();
        let end = chars.len().min(24);
        tokens.insert(format!("w:{word}"));
        for length in 2..=end {
            tokens.insert(format!("p:{}", chars[..length].iter().collect::<String>()));
        }
        for length in 2..=chars.len().min(3) {
            for start in 0..=chars.len() - length {
                tokens.insert(format!(
                    "s:{}",
                    chars[start..start + length].iter().collect::<String>()
                ));
            }
        }
    }
    tokens
}

fn normalize(value: &str) -> String {
    const PUNCTUATION: &str = ".,!?;:\"'`()[]{}<>/\\|@#$%^&*+=~_-";
    let mut normalized = String::with_capacity(value.len());
    for character in value.to_lowercase().chars() {
        if character.is_whitespace() || PUNCTUATION.contains(character) {
            normalized.push(' ');
        } else {
            normalized.push(character);
        }
    }
    normalized.split_whitespace().collect::<Vec<_>>().join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn creates_prefix_tokens() {
        let tokens = index_tokens("Hello, world!");
        assert!(tokens.contains("p:he"));
        assert!(tokens.contains("p:hello"));
        assert!(tokens.contains("w:world"));
        assert!(tokens.contains("s:ell"));
    }

    #[test]
    fn query_words_match_client_normalization() {
        assert_eq!(query_words("  Two-WORDS two "), ["two", "words"]);
    }
}
