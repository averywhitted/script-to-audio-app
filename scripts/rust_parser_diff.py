#!/usr/bin/env python3
"""rust_parser_diff.py — compare the Rust parser port with backend/parser.py, stage by stage, field for field.

Both parsers read the same input: the Rust PDFium extractor's output (the PyMuPDF `get_text("dict")` shape). The
parser is deterministic given those blocks, so any difference is a porting bug. Stages (grows with the port):

  text_blocks   _split_raw_block + _merge_open_parentheticals  ->  list of TextBlock
  doc_model     _build_document_model + _compute_doc_stats       ->  profile, cast, columns, furniture, doc stats
  classified_nostyle  _classify_blocks without the learned-style pass ->  role/speaker/aside per block
  style         _learn_style (prior, evidence, both feature tables)
  classified    the complete _classify_blocks (style pass + bare-name silencing)
  script        _build_script_from_blocks + _finalise + corrections config  ->  the worker's script summary

Usage:
  python3 scripts/rust_parser_diff.py [-v] [stage] [pdf ...]      (default: every PDF in Test PDFs/ and Test PDFs/synthetic/)
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


def _py_blocks(doc: dict) -> list:
    blocks = []
    for page_num, page in enumerate(doc["pages"]):
        for raw in page["blocks"]:
            if raw.get("type", 0) == 0:
                blocks.extend(P._split_raw_block(raw, page_num))
    return P._merge_open_parentheticals(blocks)


def py_doc_model(doc: dict) -> dict:
    blocks = _py_blocks(doc)
    page_widths = [b.x1 for b in blocks if b.x1 > 200]
    page_width = max(page_widths) + 90.0 if page_widths else 612.0
    m = P._build_document_model(blocks, page_width=page_width)
    s = P._compute_doc_stats(blocks)
    return {
        "profile": dataclasses.asdict(m.profile), "cast_lexicon": dict(m.cast_lexicon), "cast": sorted(m.cast),
        "cue_columns": m.cue_columns, "dialog_columns": m.dialog_columns,
        "furniture": sorted(m.furniture), "cue_labels": sorted(m.cue_labels),
        "doc_stats": {
            "x_bin_count": {str(k): v for k, v in s.x_bin_count.items()},
            "x_bin_caps_avg": {str(k): v for k, v in s.x_bin_caps_avg.items()},
            "text_frequency": dict(s.text_frequency), "max_x_count": s.max_x_count,
            "total_blocks": s.total_blocks, "body_top": s.body_top, "body_bottom": s.body_bottom,
        },
    }


def py_classified_nostyle(doc: dict) -> list:
    """_classify_blocks with the learned-style pass switched off (that is stage 4)."""
    blocks = _py_blocks(doc)
    page_widths = [b.x1 for b in blocks if b.x1 > 200]
    model = P._build_document_model(blocks, page_width=max(page_widths) + 90.0 if page_widths else 612.0)
    saved = P._apply_learned_style
    P._apply_learned_style = lambda result, model: None
    try:
        out = P._classify_blocks(blocks, model)
    finally:
        P._apply_learned_style = saved
    return [{"page": c.block.page, "x0": c.block.x0, "y0": c.block.y0, "text": c.block.text,
             "role": c.role, "speaker": c.speaker, "aside": c.aside} for c in out]


def _py_model(doc: dict):
    blocks = _py_blocks(doc)
    page_widths = [b.x1 for b in blocks if b.x1 > 200]
    return blocks, P._build_document_model(blocks, page_width=max(page_widths) + 90.0 if page_widths else 612.0)


def py_style(doc: dict):
    """The fitted style model, captured where _classify_blocks calls it (before bare names are silenced)."""
    blocks, model = _py_model(doc)
    captured = {}
    saved = P._apply_learned_style
    P._apply_learned_style = lambda result, m: captured.update(learned=P._learn_style(result, m))
    try:
        P._classify_blocks(blocks, model)
    finally:
        P._apply_learned_style = saved
    l = captured["learned"]
    if l is None:
        return None
    return {"prior": l["prior"], "evidence": l["evidence"], "pool_size": len(l["pool"]),
            "dialog": [dict(t) for t in l["dialog"]], "direction": [dict(t) for t in l["direction"]]}


def py_classified(doc: dict) -> list:
    blocks, model = _py_model(doc)
    return [{"page": c.block.page, "x0": c.block.x0, "y0": c.block.y0, "text": c.block.text,
             "role": c.role, "speaker": c.speaker, "aside": c.aside} for c in P._classify_blocks(blocks, model)]


def py_script(doc: dict) -> dict:
    """The assembled Script (as the worker serialises it) for the fixed title "TITLE" and the real corrections config."""
    sys.path.insert(0, str(ROOT / "backend"))
    import audio_worker
    blocks, model = _py_model(doc)
    classified = P._classify_blocks(blocks, model)
    script = P._build_script_from_blocks(classified, title="TITLE", config=P._load_corrections_config(), cast=model.cast)
    return audio_worker._script_summary(script)


STAGES = {"text_blocks": py_text_blocks, "doc_model": py_doc_model, "classified_nostyle": py_classified_nostyle,
          "style": py_style, "classified": py_classified, "script": py_script}


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
    args = [a for a in sys.argv[1:] if a != "-v"]
    stages = []
    while args and args[0] in STAGES:
        stages.append(args.pop(0))
    stages = stages or list(STAGES)
    pdfs = [Path(a) for a in args] or sorted((ROOT / "Test PDFs").glob("*.pdf")) + sorted((ROOT / "Test PDFs" / "synthetic").glob("*.pdf"))
    verbose = "-v" in sys.argv
    bad_total = 0
    for st in stages:
        bad = 0
        for pdf in pdfs:
            blocks_json = extract(pdf)
            doc = json.loads(blocks_json.read_text())
            expected = STAGES[st](doc)
            extra = [str(ROOT / "backend" / "corrections_config.json")] if st == "script" else []
            got = json.loads(subprocess.run([str(RELEASE / "parser_stage"), st, str(blocks_json)] + extra,
                                            capture_output=True, check=True).stdout)
            d = diff(expected, got)
            if d or verbose:
                print(f"{'ok' if not d else 'DIFFERS':8} {st:12} {pdf.stem[:48]}")
            for line in d:
                print("         ", line)
            bad += bool(d)
        print(f"{'✓ identical' if not bad else f'✗ {bad} of {len(pdfs)} differ'}: {st} on {len(pdfs)} PDFs")
        bad_total += bad
    return 1 if bad_total else 0


if __name__ == "__main__":
    sys.exit(main())
