# Table Read — Claude Code Guide

## Project overview
Table Read converts screenplay PDFs into per-scene `.m4a` audio dramas using TTS.
Swift/SwiftUI macOS app → Python backend (`backend/audio_worker.py`) via stdin/stdout JSON bridge.

## Branch
Active development is on `parser-block-extraction`. PRs target `main`.

## Testing — run after every code change

```bash
bash scripts/test.sh          # full suite (Python + Swift build + Swift tests)
bash scripts/test.sh python   # backend: pytest + parser scorecard (~3 min)
bash scripts/test.sh python-fast  # parser unit tests only, no scorecard (~1 s)
bash scripts/test.sh swift    # build + XCTest only (~30 s)
```

**Rule: always run `bash scripts/test.sh` before committing. Fix failures before moving on.**

- Python changes → at minimum `bash scripts/test.sh python`
- Swift changes → at minimum `bash scripts/test.sh swift`
- Both touched → `bash scripts/test.sh` (full)

The suite is also checked by a Claude PostToolUse hook (`.claude/settings.json`).

## Parser change protocol — READ THIS before editing `backend/parser.py`

The parser is governed by a **correctness oracle** so changes are convergent, not
whack-a-mole. Four rewrites failed because there was no way to tell "better" from "worse";
this protocol is that way. Follow it for ANY change to `backend/parser.py` or
`backend/corrections_config.json`:

1. **Make the change.**
2. **Measure:** `python scripts/scorecard.py --check`
   Scores the live parser on all 7 corpus scripts against the locked watermark and prints a
   **BETTER / WORSE / HOLD** verdict with per-script deltas (attribution %, kind %, unattributed
   dialog). (Or launch the `parser-regression-guard` agent, which runs this and reports.)
3. **Act on the verdict:**
   - **WORSE** → a script regressed. Fix or revert; do NOT commit. (The git pre-commit hook
     blocks it anyway.)
   - **HOLD** → no measured change — fine for refactors; confirm that's intended.
   - **BETTER** → lock it in:
     `python scripts/scorecard.py --save` (bump watermark), then
     `python scripts/generate_reference.py <ChangedName>` (regen changed baselines), then commit
     (include `Test PDFs/reference/`).
4. **Never tune a global constant to fix one script without re-running the scorecard across ALL
   scripts** — that is the exact trap this system exists to prevent. Prefer per-document logic
   (the `DocumentModel`) over global constants.

Enforcement: a git pre-commit hook (`scripts/git-hooks/pre-commit`, active via
`git config core.hooksPath scripts/git-hooks` — **re-run once after cloning**) blocks any commit
that regresses the scorecard when parser files are staged.

Ground truth: `Test PDFs/reference/*_independent.json` (locked, parser-independent — the oracle).
`{Name}.json` are parser-generated regression baselines (change-detectors; regenerate after
intentional improvements). See memory `parser_audit_root_cause.md` for the full history.

## Project structure

```
backend/
  audio_worker.py      # stdin/stdout JSON bridge — entry point for Swift
  parser.py            # PDF screenplay parser (PyMuPDF blocks → DocumentModel → classify)
  tts_engines.py       # macOS say / Kokoro / OpenAI TTS implementations
  audio_pipeline.py    # scene-by-scene generation orchestration
  voice_assignment.py  # character → voice mapping logic
  tests/               # pytest suite for the parser

Sources/TableRead/
  AppState.swift       # @MainActor ObservableObject — all app state + business logic
  PythonBridge.swift   # Process management: spawns audio_worker.py, streams events
  Models.swift         # Codable structs shared between Swift and Python JSON
  ContentView.swift    # Window chrome, WorkflowStepBar, step transitions
  Views.swift          # ImportView, ReviewView, CastView, GenerateView + components
  SettingsView.swift   # Settings sheet (General, Engines, About tabs)

scripts/
  embed_python.sh      # One-time: download python-build-standalone → vendor/python/
  xcode_copy_python.sh # Xcode Run Script phase: copies vendor/python/ into .app bundle
  test.sh              # Master test runner (python target runs scorecard.py --check)
  scorecard.py         # Parser correctness oracle — scores live parser vs ground truth
  extract_independent.py  # Builds parser-independent ground truth (Test PDFs/reference/*_independent.json)
  generate_reference.py   # Regenerates parser-baseline references after intentional changes
  diagnose_parse.py    # Block-path parser diagnostics for one PDF
  git-hooks/pre-commit # Blocks commits that regress the scorecard (core.hooksPath)

vendor/python/          # Embedded CPython 3.12 — gitignored, built by embed_python.sh
requirements.txt        # Core pip deps (pdfplumber, soundfile)
```

## Python runtime

For dev: `.venv/bin/python3` (Python 3.14 on the dev machine).
For distribution: `vendor/python/bin/python3` (CPython 3.12.13 via python-build-standalone).

PythonBridge prefers the bundled interpreter; falls back to `.venv` / `python3`.

Optional engines (Kokoro, Piper) install to `~/Library/Application Support/TableRead/python-packages/`
via `pip install --target` so they live outside the signed bundle.

To rebuild the embedded runtime:
```bash
bash scripts/embed_python.sh
```

## Key conventions

- All app state lives in `AppState.swift` (`@MainActor`). No state in views.
- Python↔Swift boundary: JSON over stdin/stdout. Worker speaks `GenerationEvent` structs.
- Corrections keyed as `"<pdfPath>|<sceneNumber>|<text.prefix(60)>"` — stable across re-parses.
- Speaker color palette is a top-level `speakerColor(_:)` function in Views.swift — used in both ReviewView and CastView so colors match.
- `NARRATOR_KEY = "__NARRATOR__"` — matches `voice_assignment.py`.

## GitHub issues

| Milestone | Key open issues |
|---|---|
| Voice Engines | #2 Piper, #3 OpenAI preflight, #5 download progress bar |
| Packaging & Distribution | #8 Code signing, #9 DMG, #10 CI pipeline, #11 distribution decision |
| Visual Identity & QoL | #13 Color system, #15 Bug reporting, #17 Onboarding |
| Parser & Core Quality | #19 Additional screenplay formats |
| iOS | #21–26 full iOS port |
