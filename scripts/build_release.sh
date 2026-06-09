#!/usr/bin/env bash
# =============================================================================
# Table Read — Release Build Script
# =============================================================================
#
# DEFAULT (no arguments) — ad-hoc signed, no notarization.
#   Works with no Apple Developer account.
#   Users will see a one-time Gatekeeper prompt on first launch —
#   see website/download.html for the instructions to walk them through it.
#
# WITH --notarize — full Developer ID + notarization pipeline.
#   Requires a paid Apple Developer account ($99/yr) and setup below.
#
# USAGE:
#   bash scripts/build_release.sh               # ad-hoc, distribute now
#   bash scripts/build_release.sh --notarize    # full notarization (future)
#
# =============================================================================
# NOTARIZATION SETUP (only needed for --notarize):
#
#   1. Create a "Developer ID Application" certificate:
#      developer.apple.com → Certificates → + → Developer ID Application
#      Download and double-click to install.
#
#   2. Store App Store Connect API credentials for notarytool:
#      appstoreconnect.apple.com → Users & Access → Integrations → API Keys
#      Download the .p8 file (one chance only), then:
#        xcrun notarytool store-credentials "TableRead-notary" \
#          --key "/path/to/AuthKey_XXXXXXXX.p8" \
#          --key-id "XXXXXXXX" \
#          --issuer "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
#
#   3. Set env vars (or edit the DEFAULTS below):
#      DEVELOPER_ID  e.g. "Developer ID Application: Avery Whitted (AB1CD2EF3G)"
#      TEAM_ID       e.g. "AB1CD2EF3G"
#      NOTARY_PROFILE (default: "TableRead-notary")
# =============================================================================
set -euo pipefail

# ── FLAGS ────────────────────────────────────────────────────────────────────
NOTARIZE=false
for arg in "$@"; do
    [[ "$arg" == "--notarize" ]] && NOTARIZE=true
done

# ── DEFAULTS ─────────────────────────────────────────────────────────────────
: "${DEVELOPER_ID:=""}"           # Only needed for --notarize
: "${TEAM_ID:=""}"                # Only needed for --notarize
: "${NOTARY_PROFILE:="TableRead-notary"}"

# ── PATHS ────────────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build"
ARCHIVE_PATH="$BUILD_DIR/TableRead.xcarchive"
APP_PATH="$BUILD_DIR/TableRead.app"
VERSION="$(defaults read "$REPO_ROOT/Sources/TableRead/Info.plist" \
    CFBundleShortVersionString 2>/dev/null || echo "0.1.0")"
DMG_NAME="TableRead.dmg"
DMG_PATH="$BUILD_DIR/$DMG_NAME"

# ── COLOURS ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
step()  { echo -e "\n${CYAN}▶ $*${NC}"; }
ok()    { echo -e "${GREEN}✓ $*${NC}"; }
warn()  { echo -e "${YELLOW}⚠ $*${NC}"; }
fail()  { echo -e "${RED}✗ $*${NC}"; exit 1; }

# ── BANNER ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}Table Read $VERSION — Release Build${NC}"
$NOTARIZE && echo -e "${YELLOW}Mode: notarized (Developer ID)${NC}" \
          || echo -e "${YELLOW}Mode: ad-hoc (no notarization)${NC}"

# ── NOTARIZE PREFLIGHT ───────────────────────────────────────────────────────
if $NOTARIZE; then
    step "Notarization preflight"
    [[ -n "$DEVELOPER_ID" ]] || fail "DEVELOPER_ID is not set. See usage at the top of this script."
    [[ -n "$TEAM_ID" ]]      || fail "TEAM_ID is not set."
    if ! security find-identity -p codesigning -v 2>/dev/null | grep -qF "$DEVELOPER_ID"; then
        fail "Certificate not found in keychain:\n  \"$DEVELOPER_ID\"\nInstall it from developer.apple.com → Certificates."
    fi
    if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" &>/dev/null; then
        fail "Notarytool profile \"$NOTARY_PROFILE\" not found.\nRun: xcrun notarytool store-credentials \"$NOTARY_PROFILE\" ..."
    fi
    ok "Certificate: $DEVELOPER_ID"
    ok "Notary profile: $NOTARY_PROFILE"
