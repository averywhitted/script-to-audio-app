#!/usr/bin/env python3
"""answer_key_rust.py — the answer-key gate with the Rust core (PDFium extraction + Rust parser) as the parser.

Runs scripts/answer_key.py unchanged, but `parser.parse_pdf` is replaced by a call to
rust/target/release/table_read_parse, whose output is turned back into the parser's Script objects. Compares against
the committed baselines (generated: Test PDFs/reference/synth_baseline.json; real: the local labelled sample's
baseline). Never saves a baseline.

Usage: python3 scripts/answer_key_rust.py [--check]      (needs: cd rust && cargo build --release)
"""
import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path[:0] = [str(ROOT / "backend"), str(ROOT / "scripts")]

import parser as P  # noqa: E402

EXE = os.environ.get("TABLE_READ_PARSE", str(ROOT / "rust/target/release/table_read_parse"))
LIB = os.environ.get("PDFIUM_LIB", str(ROOT / ".venv/lib/python3.14/site-packages/pypdfium2_raw/libpdfium.dylib"))
CONFIG = str(ROOT / "backend" / "corrections_config.json")


def parse_pdf_rust(pdf_path: str) -> "P.Script":
    out = subprocess.run([EXE, LIB, pdf_path, CONFIG], capture_output=True, check=True).stdout
    d = json.loads(out)
    return P.Script(
        title=d["title"],
        characters=[P.Character(name=c["name"], gender_hint=c.get("genderHint"), role_hint=c.get("roleHint"))
                    for c in d["characters"]],
        scenes=[P.Scene(number=s["number"], title=s["title"], elements=[
            P.Element(kind=e["kind"], text=e["text"], speaker=e["speaker"], overlap_cue=e["overlapCue"],
                      overlap_texts=e["overlapTexts"], confidence=e["confidence"], reason=e["reason"])
            for e in s["elements"]]) for s in d["scenes"]],
    )


P.parse_pdf = parse_pdf_rust

if __name__ == "__main__":
    import answer_key
    sys.exit(answer_key.main())
