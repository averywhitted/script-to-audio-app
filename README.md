# Table Read

**Table Read** converts screenplay and stage-play PDFs into per-scene `.m4a` audio dramas — each character voiced by a distinct TTS voice, stage directions read by a narrator, and simultaneous/overlapping dialogue mixed in real time.

It is a native macOS app (SwiftUI, macOS 13+) with an embedded Python backend for PDF parsing and audio synthesis.

---

## Features

### Import & Parse
- Drag-and-drop or open any screenplay / stage-play PDF
- Automatically detects script format: heist, dash-dialog, two-column overlap, and more
- Extracts scenes, characters, dialogue, parentheticals, and stage directions
- Detects simultaneous/overlapping speech (slash-cues, compound speaker cues, two-column PDF layout)

### Review (per-line editing)
- Browse every scene and element with inline editing
- Change speaker, kind (dialog / narration), or rewrite text
- Mark lines as noise (excluded from generation)
- Add new lines between parsed elements
- Link any two dialog lines as simultaneous (played mixed together)
- Unlink / relink parser-detected simultaneous pairs
- Per-voice independent Remove / Restore on simultaneous lines
- **Undo / Redo** (Cmd+Z / Cmd+Shift+Z) for all edits, up to 50 steps
- Floating undo bar shows current edit depth

### Voice Assignment (Cast)
- Auto-assigns voices per character with gender-aware round-robin selection
- **Gender selector** (Male / Female / Neutral) per character — overrides the parser's gender hint
- Changing gender auto-assigns the next unclaimed voice of that gender
- Full voice picker override always available
- Live voice preview (plays a sample before committing)

### TTS Engines
| Engine | Quality | Cost | Setup |
|--------|---------|------|-------|
| **macOS Voices** | Good | Free, offline | Built-in (install Premium Siri voices for best results) |
| **Kokoro Local** | Excellent | Free, offline | ~88 MB one-time download, Apache-licensed |
| **OpenAI TTS** | Excellent | ~$0.015/1K chars | API key required |
| **Piper** | Good | Free, offline | Coming soon |

### Generate
- Renders one `.m4a` per scene (AAC, 44.1 kHz)
- Simultaneous lines are synthesised independently and mixed to stereo
- Scene-level progress with per-element detail
- Skip or re-render individual scenes
- Output folder opens in Finder on completion
- Optional macOS notification on completion

### Other
- Recent scripts list with quick-open
- Scene title overrides
- Settings: engine selection, output directory, notification preferences, OpenAI key
- In-app bug reporting (Cmd+Shift+B) → creates a GitHub issue
- Onboarding for first launch (Help → Table Read Help)
- Personal Use License — free for personal use, source-available

---

## Requirements

- **macOS 13 Ventura** or later
- **Xcode 15+** to build from source
- An internet connection on first run when installing Kokoro or using OpenAI (optional)

---

## Building from source

```bash
git clone https://github.com/averywhitted/script-to-audio-app.git
cd script-to-audio-app
git checkout parser-refactor   # active development branch

# Set up the Python venv (used during development; bundled runtime used in the .app)
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt

# Open in Xcode
open TableRead.xcodeproj
```

The app bundles its own CPython 3.12 runtime — no system Python required for end users.
Run `bash scripts/embed_python.sh` once to download the embedded runtime into `vendor/python/`.

---

## Development

### Running tests

```bash
bash scripts/test.sh          # full suite: Python + Swift build + XCTest
bash scripts/test.sh python   # Python backend only (~0.5 s, 152 tests)
bash scripts/test.sh swift    # Swift build + XCTest only (~30 s)
```

Tests run automatically as a pre-commit hook.

### Project structure

```
backend/
  audio_worker.py      # stdin/stdout JSON bridge — entry point for Swift
  parser.py            # PDF screenplay parser (pdfplumber)
  tts_engines.py       # macOS say / Kokoro / OpenAI TTS implementations
  audio_pipeline.py    # scene-by-scene orchestration + overlap mixing
  voice_assignment.py  # character → voice mapping
  tests/               # pytest suite (152 tests)

Sources/TableRead/
  AppState.swift        # @MainActor ObservableObject — all app state + business logic
  PythonBridge.swift    # Process management: spawns audio_worker.py, streams events
  Models.swift          # Codable structs shared between Swift and Python JSON
  ContentView.swift     # Window chrome, WorkflowStepBar, step transitions
  Views.swift           # ImportView, ReviewView, CastView, GenerateView + components
  SettingsView.swift    # Settings sheet (General, Engines, About tabs)
  TableReadApp.swift    # App entry point, menu commands (undo/redo, help)
  iOS/                  # iOS port (in progress — ios-onnx-tts branch)

scripts/
  embed_python.sh       # One-time: downloads CPython 3.12 → vendor/python/
  xcode_copy_python.sh  # Xcode Run Script phase: copies runtime into .app bundle
  test.sh               # Master test runner
```

### Architecture

Swift talks to Python exclusively via **stdin/stdout JSON**. Swift spawns `audio_worker.py` as a child process, writes a JSON command, and streams `GenerationEvent` structs back line-by-line. No network, no IPC sockets.

**Corrections** (Review edits) are stored in `UserDefaults` as `[String: ParserCorrection]` keyed by `"pdfPath|sceneNumber|textPrefix"`. At generation time, all corrections for the active PDF are serialised to JSON and sent to Python, where `_apply_corrections()` mutates the parsed script in-place before rendering.

### Active branch

All current development is on **`parser-refactor`**. PRs target `main`.

| Branch | Purpose |
|--------|---------|
| `main` | Stable releases |
| `parser-refactor` | Active development |
| `ios-onnx-tts` | iOS port: AVSpeechSynthesizer + ONNX Kokoro engine |

---

## Roadmap

| Area | Status |
|------|--------|
| Simultaneous/overlap speech — parser + UI + audio | ✅ Done |
| Undo/redo for Review edits | ✅ Done |
| Gender-aware voice assignment | ✅ Done |
| macOS Voices engine | ✅ Done |
| Kokoro local engine | ✅ Done |
| OpenAI TTS engine | ✅ Done |
| In-app bug reporting | ✅ Done |
| Onboarding | ✅ Done |
| Piper local engine | 🔲 Planned |
| OpenAI preflight / partial resume | 🔲 Planned |
| Kokoro download progress bar | 🔲 Planned |
| Code signing + notarization | 🔲 Planned |
| DMG installer | 🔲 Planned |
| GitHub Releases CI pipeline | 🔲 Planned |
| iOS port | 🔲 In progress (ios-onnx-tts branch) |
| Additional screenplay formats | 🔲 Planned |

---

## License

**Table Read — Personal Use License**
Copyright © 2025 Avery Whitted. All rights reserved.

Free for personal, non-commercial use. Source is available for inspection and study.
See [LICENSE](LICENSE) for full terms.

[Donate on Buy Me a Coffee](https://buymeacoffee.com/averywhitted)
