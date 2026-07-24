# Threat model

## Privacy goals

Patrick Messenger is intended to protect conversation text and media from:

- the homeserver operator during routine operation;
- an attacker who obtains only the homeserver database or media directory;
- internet service providers and observers between a client and the server;
- Apple and Google push infrastructure;
- unverified watches and newly added devices;
- casual observers of a locked phone or watch.

## What remains visible

End-to-end encryption does not hide all metadata. The homeserver can observe
accounts, devices, IP addresses, room membership, connection times, message
timing, and approximate message sizes. Apple or Google can observe that an
opaque push was delivered to a particular device at a particular time.

Traffic padding, anonymity, and resistance to a global timing observer are not
goals of the first release.

## Endpoint compromise

Messages are plaintext on an authorized device while being displayed. A
compromised operating system, malicious accessibility service, third-party
keyboard, screen recording, unlocked watch, or person with physical access can
read them. End-to-end encryption cannot correct a compromised endpoint.

Inviting Liam intentionally adds a dedicated Matrix device to that encrypted
room. The Liam bot can decrypt messages delivered while it is an authorized
participant and intentionally discloses the current question, plus the
verified Matrix sender ID, to the local Liam agent bridge. The bot and bridge
hosts are therefore trusted endpoints. The bridge's HTTP port must remain
restricted to loopback, a trusted LAN, or an authenticated private tunnel and
must never be forwarded publicly. Plain HTTP does not protect that disclosure
on an untrusted local network; remote access requires a trusted VPN or HTTPS.
Unlike a stateless model call, the bridge's agent keeps real persistent
memory of each room it is used in (one isolated notes/history bucket per
room, except the one room configured to share the owner's existing global
notes). Removing Liam stops delivery of future room keys and messages to it,
but cannot make it forget plaintext it has already processed and stored.

Conversation text supplied as Liam context is treated as untrusted quoted
material in the model prompt, but prompt injection cannot be eliminated by an
instruction alone. Liam must not be given tools, secrets, or authority to
change external systems without a separate reviewed permission boundary.

Production clients must add:

- biometric or passcode application locking;
- hidden notification content by default;
- encrypted local databases and attachment caches;
- device verification and prominent verification state;
- device revocation and room-key rotation;
- a security audit of the encrypted recovery flow and its user-controlled
  recovery key;
- screenshot/app-switcher protection where operating systems permit it.

## Server compromise

A server compromise must not reveal content, but it can:

- deny, delay, replay, or delete encrypted events;
- manipulate device lists in an attempt to introduce a malicious device;
- expose metadata and encrypted history;
- replace downloadable application builds if distribution is also compromised.

Cross-device verification, signed releases, reproducible builds, backups, and
client warnings are therefore part of the security boundary.

## Current status

The repository is an engineering milestone, not an audited secure messenger.
No one should depend on it for sensitive communication until the remaining
controls are implemented and independently reviewed.
