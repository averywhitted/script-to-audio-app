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

SRC="$SRCROOT/vendor/python"
DEST="$BUILT_PRODUCTS_DIR/$CONTENTS_FOLDER_PATH/Resources/python"

if [ ! -d "$SRC" ]; then
    echo "warning: vendor/python/ not found — skipping Python bundle copy."
    echo "         Run:  bash scripts/embed_python.sh"
    exit 0
fi

echo "Copying Python runtime into app bundle..."
rm -rf "$DEST"
cp -R "$SRC" "$DEST"
echo "✓ Python runtime copied to $DEST"
