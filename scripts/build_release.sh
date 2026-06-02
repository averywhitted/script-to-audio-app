#!/usr/bin/env bash
# =============================================================================
# Table Read — Release Build Script
# =============================================================================
# Builds a signed, notarized, stapled DMG ready for direct download.
#
# PREREQUISITES — one-time setup:
#
#   1. Apple Developer account (paid, $99/yr) at developer.apple.com
#
#   2. "Developer ID Application" certificate in your Keychain
#      developer.apple.com → Certificates → + → Developer ID Application
#      Download and double-click to install.
#
#   3. App Store Connect API key for notarization (recommended over Apple ID):
#      appstoreconnect.apple.com → Users & Access → Integrations → API Keys
#      Download the .p8 file once (can't re-download).
#      Then store it:
#        xcrun notarytool store-credentials "TableRead-notary" \
#          --key "/path/to/AuthKey_XXXXXXXX.p8" \
#          --key-id "XXXXXXXX" \
#          --issuer "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
#      (The issuer UUID is shown on the same API Keys page.)
#
#   4. Set DEVELOPMENT_TEAM in the Xcode project (or pass it to this script):
#      Open TableRead.xcodeproj → Signing & Capabilities → Team dropdown.
#
# REQUIRED ENV VARS (or edit the defaults below):
#
#   DEVELOPER_ID      Full cert name, e.g.:
#                     "Developer ID Application: Avery Whitted (XXXXXXXXXX)"
#
#   TEAM_ID           10-char Apple team ID, e.g. "XXXXXXXXXX"
#                     (shown in parentheses at end of cert name above)
#
#   NOTARY_PROFILE    Keychain profile name you used in store-credentials
#                     (default: "TableRead-notary")
#
# USAGE:
#   DEVELOPER_ID="Developer ID Application: Avery Whitted (XXXXXXXXXX)" \
#   TEAM_ID="XXXXXXXXXX" \
#   bash scripts/build_release.sh
#
#   Or just edit the DEFAULTS section below and run: bash scripts/build_release.sh
# =============================================================================
set -euo pipefail

# ── DEFAULTS (edit these once you have your cert) ────────────────────────────
: "${DEVELOPER_ID:=""}"          # e.g. "Developer ID Application: Avery Whitted (AB1CD2EF3G)"
: "${TEAM_ID:=""}"               # e.g. "AB1CD2EF3G"
: "${NOTARY_PROFILE:="TableRead-notary"}"

# ── PATHS ────────────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build"
ARCHIVE_PATH="$BUILD_DIR/TableRead.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP_PATH="$EXPORT_DIR/TableRead.app"
EXPORT_OPTIONS="$REPO_ROOT/scripts/ExportOptions.plist"
VERSION="$(defaults read "$REPO_ROOT/Sources/TableRead/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "0.1.0")"
DMG_NAME="TableRead-$VERSION.dmg"
DMG_PATH="$BUILD_DIR/$DMG_NAME"

# ── COLOURS ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
step()  { echo -e "\n${CYAN}▶ $*${NC}"; }
ok()    { echo -e "${GREEN}✓ $*${NC}"; }
warn()  { echo -e "${YELLOW}⚠ $*${NC}"; }
fail()  { echo -e "${RED}✗ $*${NC}"; exit 1; }

# ── PREFLIGHT CHECKS ─────────────────────────────────────────────────────────
step "Preflight checks"

[[ -n "$DEVELOPER_ID" ]] || fail "DEVELOPER_ID is not set. See usage at the top of this script."
[[ -n "$TEAM_ID" ]]      || fail "TEAM_ID is not set. See usage at the top of this script."

# Verify cert is in keychain
if ! security find-identity -p codesigning -v 2>/dev/null | grep -qF "$DEVELOPER_ID"; then
    fail "Certificate not found in keychain: \"$DEVELOPER_ID\"\nInstall it from developer.apple.com → Certificates."
fi

# Verify notarytool profile exists
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" &>/dev/null; then
    fail "Notarytool profile \"$NOTARY_PROFILE\" not found.\nRun: xcrun notarytool store-credentials \"$NOTARY_PROFILE\" ..."
fi

ok "Certificate found: $DEVELOPER_ID"
ok "Notary profile found: $NOTARY_PROFILE"
ok "Building version $VERSION"

# ── CLEAN BUILD DIR ───────────────────────────────────────────────────────────
step "Preparing build directory"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
ok "Build directory ready: $BUILD_DIR"

# ── EMBED PYTHON (if not already done) ───────────────────────────────────────
if [[ ! -d "$REPO_ROOT/vendor/python" ]]; then
    step "Embedding CPython (one-time, ~5 min)"
    bash "$REPO_ROOT/scripts/embed_python.sh"
fi
ok "Embedded Python present"

# ── ARCHIVE ──────────────────────────────────────────────────────────────────
step "Archiving (Release configuration)"
xcodebuild archive \
    -project "$REPO_ROOT/TableRead.xcodeproj" \
    -scheme TableRead \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_IDENTITY="$DEVELOPER_ID" \
    CODE_SIGN_STYLE=Manual \
    ENABLE_HARDENED_RUNTIME=YES \
    CODE_SIGN_ENTITLEMENTS="Sources/TableRead/TableRead-release.entitlements" \
    | xcpretty 2>/dev/null || cat /dev/stdin
