"""Run the repo's real answer-key gate with PDFium-based extraction instead of PyMuPDF.

Patches backend/parser._extract_blocks with a builder that rebuilds PyMuPDF's page->block->line->span
"dict" structure from PDFium (pypdfium2 here; pdfium-render in the Rust port) and feeds it through the
unchanged _split_raw_block. Compares against the committed PyMuPDF baselines (never saves them).
Usage: python pdfium_answer_key.py [--check]   env BLOCKS=mupdf|gap|line (default mupdf), GAP=1.45, TOL=0.25
"""
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent.parent
sys.path[:0] = [str(HERE), str(ROOT / "backend"), str(ROOT / "scripts")]

import pypdfium2 as pdfium  # noqa: E402
import parser as P  # noqa: E402
import answer_key as AK  # noqa: E402
from proto_chars import page_chars  # noqa: E402
from proto_lines import build_lines  # noqa: E402

STRATEGY = os.environ.get("BLOCKS", "mupdf")
GAP = float(os.environ.get("GAP", "1.45"))
TOL = float(os.environ.get("TOL", "0.25"))


def to_raw_line(ln):
    spans = []
    for s in ln["spans"]:
        spans.append({"text": s["text"], "font": s["font"], "size": s["size"],
                      "flags": (1 << 1 if s["italic"] else 0) | (1 << 4 if s["bold"] else 0),
                      "bbox": ln["bbox"]})
    return {"bbox": tuple(ln["bbox"]), "spans": spans}


def group_blocks(lines):
    blocks, cur = [], []
    for ln in lines:
        if cur and STRATEGY == "mupdf":
            prev = cur[-1]
            size = max(s["size"] for s in ln["spans"])
            dy = ln["bbox"][1] - prev["bbox"][1]
            dx = ln["bbox"][0] - prev["bbox"][0]
            # Reproduces MuPDF's block boundaries (19349 of 19357 across the corpus): a new block when
            # the line jumps up, drops past 1.45 em, or is indented further than the line before it.
            if dy < -0.5 * size or dy > GAP * size or (dy > 0.3 * size and dx > TOL * size):
                blocks.append(cur); cur = []
        elif cur and STRATEGY == "gap":
            prev = cur[-1]
            size = max(s["size"] for s in ln["spans"])
            dy = ln["bbox"][1] - prev["bbox"][1]
            if not (0 < dy <= GAP * size):
                blocks.append(cur); cur = []
        elif cur and STRATEGY == "line":
            blocks.append(cur); cur = []
        cur.append(ln)
    if cur:
        blocks.append(cur)
    return blocks


def extract_blocks_pdfium(pdf_path):
    out = []
    doc = pdfium.PdfDocument(pdf_path)
    n = len(doc)
    for pi in range(n):
        P._report_progress(0.8 * pi / max(n, 1), f"Reading page {pi + 1} of {n}")
        lines = build_lines(page_chars(doc[pi])["chars"], keep_blank=True)
        for blk in group_blocks(lines):
            bb = (min(l["bbox"][0] for l in blk), min(l["bbox"][1] for l in blk),
                  max(l["bbox"][2] for l in blk), max(l["bbox"][3] for l in blk))
            out.extend(P._split_raw_block({"type": 0, "bbox": bb, "lines": [to_raw_line(l) for l in blk]}, pi))
    return out


P._extract_blocks = extract_blocks_pdfium

if __name__ == "__main__":
    sys.exit(AK.main())
