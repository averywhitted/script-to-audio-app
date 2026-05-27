#!/usr/bin/env bash
# test.sh — run all Table Read tests
#
# Usage:
#   bash scripts/test.sh          # full suite
#   bash scripts/test.sh python   # Python backend only
#   bash scripts/test.sh swift    # Swift build + unit tests only
#
# Exit code is non-zero if any suite fails.

set -euo pipefail
cd "$(dirname "$0")/.."

SUITE="${1:-all}"
FAILED=0

# ── helpers ──────────────────────────────────────────────────────────────────

section() { echo ""; echo "━━━ $* ━━━"; }
ok()      { echo "✓ $*"; }
fail()    { echo "✗ $*"; FAILED=1; }

# ── Python backend ────────────────────────────────────────────────────────────

run_python() {
    section "Python backend tests"
    PYTHON=""
    for candidate in vendor/python/bin/python3 .venv/bin/python3 .venv/bin/python python3; do
        if [ -x "$candidate" ] 2>/dev/null || command -v "$candidate" &>/dev/null; then
            PYTHON="$candidate"
            break
        fi
    done
    if [ -z "$PYTHON" ]; then
        fail "No Python found. Run: bash scripts/embed_python.sh"
        return
    fi
    if "$PYTHON" -m pytest backend/tests/ -v --tb=short 2>&1; then
        ok "Python tests passed"
    else
        fail "Python tests FAILED"
    fi
}

# ── Swift build + unit tests ──────────────────────────────────────────────────

run_swift() {
    section "Swift build"
    if xcodebuild \
        -project TableRead.xcodeproj \
        -scheme TableRead \
        -destination 'platform=macOS' \
        build 2>&1 | tail -3 | grep -q "BUILD SUCCEEDED"; then
        ok "Swift build passed"
    else
        fail "Swift build FAILED"
        return
    fi

    section "Swift unit tests"
    if xcodebuild \
        test \
        -project TableRead.xcodeproj \
        -scheme TableRead \
        -destination 'platform=macOS' 2>&1 \
        | grep -E "Test Suite|passed|failed|error:" \
        | grep -v "^$"; then
        # xcodebuild test exits non-zero on test failure
        ok "Swift tests passed"
    else
        fail "Swift tests FAILED"
    fi
}

# ── dispatch ──────────────────────────────────────────────────────────────────

case "$SUITE" in
    python) run_python ;;
    swift)  run_swift  ;;
    all)    run_python; run_swift ;;
    *)
        echo "Usage: bash scripts/test.sh [python|swift|all]"
        exit 1
        ;;
esac

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "✓ All tests passed."
else
    echo "✗ One or more test suites failed."
    exit 1
fi
