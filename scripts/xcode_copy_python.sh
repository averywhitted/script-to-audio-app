#!/usr/bin/env bash
# xcode_copy_python.sh — Xcode Run Script build phase
#
# Copies vendor/python/ into the app bundle so the embedded interpreter is
# available at runtime without requiring any user Python installation.
#
# Add this as a Run Script build phase in Xcode (Build Phases → + → New Run
# Script Phase). Paste:
#
#   bash "$SRCROOT/scripts/xcode_copy_python.sh"
#
# Place the phase BEFORE "Copy Bundle Resources".
# Input files: $(SRCROOT)/vendor/python (mark so Xcode can skip if unchanged)

set -euo pipefail

RESOURCES="$BUILT_PRODUCTS_DIR/$CONTENTS_FOLDER_PATH/Resources"

# ── 1. Embedded Python runtime ───────────────────────────────────────────────
SRC_PY="$SRCROOT/vendor/python"
DEST_PY="$RESOURCES/python"

if [ ! -d "$SRC_PY" ]; then
    echo "warning: vendor/python/ not found — skipping Python bundle copy."
    echo "         Run:  bash scripts/embed_python.sh"
else
    echo "Copying Python runtime into app bundle..."
    rm -rf "$DEST_PY"
    cp -R "$SRC_PY" "$DEST_PY"
    echo "✓ Python runtime copied to $DEST_PY"
fi

# ── 2. Backend Python files ───────────────────────────────────────────────────
# Bundle the worker and all modules so the subprocess never needs to read files
# from ~/Documents (which triggers a TCC permission prompt).
DEST_BACKEND="$RESOURCES/backend"
mkdir -p "$DEST_BACKEND"
cp "$SRCROOT/backend/"*.py "$DEST_BACKEND/"
echo "✓ Backend Python files copied to $DEST_BACKEND"
