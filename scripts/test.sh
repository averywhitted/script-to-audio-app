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
    # Prefer the dev venv for tests (pytest lives there, not in the bundled runtime)
    PYTHON=""
    for candidate in .venv/bin/python3 .venv/bin/python vendor/python/bin/python3 python3; do
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

    # Correctness oracle: score the live parser against locked ground truth and
    # fail on any regression vs the watermark. This catches "fixed one script,
    # broke another" — which the reference tests (change detectors) cannot.
    section "Parser correctness scorecard"
    if "$PYTHON" scripts/scorecard.py --check 2>&1; then
        ok "Scorecard: no regression vs watermark"
    else
        fail "Scorecard: REGRESSION vs watermark"
    fi
}

# ── Python fast subset (used by the edit hook during parser work) ──────────────
# Runs the parser UNIT tests only — skips the slow reference/scorecard pass, which
# is run explicitly at stage boundaries instead. Keeps the per-edit hook snappy.

run_python_fast() {
    section "Python unit tests (fast: no reference/scorecard)"
    PYTHON=""
    for candidate in .venv/bin/python3 .venv/bin/python vendor/python/bin/python3 python3; do
        if [ -x "$candidate" ] 2>/dev/null || command -v "$candidate" &>/dev/null; then
            PYTHON="$candidate"; break
        fi
    done
    if [ -z "$PYTHON" ]; then fail "No Python found."; return; fi
    if "$PYTHON" -m pytest backend/tests/ -q -k "not reference" 2>&1 | tail -20; then
        ok "Python fast tests passed"
    else
        fail "Python fast tests FAILED"
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

    # Belt-and-suspenders: the "Copy Python Runtime" build phase bundles
    # backend/*.py into the app so the worker subprocess never needs Documents
    # access. That phase's declared inputPaths only track vendor/python, so an
    # incremental Xcode build CAN skip re-copying backend/*.py after a source
    # edit (this is exactly how a real "Unknown command" bug shipped once,
    # even though scripts/test.sh was green — see CLAUDE.md). alwaysOutOfDate
    # on that phase should prevent it going forward; this check catches it if
    # that ever regresses.
    section "Bundled backend freshness"
    BUILT_PRODUCTS_DIR=$(xcodebuild -showBuildSettings \
        -project TableRead.xcodeproj -scheme TableRead \
        -destination 'platform=macOS' 2>/dev/null \
        | awk -F'= ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')
    BUNDLED_BACKEND="$BUILT_PRODUCTS_DIR/TableRead.app/Contents/Resources/backend"
    if [ -z "$BUILT_PRODUCTS_DIR" ] || [ ! -d "$BUNDLED_BACKEND" ]; then
        fail "Could not locate bundled backend/ in the built app at '$BUNDLED_BACKEND' — did the Copy Python Runtime phase run?"
    else
        STALE=0
        for src in backend/*.py; do
            name="$(basename "$src")"
            if ! diff -q "$src" "$BUNDLED_BACKEND/$name" >/dev/null 2>&1; then
                echo "  ✗ stale in bundle: $name"
                STALE=1
            fi
        done
        if [ "$STALE" -eq 0 ]; then
            ok "Bundled backend/*.py matches source"
        else
            fail "Bundled backend/*.py is stale — rebuild needed (Copy Python Runtime phase didn't refresh it)"
        fi
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
    python)      run_python ;;
    python-fast) run_python_fast ;;
    swift)       run_swift  ;;
    all)         run_python; run_swift ;;
    *)
        echo "Usage: bash scripts/test.sh [python|python-fast|swift|all]"
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
