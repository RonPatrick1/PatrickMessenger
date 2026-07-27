# Local private homeserver

This directory starts a development Synapse homeserver bound to
`127.0.0.1:8008` and the Ubuntu workstation's private-LAN address,
`192.168.0.178:8008`. The LAN binding exists only for physical-device
development and must never be forwarded through the router. The server is
deliberately:

- closed to public registration and guests;
- non-federated;
- configured to create encrypted rooms by default;
- configured without URL previews, server-side search, presence, analytics,
  or analytics. Push notifications are disabled until the optional private
  Sygnal service is configured below.

Start it from the repository root:

```sh
./server/bootstrap.sh
./server/create-user.sh
./server/setup-liam.sh
./server/setup-search.sh
```

Run `create-user.sh` for each initial development account. Do not reuse
important passwords in this development instance.

`setup-liam.sh` generates an ignored `server/.env`, creates the non-admin
`@liam:matrix.patrick-lamphier.com` account, builds the encrypted Matrix bot,
and starts it beside Synapse. It is safe to run again: existing private
credentials and the persistent encrypted bot store are retained. The bot is
available to every authenticated account; there is no user allowlist.

`setup-search.sh` likewise creates the non-admin
`@search:matrix.patrick-lamphier.com` account and its persistent encrypted
Matrix device. Search joins only rooms where a member explicitly adds it. Its
durable index stores keyed token hashes, Matrix/archive message identifiers,
timestamps, and media flags—not message text or media. Historical searchable
text travels to it only inside encrypted room events. Any room member can tell
Search to delete that room's index and leave.

The generated `server/data` directory contains signing keys, the registration
secret, message metadata, encrypted message events, and uploaded encrypted
media. It is ignored by Git and must never be committed.

This compose setup uses SQLite because it is a local development service.
Before deploying to `matrix.patrick-lamphier.com`, move Synapse to PostgreSQL,
put Caddy or nginx in front of it with HTTPS, add tested backups, and continue
to expose only the Matrix client endpoints.

On the current Ubuntu host, install the narrow public HTTPS client proxy with:

```sh
sudo ./server/install-public-matrix-proxy.sh
```

This adds only `/_matrix/client/` and the compatible `/_matrix/media/` path to
the existing `patrick-lamphier.com` TLS server, plus the exact Matrix push
gateway endpoint when Sygnal is enabled. It validates nginx before reloading
and does not expose raw port 8008, federation, administration, or Ollama.

## Apple push notifications

Locked-screen delivery requires APNs; the local notification test in the app
cannot wake a suspended iPhone. In the Apple Developer portal, enable Push
Notifications for the explicit App ID
`com.patricklamphier.patrickMessenger`, create an APNs authentication key, and
download its `.p8` file. Apple permits that private key to be downloaded only
once. Keep it outside the repository.

For an iPhone installed directly from Xcode, deploy Sygnal in the APNs sandbox
environment on the Ubuntu host that runs Synapse:

```sh
APNS_KEY_FILE=/secure/path/AuthKey_KEYID.p8 \
APNS_KEY_ID=YOUR_KEY_ID \
APNS_TEAM_ID=Q3UFU92XZG \
APNS_PLATFORM=sandbox \
./server/setup-apple-push.sh

sudo ./server/install-public-matrix-proxy.sh
./server/verify-apple-push.sh
```

Use `APNS_PLATFORM=production` only for TestFlight, App Store, or another
distribution-signed build. A sandbox token cannot be delivered through the
production APNs endpoint, or vice versa.

After changing the App ID capability or APNs environment, refresh automatic
signing in Xcode, delete the old copy from the iPhone, and reinstall from
`ios/Runner.xcworkspace`. Launch the app, sign in, and enable **Message
notifications** in Account settings. Also enable Allow Notifications, Lock
Screen, and Sounds under the iPhone's Patrick Messenger notification settings.

The built-in test button proves only that iOS permission and local alerts
work. For the end-to-end test, lock the iPhone and send a message from a
different Matrix account. Follow the server side while testing:

```sh
docker compose -f server/compose.yaml --profile push logs -f synapse sygnal
```

If Sleep Focus is active, add Patrick Messenger to that Focus's allowed apps.
Ordinary Apple Watch notification mirroring needs no watchOS target: enable
Patrick Messenger under Watch app > My Watch > Notifications. When the iPhone
is locked and the paired watch is connected, unlocked, and on the wrist, Apple
normally presents the alert on the watch instead of the phone. The remote
payload remains generic and does not contain decrypted message text.
