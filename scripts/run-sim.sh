#!/usr/bin/env bash
# Build, install and launch Nearby on an iOS Simulator, streaming the console.
# Override the device with SIM_DEVICE. Bluetooth is unavailable in the
# simulator; discovery there is Bonjour only.
set -euo pipefail
cd "$(dirname "$0")/.."

DEVICE="${SIM_DEVICE:-iPhone 17 Pro Max}"
BUNDLE_ID="com.arsenstorm.nearby"

xcrun simctl boot "$DEVICE" 2>/dev/null || true
open -a Simulator

xcodebuild build \
  -project Nearby.xcodeproj \
  -scheme Nearby \
  -destination "platform=iOS Simulator,name=$DEVICE" \
  -derivedDataPath build/sim \
  -quiet

xcrun simctl install "$DEVICE" "build/sim/Build/Products/Debug-iphonesimulator/Nearby.app"
exec xcrun simctl launch --console "$DEVICE" "$BUNDLE_ID"
