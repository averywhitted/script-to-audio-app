"""
Generate compressed reference JSON files for all test PDFs.

For each PDF, runs parse_pdf() and writes a reference file to
Test PDFs/reference/<Name>.json containing a fingerprint of every
element in every scene: (kind, speaker, sig, overlap_cue?).

sig = first character of each whitespace-separated token, preserving
case. Captures the shape of the text compactly without storing full
content.

Usage:
    python scripts/generate_reference.py
    python scripts/generate_reference.py TheHarvest  # single file
"""

import json
import sys
from datetime import date
from pathlib import Path

ROOT = Path(__file__).parent.parent
sys.path.insert(0, str(ROOT / "backend"))
from parser import parse_pdf  # noqa: E402

CASES = [
    ("TheHarvest",        "TheHarvest(3.0).pdf"),
    ("KillFloor",         "Kill Floor (LCT Reading Draft).pdf"),
    ("AgainstTheHillside","Against the Hillside 11.20.17.pdf"),
    ("NoneOfUs",          "5.0 None of Us Are Getting Out of This Alive (2).pdf"),
    ("MercuryFur",        "Mercury Fur-13 f Draft-June 10-2013.pdf"),
    ("EMMA",              "EMMA Script (2).pdf"),
    ("Stereophonic",      "4.10.24_Stereophonic (2).pdf"),
]

PDF_DIR  = ROOT / "Test PDFs"
OUT_DIR  = ROOT / "Test PDFs" / "reference"


def sig(text: str) -> str:
    """First character of each whitespace-separated token, preserving case."""
    return "".join(w[0] for w in (text or "").split() if w)


def element_to_ref(el) -> dict:
    entry = {
        "kind":    el.kind,
        "speaker": el.speaker,
        "sig":     sig(el.text),
    }
    if el.overlap_cue:
        entry["overlap_cue"] = el.overlap_cue
        if el.overlap_texts:
            entry["overlap_sigs"] = [sig(t) for t in el.overlap_texts]
    return entry


def generate(name: str, pdf_name: str) -> None:
    pdf_path = str(PDF_DIR / pdf_name)
    if not (PDF_DIR / pdf_name).exists():
        print(f"  SKIP  {name}: PDF not found")
        return

    try:
        script = parse_pdf(pdf_path)
    except Exception as exc:
        print(f"  ERROR {name}: {exc}")
        return

    ref = {
        "_meta": {
            "source_pdf": pdf_name,
            "generated":  str(date.today()),
            "note": "Auto-generated. Reviewed and corrected by hand before locking as ground truth.",
        },
        "title":      script.title,
        "characters": [c.name for c in script.characters],
        "scenes": [
            {
                "number":   scene.number,
                "title":    scene.title,
                "elements": [element_to_ref(el) for el in scene.elements],
            }
            for scene in script.scenes
        ],
    }

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    out_path = OUT_DIR / f"{name}.json"
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(ref, f, indent=2, ensure_ascii=False)

    total_elements = sum(len(s["elements"]) for s in ref["scenes"])
    print(f"  OK    {name}: {len(ref['scenes'])} scenes, {total_elements} elements → {out_path.name}")


if __name__ == "__main__":
    filter_name = sys.argv[1] if len(sys.argv) > 1 else None
    cases = [(n, p) for n, p in CASES if not filter_name or n == filter_name]
    if not cases:
        print(f"Unknown name: {filter_name}. Valid: {[n for n,_ in CASES]}")
        sys.exit(1)
    for name, pdf_name in cases:
        generate(name, pdf_name)
