# Contributing

Thanks for your interest in improving Nearby.

## Getting started

You'll need Xcode 26 with the iOS 26 platform installed.

```sh
swift test            # NearbyCore package tests
scripts/run-sim.sh    # build and launch the app on a simulator
```

Anything involving discovery, audio or Bluetooth needs at least one physical
iPhone: `scripts/run-device.sh`.

## Before opening a pull request

Run the same checks CI runs:

```sh
swift test
xcodebuild build -project Nearby.xcodeproj -scheme Nearby \
  -destination "generic/platform=iOS Simulator" CODE_SIGNING_ALLOWED=NO -quiet
```

## Coding standards

Swift 6 strict concurrency; keep NearbyCore free of UIKit/SwiftUI so it stays
testable on macOS.

Commit messages follow the conventional commit format: `type(scope): message`
(e.g. `fix(app): restart transports after returning from background`).

## Reporting issues

Use the issue templates for bugs and feature requests. For security issues, see
[`SECURITY.md`](./SECURITY.md).
