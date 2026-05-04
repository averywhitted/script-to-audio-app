# Script → Audio Drama

A small Mac app that takes a PDF of a play or screenplay and turns it into a folder of audio files — one per scene — with each character voiced by a different automated voice and stage directions read by a separate narrator voice.

## Run it

In Finder, double-click **`launch.command`**.

(If macOS blocks the launcher the first time, right-click it and choose Open. You'll only need to do this once.)

The launcher creates a hidden virtual environment alongside the app on first run, installs `pdfplumber`, and opens the GUI.

## Use it

1. **Choose a script PDF.** The app parses it and shows you the cast list.
2. **Pick a voice engine.**
   - **macOS built-in** is offline, free, and instant. Voice quality is decent — install the Premium Siri voices via *System Settings → Accessibility → Spoken Content → System Voice → Manage Voices* for the best results.
   - **OpenAI TTS** sounds more natural and expressive but needs an API key (paste it into the field) and costs about \$1–3 per full play.
3. **Review voice assignments.** Each character gets a distinct voice automatically; use the dropdowns to change any of them. The narrator (top of the list) reads stage directions.
4. **Pick an output folder.**
5. **Click *Generate audio drama*.** Progress shows scene-by-scene; the output folder opens in Finder when done.

## What you get

One `.m4a` file per scene, named like `Scene_04_Present_Day_Alley_The_Ruby_Job.m4a`. Drop them into the Music app, Apple Podcasts, or any audio player and they'll play in scene order.

## How it works

- **`parser.py`** uses `pdfplumber`'s layout-aware text extraction to detect scene headers, character cues, dialog, parentheticals, and stage directions based on indentation patterns common to plays and screenplays.
- **`tts_engines.py`** wraps both the macOS `say` command and the OpenAI TTS API behind one interface.
- **`voice_assignment.py`** spreads voices across characters, matching the gender hint in the cast list when available, and reserves a separate voice for the narrator.
- **`audio_pipeline.py`** synthesizes each line, normalizes everything to PCM WAV with `afconvert`, concatenates with calibrated pauses (longer around stage directions), and encodes the per-scene result to AAC inside an M4A container.
- **`audio_drama.py`** is the Tkinter GUI.

## Requirements

- macOS (built-in `say` and `afconvert`)
- Python 3.9+

The launcher takes care of everything else.