ok "Archive created: $ARCHIVE_PATH"

# ── EXPORT ───────────────────────────────────────────────────────────────────
step "Exporting with Developer ID signing"

# Generate ExportOptions.plist with the actual team ID substituted
EXPORT_OPTIONS_TMP="$BUILD_DIR/ExportOptions.plist"
sed "s/__TEAM_ID__/$TEAM_ID/g; s|__DEVELOPER_ID__|$DEVELOPER_ID|g" \
    "$EXPORT_OPTIONS" > "$EXPORT_OPTIONS_TMP"

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS_TMP"
ok "App exported: $APP_PATH"

# ── VERIFY CODE SIGNATURE ────────────────────────────────────────────────────
step "Verifying code signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
ok "Signature valid"

# ── CREATE ZIP FOR NOTARIZATION ──────────────────────────────────────────────
step "Zipping app for notarization submission"
NOTARIZE_ZIP="$BUILD_DIR/TableRead-notarize.zip"
ditto -c -k --keepParent "$APP_PATH" "$NOTARIZE_ZIP"
ok "Zip created: $NOTARIZE_ZIP"

# ── NOTARIZE ─────────────────────────────────────────────────────────────────
step "Submitting to Apple Notary Service (this takes 1–5 minutes)"
NOTARY_OUTPUT=$(xcrun notarytool submit "$NOTARIZE_ZIP" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait 2>&1)
echo "$NOTARY_OUTPUT"

if echo "$NOTARY_OUTPUT" | grep -q "status: Accepted"; then
    ok "Notarization accepted"
else
    # Extract submission ID for log fetch
    SUB_ID=$(echo "$NOTARY_OUTPUT" | grep -oE 'id: [0-9a-f-]{36}' | head -1 | awk '{print $2}')
    if [[ -n "$SUB_ID" ]]; then
        warn "Fetching notarization log for submission $SUB_ID…"
        xcrun notarytool log "$SUB_ID" --keychain-profile "$NOTARY_PROFILE" 2>&1 || true
    fi
    fail "Notarization failed. See log above."
fi

# ── STAPLE ───────────────────────────────────────────────────────────────────
step "Stapling notarization ticket to app"
xcrun stapler staple "$APP_PATH"
ok "Stapled"

# ── CREATE DMG ───────────────────────────────────────────────────────────────
step "Creating DMG"
VOLUME_NAME="Table Read $VERSION"
TMP_DMG="$BUILD_DIR/tmp.dmg"
MOUNT_DIR="/Volumes/$VOLUME_NAME"

# Size: app + 20 MB headroom
APP_SIZE_MB=$(du -sm "$APP_PATH" | awk '{print $1}')
DMG_SIZE_MB=$((APP_SIZE_MB + 25))

# Create writable image
hdiutil create -size "${DMG_SIZE_MB}m" \
    -volname "$VOLUME_NAME" \
    -fs HFS+ \
    -fsargs "-c c=16,a=16,b=16" \
    -format UDRW \
    -srcfolder /dev/null \
    "$TMP_DMG"

# Mount it (suppress auto-open)
hdiutil attach "$TMP_DMG" -readwrite -noverify -noautoopen -quiet

# Copy app and add Applications symlink
cp -a "$APP_PATH" "$MOUNT_DIR/"
ln -s /Applications "$MOUNT_DIR/Applications"

# Position window, icon sizes, and background via AppleScript
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOLUME_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 100, 760, 450}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set position of item "TableRead.app" of container window to {160, 180}
        set position of item "Applications" of container window to {400, 180}
        close
        open
        update without registering applications
        delay 2
    end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$MOUNT_DIR" -quiet

# Convert to compressed read-only
hdiutil convert "$TMP_DMG" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$DMG_PATH"
rm "$TMP_DMG"
ok "DMG created: $DMG_PATH"

# ── NOTARIZE DMG ─────────────────────────────────────────────────────────────
step "Notarizing DMG"
DMG_NOTARY_OUTPUT=$(xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait 2>&1)
echo "$DMG_NOTARY_OUTPUT"

if echo "$DMG_NOTARY_OUTPUT" | grep -q "status: Accepted"; then
    ok "DMG notarization accepted"
else
    SUB_ID=$(echo "$DMG_NOTARY_OUTPUT" | grep -oE 'id: [0-9a-f-]{36}' | head -1 | awk '{print $2}')
    [[ -n "$SUB_ID" ]] && xcrun notarytool log "$SUB_ID" --keychain-profile "$NOTARY_PROFILE" 2>&1 || true
    fail "DMG notarization failed."
fi

# ── STAPLE DMG ────────────────────────────────────────────────────────────────
step "Stapling notarization ticket to DMG"
xcrun stapler staple "$DMG_PATH"
ok "DMG stapled"

# ── CHECKSUM ─────────────────────────────────────────────────────────────────
step "Generating checksum"
CHECKSUM_FILE="$BUILD_DIR/${DMG_NAME%.dmg}.sha256"
shasum -a 256 "$DMG_PATH" | tee "$CHECKSUM_FILE"
ok "Checksum: $CHECKSUM_FILE"

# ── DONE ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  ✓ Table Read $VERSION release build complete!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
echo ""
echo "  DMG:      $DMG_PATH"
echo "  Checksum: $CHECKSUM_FILE"
echo ""
echo "  Upload the DMG to your web server and update download.html."
echo ""
