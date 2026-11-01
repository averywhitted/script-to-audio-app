#!/usr/bin/env bash
# build_ios_native.sh — native libraries the iPhone app embeds: the Rust core and PDFium, for device and Simulator.
#
# Output (gitignored): app/ios/native/{iphoneos,iphonesimulator}/{libtable_read_ffi,libpdfium}.dylib
# The Runner target's "Embed native libraries" build phase copies the matching pair into the .app's Frameworks
# folder and signs it. Dart finds them there (app/lib/services/rust_core.dart).
#
# Needs: rustup stable with the aarch64-apple-ios and aarch64-apple-ios-sim targets (~/.cargo/bin), and
#   - a crate source: set MIRROR=<dir> on the sandboxed dev Mac (see rust/cargo-offline.sh), or leave it unset
#     where cargo can reach crates.io;
#   - PDFium: downloaded from bblanchon/pdfium-binaries (BSD-3, same Chromium build as the dev dylib), or set
#     PDFIUM_DIR=<dir holding pdfium-ios-device-arm64/ and pdfium-ios-simulator-arm64/> to reuse a download.
#
#   MIRROR=<dir> bash scripts/build_ios_native.sh

set -euo pipefail
cd "$(dirname "$0")/.."

PDFIUM_BUILD="${PDFIUM_BUILD:-7802}"   # Chromium build; must match the pdfium-render feature (pdfium_7763 works with it)
OUT="app/ios/native"
export PATH="$HOME/.cargo/bin:$PATH"   # rustup's rustc, not Homebrew's (which has no iOS targets)

if [ -n "${MIRROR:-}" ]; then CARGO=(rust/cargo-offline.sh); else CARGO=(cargo --manifest-path rust/Cargo.toml); fi

if [ -z "${PDFIUM_DIR:-}" ]; then
    PDFIUM_DIR="$OUT/_pdfium-$PDFIUM_BUILD"
    for flavour in ios-device-arm64 ios-simulator-arm64; do
        if [ ! -f "$PDFIUM_DIR/pdfium-$flavour/lib/libpdfium.dylib" ]; then
            echo "Downloading PDFium $PDFIUM_BUILD ($flavour)…"
            mkdir -p "$PDFIUM_DIR"
            curl -fSL "https://github.com/bblanchon/pdfium-binaries/releases/download/chromium/$PDFIUM_BUILD/pdfium-$flavour.tgz" \
                | tar -xz -C "$PDFIUM_DIR" --one-top-level="pdfium-$flavour"
        fi
    done
fi

build() {  # <rust target> <sdk folder> <pdfium flavour>
    local target="$1" sdk="$2" flavour="$3"
    echo "Building the Rust core for $target…"
    RUSTFLAGS="-C link-arg=-Wl,-install_name,@rpath/libtable_read_ffi.dylib" IPHONEOS_DEPLOYMENT_TARGET=15.0 \
        "${CARGO[@]}" rustc --release --target "$target" -p table-read-ffi --lib --crate-type cdylib
    mkdir -p "$OUT/$sdk"
    cp "rust/target/$target/release/libtable_read_ffi.dylib" "$OUT/$sdk/"
    cp "$PDFIUM_DIR/pdfium-$flavour/lib/libpdfium.dylib" "$OUT/$sdk/"
    install_name_tool -id @rpath/libpdfium.dylib "$OUT/$sdk/libpdfium.dylib"
}

build aarch64-apple-ios iphoneos ios-device-arm64
build aarch64-apple-ios-sim iphonesimulator ios-simulator-arm64

# PDFium's licence text travels with the binary.
mkdir -p "$OUT/licenses"
cp "$PDFIUM_DIR/pdfium-ios-device-arm64/LICENSE" "$OUT/licenses/PDFium-LICENSE.txt"
cp -R "$PDFIUM_DIR/pdfium-ios-device-arm64/licenses/." "$OUT/licenses/"

echo "✓ $OUT:"
ls -la "$OUT/iphoneos" "$OUT/iphonesimulator"
