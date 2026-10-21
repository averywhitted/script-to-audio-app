# PDFium extraction spike (#99)

Goal: prove PDFium can rebuild the page > block > line > span structure that `backend/parser.py`
(`_extract_blocks` / `_split_raw_block`) gets from PyMuPDF, well enough that the answer-key gate does not
get worse. Prototyped in Python with `pypdfium2` (the same PDFium) before the Rust port (`pdfium-render`).

Result (Oct 21 2026): `python spikes/pdfium_extract/scripts/pdfium_answer_key.py --check` reports
"Nothing got worse": generated 99.4% (= baseline, 0 broken), real sample 98.5% (= baseline, 0 broken).

What the builder has to do (each was a measured failure first):
- Scale font size by the text matrix (`sqrt|det|`); `FPDFText_GetFontSize` alone gives 1.0 on some PDFs.
- Map coordinates with `FPDF_PageToDevice` (some PDFs have odd page boxes / negative y); use the loose
  char box for x (advance based).
- Line box = baseline -/+ font ascent/descent x size. PDFium's font ascent/descent equal MuPDF's for
  embedded fonts; the 14 standard fonts need MuPDF's own numbers (`base14_metrics.json`).
- Lines: same baseline, no backwards jump, no forward gap over 2 em; ignore PDFium's synthetic spaces
  when deciding breaks, and add a space for gaps over 0.1 em (MuPDF spaces by gap).
- Rotated (near-vertical) text forms its own lines along its baseline; PDFium also reports italic shear
  as an "angle", so only |sin| > 0.7 counts as rotated.
- Content-stream order, not PDFium's text-page order (it decides which line starts a block). Text
  objects the text page drops (a lone " " after a line, or a blank line) become space characters.
- Blocks: new block when the line jumps up, drops over 1.45 em, or is indented over 0.25 em more than
  the previous line. Reproduces 19349 of 19357 PyMuPDF block boundaries.

Known gaps (not gate-relevant yet): the trailing space's width (0.25 em assumed; Courier is 0.6 em) so some
right edges are off by a space; non-standard non-embedded fonts get slightly different line heights;
rotated pages / non-zero page rotation are untested; EMMA gets 4960 lines vs 4746.

Scripts: `dump_pymupdf.py` (reference dump), `proto_chars.py` (PDFium chars), `proto_lines.py` (line builder
+ scorer vs the reference dump), `pdfium_answer_key.py` (gate with PDFium extraction). Outputs go to
the gitignored `out/` (they contain script text).
