#!/usr/bin/env python3
"""
JSON bridge for the native macOS shell.

The SwiftUI app talks to this worker over stdin/stdout using one JSON request
per process. Keeping the boundary narrow lets the native UI stay responsive
while the existing Python parser/audio pipeline remains reusable.
"""

from __future__ import annotations

import json
import os
import shutil
import sys
import time
import traceback
from pathlib import Path
from typing import Any, Dict, List

# ── User-installed packages (Kokoro, etc.) ───────────────────────────────────
# When Table Read is distributed as a bundled .app the Python interpreter is
# embedded in Contents/Resources/python/. Optional engines (Kokoro, Piper) are
# pip-installed to ~/Library/Application Support/TableRead/python-packages/
# so they live outside the app bundle (avoids breaking code signing on update).
# PythonBridge sets TABLEREAD_PACKAGES before spawning this worker.
_user_pkgs = os.environ.get("TABLEREAD_PACKAGES", "").strip()
if _user_pkgs and _user_pkgs not in sys.path:
    sys.path.insert(0, _user_pkgs)
# ─────────────────────────────────────────────────────────────────────────────

ROOT = Path(__file__).resolve().parents[0]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

import parser as script_parser
import tts_engines
from audio_pipeline import GenerationProgress, estimate_tts_chars, estimate_tts_requests, generate_script
from voice_assignment import Assignment, auto_assign


KOKORO_CACHE_DIR = Path.home() / ".cache" / "tableread" / "kokoro"
KOKORO_PREVIEW_DIR = KOKORO_CACHE_DIR / "previews"


def _dir_size(path: Path) -> int:
    if not path.exists():
        return 0
    total = 0
    for item in path.rglob("*"):
        if item.is_file():
            try:
                total += item.stat().st_size
            except OSError:
                pass
    return total


def _format_bytes(size: int) -> str:
    if size <= 0:
        return "0 MB"
    units = ["bytes", "KB", "MB", "GB"]
    value = float(size)
    unit = 0
    while value >= 1024 and unit < len(units) - 1:
        value /= 1024
        unit += 1
    if unit == 0:
        return f"{int(value)} {units[unit]}"
    return f"{value:.1f} {units[unit]}"


def _kokoro_installed() -> bool:
    """True once the user has completed the install flow (sentinel file exists)."""
    return (KOKORO_CACHE_DIR / ".installed").exists()


def _kokoro_files_present() -> bool:
    return (
        (KOKORO_CACHE_DIR / "kokoro-v1.0.int8.onnx").exists()
        and (KOKORO_CACHE_DIR / "voices-v1.0.bin").exists()
    )


def _voice_preview_text(voice: tts_engines.VoiceInfo) -> str:
    style = voice.note or "natural"
    return (
        f"This is {voice.label}, a {style} voice for Table Read. "
        "I can carry narration, dialogue, and quick changes in tone."
    )


def _preview_path(engine_id: str, voice_id: str) -> Path:
    safe_id = "".join(ch if ch.isalnum() or ch in {"-", "_"} else "_" for ch in voice_id)
    if engine_id == "kokoro":
        return KOKORO_PREVIEW_DIR / f"{safe_id}.wav"
    if engine_id in {"openAI", "openai"}:
        return Path("/tmp") / f"tableread_preview_openai_{safe_id}.mp3"
    return Path("/tmp") / f"tableread_preview_{engine_id}_{safe_id}.aiff"


def _script_summary(script: script_parser.Script) -> Dict[str, Any]:
    line_count = sum(
        1 for scene in script.scenes for element in scene.elements
        if element.kind == "dialog"
    )
    return {
        "title": script.title,
        "sceneCount": len(script.scenes),
        "characterCount": len(script.characters),
        "lineCount": line_count,
        "characters": [
            {
                "name": ch.name,
                "genderHint": ch.gender_hint,
                "roleHint": ch.role_hint,
            }
            for ch in script.characters
        ],
        "scenes": [
            {
                "number": scene.number,
                "title": scene.title,
                "elementCount": len([e for e in scene.elements if e.text.strip()]),
                "elements": [
                    {
                        "kind": element.kind,
                        "speaker": element.speaker,
                        "text": element.text,
                        "overlapCue": element.overlap_cue,
                        "overlapTexts": element.overlap_texts,
                        "confidence": element.confidence,
                    }
                    for element in scene.elements
                    if element.text.strip()
                ],
            }
            for scene in script.scenes
        ],
    }


