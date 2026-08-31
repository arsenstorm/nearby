# Nearby

Voice rooms between iPhones that are physically close — over the local
network, Wi‑Fi Aware or Bluetooth, with no account. Nearby calls use no
server; calls to far-away friends connect through a small rendezvous Worker
and, with a subscription, an encrypted relay.

## Layout

- `Sources/NearbyCore` — pure Swift package: wire format, routing, crypto, Opus, session logic (`swift test`)
- `App` — the iOS app (SwiftUI, iOS 26)
- `Activity` — the call Live Activity / Dynamic Island extension
- `Shared` — types shared between app and extension
- `scripts` — build, install and release helpers
- `docs/app-store` — App Store Connect checklist, privacy policy and review notes
- `web` — nearby.arsenstorm.com: landing, privacy and support pages (static Cloudflare Worker)

## Run

```sh
swift test               # package tests
scripts/run-sim.sh       # build + launch on the simulator
scripts/run-device.sh    # build + launch on the connected iPhone
scripts/run-all.sh       # both — one sim and one phone make a call
```

Bluetooth doesn't exist in the simulator; test it with two phones.

## Release

Publishing a GitHub release tagged `vX.Y` runs `release-ios.yml`, which
archives the app and uploads it to TestFlight. `scripts/deploy.sh` does the
same from a Mac. Setup is in [`docs/app-store/connect-checklist.md`](docs/app-store/connect-checklist.md).
