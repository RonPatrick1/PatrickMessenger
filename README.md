# Patrick Messenger

Patrick Messenger is a private, multi-device messenger for Android,
iPhone/iPad, macOS, Ubuntu, Apple Watch, and Wear OS. It is intended for a
general App Store and Google Play release, not a hardcoded family or account
allowlist. The project uses Matrix for message synchronization and Vodozemac
for end-to-end encryption while keeping the homeserver under the operator's
control.

The first milestone currently provides:

- generated Flutter projects for Android, iOS, macOS, and Linux;
- login restricted to the configured private homeserver;
- restored sessions and multi-device Matrix identities;
- encrypted, non-federated one-to-one rooms;
- encrypted text, picture, and animated GIF messages;
- emoji picking, emoji reactions, replies, edits, forwarding, copying,
  multi-select, shared pins, message information, and delete-for-everyone;
- human-readable Matrix display names and renameable conversations;
- encrypted picture sending from the system clipboard;
- private local Ollama questions through the optional Liam assistant;
- encrypted message-history recovery for adding new devices;
- encrypted Signal-history import with original dates and media;
- optional shared encrypted search across messages, filenames, captions, and
  server-side picture OCR, with private text search as the fallback;
- per-conversation decrypted ZIP exports with readable history and media;
- sent, delivered, and read indicators with per-member group counts;
- persistent System, Light, and Dark appearance choices;
- per-device message notification, sound, lock-screen-preview, and
  cross-device-read choices;
- a local, privacy-hardened Synapse development server;
- an enforced privacy policy for future Apple Watch and Wear OS previews.

This is not production-ready yet. Device verification, application-level
database encryption, push delivery, native watch companions, production
hosting, and an independent security review remain required.

## Start the local server

Docker 29+ with the Compose plugin is required.

```sh
./server/bootstrap.sh
./server/create-user.sh
./server/create-user.sh
./server/setup-liam.sh
./server/setup-search.sh
```

Create one development account for each person. The server name is fixed at
`matrix.patrick-lamphier.com`, even though local development connects through
port 8008.

## Run the client

Flutter 3.44.6 is installed at
`~/.local/share/flutter-3.44.6`. Add the local tools to the shell:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

On this Ubuntu workstation, install the standard Flutter Linux build
prerequisites before the first desktop build:

```sh
sudo apt install \
  clang cmake libgtk-3-dev liblzma-dev libstdc++-12-dev \
  ninja-build pkg-config rustup
rustup default stable
```

Copy `dart_define.env.example` to `dart_define.env` and fill in your own
GIPHY_API_KEY (see "Public GIF search" below). That file is gitignored, so it
never enters the repository. Then run:

```sh
flutter run -d linux --dart-define-from-file=dart_define.env
```

The installed Ubuntu launcher runs the built Linux bundle. After rebuilding,
close and reopen **Patrick Messenger** from the Ubuntu app screen.

The Ubuntu launcher uses the same centered application artwork as the Apple
and Android builds. Install or refresh its user-local launcher and icon theme
without `sudo`:

```sh
desktop-file-install --dir="$HOME/.local/share/applications" \
  linux/packaging/com.patricklamphier.patrick_messenger.desktop
cp -R linux/icons/hicolor/. "$HOME/.local/share/icons/hicolor/"
gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor"
update-desktop-database "$HOME/.local/share/applications"
```

Every client uses the single public HTTPS endpoint at
`https://patrick-lamphier.com`; the login screen does not expose a server
selector. Matrix account IDs use the server name
`matrix.patrick-lamphier.com`.

On desktop, Enter sends the current message and Shift+Enter or Control+Enter
inserts a newline. A hardware keyboard connected to an Android phone/tablet,
iPhone, or iPad—including the Mac keyboard driving the iOS Simulator—uses the
same shortcuts. A phone or tablet's on-screen Return key retains its normal
multiline behavior, and the visible Send button sends the message. The input
box grows from one through five visible lines, then scrolls internally rather
than taking over the chat window.

