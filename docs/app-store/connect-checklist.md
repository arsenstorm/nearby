# App Store Connect Checklist — Nearby

## One-time setup

1. **App record.** App Store Connect → Apps → New. Bundle ID `com.arsenstorm.nearby`
   (team `K667TL7H29`). Name "Nearby" (check availability; fall back to a
   subtitle-qualified name if taken).
2. **Identifiers.** Developer portal → Identifiers: register both
   `com.arsenstorm.nearby` (capabilities: Wi‑Fi Aware) and
   `com.arsenstorm.nearby.activity` (the Live Activity extension).
3. **Distribution certificate.** Xcode → Settings → Accounts → Manage
   Certificates → "+" → Apple Distribution. Export it as a `.p12` from Keychain
   Access; `base64 -i dist.p12 | pbcopy` → GitHub secret `DIST_CERT_P12`, its
   password → `DIST_CERT_P12_PASSWORD`.
4. **Provisioning profiles.** Two App Store profiles, named exactly as
   `Config/ExportOptions.plist` expects:
   - `Nearby App Store` → `com.arsenstorm.nearby`
   - `Nearby Activity App Store` → `com.arsenstorm.nearby.activity`
5. **API key.** App Store Connect → Users and Access → Integrations → App Store
   Connect API → generate a key with the **App Manager** role (not Admin). Store
   `ASC_KEY_ID`, `ASC_ISSUER_ID`, and the `.p8` contents as `ASC_PRIVATE_KEY` in
   GitHub secrets; keep the `.p8` locally (e.g. `~/.appstoreconnect/`) for
   `scripts/deploy.sh`.
6. **Test the pipeline** with Actions → Release iOS → Run workflow before
   cutting a real release.

## Shipping a build

- Tag and publish a GitHub release `vX.Y` → TestFlight build appears in ~15 min.
- Or locally: `ASC_KEY_ID=… ASC_ISSUER_ID=… ASC_KEY_PATH=… VERSION=X.Y scripts/deploy.sh`.

## Privacy nutrition label (App Privacy section)

**"Data Not Collected."** Nearby has no server, no account and no analytics.
Voice and names travel directly between phones, end-to-end encrypted, and
nothing leaves the devices otherwise. Answer "No, we do not collect data".

## Permissions the reviewer will see

| Prompt | Why |
|---|---|
| Microphone | Sending your voice to the room |
| Local Network | Finding phones on the same Wi‑Fi (Bonjour `_nearby._udp`) |
| Bluetooth | Reaching phones with no shared Wi‑Fi |

Background modes: `audio` (keep the call alive), `bluetooth-central` /
`bluetooth-peripheral` (keep the Bluetooth link alive). Both are used only
while in a room.

## URLs

- **Privacy Policy URL:** host `privacy-policy.md` (placeholder until hosted)
- **Support URL:** `mailto:arsen@shkrumelyak.com` or a simple page

## Export compliance

The app uses standard algorithms only (Curve25519, HKDF, ChaCha20‑Poly1305 via
Apple CryptoKit). Answer **Yes** to "uses encryption", then **Yes** to "only
standard algorithms / exempt". Apple no longer requires an ERN for this, but a
yearly self-classification report to BIS may be required — confirm on the
Encryption page before submitting. Set `ITSAppUsesNonExemptEncryption` to
`NO` in `Config/Info.plist` once confirmed so TestFlight stops asking.

## Age rating

**4+.** Voice chat is only with people physically nearby who explicitly join
your room; there's no public matchmaking. Declare "Unrestricted Web Access:
No" and "User Generated Content: No".

## Category

**Social Networking** (primary), **Utilities** (secondary).
