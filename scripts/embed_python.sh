#!/usr/bin/env bash
# embed_python.sh — Download python-build-standalone and create vendor/python/
#
# Run this once (or when you want to update the bundled Python version) from
# the repo root:
#
#   bash scripts/embed_python.sh
#
# The resulting vendor/python/ directory is committed to the repo and copied
# into the app bundle by the Xcode "Copy Python Runtime" Run Script build phase
# (scripts/xcode_copy_python.sh).
#
# Packages installed into the bundle (core — always present):
#   pdfplumber, pdfminer.six, soundfile
#
# Packages NOT bundled (user-installed on demand via the Install button):
#   kokoro-onnx, onnxruntime, numpy, phonemizer-fork, espeakng-loader
#   → installed to ~/Library/Application Support/TableRead/python-packages/

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_DIR="$REPO_ROOT/vendor/python"

# ── Version pins ──────────────────────────────────────────────────────────────
PYTHON_VERSION="3.12.13"
PBS_TAG="20260510"
# ─────────────────────────────────────────────────────────────────────────────

ARCH="$(uname -m)"
if [ "$ARCH" = "arm64" ]; then
    PBS_ARCH="aarch64-apple-darwin"
else
    PBS_ARCH="x86_64-apple-darwin"
fi

FILENAME="cpython-${PYTHON_VERSION}+${PBS_TAG}-${PBS_ARCH}-install_only_stripped.tar.gz"
URL="https://github.com/indygreg/python-build-standalone/releases/download/${PBS_TAG}/${FILENAME}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "→ Downloading python-build-standalone ${PYTHON_VERSION} (${PBS_ARCH})..."
curl --location --progress-bar "$URL" -o "$TMP/python.tar.gz"

echo "→ Extracting..."
tar -xzf "$TMP/python.tar.gz" -C "$TMP"

# The install_only tarball always extracts to a top-level "python/" directory.
rm -rf "$VENDOR_DIR"
mkdir -p "$(dirname "$VENDOR_DIR")"
mv "$TMP/python" "$VENDOR_DIR"

PYTHON="$VENDOR_DIR/bin/python3"

echo "→ Upgrading pip..."
"$PYTHON" -m pip install --upgrade pip --quiet

echo "→ Installing core packages (pdfplumber, soundfile)..."
"$PYTHON" -m pip install \
    "pdfplumber>=0.11" \
    "soundfile>=0.12" \
    --quiet

echo "→ Stripping test directories, __pycache__, and *.pyc files..."
find "$VENDOR_DIR" -type d -name "test"        -exec rm -rf {} + 2>/dev/null || true
find "$VENDOR_DIR" -type d -name "tests"       -exec rm -rf {} + 2>/dev/null || true
find "$VENDOR_DIR" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find "$VENDOR_DIR" -name "*.pyc"               -delete 2>/dev/null || true
find "$VENDOR_DIR" -name "*.pyo"               -delete 2>/dev/null || true

# Strip idle, tkinter, turtle (GUI tools we don't need)
rm -rf "$VENDOR_DIR/lib/python${PYTHON_VERSION%.*}/idlelib"
rm -rf "$VENDOR_DIR/lib/python${PYTHON_VERSION%.*}/tkinter"
rm -rf "$VENDOR_DIR/lib/python${PYTHON_VERSION%.*}/turtledemo"
rm -f  "$VENDOR_DIR/lib/python${PYTHON_VERSION%.*}/turtle.py"

SIZE="$(du -sh "$VENDOR_DIR" | cut -f1)"
echo ""
echo "✓ vendor/python/ ready — ${SIZE} on disk"
echo ""
echo "Next steps:"
echo "  1. Commit vendor/python/ (add to git — it's intentionally tracked)"
echo "  2. In Xcode, add the 'Copy Python Runtime' Run Script build phase:"
echo "       bash \"\$SRCROOT/scripts/xcode_copy_python.sh\""
echo "     Place it before 'Copy Bundle Resources'."
echo "  3. The first time you distribute, run: bash scripts/embed_python.sh"
echo "     again to pick up any new PBS release."