Use the appearance button on the login or Messages screen to choose System,
Light, or Dark. The choice is stored separately on each device.

### Encrypted history on a new device

From a device that already has readable messages, open the cloud-history
button on the Messages screen and turn on encrypted history sync. Enter the
Matrix account password to authorize setup, choose a separate recovery
passphrase, and save the displayed recovery key. Passwords are not stored.

On a new device, sign in to the same account and open the cloud-history
button. Enter the recovery passphrase or recovery key. The app downloads the
complete encrypted event history from the private server and restores the
room keys needed to read it. Each person enables recovery for their own
Matrix account. A recovery backup for one person cannot restore another
person's keys. If a backup was never enabled, turn it on from a device that can
still read the older messages; messages whose keys no longer exist on any
device cannot be decrypted retroactively.

Each message now has a visible `…` action button. Right-clicking or
long-pressing a message opens the same menu. Edit applies to the current user's
own text messages; Delete for everyone applies to messages that the current
user has permission to redact. On iPhone and Android this menu opens as a
touch-friendly bottom sheet.

Use **Account settings** in the account menu on the Messages screen to set the
display name, change the Matrix account password, and set this device's
notification choices. A user can sign in with the temporary password supplied
when the account was created, then replace it without disclosing the new
password to the server administrator. Other signed-in Patrick Messenger
devices remain connected. Notifications and the system default sound can each
be enabled or disabled. Message previews default to off, so a lock screen says
only that a new encrypted message arrived; turn previews on to include the
readable sender and message text. **Notify after reading elsewhere** controls
whether this device still alerts after another client has advanced the
account's read marker. **Send test notification** requests the phone's OS
permission when needed and verifies the current sound choice.

Read receipts are enabled by default and can be disabled in the same Account
settings dialog. Sent messages use one circled check, delivered messages use
two outlined circled checks, and read messages use two filled circled checks.
In a group, a partial status also shows the number of recipients who have
delivered or read the message. This receipt metadata is sent inside the
encrypted room; the server does not receive message text.

### Import Signal history

The importer stores Signal history as encrypted, versioned archive chunks in
the existing Matrix room. Clients merge those records with normal Matrix
events by their original timestamp, so imported text and media appear in the
correct part of the conversation rather than as thousands of new messages.
Edits, reactions, replies, forwarding, copying, information, and
delete-for-everyone use small encrypted overlay events and do not rewrite the
original archive.

First validate an export without uploading anything:

```sh
dart run tooling/import_signal_history.dart \
  --source /home/ronpatrick/Documents/Elizabeth/signal-export-2026-07-22-07-22-23 \
  --scan-only
```

Then perform the resumable import. It asks for Ron's Matrix password without
echoing it and asks for confirmation before uploading. The importer uses its
own Matrix device and keeps a private checkpoint under
`~/.patrick-messenger-import/`, so rerunning the same command resumes rather
than duplicating uploaded media.

```sh
dart run tooling/import_signal_history.dart \
  --source /home/ronpatrick/Documents/Elizabeth/signal-export-2026-07-22-07-22-23
```

Picture OCR is performed locally with Tesseract when available. Use
`--skip-ocr` only if searchable text inside imported pictures is not wanted.
No Signal export text is sent to an OCR cloud service.

### Search

Use the search button on the Messages screen to search every conversation, or
the search button inside a chat to restrict results to that chat. The Media
filter searches filenames, captions, and text recognized in pictures by the
authorized Search service.
Opening a result returns to the message in context. Account settings includes
a **Rebuild search index** button for a full rescan of encrypted history.

By default, each device keeps its own private search index. In a chat's plus
menu, **Add shared Search** adds the dedicated Search Matrix participant and
securely backfills the complete history that the current device can decrypt.
After that, every authorized device can search without separately rebuilding
the entire index. **Rebuild shared Search** refreshes the historical index and
**Remove shared Search** deletes that room's shared index and asks Search to
leave. These controls work in one-to-one and group conversations and are
available to every room member.

