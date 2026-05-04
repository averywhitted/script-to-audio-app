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
- macOS voice generation for preview or selected scenes through the Python worker
- Native progress/log surface for generation jobs
- Voice-library placeholder for future Kokoro/Piper downloads

OpenAI, Kokoro, and Piper generation are still placeholders in the SwiftUI app.
The next step is adding real cancellation, output-folder selection, and local
voice-model download/install flows.
