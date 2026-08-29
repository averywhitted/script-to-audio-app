"""
Contract test: every command Sources/TableRead/PythonBridge.swift can send
must be recognized by audio_worker.py's dispatch (handle()/main()).

This is the boundary that silently broke once: `bash scripts/test.sh` was
fully green while the live app returned "Unknown command: 'sampleBlocks'",
because nothing exercised audio_worker.py the way PythonBridge.swift actually
does — as a real subprocess, JSON in on stdin, JSON out on stdout. Every other
test in this directory imports `audio_worker`/`parser` and calls functions
in-process, which can never catch a Swift-side command string audio_worker.py
doesn't recognize.

The command list is scraped directly out of PythonBridge.swift rather than
hand-duplicated here, so it can never itself drift out of sync with Swift.

Run from the repo root:
    .venv/bin/python -m pytest backend/tests/test_worker_contract.py -v
"""

import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

import pytest

BACKEND_DIR = Path(__file__).resolve().parents[1]
REPO_ROOT = BACKEND_DIR.parent
BRIDGE_SWIFT = REPO_ROOT / "Sources" / "TableRead" / "PythonBridge.swift"
WORKER = BACKEND_DIR / "audio_worker.py"

_COMMAND_RE = re.compile(r'"command"\s*:\s*"([^"]+)"')


def _swift_command_names() -> list:
    text = BRIDGE_SWIFT.read_text()
    return sorted(set(_COMMAND_RE.findall(text)))


def _run_worker(payload: dict) -> dict:
    """Spawn audio_worker.py as a real subprocess — exactly what
    PythonBridge.rawRequest/streamRequest do: JSON on stdin, JSON on stdout."""
    proc = subprocess.run(
        [sys.executable, str(WORKER)],
        input=json.dumps(payload),
        capture_output=True,
        text=True,
        timeout=30,
    )
    lines = [line for line in proc.stdout.splitlines() if line.strip()]
    assert lines, (
        f"No JSON output from audio_worker.py for payload {payload!r}.\n"
        f"stderr:\n{proc.stderr}"
    )
    return json.loads(lines[-1])


@pytest.fixture(scope="module")
def command_names() -> list:
    names = _swift_command_names()
    assert names, (
        "No \"command\": \"...\" literals found in PythonBridge.swift — "
        "the scrape regex may be stale (has the payload style changed?)."
    )
    return names


def test_swift_command_scrape_found_the_known_commands(command_names):
    # Loose sanity check on the scrape itself (not the worker) — catches a
    # silently-broken regex before it silently stops testing anything.
    expected_minimum = {
        "parse", "voices", "estimateOpenAI", "checkOutputFiles", "generate",
        "installEngine", "engineStatus", "uninstallEngine", "previewVoice",
        "sampleBlocks", "deriveFormatProfile",
    }
    missing = expected_minimum - set(command_names)
    assert not missing, f"Expected commands missing from the scrape: {missing}"


def test_every_swift_command_is_recognized_by_worker(command_names):
    with tempfile.TemporaryDirectory() as tmp_dir:
        placeholder_pdf = str(Path(tmp_dir) / "nonexistent.pdf")
        for name in command_names:
            payload = {
                "command": name,
                "pdfPath": placeholder_pdf,
                "outputDir": tmp_dir,
                "examples": [],
            }
            response = _run_worker(payload)
            if response.get("ok") is False:
                error = response.get("error", "")
                assert "Unknown command" not in error, (
                    f"audio_worker.py does not recognize {name!r}, sent by "
                    f"PythonBridge.swift — the Swift/Python command contract "
                    f"has drifted. Worker error: {error}"
                )