fi

# ── CLEAN BUILD DIR ───────────────────────────────────────────────────────────
step "Preparing build directory"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
ok "Ready: $BUILD_DIR"

# ── EMBED PYTHON ─────────────────────────────────────────────────────────────
if [[ ! -d "$REPO_ROOT/vendor/python" ]]; then
    step "Embedding CPython (one-time, ~5 min)"
    bash "$REPO_ROOT/scripts/embed_python.sh"
fi
ok "Embedded Python present"

# ── ARCHIVE ──────────────────────────────────────────────────────────────────
step "Archiving (Release)"

if $NOTARIZE; then
    # Developer ID — hardened runtime, manual signing
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
        2>&1 | grep -E "^(error:|warning: |Build succeeded|\*\* ARCHIVE)" || true
else
    # Ad-hoc — no team, no hardened runtime required
    xcodebuild archive \
        -project "$REPO_ROOT/TableRead.xcodeproj" \
        -scheme TableRead \
        -configuration Release \
        -archivePath "$ARCHIVE_PATH" \
        CODE_SIGN_IDENTITY="-" \
        CODE_SIGN_STYLE=Manual \
        AD_HOC_CODE_SIGNING_ALLOWED=YES \
        2>&1 | grep -E "^(error:|warning: |Build succeeded|\*\* ARCHIVE)" || true
fi

ok "Archive created: $ARCHIVE_PATH"

# ── EXTRACT APP ──────────────────────────────────────────────────────────────
step "Extracting app from archive"

if $NOTARIZE; then
    # Use xcodebuild -exportArchive for Developer ID export
    EXPORT_DIR="$BUILD_DIR/export"
    EXPORT_OPTIONS_TMP="$BUILD_DIR/ExportOptions.plist"
    sed "s/__TEAM_ID__/$TEAM_ID/g; s|__DEVELOPER_ID__|$DEVELOPER_ID|g" \
        "$REPO_ROOT/scripts/ExportOptions.plist" > "$EXPORT_OPTIONS_TMP"
    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportPath "$EXPORT_DIR" \
        -exportOptionsPlist "$EXPORT_OPTIONS_TMP"
    cp -a "$EXPORT_DIR/TableRead.app" "$APP_PATH"
else
    # Ad-hoc: pull .app directly from the archive
    ARCHIVED_APP=$(find "$ARCHIVE_PATH/Products" -name "TableRead.app" -maxdepth 4 | head -1)
    [[ -n "$ARCHIVED_APP" ]] || fail "Could not find TableRead.app in archive."
    cp -a "$ARCHIVED_APP" "$APP_PATH"
fi

ok "App ready: $APP_PATH"

# ── VERIFY SIGNATURE ─────────────────────────────────────────────────────────
step "Verifying code signature"
codesign --verify --deep --verbose=1 "$APP_PATH" && ok "Signature valid" \
    || warn "Signature check returned warnings (may be normal for ad-hoc)"

# ── NOTARIZE ─────────────────────────────────────────────────────────────────
if $NOTARIZE; then
    step "Zipping for notarization"
    NOTARIZE_ZIP="$BUILD_DIR/TableRead-notarize.zip"
    ditto -c -k --keepParent "$APP_PATH" "$NOTARIZE_ZIP"
    ok "Zip: $NOTARIZE_ZIP"

    step "Submitting to Apple Notary Service (1–5 min)…"
    NOTARY_OUT=$(xcrun notarytool submit "$NOTARIZE_ZIP" \
        --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)
    echo "$NOTARY_OUT"
    if echo "$NOTARY_OUT" | grep -q "status: Accepted"; then
        ok "Notarization accepted"
    else
        SUB_ID=$(echo "$NOTARY_OUT" | grep -oE 'id: [0-9a-f-]{36}' | head -1 | awk '{print $2}')
        [[ -n "$SUB_ID" ]] && xcrun notarytool log "$SUB_ID" --keychain-profile "$NOTARY_PROFILE" || true
        fail "Notarization failed."
    fi

    step "Stapling notarization ticket"
    xcrun stapler staple "$APP_PATH"
    ok "Stapled"
