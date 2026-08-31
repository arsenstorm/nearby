# Privacy Policy for Nearby

**Last updated:** August 31, 2026

Nearby lets iPhones talk in an encrypted voice room. Calls between phones that
are physically close use no server. Calls to friends over the internet use our
server to connect the phones. This policy covers both.

## Calls between nearby phones

Phones that are close find each other over the local network, Wi‑Fi Aware or
Bluetooth. Voice and names travel directly between the phones, end‑to‑end
encrypted. No server is involved. We receive nothing.

## Calls over the internet

You can call a friend who is not nearby. These calls use our server (a
Cloudflare Worker) so the two phones can find each other. When no direct path
exists between the phones, the call goes through a relay on Cloudflare. The
relay needs the Nearby subscription.

Voice on internet calls stays end‑to‑end encrypted. The server and the relay
forward encrypted packets. They cannot read or hear them. Like any internet
service, they see your IP address while you are connected. We do not store IP
addresses.

## What we store

Your app creates a random node ID. The node ID is not tied to your name,
email or Apple ID. For internet calls, our server stores two things under
your node ID:

- **Relay minutes used this calendar month**, to enforce the monthly relay
  allowance. This record is deleted after about 40 days.
- **A device attestation key** (Apple App Attest), to keep fraudulent
  clients off the relay.

We store nothing else: no names, no contacts, no audio, no call history and
no IP addresses. There are no analytics, no advertising identifiers and no
ads.

## Subscription

Apple bills the relay subscription. Our server examines the subscription
receipt to grant relay access, but does not store it.

## What stays on your phone

- **Your name**, if you set one, so others in a room can see who's talking.
- **A device key pair** used to encrypt conversations and derive your node ID.
- **Your friends and blocked lists.**

All three live only on your phone. They are removed when you delete the app.

## Permissions

- **Microphone** — to send your voice to the room.
- **Local Network** — to find phones on the same Wi‑Fi.
- **Bluetooth** — to reach phones that don't share a Wi‑Fi network.

## Contact

Questions about this policy: **arsen@shkrumelyak.com**
