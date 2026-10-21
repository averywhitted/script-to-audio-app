#!/usr/bin/env python3
"""rust_vs_worker.py — how closely the Rust core (PDFium + Rust parser) reproduces the Python worker (PyMuPDF +
backend/parser.py) on every corpus PDF: scene, line and character counts, and the share of elements (scene, kind,
speaker, exact text) found in both. The answer keys only sample lines; this sees every element, so it catches things
like doubled spaces or split speeches that change the text the app stores and keys corrections on.

Usage: python3 scripts/rust_vs_worker.py [--min 95]     (needs: cd rust && cargo build --release)
Exit status 1 if any PDF falls below --min percent overlap (default off).
"""
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path[:0] = [str(ROOT / "backend")]
import parser as P  # noqa: E402
import audio_worker  # noqa: E402

EXE = ROOT / "rust/target/release/table_read_parse"
LIB = ROOT / ".venv/lib/python3.14/site-packages/pypdfium2_raw/libpdfium.dylib"
CONFIG = ROOT / "backend/corrections_config.json"


def elements(summary):
    return [(sc["number"], e["kind"], e["speaker"], e["text"]) for sc in summary["scenes"] for e in sc["elements"]]


def main() -> int:
    floor = float(sys.argv[sys.argv.index("--min") + 1]) if "--min" in sys.argv else None
    rows = []
    for pdf in sorted((ROOT / "Test PDFs").glob("*.pdf")) + sorted((ROOT / "Test PDFs/synthetic").glob("*.pdf")):
        py = audio_worker._script_summary(P.parse_pdf(str(pdf)))
        rs = json.loads(subprocess.run([str(EXE), str(LIB), str(pdf), str(CONFIG)], capture_output=True, check=True).stdout)
        a, b = set(elements(py)), set(elements(rs))
        rows.append((100 * len(a & b) / max(1, len(a | b)), pdf.stem[:34], py, rs))
    for pct, name, py, rs in sorted(rows, key=lambda r: r[0]):
        print(f"{pct:5.1f}%  {name:35} scenes {py['sceneCount']:3}/{rs['sceneCount']:3}  lines {py['lineCount']:5}/{rs['lineCount']:5}  "
              f"characters {py['characterCount']:3}/{rs['characterCount']:3}")
    mean = sum(r[0] for r in rows) / len(rows)
    print(f"\nmean overlap {mean:.1f}% over {len(rows)} PDFs (python/rust counts)")
    return 1 if floor is not None and any(r[0] < floor for r in rows) else 0


if __name__ == "__main__":
    sys.exit(main())
