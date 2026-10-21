#!/usr/bin/env bash
# test.sh — run all Table Read tests
#
# Usage:
#   bash scripts/test.sh          # full suite
#   bash scripts/test.sh python   # Python backend only
#   bash scripts/test.sh swift    # Swift build + unit tests only
#   bash scripts/test.sh flutter  # Flutter app: analyze + tests (logic, screens, real worker)
#   bash scripts/test.sh rust     # Rust core: cargo tests, license policy, Rust parser vs Python, extraction vs the answer keys
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
    section "Parser answer keys"
    if "$PYTHON" scripts/answer_key.py --check 2>&1; then
        ok "Answer keys: nothing got worse"
    else
        fail "Answer keys: something got worse"
    fi
}

# ── Python fast subset (used by the edit hook during parser work) ──────────────
# Runs the parser UNIT tests only — skips the slow reference/answer-key pass, which
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

# ── Flutter app (app/) ───────────────────────────────────────────────────────
# Screen renders compare against test/goldens/. After an intentional visual
# change, refresh them with: (cd app && flutter test --update-goldens test/screens_test.dart)

run_flutter() {
    section "Flutter analyze"
    if ! command -v flutter &>/dev/null; then
        fail "Flutter not installed (brew install --cask flutter)"
        return
    fi
    if (cd app && flutter analyze --no-fatal-infos 2>&1 | tail -3); then
        ok "Flutter analyze passed"
    else
        fail "Flutter analyze FAILED"
    fi
    section "Flutter tests"
    if (cd app && flutter test 2>&1 | tail -5); then
        ok "Flutter tests passed"
    else
        fail "Flutter tests FAILED"
    fi
}

# ── Rust core (rust/) ────────────────────────────────────────────────────────
# Not part of `all` yet: needs the Rust toolchain (~/.cargo/bin). On the sandboxed dev Mac Rust binaries cannot reach
# crates.io, so build a local registry first and pass it: MIRROR=<dir> bash scripts/test.sh rust
# (python3 scripts/local_crate_mirror.py <dir> pdfium-render serde serde_json --features "serde:derive").

run_rust() {
    section "Rust core"
    CARGO="$HOME/.cargo/bin/cargo"
    if [ ! -x "$CARGO" ]; then
        fail "Rust not installed (rustup, see docs/adr/0002-shared-rust-core.md)"
        return
    fi
    if [ -n "${MIRROR:-}" ]; then CARGO_RUN="$PWD/rust/cargo-offline.sh"; else CARGO_RUN="$CARGO"; fi
    if (cd rust && "$CARGO_RUN" test 2>&1 | tail -6); then
        ok "cargo test passed"
    else
        fail "cargo test FAILED"
        return
    fi
    section "License policy (permissive-only core)"
    if python3 scripts/check_licenses.py 2>&1 | tail -8; then
        ok "License check passed"
    else
        fail "License check FAILED"
    fi
    section "PDFium extraction vs the answer keys"
    PYTHON=".venv/bin/python3"
    if ! (cd rust && "$CARGO_RUN" build --release 2>&1 | tail -2); then
        fail "Rust release build FAILED"
        return
    fi
    rc=0
    out=$("$PYTHON" scripts/rust_parser_diff.py 2>&1) || rc=$?
    echo "$out" | grep -v '^\[parser\]' | tail -3
    if [ "$rc" -eq 0 ]; then
        ok "Rust parser stages identical to Python"
    else
        fail "Rust parser differs from Python"
    fi
    rc=0
    out=$(EXTRACTOR=rust "$PYTHON" spikes/pdfium_extract/scripts/pdfium_answer_key.py --check 2>&1) || rc=$?
    echo "$out" | grep -v '^\[parser\]' | tail -6
    if [ "$rc" -eq 0 ]; then
        ok "Extraction gate: nothing got worse"
    else
        fail "Extraction gate: something got worse"
    fi
}

# ── dispatch ──────────────────────────────────────────────────────────────────

case "$SUITE" in
    python)      run_python ;;
    python-fast) run_python_fast ;;
    swift)       run_swift  ;;
    flutter)     run_flutter ;;
    rust)        run_rust ;;
    all)         run_python; run_swift; run_flutter ;;
    *)
        echo "Usage: bash scripts/test.sh [python|python-fast|swift|flutter|rust|all]"
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
