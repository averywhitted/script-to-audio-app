"""Reference extraction: dump the structure backend/parser.py consumes from PyMuPDF.

Writes out/<stem>.pymupdf.json = {"pages": [{"w","h","blocks":[{"bbox","lines":[{"bbox","spans":[
{"text","font","size","bold","italic","bbox"}]}]}]}]}. Same call and flags as parser._extract_blocks.
Usage: python dump_pymupdf.py <pdf> <outdir>
"""
import json
import sys
from pathlib import Path

import fitz  # PyMuPDF


def dump(pdf: str) -> dict:
    pages = []
    with fitz.open(pdf) as doc:
        for page in doc:
            raw = page.get_text(
                "dict", flags=fitz.TEXTFLAGS_DICT & ~fitz.TEXT_PRESERVE_IMAGES)["blocks"]
            blocks = []
            for b in raw:
                if b["type"] != 0:
                    continue
                lines = []
                for ln in b["lines"]:
                    spans = [{
                        "text": s["text"], "font": s["font"], "size": s["size"],
                        "bold": bool(s["flags"] & (1 << 4)),
                        "italic": bool(s["flags"] & (1 << 1)),
                        "bbox": list(s["bbox"]),
                    } for s in ln["spans"]]
                    lines.append({"bbox": list(ln["bbox"]), "spans": spans})
                blocks.append({"bbox": list(b["bbox"]), "lines": lines})
            pages.append({"w": page.rect.width, "h": page.rect.height, "blocks": blocks})
    return {"pages": pages}


if __name__ == "__main__":
    pdf, out = Path(sys.argv[1]), Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)
    (out / f"{pdf.stem}.pymupdf.json").write_text(json.dumps(dump(str(pdf))))
