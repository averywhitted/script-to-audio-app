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

import array
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
    overlap_voices: Optional[List[str]] = None  # when set, mix these voices simultaneously
    overlap_texts: Optional[List[str]] = None   # per-voice texts (parallel with overlap_voices); None = all voices read .text


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


def _mix_wavs(sources: List[str], dest: str) -> None:
    """Mix multiple uniform PCM WAV files into one output by summing samples.

    All sources must already be in the pipeline's canonical format
    (PCM_SAMPLE_RATE / PCM_SAMPLE_WIDTH / PCM_CHANNELS). Shorter files are
    zero-padded to the length of the longest. Samples are summed and clamped
    to the 16-bit signed range [-32768, 32767] to prevent wrap-around clipping.

    Uses only stdlib (array module) — no numpy required.
    """
    if not sources:
        raise ValueError("_mix_wavs requires at least one source")
    if len(sources) == 1:
        shutil.copy2(sources[0], dest)
        return

    all_samples: List[array.array] = []
    max_n = 0
    for src in sources:
        with wave.open(src, "rb") as r:
            assert r.getnchannels() == PCM_CHANNELS
            assert r.getsampwidth() == PCM_SAMPLE_WIDTH
            assert r.getframerate() == PCM_SAMPLE_RATE
            raw = r.readframes(r.getnframes())
        track: array.array = array.array("h")  # signed 16-bit
        track.frombytes(raw)
        all_samples.append(track)
        max_n = max(max_n, len(track))

    mixed: array.array = array.array("h", [0] * max_n)
    for track in all_samples:
        for i in range(len(track)):
            mixed[i] = max(-32768, min(32767, mixed[i] + track[i]))

    with wave.open(dest, "wb") as w:
        w.setnchannels(PCM_CHANNELS)
        w.setsampwidth(PCM_SAMPLE_WIDTH)
        w.setframerate(PCM_SAMPLE_RATE)
        w.writeframes(mixed.tobytes())


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

        # Pre-compute which narrator chunks fall *between* overlap chunks in the
        # same simultaneous-speech sequence.  Those are suppressed: reading a
        # stage-direction or parenthetical in the middle of overlapping voices
        # is jarring and almost always a PDF merge artifact rather than
        # intentional narration.
        #
        # A narrator chunk at index `ci` is "within overlap" when:
        #   • At least one overlap chunk precedes it (prev_overlap_idx is set).
        #   • A subsequent overlap chunk follows it before any non-narrator /
        #     non-overlap chunk intervenes.
        _skip_in_overlap: set[int] = set()
        _prev_overlap_idx: Optional[int] = None
        _pending_narrator_indices: List[int] = []
        for _ci, _ch in enumerate(chunks):
            if _ch.overlap_voices:
                if _prev_overlap_idx is not None:
                    _skip_in_overlap.update(_pending_narrator_indices)
                _prev_overlap_idx = _ci
                _pending_narrator_indices = []
            elif _ch.speaker is None and _prev_overlap_idx is not None:
                _pending_narrator_indices.append(_ci)
            else:
                # Non-narrator, non-overlap chunk — close the active overlap block.
                _prev_overlap_idx = None
                _pending_narrator_indices = []

        previous_speaker: Optional[str] = None
        previous_kind: Optional[str] = None
        previous_was_overlap: bool = False

        for ci, chunk in enumerate(chunks):
            if ci in _skip_in_overlap:
                continue  # narrator between overlaps — suppress
            if cancel_check and cancel_check():
                writer.close()
                return None

            # Choose the pause to insert BEFORE this element based on transition.
            # Consecutive overlap chunks (same simultaneous-speech block split
            # across paragraph boundaries) get no inter-chunk gap — they should
            # feel continuous, not like one speaker waiting for the other.
            first_el = elements[chunk.start_index]
            current_is_overlap = bool(chunk.overlap_voices)
            if previous_was_overlap and current_is_overlap:
                pause = 0.0
            else:
                pause = _transition_pause(previous_kind, previous_speaker, first_el)
            writer.writeframes(_silence_frames(pause))

            try:
                if chunk.overlap_voices and len(chunk.overlap_voices) >= 2:
                    _synthesize_overlap_into(
                        writer, chunk.text, chunk.overlap_voices, engine, work_dir,
                        f"e{chunk.start_index}",
                        texts=chunk.overlap_texts,
                    )
                else:
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
            previous_was_overlap = current_is_overlap

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

        # Resolve overlap voices: each name in overlap_cue maps to a voice ID.
        overlap_voices: Optional[List[str]] = None
        overlap_texts: Optional[List[str]] = None
        if el.overlap_cue and len(el.overlap_cue) >= 2:
            overlap_voices = [assignment.voice_for(name) for name in el.overlap_cue]
            overlap_texts = el.overlap_texts  # per-voice texts; None = chorus mode

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
                overlap_voices=overlap_voices,
                overlap_texts=overlap_texts,
            ))
    return chunks


def _can_merge_chunk(chunk: RenderChunk, el: Element, voice_id: str, text: str) -> bool:
    # Never merge overlap chunks — each simultaneous-speech line is self-contained.
    if chunk.overlap_voices is not None or el.overlap_cue:
        return False
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


def _synthesize_overlap_into(
    writer: wave.Wave_write,
    text: str,
    voice_ids: List[str],
    engine: TTSEngine,
    work_dir: str,
    tag: str,
    texts: Optional[List[str]] = None,
) -> None:
    """Synthesize simultaneous dialog and mix the results into `writer`.

    When `texts` is provided (per-voice texts from a two-column PDF overlap),
    each voice renders its own text — e.g. LEAH reads "What do you mean?" while
    CREDIT CARD COMPANY reads "I'm sorry, I don't recognize that number."
    When `texts` is None (slash / ampersand chorus cues), every voice renders
    the shared `text` simultaneously (unison / stacked effect).

    Results are sample-summed (with clamping) to produce a simultaneous-speech
    effect. Falls back to a solo render of the first voice if mixing fails.
    """
    per_voice_wavs: List[str] = []
    per_voice_srcs: List[str] = []
    try:
        for idx, vid in enumerate(voice_ids):
            # Per-voice text when available (two-column split); shared text otherwise.
            voice_text = texts[idx] if (texts and idx < len(texts)) else text
            src = os.path.join(work_dir, f"line_{tag}_v{idx}{engine.audio_extension}")
            wav = os.path.join(work_dir, f"line_{tag}_v{idx}.wav")
            engine.synthesize(voice_text, vid, src)
            _afconvert_to_wav(src, wav)
            per_voice_srcs.append(src)
            per_voice_wavs.append(wav)

        mixed_wav = os.path.join(work_dir, f"line_{tag}_mixed.wav")
        _mix_wavs(per_voice_wavs, mixed_wav)
        _append_wav(writer, mixed_wav)
        try:
            os.remove(mixed_wav)
        except OSError:
            pass
    except Exception:
        # If mixing fails for any reason, fall back to solo render of first voice
        if per_voice_wavs:
            _append_wav(writer, per_voice_wavs[0])
        else:
            _synthesize_into(writer, text, voice_ids[0], engine, work_dir, tag + "_fb")
    finally:
        for p in per_voice_srcs + per_voice_wavs:
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