Search requests and backfill records are custom end-to-end encrypted Matrix
events. For picture OCR, the client passes the already-uploaded encrypted media
reference and its key to Search inside that encrypted event. Search downloads,
decrypts, and recognizes the picture on the server; phones do not run OCR or
re-upload the picture. The separate search index stores keyed token hashes,
message IDs, timestamps, and media flags—not plaintext bodies or pictures.
Candidate results contain IDs only and the requesting device decrypts the
matching message for display. Search is nevertheless an authorized room
participant while enabled: it receives room keys and can decrypt messages just
like any other participant. Removing it prevents future access but cannot undo
access it already had. Chats without Search continue using a private local text
index for message text, captions, and filenames, but picture OCR requires the
shared Search service.

### Export a conversation

Open a conversation and use the download button in its header. Patrick
Messenger loads the room's full server history, merges in imported Signal
history at its original timestamps, and creates a ZIP containing a readable
transcript, one structured JSON record per message, a manifest, and every
attachment the current device can download and decrypt. Ubuntu, macOS, and
Windows ask where to save it; iPhone/iPad and Android open the system share
sheet so it can be saved or sent to another app.

The ZIP is deliberately a portable, decrypted copy. It is no longer protected
by Matrix end-to-end encryption, so the app warns before export and reports
media or messages that the current device could not decrypt. Store exported
ZIPs somewhere private and protected.

Computer-style account names such as `ron_patrick` are displayed as
`Ron Patrick` until a display name is chosen. Use the pencil button in a
conversation header to rename that conversation.

