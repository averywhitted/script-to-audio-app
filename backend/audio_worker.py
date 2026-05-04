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
import sys
import time
import traceback
from pathlib import Path
from typing import Any, Dict, List

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

import parser as script_parser
import tts_engines
from audio_pipeline import GenerationProgress, estimate_tts_requests, generate_script
from voice_assignment import Assignment, auto_assign


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
                    }
                    for element in scene.elements
                    if element.text.strip()
                ],
            }
            for scene in script.scenes
        ],
    }


def _voices_for_engine(engine_id: str) -> List[tts_engines.VoiceInfo]:
    if engine_id == "openai":
        return tts_engines.OpenAIEngine().list_voices()
    return tts_engines.MacSayEngine().list_voices()


def _estimate_openai(pdf_path: str, scene_numbers: List[int] | None) -> Dict[str, Any]:
    script = script_parser.parse_pdf(pdf_path)
    voices = tts_engines.OpenAIEngine().list_voices()
    assignment = auto_assign(script.characters, voices)
    request_count = estimate_tts_requests(script, assignment, scene_numbers)
    rpm = tts_engines.OpenAIEngine.REQUESTS_PER_MINUTE
    minimum_seconds = int(((request_count + max(rpm, 1) - 1) // max(rpm, 1)) * 60)
    return {
        "requestCount": request_count,
        "requestsPerMinute": rpm,
        "minimumSeconds": minimum_seconds,
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
    if engine_id in {"kokoro", "piper"}:
        raise RuntimeError(f"{engine_id} generation is not installed yet.")
    return tts_engines.MacSayEngine()


def _generate(payload: Dict[str, Any]) -> int:
    pdf_path = payload["pdfPath"]
    output_dir = payload["outputDir"]
    scene_numbers = payload.get("sceneNumbers")
    engine = _engine_for_payload(payload)
    script = script_parser.parse_pdf(pdf_path)
    voices = _voices_for_engine(payload.get("engine", "macOS"))
    assignment = auto_assign(script.characters, voices)

    if not voices:
        raise RuntimeError(f"No voices are available for {engine.name}.")
    if not engine.is_available():
        raise RuntimeError(f"{engine.name} is not available.")

    _emit({
        "event": "started",
        "message": f"Rendering {len(scene_numbers or script.scenes)} scene(s) with {engine.name}.",
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
    return 0


def handle(payload: Dict[str, Any]) -> Dict[str, Any]:
    command = payload.get("command")
    if command == "parse":
        pdf_path = payload["pdfPath"]
        return {"ok": True, "script": _script_summary(script_parser.parse_pdf(pdf_path))}
    if command == "voices":
        engine_id = payload.get("engine", "mac")
        return {
            "ok": True,
            "voices": [
                {
                    "id": voice.id,
                    "label": voice.label,
                    "gender": voice.gender,
                    "locale": voice.locale,
                    "note": voice.note,
                    "display": voice.display,
                }
                for voice in _voices_for_engine(engine_id)
            ],
        }
    if command == "estimateOpenAI":
        return {
            "ok": True,
            "estimate": _estimate_openai(
                payload["pdfPath"],
                payload.get("sceneNumbers"),
            ),
        }
    raise ValueError(f"Unknown command: {command!r}")


def main() -> int:
    try:
        payload = json.load(sys.stdin)
        if payload.get("command") == "generate":
            return _generate(payload)
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
