# 0002 — Shared Rust core, two crates, Python retired per component

Status: accepted (2026-10-21, Avery)

## Context
Goal: every platform shares the same parser and renderer source so improvements propagate equally,
and the result must be at least as good as the Python worker it replaces. Python cannot run on iOS.

## Decision
- A Rust workspace with two groups of crates:
  - **core** (permissive only, built for macOS and iOS): PDF extraction (PDFium), parser,
    cue and project-file logic, sync. Bridged to Flutter with `flutter_rust_bridge`.
  - **render** (desktop only, may link GPL): Kokoro via ONNX Runtime (`ort`) with espeak-ng, Piper,
    a thin Apple adapter for system voices and M4A (AudioToolbox). English only.
- Python stays in the repo as a dev-only reference oracle. A component leaves the shipped Mac app
  when its Rust replacement passes its gate:
  - **Parser gate:** extraction comparison against PyMuPDF passes; answer keys (generated and real
    labelled) no worse than the Python baseline; "nothing right may go wrong". Python parser changes
    are frozen during the port; improvements resume in Rust after cutover.
  - **Renderer gate:** cue files match (lines, speakers, order, timings within tolerance), audio length
    and loudness within tolerance, Avery listens to a set of scenes.
- The ML element classifier (shadow mode only) is not ported.
- OpenAI TTS is removed everywhere. Engines: system voices, Kokoro, Piper (desktop). More engines
  are a later milestone.
- The iPhone does no voice rendering. Cloud rendering is parked.

## Consequences
- Early risks: PDFium block builder vs PyMuPDF blocks, italic detection, `flutter_rust_bridge` static
  linking on iOS/macOS (Xcode symbol stripping), `ort` still a release candidate.
- Rust iOS targets need `rustup`; the Homebrew toolchain on the dev Mac lacks them.
