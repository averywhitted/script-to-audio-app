#!/usr/bin/env bash
# build_flutter_app.sh — self-contained Flutter app in /Applications
#
# Builds app/ in release mode, bundles the backend and the embedded Python
# runtime (vendor/python, from embed_python.sh) into Contents/Resources, signs
# it with the Apple Development cert, and installs it to /Applications.
# The installed app no longer reads the repo, so switching branches can't break it;
# rerun this script to pick up new parser/backend changes.
#
#   bash scripts/build_flutter_app.sh            # build + install
#   bash scripts/build_flutter_app.sh --no-build # re-bundle the last build
#   bash scripts/build_flutter_app.sh --package  # also write release assets to build/:
#       TableRead-Preview.zip, .dmg, .sha256 (names differ from the Swift app's
#       TableRead.zip so the Swift updater never auto-installs this app)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="Table Read Preview"
BUILT="$ROOT/app/build/macos/Build/Products/Release/$NAME.app"
DEST="/Applications/$NAME.app"
IDENTITY="Apple Development: whitted.avery@protonmail.com (95GY76YVFT)"

[ -d "$ROOT/vendor/python" ] || { echo "vendor/python/ missing — run: bash scripts/embed_python.sh"; exit 1; }

BUILD=1; PACKAGE=0
for arg in "$@"; do
    case "$arg" in
        --no-build) BUILD=0 ;;
        --package)  PACKAGE=1 ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done

if [ "$BUILD" = 1 ]; then
    (cd "$ROOT/app" && flutter build macos --release)
fi

STAGE="$(mktemp -d)/$NAME.app"
cp -R "$BUILT" "$STAGE"
RES="$STAGE/Contents/Resources"

echo "Bundling backend and Python runtime..."
mkdir -p "$RES/backend"
cp "$ROOT/backend/"*.py "$ROOT/backend/"*.json "$RES/backend/"
cp -R "$ROOT/vendor/python" "$RES/python"
find "$RES/python" -name __pycache__ -type d -prune -exec rm -rf {} +

echo "Signing..."
# Nested Mach-O files first (interpreter, dylibs, extension modules), then the app.
# No hardened runtime on Python: it would refuse the optional engines (Kokoro)
# pip-installed to ~/Library/Application Support/TableRead/python-packages.
find "$RES/python" -type f \( -perm -u+x -o -name '*.so' -o -name '*.dylib' \) -print0 |
    while IFS= read -r -d '' f; do
        if file -b "$f" | grep -q Mach-O; then
            codesign --force --timestamp=none --sign "$IDENTITY" "$f" 2>/dev/null
        fi
    done
codesign --force --timestamp=none --sign "$IDENTITY" \
    --preserve-metadata=entitlements,requirements,flags,runtime "$STAGE"
codesign --verify --strict "$STAGE"

if [ "$PACKAGE" = 1 ]; then
    echo "Packaging release assets..."
    OUT="$ROOT/build"; mkdir -p "$OUT"
    rm -f "$OUT/TableRead-Preview.zip" "$OUT/TableRead-Preview.dmg"
    ditto -c -k --keepParent "$STAGE" "$OUT/TableRead-Preview.zip"
    DMG_SRC="$(mktemp -d)"
    ditto "$STAGE" "$DMG_SRC/$NAME.app"
    ln -s /Applications "$DMG_SRC/Applications"
    hdiutil create -quiet -volname "$NAME" -srcfolder "$DMG_SRC" -ov -format UDZO "$OUT/TableRead-Preview.dmg"
    rm -rf "$DMG_SRC"
    (cd "$OUT" && shasum -a 256 TableRead-Preview.zip TableRead-Preview.dmg > TableRead-Preview.sha256)
    echo "✓ $OUT/TableRead-Preview.{zip,dmg,sha256}"
fi

echo "Installing to $DEST..."
osascript -e "tell application \"$NAME\" to quit" 2>/dev/null || true
rm -rf "$DEST"
ditto "$STAGE" "$DEST"
rm -rf "$(dirname "$STAGE")"
echo "✓ Installed $DEST ($(du -sh "$DEST" | cut -f1))"
