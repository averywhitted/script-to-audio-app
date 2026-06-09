# Table Read — Claude Code Guide

## Project overview
Table Read converts screenplay PDFs into per-scene `.m4a` audio dramas using TTS.
Swift/SwiftUI macOS app → Python backend (`backend/audio_worker.py`) via stdin/stdout JSON bridge.

## Branch
Active development is on `parser-refactor`. PRs target `main`.

## Testing — run after every code change

```bash
bash scripts/test.sh          # full suite (Python + Swift build + Swift tests)
bash scripts/test.sh python   # backend only (fast, ~2 s)
bash scripts/test.sh swift    # build + XCTest only (~30 s)
```

**Rule: always run `bash scripts/test.sh` before committing. Fix failures before moving on.**

- Python changes → at minimum `bash scripts/test.sh python`
- Swift changes → at minimum `bash scripts/test.sh swift`
- Both touched → `bash scripts/test.sh` (full)

The suite is also checked by a pre-commit hook (`.claude/settings.json`).

## Project structure

```
backend/
  audio_worker.py      # stdin/stdout JSON bridge — entry point for Swift
  parser.py            # PDF screenplay parser (pdfplumber)
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
  test.sh              # Master test runner

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