fi

# ── CREATE DMG ───────────────────────────────────────────────────────────────
step "Creating DMG"
VOLUME_NAME="Table Read $VERSION"
TMP_DMG="$BUILD_DIR/tmp.dmg"
MOUNT_DIR="/Volumes/$VOLUME_NAME"

# Size: app + 25 MB headroom
APP_SIZE_MB=$(du -sm "$APP_PATH" | awk '{print $1}')
DMG_SIZE_MB=$((APP_SIZE_MB + 25))

hdiutil create -size "${DMG_SIZE_MB}m" \
    -volname "$VOLUME_NAME" \
    -fs HFS+ \
    -fsargs "-c c=16,a=16,b=16" \
    -format UDRW \
    -srcfolder /dev/null \
    "$TMP_DMG"

hdiutil attach "$TMP_DMG" -readwrite -noverify -noautoopen -quiet

cp -a "$APP_PATH" "$MOUNT_DIR/"
ln -s /Applications "$MOUNT_DIR/Applications"

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

hdiutil convert "$TMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH"
rm "$TMP_DMG"
ok "DMG: $DMG_PATH"

# ── NOTARIZE DMG ─────────────────────────────────────────────────────────────
if $NOTARIZE; then
    step "Notarizing DMG"
    DMG_OUT=$(xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)
    echo "$DMG_OUT"
    if echo "$DMG_OUT" | grep -q "status: Accepted"; then
        ok "DMG notarization accepted"
    else
        SUB_ID=$(echo "$DMG_OUT" | grep -oE 'id: [0-9a-f-]{36}' | head -1 | awk '{print $2}')
        [[ -n "$SUB_ID" ]] && xcrun notarytool log "$SUB_ID" --keychain-profile "$NOTARY_PROFILE" || true
        fail "DMG notarization failed."
    fi
    step "Stapling DMG"
    xcrun stapler staple "$DMG_PATH"
    ok "DMG stapled"
fi

# ── ZIP (for in-app updater) ──────────────────────────────────────────────────
# The in-app updater (AppUpdater.swift) looks for a release asset named
# "TableRead.zip". This zip contains TableRead.app and is downloaded directly
# by the app to perform a self-update.
step "Creating zip for in-app updater"
ZIP_PATH="$BUILD_DIR/TableRead.zip"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
ok "Zip: $ZIP_PATH"

# ── CHECKSUM ─────────────────────────────────────────────────────────────────
step "Generating checksums"
CHECKSUM_FILE="$BUILD_DIR/TableRead.sha256"
(cd "$BUILD_DIR" && shasum -a 256 TableRead.dmg TableRead.zip) | tee "$CHECKSUM_FILE"
ok "Checksums: $CHECKSUM_FILE"

# ── DONE ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  ✓ Table Read $VERSION ready to ship!${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════${NC}"
echo ""
echo "  DMG:       $DMG_PATH"
echo "  Zip:       $ZIP_PATH"
echo "  Checksums: $CHECKSUM_FILE"
echo ""
if ! $NOTARIZE; then
    echo -e "${YELLOW}  Ad-hoc build: users will see a one-time Gatekeeper${NC}"
    echo -e "${YELLOW}  prompt on first launch. See website/download.html${NC}"
    echo -e "${YELLOW}  for the installation instructions to show them.${NC}"
    echo ""
fi
