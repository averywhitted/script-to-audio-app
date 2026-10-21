#!/usr/bin/env python3
"""rust_parser_diff.py — compare the Rust parser port with backend/parser.py, stage by stage, field for field.

Both parsers read the same input: the Rust PDFium extractor's output (the PyMuPDF `get_text("dict")` shape). The
parser is deterministic given those blocks, so any difference is a porting bug. Stages (grows with the port):

  text_blocks   _split_raw_block + _merge_open_parentheticals  ->  list of TextBlock

Usage:
  python3 scripts/rust_parser_diff.py [stage] [pdf ...]      (default: every PDF in Test PDFs/ and Test PDFs/synthetic/)
Needs the release builds (cd rust && cargo build --release; see scripts/test.sh rust for the MIRROR note).
"""
from __future__ import annotations

import dataclasses
import json
import logging
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "backend"))
import parser as P  # noqa: E402

logging.disable(logging.CRITICAL)
RELEASE = ROOT / "rust" / "target" / "release"
CACHE = ROOT / "rust" / "target" / "parity"
LIB = os.environ.get("PDFIUM_LIB", str(ROOT / ".venv/lib/python3.14/site-packages/pypdfium2_raw/libpdfium.dylib"))


def py_text_blocks(doc: dict) -> list:
    blocks = []
    for page_num, page in enumerate(doc["pages"]):
        for raw in page["blocks"]:
            if raw.get("type", 0) == 0:
                blocks.extend(P._split_raw_block(raw, page_num))
    return [dataclasses.asdict(b) for b in P._merge_open_parentheticals(blocks)]


STAGES = {"text_blocks": py_text_blocks}


def extract(pdf: Path) -> Path:
    CACHE.mkdir(parents=True, exist_ok=True)
    out = CACHE / (pdf.stem + ".blocks.json")
    if not out.exists() or out.stat().st_mtime < pdf.stat().st_mtime:
        out.write_bytes(subprocess.run([str(RELEASE / "pdfium_extract"), LIB, str(pdf), "blocks"],
                                       capture_output=True, check=True).stdout)
    return out


def diff(a, b, path="", out=None, limit=8):
    """Collect up to `limit` differences between two JSON values (floats compared to 1e-9)."""
    out = [] if out is None else out
    if len(out) >= limit:
        return out
    if isinstance(a, dict) and isinstance(b, dict):
        for k in sorted(set(a) | set(b)):
            if k not in a or k not in b:
                out.append(f"{path}.{k}: missing in {'python' if k not in a else 'rust'}")
            else:
                diff(a[k], b[k], f"{path}.{k}", out, limit)
    elif isinstance(a, list) and isinstance(b, list):
        if len(a) != len(b):
            out.append(f"{path}: length python {len(a)} vs rust {len(b)}")
        for i, (x, y) in enumerate(zip(a, b)):
            diff(x, y, f"{path}[{i}]", out, limit)
            if len(out) >= limit:
                break
    elif isinstance(a, (int, float)) and isinstance(b, (int, float)) and not isinstance(a, bool) and not isinstance(b, bool):
        if abs(a - b) > 1e-9 * max(1.0, abs(a)):
            out.append(f"{path}: python {a!r} vs rust {b!r}")
    elif a != b:
        out.append(f"{path}: python {a!r} vs rust {b!r}")
    return out


def main() -> int:
    args = sys.argv[1:]
    stage = args.pop(0) if args and args[0] in STAGES else "text_blocks"
    pdfs = [Path(a) for a in args] or sorted((ROOT / "Test PDFs").glob("*.pdf")) + sorted((ROOT / "Test PDFs" / "synthetic").glob("*.pdf"))
    bad = 0
    for pdf in pdfs:
        blocks_json = extract(pdf)
        doc = json.loads(blocks_json.read_text())
        expected = STAGES[stage](doc)
        got = json.loads(subprocess.run([str(RELEASE / "parser_stage"), stage, str(blocks_json)],
                                        capture_output=True, check=True).stdout)
        d = diff(expected, got)
        status = "ok" if not d else "DIFFERS"
        print(f"{status:8} {pdf.stem[:48]:48} {len(expected)} {stage}")
        for line in d:
            print("         ", line)
        bad += bool(d)
    print(f"\n{'✓ identical' if not bad else f'✗ {bad} of {len(pdfs)} differ'} ({stage})")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
