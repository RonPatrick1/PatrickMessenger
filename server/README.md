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
  or push notifications.

Start it from the repository root:

```sh
./server/bootstrap.sh
./server/create-user.sh
./server/setup-liam.sh
```

Run `create-user.sh` for each initial development account. Do not reuse
important passwords in this development instance.

`setup-liam.sh` generates an ignored `server/.env`, creates the non-admin
`@liam:matrix.patrick-lamphier.com` account, builds the encrypted Matrix bot,
and starts it beside Synapse. It is safe to run again: existing private
credentials and the persistent encrypted bot store are retained. The bot is
available to every authenticated account; there is no user allowlist.

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
the existing `patrick-lamphier.com` TLS server. It validates nginx before
reloading and does not expose raw port 8008, federation, administration, or
Ollama.