The current local notification path works whenever the client is alive and its
Matrix synchronization receives the event. A message sent from another device
logged into the same Matrix account is included; only the exact device that
sent the message suppresses its own notification. Each installation can also
choose whether a read marker from another device suppresses its alert. Reliable
delivery after iOS
or Android suspends or terminates the app still requires the production
APNs/FCM push gateway described in the architecture; local notifications alone
cannot wake a stopped phone app. The direct-from-Xcode APNs sandbox deployment
and locked-iPhone verification steps are in
[`server/README.md`](server/README.md#apple-push-notifications).

With the message field focused, Control+V on Ubuntu or Command+V on macOS/iOS
hardware keyboards sends a copied PNG, JPEG, GIF, or WebP picture through the
same encrypted attachment path as the picture picker. If the clipboard contains
text instead, it is inserted normally. **Paste picture** is also available from
the attachment menu.

The Ubuntu runner remembers the last monitor, ordinary size and position,
maximized state, and GNOME left/right snapped geometry. It stores this local
desktop preference in
`~/.config/patrick-messenger/window-state.ini`. If the saved monitor is no
longer connected, the window is constrained to an available monitor.

### Public GIF search

Create a beta API key in the GIPHY developer dashboard, then put it in your
local `dart_define.env` (copied from `dart_define.env.example`, gitignored):

```sh
GIPHY_API_KEY=your key
```

Every build command in this README reads that file via
`--dart-define-from-file=dart_define.env`, so the key only needs to be typed
once per machine. The same GIPHY API key works across all platforms. Do not
commit keys to the repository. The development app displays the required
GIPHY attribution and
uses a PG-13 content filter. GIPHY receives GIF searches, the workstation's
public IP address, and requests for preview/selected media. After selection,
Patrick Messenger downloads the GIF and uploads a new end-to-end-encrypted
copy to the private Matrix server.

### Ask Liam

Use **Ask Liam** in the plus menu to insert `Liam: ` into the normal message
composer, finish the question there, and send it normally. You can also type
the prefix yourself. If Liam is not in that encrypted room, the client invites
the normal Matrix account `@liam:matrix.patrick-lamphier.com` and waits for it
to join before sending the question. Liam decrypts the request as an authorized
room participant, calls Ollama locally on the Ubuntu host, and returns one
encrypted, clearly labeled Matrix answer.

This is not restricted to named accounts or a family allowlist. Any
authenticated Patrick Messenger account can invite Liam into an encrypted
one-to-one or group room. While Liam is present, every participant can see that
membership. Any participant can choose **Remove Liam**; the app sends the
public room command `Liam: leave this conversation`, and the bot leaves without
requiring moderator power.

Hiding Liam is a per-user, per-room preference synchronized across that
user's devices. It hides Liam questions and replies and installs matching
Matrix push rules, so hidden Liam chatter does not create notifications.
Other participants keep their own independent visibility choice.

Liam downloads encrypted Matrix history that its bot device is authorized and
able to decrypt until it has enough of the newest readable text to fill the
configured model context or the room history ends.
The transcript contains ordinary messages, Liam questions, and Liam answers in
their original chronological order. There are no speaker-balancing, pinned
message, or relevance-selection rules. If the transcript is too large, only
its oldest edge is removed.

Ollama is explicitly given a 32,768-token context window, with 2,048 tokens
reserved for Liam's answer. Because Ollama does not expose a tokenizer
endpoint, the bot uses a conservative 84,000-character transcript budget
to leave room for the system instructions, current question, formatting, and
answer. Pictures, GIFs, removed messages, and undecryptable events are not sent
to Ollama.

Only the Liam service has an Ollama URL. Phones and desktops never connect to
Ollama and therefore need no Ollama build setting, LAN access, or VPN route.
Keep TCP 11434 private. If Ollama moves, change `OLLAMA_URL` for the Liam
service (or give that service the existing WireGuard route) and restart it;
client applications do not need to be rebuilt.

`server/setup-liam.sh` creates private credentials in ignored `server/.env`,
registers the non-admin bot account, builds the Rust Matrix bot, and starts it.
The bot rejects unencrypted rooms. Its encrypted Matrix device store persists
under ignored `server/liam-data/`.

## Keep one shared source tree

Android, iPhone, macOS, and Ubuntu are targets of this same Flutter project.
Do not maintain a separate Apple copy of `lib/`, `pubspec.yaml`, or the tests.
Keep this project in one Git repository and clone that repository on the Mac.
Feature work is then committed once and pulled on the other computer; only
small platform-specific files under `ios/`, `macos/`, `android/`, and `linux/`
should differ where the operating systems require it.

The emoji picker runs locally. Public GIF search uses GIPHY; the app makes that
privacy boundary visible in the picker rather than suggesting those searches
are end-to-end encrypted.

If the host prerequisites are unavailable, reproduce the verified Linux build
in Docker:

```sh
docker build \
  -f tooling/linux-build.Dockerfile \
  -t patrick-messenger-linux-build:local .
docker run --rm \
  -v "$PWD:/app" \
  -v "$HOME/.local/share/flutter-3.44.6:/opt/flutter" \
  -v "$HOME/.pub-cache:/home/ubuntu/.pub-cache" \
  patrick-messenger-linux-build:local \
  flutter build linux --debug --dart-define-from-file=dart_define.env
```

The reproducible Android builder supplies API 36 and NDK 28.2 without changing
the host's system Android SDK:

```sh
docker build \
  -f tooling/android-build.Dockerfile \
  -t patrick-messenger-android-build:local .
```

## Checks

```sh
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
docker compose -f server/compose.yaml config --quiet
```

Read [architecture](docs/ARCHITECTURE.md) and the
[threat model](docs/THREAT_MODEL.md) before adding features.

## Licensing

The Matrix Dart SDK and Synapse are AGPL-licensed. Distributing an application
based on this implementation requires satisfying their license terms. The
licensing decision must be settled before any public or proprietary release.

## Android push notifications

Android uses Firebase Cloud Messaging through the existing Matrix/Sygnal push
gateway. It does not keep a permanent foreground service or show a permanent
connected notification.

Copy the Android Firebase values into the gitignored `dart_define.env` file
using the names in `dart_define.env.example`. Put the Firebase service-account
JSON at `server/push-secrets/firebase-service-account.json`, copy the Android
application block from `server/sygnal.yaml.example` into the active
`server/sygnal.yaml`, replace its Firebase project ID, and restart the Sygnal
container. When the Firebase client values are absent, the app continues to
start normally but logs that Android push is disabled.
