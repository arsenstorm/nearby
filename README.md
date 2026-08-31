# Nearby

Voice rooms between iPhones that are physically close — over the local
network, Wi‑Fi Aware or Bluetooth, with no account. Nearby calls use no
server; calls to far-away friends connect through a small rendezvous Worker
and, with a subscription, an encrypted relay.

## Layout

- `apps/ios` — the iOS app (SwiftUI, iOS 26): the Xcode project, the Live
  Activity extension and `Sources/NearbyCore`, a pure Swift package with the
  wire format, routing, crypto, Opus and session logic (`swift test`)
- `apps/api` — the Cloudflare Worker (Hono): rendezvous, relay minting,
  attestation and the relay budget
- `apps/web` — nearby.arsenstorm.com: landing, privacy and support pages,
  served as the api worker's static assets
- `apps/android` — placeholder for the Android app
- `docs/app-store` — App Store Connect checklist, privacy policy and review notes

Each app has its own `scripts` folder.

## Run

```sh
cd apps/ios
swift test               # package tests
scripts/run-sim.sh       # build + launch on the simulator
scripts/run-device.sh    # build + launch on the connected iPhone
scripts/run-all.sh       # both — one sim and one phone make a call
```

Bluetooth doesn't exist in the simulator; test it with two phones.

## Release

Publishing a GitHub release tagged `vX.Y` runs `release-ios.yml`, which
archives the app and uploads it to TestFlight. `apps/ios/scripts/deploy.sh` does the
same from a Mac. Setup is in [`docs/app-store/connect-checklist.md`](docs/app-store/connect-checklist.md).
