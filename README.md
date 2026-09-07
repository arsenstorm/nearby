# Nearby

Nearby is a voice room between iPhones that are close to each other. The
phones find each other over the local network, Wi-Fi Aware, or Bluetooth.
No account is necessary. Nearby calls use no server. Friends who are far
away can also call over the internet. Those calls connect through a small
rendezvous Worker. If no direct path exists, the call goes through a TURN
relay. Nearby Plus, a subscription, pays for the relay.

> [!NOTE]
> To test the app on your iPhone, join the TestFlight beta:
> https://testflight.apple.com/join/c5UfgVpA
>
> TestFlight builds get relay access without a subscription.

## How it works

Every packet is end-to-end encrypted. Each pair of phones has a session
key, and each room has a room key. The phones form a mesh. A packet can hop
through other phones in the room, up to 8 hops.

Nearby calls use these transports:

- the local network (Bonjour), and Apple peer-to-peer Wi-Fi with the same code
- Wi-Fi Aware, for phones that went through the system pairing flow once
- Bluetooth LE, over L2CAP channels

Internet calls need a friend code. A friend code is a QR code or link that
carries the signing key of the other phone. An internet call then goes
through these steps:

1. The two phones open a WebSocket to a rendezvous room on the Worker. The
   room name is a hash of both node IDs. Each phone signs a challenge.
2. The Worker forwards signed Hellos and address candidates between the
   two phones. It cannot read the packets.
3. The phones get their public addresses from STUN and try a UDP hole
   punch. A direct call is free.
4. If the punch fails, the app asks the Worker for a relay. The Worker
   checks an App Attest proof and an Apple StoreKit receipt. Then it charges
   10 minutes from the monthly allowance of the phone and mints 10-minute
   Cloudflare TURN credentials. The app renews them over the same socket.

The Worker refuses a relay when the phone is not attested, has no
entitlement, or has no allowance left. An hourly cron reads the TURN egress
for the month from Cloudflare. If the egress passes the budget, the Worker
stops all relays until the next month.

## Layout

- `apps/ios`: the iOS app (SwiftUI, iOS 26). It contains the Xcode project,
  the Live Activity extension, and `Sources/NearbyCore`. NearbyCore is a pure
  Swift package with the wire format, routing, crypto, Opus, and session
  logic. The transports, the TURN client, and the NAT probe are in `App`.
- `apps/api`: the Cloudflare Worker (Hono). It does rendezvous, App Attest,
  StoreKit checks, the relay allowance, TURN minting, and the budget.
- `apps/web`: the pages at nearby.arsenstorm.com (landing, privacy, and
  support). The api Worker serves them as static assets.
- `apps/android`: a placeholder for the Android app.
- `docs/app-store`: the App Store Connect checklist, the privacy policy, and
  the review notes.

## Run

You need Xcode 26 with the iOS 26 platform.

```sh
cd apps/ios
swift test               # NearbyCore package tests
scripts/run-sim.sh       # build and launch on the simulator
scripts/run-device.sh    # build and launch on the connected iPhone
scripts/run-all.sh       # both: one simulator and one phone make a call
```

The simulator finds other phones over Bonjour only. It has no Bluetooth.
It also cannot attest or hold a subscription, so a relay between two
simulators needs a Worker deployed with `--var RELAY_UNGATED:1`.
To test Bluetooth or Wi-Fi Aware, use two phones.

The Worker tests need Node 24 and `openssl`. They start `wrangler dev`
themselves.

```sh
cd apps/api
npm ci
npm test                 # worker tests
scripts/dev.sh           # run the worker locally, with the web pages
scripts/deploy.sh        # deploy to Cloudflare
```

`apps/web/scripts/preview.sh` starts the same local Worker. The Worker
secrets are listed in `apps/api/wrangler.jsonc`.

## Release

CI runs the package tests and a simulator build on every pull request. A
push to `main` that changes `apps/api` or `apps/web` also deploys the Worker.

When you publish a GitHub release with the tag `vX.Y`, `release-ios.yml`
archives the app and uploads it to TestFlight. `apps/ios/scripts/deploy.sh`
does the same from a Mac. The setup is in
[`docs/app-store/connect-checklist.md`](docs/app-store/connect-checklist.md).
