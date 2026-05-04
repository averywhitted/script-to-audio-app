"""
audio_pipeline.py
=================

Drive the TTS engine across a parsed Script and produce one M4A file per
scene. Pipeline:

  1. For each scene element (dialog/parenthetical/stage_direction):
       - Determine voice (character voice or narrator)
       - TTS engine synthesizes a short audio clip to a temp file
  2. Each clip is normalized to a uniform PCM WAV using `afconvert`
     (16-bit linear PCM, mono, 22.05 kHz). This makes concatenation safe
     regardless of which engine produced the source clip.
  3. Clips are concatenated using Python's `wave` module, with calibrated
     silences between elements (longer pauses around stage directions).
  4. The combined WAV is converted to M4A with `afconvert`.

The pipeline emits progress callbacks so the GUI can update.
"""

from __future__ import annotations

import os
import re
import shutil
import struct
import subprocess
import tempfile
import wave
from dataclasses import dataclass, field
from typing import Callable, List, Optional

from parser import Element, Scene, Script
from tts_engines import TTSEngine, TTSFatalError
from voice_assignment import Assignment, NARRATOR_KEY


# Uniform PCM format used internally
PCM_SAMPLE_RATE = 22050
PCM_SAMPLE_WIDTH = 2  # bytes (16-bit)
PCM_CHANNELS = 1


# Pause durations (seconds) inserted between elements
PAUSE_BETWEEN_DIALOG_SAME_SPEAKER = 0.25
PAUSE_BETWEEN_DIALOG_DIFFERENT_SPEAKER = 0.45
PAUSE_AROUND_STAGE_DIRECTION = 0.7
PAUSE_AROUND_PARENTHETICAL = 0.35
PAUSE_AT_SCENE_START = 1.0
PAUSE_AT_SCENE_END = 1.5


@dataclass
class GenerationProgress:
    scene_index: int          # 0-based
    total_scenes: int
    scene_title: str
    element_index: int        # 0-based within scene
    total_elements_in_scene: int
    message: str = ""


@dataclass
class GenerationResult:
    output_dir: str
    files: List[str] = field(default_factory=list)
    skipped_scenes: List[str] = field(default_factory=list)
    errors: List[str] = field(default_factory=list)


@dataclass
class RenderChunk:
    start_index: int
    end_index: int
    kind: str
    speaker: Optional[str]
    voice_id: str
    text: str


# ---------------------------------------------------------------------------
# Audio utilities (built-in tools only)
# ---------------------------------------------------------------------------


