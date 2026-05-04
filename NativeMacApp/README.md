# Script Audio Drama Native Shell

This is the first SwiftUI shell for the macOS refresh. It is intentionally
separate from the existing Tkinter app while the native experience is rebuilt.

## Run

From this folder:

```sh
swift run ScriptAudioDrama
```

The app calls `../backend/audio_worker.py` for parser and estimate operations.
When the repository `.venv` exists, the bridge uses it automatically so Python
dependencies match the current launcher.

## Current Slice

- Native macOS split-view shell
- PDF import through a native file picker
- Python worker bridge over JSON
- Script summary, scene selection, engine cards, and OpenAI preflight estimates
- Voice-library placeholder for future Kokoro/Piper downloads

Generation is still handled by the existing Python app. The next step is moving
generation to the worker as structured progress events, then wiring the SwiftUI
run controls to that job stream.
