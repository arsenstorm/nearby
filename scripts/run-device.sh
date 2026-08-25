#!/usr/bin/env bash
# Build, install and launch Nearby on a connected iPhone (USB or Wi-Fi).
# Pick a device with IOS_DEVICE=<udid>; otherwise the single reachable iPhone
# is used. List UDIDs with: xcrun devicectl list devices
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="com.arsenstorm.nearby"

UDID="${IOS_DEVICE:-}"
if [[ -z "$UDID" ]]; then
  LIST="$(mktemp)"
  xcrun devicectl list devices --json-output "$LIST" >/dev/null 2>&1 || true
  # Skip paired-but-unreachable phones (tunnelState "unavailable"); use the
  # hardware UDID, which is what xcodebuild -destination matches.
  UDID=$(python3 - "$LIST" <<'PY'
import json, sys
try:
    devs = json.load(open(sys.argv[1]))['result']['devices']
except Exception:
    sys.exit(0)
phys = [d['hardwareProperties']['udid'] for d in devs
        if d.get('hardwareProperties', {}).get('reality') == 'physical'
        and d.get('hardwareProperties', {}).get('udid')
        and d.get('connectionProperties', {}).get('tunnelState') != 'unavailable']
if len(phys) == 1:
    print(phys[0])
PY
)
fi
if [[ -z "$UDID" ]]; then
  echo "No single reachable iPhone found (unlock it, plug it in, or join the same Wi-Fi). Devices:" >&2
  xcrun devicectl list devices >&2
  echo "Set IOS_DEVICE=<udid> and re-run." >&2
  exit 1
fi
echo "Target device: $UDID"

xcodebuild build \
  -project Nearby.xcodeproj \
  -scheme Nearby \
  -destination "generic/platform=iOS" \
  -derivedDataPath build/ios \
  -allowProvisioningUpdates \
  -quiet

APP="build/ios/Build/Products/Debug-iphoneos/Nearby.app"
# The tunnel to the phone drops for a few seconds after (re)connecting; retry.
for attempt in 1 2 3 4 5; do
  xcrun devicectl device install app --device "$UDID" "$APP" && break
  [[ $attempt == 5 ]] && exit 1
  echo "Install failed (attempt $attempt), retrying…" >&2
  sleep 5
done
exec xcrun devicectl device process launch --device "$UDID" "$BUNDLE_ID"