def _afconvert_to_wav(src: str, dst: str) -> None:
    """Convert any audio file (AIFF, MP3, etc.) to a uniform PCM WAV."""
    cmd = [
        "afconvert",
        "-f", "WAVE",
        "-d", f"LEI16@{PCM_SAMPLE_RATE}",
        "-c", str(PCM_CHANNELS),
        src, dst,
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(
            f"afconvert (to WAV) failed: {result.stderr.strip() or '(empty)'}. "
            f"src={src!r}"
        )


def _afconvert_to_m4a(src_wav: str, dst_m4a: str, bitrate_kbps: int = 96) -> None:
    """Encode a WAV file to AAC inside an M4A container.

    Tries several encoder configurations because the AAC encoder on
    different macOS versions accepts different parameter combinations.
    """
    # Variations, in order of preference (smallest/cleanest first).
    variants = [
        # Bare-minimum — let afconvert pick everything
        ["afconvert", "-f", "m4af", "-d", "aac",
         src_wav, dst_m4a],
        # Explicit sample rate (some encoders need this)
        ["afconvert", "-f", "m4af", "-d", f"aac@{PCM_SAMPLE_RATE}",
         src_wav, dst_m4a],
        # Bumped sample rate to the AAC sweet spot
        ["afconvert", "-f", "m4af", "-d", "aac@44100",
         src_wav, dst_m4a],
        # Explicit bitrate too
        ["afconvert", "-f", "m4af", "-d", "aac@44100",
         "-b", str(bitrate_kbps * 1000), src_wav, dst_m4a],
    ]
    last_err = ""
    for cmd in variants:
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode == 0:
            return
        last_err = result.stderr.strip() or "(empty)"
    raise RuntimeError(
        f"afconvert (to M4A) failed after trying {len(variants)} encoder "
        f"variants. Last error: {last_err}. src={src_wav!r}"
    )


def _silence_frames(seconds: float) -> bytes:
    n = int(seconds * PCM_SAMPLE_RATE) * PCM_SAMPLE_WIDTH * PCM_CHANNELS
    return b"\x00" * n


def _open_writer(path: str) -> wave.Wave_write:
    w = wave.open(path, "wb")
    w.setnchannels(PCM_CHANNELS)
    w.setsampwidth(PCM_SAMPLE_WIDTH)
    w.setframerate(PCM_SAMPLE_RATE)
    return w


def _append_wav(writer: wave.Wave_write, wav_path: str) -> None:
    with wave.open(wav_path, "rb") as r:
        # Sanity check: the source MUST be in our uniform format. afconvert
        # should have produced this. If not, refuse rather than emit garbage.
        assert r.getnchannels() == PCM_CHANNELS
        assert r.getsampwidth() == PCM_SAMPLE_WIDTH
        assert r.getframerate() == PCM_SAMPLE_RATE
        writer.writeframes(r.readframes(r.getnframes()))


# ---------------------------------------------------------------------------
# Filename helper
# ---------------------------------------------------------------------------


def _sanitize_filename_part(s: str) -> str:
    s = s.strip()
    s = re.sub(r"[^\w\s\-]", "", s, flags=re.UNICODE)
    s = re.sub(r"[\s\-]+", "_", s)
    s = s.strip("_")
    return s[:60] or "Scene"


def scene_filename(scene: Scene, ext: str = "m4a") -> str:
    return f"Scene_{scene.number:02d}_{_sanitize_filename_part(scene.title)}.{ext}"


# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------


def generate_scene(
    scene: Scene,
    engine: TTSEngine,
    assignment: Assignment,
    output_dir: str,
    work_dir: str,
    progress_cb: Optional[Callable[[GenerationProgress], None]] = None,
    scene_index: int = 0,
    total_scenes: int = 1,
    cancel_check: Optional[Callable[[], bool]] = None,
) -> Optional[str]:
    """Render one scene to a single M4A file. Returns the output path, or
    None if the scene had no audible content (and therefore no file)."""
    elements = [e for e in scene.elements if e.text.strip()]
    if not elements:
        return None

    os.makedirs(work_dir, exist_ok=True)
    os.makedirs(output_dir, exist_ok=True)

    combined_wav = os.path.join(work_dir, f"scene_{scene.number:02d}_combined.wav")
    writer = _open_writer(combined_wav)
    try:
        # Lead-in silence
        writer.writeframes(_silence_frames(PAUSE_AT_SCENE_START))

        # Optional: announce scene title via narrator. Helpful when listening
        # so you know where you are in the play. Keep it brief.
        title_text = f"Scene {scene.number}. {scene.title.title()}."
        narrator_voice = assignment.voice_for(None)
        try:
            _synthesize_into(writer, title_text, narrator_voice, engine, work_dir, "title")
        except TTSFatalError:
            raise
        except Exception as e:
            # Title is decorative; don't fail the scene over it
            if progress_cb:
                progress_cb(GenerationProgress(
                    scene_index, total_scenes, scene.title, -1, len(elements),
                    f"warning: title narration failed: {e}"
                ))
        writer.writeframes(_silence_frames(0.6))

        chunks = _build_render_chunks(elements, assignment)
        previous_speaker: Optional[str] = None
        previous_kind: Optional[str] = None

        for chunk in chunks:
            if cancel_check and cancel_check():
                writer.close()
                return None

            # Choose the pause to insert BEFORE this element based on transition
            first_el = elements[chunk.start_index]
            pause = _transition_pause(previous_kind, previous_speaker, first_el)
            writer.writeframes(_silence_frames(pause))

            try:
                _synthesize_into(
                    writer, chunk.text, chunk.voice_id, engine, work_dir,
                    f"e{chunk.start_index}"
                )
            except TTSFatalError:
                raise
            except Exception as e:
                # Don't fail the whole scene; log and skip this element.
                if progress_cb:
                    progress_cb(GenerationProgress(
                        scene_index, total_scenes, scene.title,
                        chunk.start_index, len(elements),
                        f"skipped elements {chunk.start_index}-{chunk.end_index}: {e}"
                    ))

            previous_speaker = first_el.speaker
            previous_kind = first_el.kind

            if progress_cb:
                progress_cb(GenerationProgress(
                    scene_index=scene_index,
                    total_scenes=total_scenes,
                    scene_title=scene.title,
                    element_index=chunk.end_index,
                    total_elements_in_scene=len(elements),
                ))

        # Tail silence
        writer.writeframes(_silence_frames(PAUSE_AT_SCENE_END))
    finally:
        writer.close()

    # Encode to M4A
    out_path = os.path.join(output_dir, scene_filename(scene))
    _afconvert_to_m4a(combined_wav, out_path)
    # Clean intermediate
    try:
        os.remove(combined_wav)
    except OSError:
        pass
    return out_path


def _transition_pause(prev_kind, prev_speaker, current_el: Element) -> float:
    if prev_kind is None:
        return 0.0
    if current_el.kind == "stage_direction" or prev_kind == "stage_direction":
        return PAUSE_AROUND_STAGE_DIRECTION
    if current_el.kind == "parenthetical" or prev_kind == "parenthetical":
        return PAUSE_AROUND_PARENTHETICAL
    if current_el.kind == "dialog" and prev_kind == "dialog":
        if prev_speaker == current_el.speaker:
            return PAUSE_BETWEEN_DIALOG_SAME_SPEAKER
        return PAUSE_BETWEEN_DIALOG_DIFFERENT_SPEAKER
    return PAUSE_BETWEEN_DIALOG_DIFFERENT_SPEAKER


def _voice_for_element(el: Element, assignment: Assignment) -> str:
    if el.kind == "stage_direction":
        return assignment.voice_for(None)
    if el.kind == "parenthetical":
        # Read parentheticals with the narrator. They're directorial notes,
        # not the character speaking.
        return assignment.voice_for(None)
    return assignment.voice_for(el.speaker)


def _text_for_element(el: Element) -> str:
    if el.kind == "parenthetical":
        # Ensure it sounds like a brief aside
        return el.text.strip()
    return el.text.strip()


MAX_TTS_CHUNK_CHARS = 2500


def _build_render_chunks(elements: List[Element], assignment: Assignment) -> List[RenderChunk]:
    chunks: List[RenderChunk] = []
    for i, el in enumerate(elements):
        text = _text_for_element(el)
        if not text:
            continue
        voice_id = _voice_for_element(el, assignment)
        if chunks and _can_merge_chunk(chunks[-1], el, voice_id, text):
            chunks[-1].end_index = i
            chunks[-1].text = chunks[-1].text.rstrip() + "\n\n" + text
        else:
            chunks.append(RenderChunk(
                start_index=i,
                end_index=i,
                kind=el.kind,
                speaker=el.speaker,
                voice_id=voice_id,
                text=text,
            ))
    return chunks


def _can_merge_chunk(chunk: RenderChunk, el: Element, voice_id: str, text: str) -> bool:
    if chunk.voice_id != voice_id:
        return False
    if chunk.kind != el.kind or chunk.speaker != el.speaker:
        return False
    if el.kind not in {"dialog", "stage_direction"}:
        return False
    return len(chunk.text) + len(text) + 2 <= MAX_TTS_CHUNK_CHARS


def _synthesize_into(
    writer: wave.Wave_write,
    text: str,
    voice_id: str,
    engine: TTSEngine,
    work_dir: str,
    tag: str,
) -> None:
    # 1. Synthesize to engine-native format
    src = os.path.join(work_dir, f"line_{tag}{engine.audio_extension}")
    engine.synthesize(text, voice_id, src)
    # 2. Convert to uniform WAV
    wav = os.path.join(work_dir, f"line_{tag}.wav")
    _afconvert_to_wav(src, wav)
    # 3. Append to combined writer
    _append_wav(writer, wav)
    # 4. Clean up to keep tmp dir light
    for p in (src, wav):
        try:
            os.remove(p)
        except OSError:
            pass


# ---------------------------------------------------------------------------
# Top-level: generate the whole script
# ---------------------------------------------------------------------------


def generate_script(
    script: Script,
    engine: TTSEngine,
    assignment: Assignment,
    output_dir: str,
    progress_cb: Optional[Callable[[GenerationProgress], None]] = None,
    cancel_check: Optional[Callable[[], bool]] = None,
    scene_filter: Optional[List[int]] = None,  # only render scenes whose .number is in this list
) -> GenerationResult:
    os.makedirs(output_dir, exist_ok=True)
    result = GenerationResult(output_dir=output_dir)

    target_scenes = script.scenes
    if scene_filter is not None:
        target_scenes = [s for s in script.scenes if s.number in scene_filter]

    with tempfile.TemporaryDirectory(prefix="audio_drama_") as work_dir:
        for i, scene in enumerate(target_scenes):
            if cancel_check and cancel_check():
                break
            try:
                path = generate_scene(
                    scene=scene,
                    engine=engine,
                    assignment=assignment,
                    output_dir=output_dir,
                    work_dir=work_dir,
                    progress_cb=progress_cb,
                    scene_index=i,
                    total_scenes=len(target_scenes),
                    cancel_check=cancel_check,
                )
                if path:
                    result.files.append(path)
                    if progress_cb:
                        # Heartbeat: announce successful scene completion in
                        # the GUI log so the user can see progress even when
                        # nothing is going wrong.
                        progress_cb(GenerationProgress(
                            i, len(target_scenes), scene.title,
                            -1, 0,
                            f"✓ Wrote {os.path.basename(path)}"
                        ))
                else:
                    result.skipped_scenes.append(f"Scene {scene.number}: {scene.title}")
            except TTSFatalError as e:
                result.errors.append(f"Scene {scene.number} ({scene.title}): {e}")
                if progress_cb:
                    progress_cb(GenerationProgress(
                        i, len(target_scenes), scene.title, -1, 0,
                        f"error: {e}"
                    ))
                break
            except Exception as e:
                result.errors.append(f"Scene {scene.number} ({scene.title}): {e}")
                if progress_cb:
                    progress_cb(GenerationProgress(
                        i, len(target_scenes), scene.title, -1, 0,
                        f"error: {e}"
                    ))
    return result


def estimate_tts_requests(
    script: Script,
    assignment: Assignment,
    scene_filter: Optional[List[int]] = None,
    include_scene_titles: bool = True,
) -> int:
    target_scenes = script.scenes
    if scene_filter is not None:
        target_scenes = [s for s in script.scenes if s.number in scene_filter]
    total = 0
    for scene in target_scenes:
        elements = [e for e in scene.elements if e.text.strip()]
        if not elements:
            continue
        if include_scene_titles:
            total += 1
        total += len(_build_render_chunks(elements, assignment))
    return total


# ---------------------------------------------------------------------------
# Self-check (only runs if afconvert is on this machine)
# ---------------------------------------------------------------------------


if __name__ == "__main__":
    if not shutil.which("afconvert"):
        print("afconvert not found; this self-test only works on macOS.")
        raise SystemExit(0)
    print("Pipeline module loaded OK. Use audio_drama.py for the full app.")