def _voices_for_engine(engine_id: str) -> List[tts_engines.VoiceInfo]:
    if engine_id in {"openai", "openAI"}:
        return tts_engines.OpenAIEngine().list_voices()
    if engine_id == "kokoro":
        return tts_engines.KokoroEngine().list_voices()
    return tts_engines.MacSayEngine().list_voices()


def _estimate_openai(pdf_path: str, scene_numbers: List[int] | None) -> Dict[str, Any]:
    script = script_parser.parse_pdf(pdf_path)
    engine = tts_engines.OpenAIEngine()
    voices = engine.list_voices()
    assignment = auto_assign(script.characters, voices)
    request_count = estimate_tts_requests(script, assignment, scene_numbers)
    total_chars = estimate_tts_chars(script, assignment, scene_numbers)
    rpm = tts_engines.OpenAIEngine.REQUESTS_PER_MINUTE
    minimum_seconds = int(((request_count + max(rpm, 1) - 1) // max(rpm, 1)) * 60)
    # Cost estimate using tts-1 pricing (default model)
    model = engine.DEFAULT_MODEL
    rate = tts_engines.OpenAIEngine.COST_PER_1K_CHARS.get(model, 0.015)
    estimated_cost_usd = (total_chars / 1000.0) * rate
    return {
        "requestCount": request_count,
        "requestsPerMinute": rpm,
        "minimumSeconds": minimum_seconds,
        "totalChars": total_chars,
        "estimatedCostUSD": round(estimated_cost_usd, 4),
    }


def _emit(event: Dict[str, Any]) -> None:
    print(json.dumps(event), flush=True)


def _engine_for_payload(payload: Dict[str, Any]) -> tts_engines.TTSEngine:
    engine_id = payload.get("engine", "macOS")
    if engine_id == "openAI":
        api_key = payload.get("apiKey") or os.environ.get("OPENAI_API_KEY")
        if not api_key:
            raise RuntimeError("OpenAI generation needs an API key.")
        return tts_engines.OpenAIEngine(api_key=api_key)
    if engine_id == "kokoro":
        engine = tts_engines.KokoroEngine()
        if not engine.is_available():
            raise RuntimeError(
                "Kokoro is not installed. "
                "Activate the project virtualenv and run: "
                "pip install kokoro-onnx soundfile"
            )
        return engine
    if engine_id == "piper":
        raise RuntimeError("Piper generation is not implemented yet.")
    return tts_engines.MacSayEngine()


def _build_assignment(payload: Dict[str, Any], script, voices) -> Assignment:
    """Build an Assignment from an explicit mapping dict (from the UI) or auto-assign."""
    voices_by_id = {v.id: v for v in voices}
    explicit_map = payload.get("assignment")
    if explicit_map:
        # Fill in any missing characters with auto-assign so we never have a gap.
        base = auto_assign(script.characters, voices)
        merged = dict(base.mapping)
        merged.update(explicit_map)
        return Assignment(mapping=merged, voices_by_id=voices_by_id)
    return auto_assign(script.characters, voices)


def _apply_corrections(script, corrections_list: List[Dict[str, Any]]):
    """Apply user corrections from the Review step to the parsed script in-place.

    Handles the following correction types:
    - markedAsNoise: exclude element entirely
    - correctedKind / correctedSpeaker / correctedText: basic field overrides
    - correctedOverlapSpeakers / correctedOverlapTexts: override speaker names or
      per-voice texts on parser-detected simultaneous lines
    - manualOverlapPartnerKey: merge two solo elements into a simultaneous pair;
      the secondary element is absorbed (removed) from the scene
    - removedVoiceIndex: soft-remove one (0=left, 1=right) or both (2) voices
      from a simultaneous element; both-removed suppresses the element entirely

    Returns the (mutated) script so callers can chain.
    """
    if not corrections_list:
        return script

    corrections_by_key: Dict[tuple, Dict[str, Any]] = {}
    for c in corrections_list:
        key = (c.get("sceneNumber"), c.get("textPrefix", ""))
        corrections_by_key[key] = c

    for scene in script.scenes:
        # Build a text-prefix → element lookup for manual overlap partner resolution.
        el_by_prefix: Dict[str, Any] = {el.text[:60]: el for el in scene.elements}

        # Collect text prefixes that will be absorbed as secondaries in a manual overlap.
        # Only suppress a secondary when its primary is not itself noise.
        absorbed_prefixes: set = set()
        for el in scene.elements:
            c = corrections_by_key.get((scene.number, el.text[:60]))
            if c and "manualOverlapPartnerKey" in c and not c.get("markedAsNoise"):
                absorbed_prefixes.add(c["manualOverlapPartnerKey"])

        filtered = []
        for el in scene.elements:
            text_prefix = el.text[:60]

            # Skip elements absorbed as the secondary half of a manual overlap pair.
            if text_prefix in absorbed_prefixes:
                continue

            c = corrections_by_key.get((scene.number, text_prefix))
            if c is None:
                filtered.append(el)
                continue
            if c.get("markedAsNoise"):
                continue  # exclude this element

            # ── Basic field overrides ──────────────────────────────────────────
            if "correctedKind" in c:
                el.kind = c["correctedKind"]
            if "correctedSpeaker" in c:
                raw = c["correctedSpeaker"]
                el.speaker = None if raw == "" else raw
            if "correctedText" in c:
                el.text = c["correctedText"]

            # ── Parser-detected overlap: speaker / text overrides ─────────────
            if "correctedOverlapSpeakers" in c:
                el.overlap_cue = c["correctedOverlapSpeakers"]
            if "correctedOverlapTexts" in c:
                el.overlap_texts = c["correctedOverlapTexts"]

            # ── Soft-removed voice(s) ─────────────────────────────────────────
            # removedVoiceIndex: 0 = left removed, 1 = right removed, 2 = both
            removed_idx = c.get("removedVoiceIndex")
            if removed_idx is not None and el.overlap_cue and len(el.overlap_cue) >= 2:
                if removed_idx == 2:
                    continue  # both voices removed — suppress entirely
                keep_idx = 1 if removed_idx == 0 else 0
                texts = el.overlap_texts or ([el.text] * len(el.overlap_cue))
                el.speaker = el.overlap_cue[keep_idx] if keep_idx < len(el.overlap_cue) else None
                el.text = texts[keep_idx] if keep_idx < len(texts) else el.text
                el.overlap_cue = None
                el.overlap_texts = None

            # ── Manual overlap: merge primary + secondary into a simultaneous pair ──
            if "manualOverlapPartnerKey" in c:
                partner_key = c["manualOverlapPartnerKey"]
                partner = el_by_prefix.get(partner_key)
                if partner:
                    # Resolve speaker A (the primary element)
                    if "correctedSpeaker" in c:
                        raw = c["correctedSpeaker"]
                        speaker_a = "Narrator" if raw == "" else raw
                    else:
                        speaker_a = el.speaker or "Narrator"

                    # Resolve speaker B (the secondary element, may have its own correction)
                    partner_c = corrections_by_key.get((scene.number, partner_key))
                    if partner_c and "correctedSpeaker" in partner_c:
                        raw = partner_c["correctedSpeaker"]
                        speaker_b = "Narrator" if raw == "" else raw
                    else:
                        speaker_b = partner.speaker or "Narrator"

                    text_a = c.get("correctedText") or el.text
                    text_b = (partner_c.get("correctedText") if partner_c else None) or partner.text

                    el.overlap_cue = [speaker_a, speaker_b]
                    el.overlap_texts = [text_a, text_b]

            filtered.append(el)
        scene.elements = filtered

    return script


def _inject_user_elements(script, user_elements_map: Dict[int, List[Dict[str, Any]]],
                           warn_fn=None):
    """Inject user-added elements (from the Review UI) after their anchor elements in-place.

    user_elements_map maps scene number → list of addition dicts, each with keys:
      afterElementTextKey  – first 60 chars of the anchor element's text
      speaker              – speaker name, or "" / "Narrator" / "__NARRATOR__" for narrator
      text                 – the new line's text
      kind                 – "dialog" | "stage_direction" | "parenthetical" (default: "dialog")

    warn_fn(message) is called for any additions whose anchor key had no match.
    Returns (script, total_injected_count).
    """
    from parser import Element as _Element  # avoid circular import at module level

    total_injected = 0
    for scene in script.scenes:
        additions = user_elements_map.get(scene.number, [])
        if not additions:
            continue

        # Build a lookup: anchor-key → list of additions to insert after it.
        additions_by_key: Dict[str, List[Dict[str, Any]]] = {}
        for addition in additions:
            ak = addition.get("afterElementTextKey", "")
            additions_by_key.setdefault(ak, []).append(addition)

        matched_keys: set = set()
        new_elements = []
        for el in scene.elements:
            new_elements.append(el)
            after_key = el.text[:60]
            for addition in additions_by_key.get(after_key, []):
                text = (addition.get("text") or "").strip()
                if not text:
                    continue
                raw_speaker = (addition.get("speaker") or "").strip()
                # Map empty string, "Narrator", or "__NARRATOR__" to None (narrator voice).
                narrator_values = {"", "Narrator", "__NARRATOR__"}
                speaker = None if raw_speaker in narrator_values else raw_speaker
                new_elements.append(_Element(
                    kind=addition.get("kind", "dialog"),
                    speaker=speaker,
                    text=text,
                ))
                matched_keys.add(after_key)
                total_injected += 1
        scene.elements = new_elements

        # Warn about additions whose afterElementTextKey didn't match any parsed element.
        unmatched = [
            a for a in additions
            if a.get("afterElementTextKey", "") not in matched_keys
               and (a.get("text") or "").strip()
        ]
        if unmatched and warn_fn:
            warn_fn(
                f"Scene {scene.number}: {len(unmatched)} added line(s) could not be "
                f"matched to a parsed element and were skipped."
            )

    return script, total_injected


def _generate(payload: Dict[str, Any]) -> int:
    pdf_path = payload["pdfPath"]
    output_dir = payload["outputDir"]
    scene_numbers = payload.get("sceneNumbers")
    engine = _engine_for_payload(payload)
    script = script_parser.parse_pdf(pdf_path)
    voices = _voices_for_engine(payload.get("engine", "macOS"))

    if not voices:
        raise RuntimeError(f"No voices are available for {engine.name}.")
    if not engine.is_available():
        raise RuntimeError(f"{engine.name} is not available.")

    assignment = _build_assignment(payload, script, voices)

    # Inject user-added elements (from Swift UI) into the parsed scene element lists.
    # Payload key: {"<sceneNumber>": [{"afterElementTextKey", "speaker", "text", "kind"}, ...]}
    user_elements_map: Dict[int, List[Dict[str, Any]]] = {}
    for scene_key, additions in (payload.get("userAddedElements") or {}).items():
        try:
            user_elements_map[int(scene_key)] = additions
        except (ValueError, TypeError):
            pass

    if user_elements_map:
        _, total_injected = _inject_user_elements(
            script, user_elements_map,
            warn_fn=lambda msg: _emit({"event": "log", "level": "warning", "message": msg}),
        )
        if total_injected > 0:
            _emit({
                "event": "log", "level": "info",
                "message": f"Injected {total_injected} user-added line(s) into the script.",
            })

    # Apply user corrections (from Review section) — keyed by sceneNumber + textPrefix.
    corrections_list: List[Dict[str, Any]] = payload.get("corrections") or []
    _apply_corrections(script, corrections_list)

    _emit({
        "event": "started",
        "message": f"Rendering {len(scene_numbers or script.scenes)} scene(s) with {engine.name}.",
    })
    _emit({
        "event": "log",
        "level": "info",
        "message": f"Using {len(voices)} available voice(s). Output: {output_dir}",
    })

    def progress_cb(progress: GenerationProgress) -> None:
        _emit({
            "event": "progress",
            "sceneIndex": progress.scene_index,
            "totalScenes": progress.total_scenes,
            "sceneTitle": progress.scene_title,
            "elementIndex": progress.element_index,
            "totalElements": progress.total_elements_in_scene,
            "message": progress.message,
        })

    t0 = time.time()
    result = generate_script(
        script=script,
        engine=engine,
        assignment=assignment,
        output_dir=output_dir,
        progress_cb=progress_cb,
        scene_filter=scene_numbers,
    )
    _emit({
        "event": "done",
        "outputDir": result.output_dir,
        "files": result.files,
        "errors": result.errors,
        "skippedScenes": result.skipped_scenes,
        "seconds": round(time.time() - t0, 1),
    })
    return 1 if result.errors else 0


def _install_engine(payload: Dict[str, Any]) -> int:
    """Install Python dependencies for a voice engine, streaming pip output."""
    engine_id = payload.get("engine", "")

    PACKAGES: Dict[str, List[str]] = {
        "kokoro": ["kokoro-onnx>=0.3", "soundfile>=0.12"],
    }

    packages = PACKAGES.get(engine_id)
    if not packages:
        _emit({"event": "log", "level": "error",
               "message": f"No installable packages defined for engine '{engine_id}'."})
        return 1

    _emit({"event": "started",
           "message": f"Installing {engine_id} packages: {', '.join(packages)}"})
    _emit({"event": "log", "level": "info",
           "message": f"Using Python: {sys.executable}"})

    # When running from the bundled .app, install optional packages into the
    # user-writable Application Support directory so they live outside the
    # signed bundle and survive app updates.
    import subprocess
    target_dir = _user_pkgs or None
    if target_dir:
        os.makedirs(target_dir, exist_ok=True)
        cmd = [sys.executable, "-m", "pip", "install", "--target", target_dir] + packages
        _emit({"event": "log", "level": "info",
               "message": f"Installing to: {target_dir}"})
    else:
        cmd = [sys.executable, "-m", "pip", "install"] + packages

    try:
        process = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        for line in iter(process.stdout.readline, ""):
            line = line.rstrip()
            if line:
                _emit({"event": "log", "level": "info", "message": line})
        process.wait()
    except Exception as exc:
        _emit({"event": "log", "level": "error", "message": str(exc)})
        return 1

    if process.returncode != 0:
        _emit({"event": "log", "level": "error",
               "message": f"pip exited with code {process.returncode}."})
        return 1

    # Verify the import works before declaring victory
    try:
        if engine_id == "kokoro":
            import importlib
            importlib.import_module("kokoro_onnx")
            importlib.import_module("soundfile")
    except ImportError as exc:
        _emit({"event": "log", "level": "error",
               "message": f"Installation succeeded but import failed: {exc}"})
        return 1

    if engine_id == "kokoro":
        KOKORO_CACHE_DIR.mkdir(parents=True, exist_ok=True)
        (KOKORO_CACHE_DIR / ".installed").touch()

    _emit({"event": "done",
           "message": (
               f"✓ {engine_id} installed. "
               "The neural model (~88 MB) downloads from GitHub on first voice preview."
           )})
    return 0


def _engine_status() -> Dict[str, Any]:
    kokoro_available = tts_engines.KokoroEngine().is_available()
    kokoro_size = _dir_size(KOKORO_CACHE_DIR)
    return {
        "ok": True,
        "engines": {
            "macOS": {
                "installed": tts_engines.MacSayEngine().is_available(),
                "sizeBytes": 0,
                "sizeLabel": "Built in",
                "canUninstall": False,
            },
            "kokoro": {
                "installed": kokoro_available and _kokoro_installed(),
                "sizeBytes": kokoro_size,
                "sizeLabel": _format_bytes(kokoro_size) if kokoro_size else "~115 MB after install",
                "canUninstall": _kokoro_installed(),
            },
            "piper": {
                "installed": False,
                "sizeBytes": 0,
                "sizeLabel": "Not installed",
                "canUninstall": False,
            },
            "openAI": {
                "installed": False,
                "sizeBytes": 0,
                "sizeLabel": "Cloud service",
                "canUninstall": False,
            },
        },
    }


def _uninstall_engine(payload: Dict[str, Any]) -> Dict[str, Any]:
    engine_id = payload.get("engine", "")
    if engine_id == "kokoro":
        shutil.rmtree(KOKORO_CACHE_DIR, ignore_errors=True)
        return {"ok": True, "message": "Removed Kokoro model and voice previews."}
    return {"ok": False, "error": f"No local uninstall is defined for '{engine_id}'."}


def _engine_for_preview(engine_id: str, api_key: str | None = None) -> tts_engines.TTSEngine:
    if engine_id == "kokoro":
        return tts_engines.KokoroEngine()
    if engine_id in {"macOS", "mac", ""}:
        return tts_engines.MacSayEngine()
    if engine_id in {"openAI", "openai"}:
        if not api_key:
            raise RuntimeError(
                "Voice preview for OpenAI requires an API key. "
                "Save your key in the OpenAI Setup section first."
            )
        return tts_engines.OpenAIEngine(api_key=api_key)
    raise RuntimeError(f"Voice previews are not available for {engine_id}.")


def _prepare_voice_previews(engine_id: str) -> None:
    engine = _engine_for_preview(engine_id)
    voices = engine.list_voices()
    if engine_id == "kokoro":
        KOKORO_PREVIEW_DIR.mkdir(parents=True, exist_ok=True)
    for voice in voices:
        path = _preview_path(engine_id, voice.id)
        if path.exists():
            continue
        engine.synthesize(_voice_preview_text(voice), voice.id, str(path))


def _preview_voice(payload: Dict[str, Any]) -> Dict[str, Any]:
    engine_id = payload.get("engine", "macOS")
    voice_id = payload.get("voiceId")
    api_key = payload.get("apiKey")
    if not voice_id:
        return {"ok": False, "error": "Missing voiceId."}

    engine = _engine_for_preview(engine_id, api_key)
    voice = next((v for v in engine.list_voices() if v.id == voice_id), None)
    if voice is None:
        return {"ok": False, "error": f"Unknown voice '{voice_id}'."}

    path = _preview_path(engine_id, voice.id)
    if engine_id == "kokoro":
        KOKORO_PREVIEW_DIR.mkdir(parents=True, exist_ok=True)
    # OpenAI previews are not cached permanently (no disk cost, always fresh).
    is_cloud = engine_id in {"openAI", "openai"}
    if not path.exists() or is_cloud:
        engine.synthesize(_voice_preview_text(voice), voice.id, str(path))
    return {"ok": True, "path": str(path)}


def handle(payload: Dict[str, Any]) -> Dict[str, Any]:
    command = payload.get("command")
    if command == "parse":
        pdf_path = payload["pdfPath"]
        return {"ok": True, "script": _script_summary(script_parser.parse_pdf(pdf_path))}
    if command == "voices":
        engine_id = payload.get("engine", "mac")
        pdf_path = payload.get("pdfPath")
        voices = _voices_for_engine(engine_id)
        result: Dict[str, Any] = {
            "ok": True,
            "voices": [
                {
                    "id": v.id,
                    "label": v.label,
                    "gender": v.gender,
                    "locale": v.locale,
                    "note": v.note,
                    "display": v.display,
                }
                for v in voices
            ],
        }
        if pdf_path:
            script = script_parser.parse_pdf(pdf_path)
            assignment = auto_assign(script.characters, voices)
            result["autoAssign"] = assignment.mapping
        return result
    if command == "checkOutputFiles":
        pdf_path = payload["pdfPath"]
        output_dir = payload["outputDir"]
        script = script_parser.parse_pdf(pdf_path)
        from audio_pipeline import scene_filename
        result: Dict[str, Any] = {}
        for scene in script.scenes:
            fname = scene_filename(scene)
            exists = os.path.isfile(os.path.join(output_dir, fname))
            result[str(scene.number)] = {
                "exists": exists,
                "filename": fname,
                "title": scene.title,
            }
        return {"ok": True, "scenes": result}
    if command == "estimateOpenAI":
        return {
            "ok": True,
            "estimate": _estimate_openai(
                payload["pdfPath"],
                payload.get("sceneNumbers"),
            ),
        }
    if command == "engineStatus":
        return _engine_status()
    if command == "uninstallEngine":
        return _uninstall_engine(payload)
    if command == "previewVoice":
        return _preview_voice(payload)
    raise ValueError(f"Unknown command: {command!r}")


def main() -> int:
    try:
        payload = json.load(sys.stdin)
        if payload.get("command") == "generate":
            return _generate(payload)
        if payload.get("command") == "installEngine":
            return _install_engine(payload)
        print(json.dumps(handle(payload)))
        return 0
    except Exception as exc:
        print(json.dumps({
            "ok": False,
            "error": str(exc),
            "traceback": traceback.format_exc(),
        }))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
