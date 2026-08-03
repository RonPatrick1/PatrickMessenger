# Architecture

## Data path

```text
Android / iPhone / macOS / Ubuntu
             |
     encrypted Matrix events
             |
             v
  matrix.patrick-lamphier.com
       private Synapse
             |
   ciphertext and metadata only
```

When a participant explicitly asks Liam, the encrypted room gains another
normal Matrix participant:

```text
Patrick Messenger clients
        | encrypted Matrix question/history
        v
Synapse (ciphertext only)
        | encrypted Matrix sync
        v
Liam Matrix bot on the trusted Ubuntu endpoint
        | loopback/private plaintext HTTP
        v
local Ollama
```

Synapse is not an Ollama proxy and never receives Ollama plaintext. Liam is a
dedicated Matrix device with persistent encryption keys, so exactly one
service answers a `Liam:` request regardless of how many user devices are
logged in. Clients contain no Ollama address. The bot's runtime configuration
lets Ollama move independently from Synapse and the released applications.

Any authenticated account may invite Liam into any encrypted room, including
larger groups; there is no account allowlist. Any room participant can ask it
to leave through the explicit public room command. Liam refuses unencrypted
rooms.

Shared Search follows the same explicit-participant boundary but uses its own
dedicated Matrix account and service. When a member enables it, that client
loads the history and imported archive records it can decrypt, then sends
searchable text in encrypted custom events. Search builds a separate index of
keyed token hashes, source IDs, timestamps, and media flags. New messages are
indexed as its Matrix device receives them. Queries and ID-only results also
travel as encrypted custom events; the requesting device decrypts the matched
message and verifies the text before displaying it. Search never sends chat
messages and its control traffic is excluded from notifications and receipts.
Any member can request a rebuild or removal. Removal deletes that room's index
and makes Search leave, but cannot revoke room keys or plaintext it previously
received as an authorized participant.

Each phone, tablet, and desktop is a distinct Matrix device with its own
cryptographic identity. Adding a device must eventually require verification
from an existing device. Removing a device must stop future key sharing and
rotate affected room sessions.

Synapse queues encrypted events and encrypted media. It necessarily observes
delivery metadata such as account IDs, device connections, timestamps, IP
addresses, room membership, and payload sizes. It must never receive plaintext
message bodies, pictures, media keys, or recovery secrets.

## Client

Flutter owns the shared Android, iOS, macOS, and Ubuntu user interface. The
Matrix Dart SDK provides protocol behavior, persistent synchronization, and
Olm/Megolm support. Vodozemac provides the cryptographic implementation.

The client currently:

- initializes Vodozemac before restoring a Matrix session;
- lets an authenticated user replace a temporary or current account password
  without revoking the sessions on their other Patrick Messenger devices;
- creates encrypted rooms with Matrix federation disabled;
- refuses to open unencrypted rooms;
- encrypts picture and animated GIF data before upload;
- supports Matrix reactions, replies, edits, redactions, pins, and forwarding;
- turns new decrypted Matrix timeline events into local Android, Apple, and
  Linux notifications while the client is alive, including messages sent by
  another device logged into the same account;
- stores notification enablement, default-sound, preview, and cross-device-read
  behavior locally per device, with plaintext previews disabled by default;
- keeps downloaded media in a seven-day application cache;
- uses a private on-device search index unless a room explicitly adds the
  shared Search participant;
- disables public read receipts by default.

GIPHY search and preview traffic is not end-to-end encrypted from GIPHY.
Search terms and the client IP are visible to GIPHY. Once selected, GIF bytes
are downloaded to the client and sent through the same encrypted Matrix media
path as pictures; recipients retrieve the encrypted Matrix copy instead of
contacting GIPHY.

Liam decrypts the current question and a bounded text-only transcript on the
bot endpoint, then sends them to the configured private Ollama service. It
loads the latest messages it can decrypt and supplies them in chronological
order, including earlier Liam questions and answers. It drops only the oldest
messages when the 32,768-token model window is full. Ollama does not receive
pictures, GIFs, removed messages, or undecryptable events. Ollama and the Liam
bot both receive plaintext, so their host and private network route are trusted
endpoints.

The local SQLite database currently relies on each operating system's device
and full-disk protection. Application-level database encryption is a required
production milestone.

## Server

The development server binds to `127.0.0.1:8008` for the Ubuntu client and
`192.168.0.178:8008` for trusted-LAN device testing. The firewall must continue
to restrict the LAN listener to the local subnet, and the router must not
forward this port. Its second configuration file turns off federation, public
registration, guests, presence, URL previews, server-side search,
user-directory search, analytics, and push.

The production server will require:

- PostgreSQL with tested encrypted backups;
- HTTPS at `matrix.patrick-lamphier.com`;
- a reverse proxy exposing only Matrix client endpoints;
- firewalling, patch management, log minimization, monitoring, and recovery
  drills;
- an opaque push gateway for APNs and the selected Android delivery method.

## Watches

The first watch implementation should treat a watch as a verified extension of
its paired phone:

1. The phone receives an opaque wake-up notification.
2. The phone downloads the encrypted thumbnail.
3. The phone decrypts and resizes it locally.
4. A verified OS pairing channel transfers the short-lived thumbnail.
5. The watch shows it only while unlocked and on the owner's wrist.
6. The watch erases its cached thumbnail automatically.

The watch privacy rule already exists in
`lib/watch/watch_preview_policy.dart` and is covered by tests.

Native companion projects are required:

- SwiftUI plus Watch Connectivity for Apple Watch;
- Kotlin/Compose plus the Wear OS Data Layer for the Galaxy Watch6 Classic.

Flutter remains the primary application, but watchOS is not a Flutter target
and watch interaction should not be forced through a cross-platform shim.
Independent watch operation can follow later by promoting each watch to a
separately verified Matrix device.
