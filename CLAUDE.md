# Table Read — Claude Code Guide

## Project overview
Table Read converts screenplay PDFs into per-scene `.m4a` audio dramas using TTS.
Swift/SwiftUI macOS app → Python backend (`backend/audio_worker.py`) via stdin/stdout JSON bridge.

## Branch
Active development is on `parser-block-extraction`. PRs target `main`.

## Testing — run after every code change

```bash
bash scripts/test.sh          # full suite (Python + Swift build + Swift tests)
bash scripts/test.sh python   # backend: pytest + parser answer keys (~4 min)
bash scripts/test.sh python-fast  # parser unit tests only, no answer keys (~3 s)
bash scripts/test.sh swift    # build + XCTest only (~30 s)
```

**Rule: always run `bash scripts/test.sh` before committing. Fix failures before moving on.**

- Python changes → at minimum `bash scripts/test.sh python`
- Swift changes → at minimum `bash scripts/test.sh swift`
- Both touched → `bash scripts/test.sh` (full)

The suite is also checked by a Claude PostToolUse hook (`.claude/settings.json`).

**Green tests aren't enough on their own to trust the app runs.** `backend/tests/test_worker_contract.py`
spawns `audio_worker.py` as a real subprocess (JSON on stdin/stdout, exactly like
`PythonBridge.swift`) and checks that every `"command": "..."` string Swift can send is
actually recognized by the worker's dispatch — scraped straight out of `PythonBridge.swift`,
never hand-duplicated. It runs automatically as part of `bash scripts/test.sh python`, no
extra command needed. This exists because a Swift-side command with no matching Python
handler previously shipped past a fully green `scripts/test.sh` and only broke live, in the
running app. `bash scripts/test.sh swift` also now diffs the app bundle's copied
`Contents/Resources/backend/*.py` against source after every build, since Xcode's "Copy
Python Runtime" phase can otherwise skip re-copying a changed `backend/` file on an
incremental build.

## Parser change protocol — READ THIS before editing `backend/parser.py`

The parser is judged by **two answer keys** that check what a listener hears — was each line read
by the right voice (dialogue by its character, directions by the narrator, names/headings/page junk
not at all)? — on every line, short ones included. Four rewrites failed because there was no way to
tell "better" from "worse"; this is that way. Follow it for ANY change to `backend/parser.py` or
`backend/corrections_config.json`:

1. **Make the change.**
2. **Measure:** `python scripts/answer_key.py` — scores both keys and lists every unit/line that
   changed versus the baseline (fixed, or BROKEN, by name).
   - **Generated scripts** (`synth_generate.py` → `synth_score.py`): six layout families modelled
     on the real corpus, varied by page size/font/italics; answers exact by construction. The
     scorer is itself tested (`backend/tests/test_synth_score.py`: a perfect parse scores 100%).
   - **Real PDFs** (`label_sample.py` → `real_score.py`): 403 lines (31 per PDF) hand-labelled by
     the user; 95% range about ±2.5 pts. Local only (`real_sample*.json` is gitignored: it names
     the PDFs). Use it as the **judge**, not as design input — don't build fixes around the
     specific sampled lines. A fresh held-out sample is the final exam for big changes.
3. **The rule:** nothing that was right may go wrong — no generated unit, no labelled real line —
   unless we've reviewed it together and accepted it with `python scripts/answer_key.py --save`.
   Then `python scripts/generate_reference.py <ChangedName>` and use the diff of
   `Test PDFs/reference/{Name}.json` to confirm *only* the intended things changed; commit with
   `Test PDFs/reference/`.
4. **Never tune a global constant to fix one script.** Prefer per-document logic (the
   `DocumentModel`: learn each script's own conventions) over global constants.

Enforcement: the pre-commit hook (`scripts/git-hooks/pre-commit`, active via
`git config core.hooksPath scripts/git-hooks` — **re-run once after cloning**) runs
`answer_key.py --check` whenever parser files are staged.

Decisions on record: bare timing beats ("Beat.", "PAUSE", "(beat)") are never read aloud; real
dialogue always carries forward to the last speaker. Baselines (Oct 2026): generated 96.5%, real
sample 96.2%.

Legacy: `scripts/scorecard.py` and `Test PDFs/reference/*_independent.json` were the previous oracle.
Their "ground truth" was produced by per-script rules (not checked by a person) and only about half
of each script was scorable, so they no longer gate anything. `{Name}.json` remain useful as
"what exactly changed" diffs. See memory `parser_audit_oct2026.md` for the history.

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
  test.sh              # Master test runner (python target runs answer_key.py --check)
  answer_key.py        # Parser regression gate: both answer keys vs baseline (--check / --save)
  synth_generate.py    # Generated scripts with exact answers (6 layout families)
  synth_score.py       # Scores the parser on them: right voice per unit
  label_sample.py      # Local page to hand-label a random sample of real PDF lines
  real_score.py        # Scores the parser on the labelled sample (95% range)
  scorecard.py         # LEGACY oracle (rule-made ground truth); no longer gates
  extract_independent.py  # Builds parser-independent ground truth (Test PDFs/reference/*_independent.json)
  generate_reference.py   # Regenerates parser-baseline references after intentional changes
  diagnose_parse.py    # Block-path parser diagnostics for one PDF
  git-hooks/pre-commit # Blocks parser commits where anything gets worse (answer_key.py --check)

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
