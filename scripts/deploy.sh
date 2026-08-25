#!/usr/bin/env bash
# Archive Nearby and upload it to App Store Connect (TestFlight) from this Mac.
# The Apple Distribution cert must be in the login keychain (Xcode > Settings >
# Accounts > Manage Certificates). Provisioning profiles are fetched by name
# via the App Store Connect API key (see Config/ExportOptions.plist).
#
#   ASC_KEY_ID=… ASC_ISSUER_ID=… ASC_KEY_PATH=~/.appstoreconnect/AuthKey_….p8 \
#   [VERSION=1.0] [BUILD=42] scripts/deploy.sh
#
# BUILD defaults to a timestamp so every upload has a unique CFBundleVersion.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${ASC_KEY_ID:?set ASC_KEY_ID}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
: "${ASC_KEY_PATH:?set ASC_KEY_PATH to the AuthKey .p8}"
BUILD="${BUILD:-$(date +%Y%m%d%H%M)}"
ARCHIVE="build/Nearby.xcarchive"
AUTH=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")

xcodebuild archive \
  -project Nearby.xcodeproj \
  -scheme Nearby \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates "${AUTH[@]}" \
  CURRENT_PROJECT_VERSION="$BUILD" \
  ${VERSION:+MARKETING_VERSION="$VERSION"} \
  -quiet

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist Config/ExportOptions.plist \
  -exportPath build/export \
  -allowProvisioningUpdates "${AUTH[@]}"

echo "Uploaded build $BUILD${VERSION:+ (version $VERSION)}"
