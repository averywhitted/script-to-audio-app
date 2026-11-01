#!/usr/bin/env python3
"""side_by_side.py — find text laid out side by side on real PDF pages.

Used to draw the side-by-side exam (label_kit.py), so it must not use the
parser: an exam drawn by the parser's own detector would share its blind spots.
It works on PyMuPDF's physical lines only (label_sample.page_lines), so every
line it returns can be labelled and scored like the main sample's lines.

A *shared row* is two lines at the same height with a clear horizontal gap
between them. A *region* is a run of shared rows on one page, plus the lines
that continue one column below them (the longer side of uneven columns).
Landscape sheets that print two book pages (EMMA) are split down the middle
first, so only side-by-side text *within* a book page counts.

Usage:
  python scripts/side_by_side.py            # regions and line counts per PDF
"""
from __future__ import annotations

import re
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import label_sample as L  # noqa: E402

MIN_GAP = 0.02        # of the page (or half-page) width
MARGIN_BAND = 0.07    # top/bottom bands of the page hold headers and page numbers
PROSE = re.compile(r"[a-z]{3}")  # running text, not a name or a number
# A character name line: short ALL-CAPS, maybe with (CONT'D) or an aside.
NAME = re.compile(r"(?!(SCENE|ACT|END|INTERMISSION|CONTINUED|THE END)\b)"
                  r"[A-Z][A-Z .'\-]{0,23}[A-Z]:?(\s*\(.*\))?")  # no trailing "." (DAWN.)
JUNK = re.compile(r"^[\d\s.\-*()A-Z]{0,4}$")  # scene numbers, page numbers, revision stars


def _halves(width: float, height: float) -> list[tuple[float, float]]:
    """x-ranges to treat as separate pages: two for a landscape two-page sheet."""
    return [(0, width / 2), (width / 2, width)] if width > height else [(0, width)]


def _column_runs(lines, idx: list[int], min_gap: float) -> set[int]:
    """Lines in true two-column stretches: in top-to-bottom order, a run with no
    line crossing a gutter and at least 3 lines on each side of it. Catches
    columns whose lines alternate rather than share rows (Stereophonic's two
    rooms). An ordinary name-over-dialogue indent never qualifies, because
    action and long speeches cross the gutter every few lines; names printed
    in the margin beside their speech don't either, and neither do stage
    plays with speech on one side and names/directions on the other: each
    side must hold its own character names *and* running text."""
    found: set[int] = set()
    ordered = sorted(idx, key=lambda i: lines[i][1][1])
    starts = sorted({round(lines[i][1][0]) for i in idx})
    for right in starts[1:]:
        run: list[int] = []

        def close() -> None:
            left = [i for i in run if lines[i][1][2] <= right - min_gap]
            right_side = [i for i in run if i not in left]
            prose = lambda side: sum(1 for i in side if PROSE.search(lines[i][0]))
            names = lambda side: sum(1 for i in side if NAME.fullmatch(lines[i][0].strip()))
            if (prose(left) >= 2 and prose(right_side) >= 2
                    and names(left) >= 1 and names(right_side) >= 1):
                found.update(run)

        for i in ordered:
            x0, x1 = lines[i][1][0], lines[i][1][2]
            if x0 >= right - 1 or x1 <= right - min_gap:
                run.append(i)
            else:              # crosses the gutter: the stretch ends here
                close()
                run = []
        close()
    return found


def page_regions(pdf: str, page: int) -> list[list[int]]:
    """Regions on one page, each a sorted list of line indices (label_sample order)."""
    pg = L.doc(pdf)[page]
    W, H = pg.rect.width, pg.rect.height
    lines = L.lines_of(pdf, page)
    regions = []
    for lo, hi in _halves(W, H):
        span = hi - lo
        heights = sorted(b[3] - b[1] for _, b in lines) or [0]
        tall = 2.5 * heights[len(heights) // 2]   # rotated text (margin watermarks)
        idx = [i for i, (t, b) in enumerate(lines)
               if lo <= (b[0] + b[2]) / 2 < hi
               and MARGIN_BAND * H < (b[1] + b[3]) / 2 < (1 - MARGIN_BAND) * H
               and b[3] - b[1] <= tall
               and not JUNK.fullmatch(t.strip())]
        column_runs = _column_runs(lines, idx, MIN_GAP * span)
        # Shared rows: pairs at the same height with a gap between them.
        pair_of: dict[int, tuple[float, float]] = {}   # line -> gap (left edge, right edge)
        for a in idx:
            ta, ba = lines[a]
            for b in idx:
                if b == a:
                    continue
                tb, bb = lines[b]
                if bb[0] <= ba[0]:
                    continue                      # only look rightwards from a
                overlap = min(ba[3], bb[3]) - max(ba[1], bb[1])
                if overlap < 0.5 * min(ba[3] - ba[1], bb[3] - bb[1]):
                    continue
                if bb[0] - ba[2] < MIN_GAP * span:
                    continue
                gap = (ba[2], bb[0])
                pair_of.setdefault(a, gap)
                pair_of.setdefault(b, gap)
        if not pair_of and not column_runs:
            continue
        # Grow each shared row downwards through lines that stay in one column.
        rows = sorted(pair_of, key=lambda i: lines[i][1][1])
        in_region: set[int] = set(rows) | column_runs
        for i in idx:
            if i in in_region:
                continue
            t, b = lines[i]
            above = [r for r in rows if lines[r][1][3] <= b[1] + 1]
            if not above:
                continue
            r = max(above, key=lambda r: lines[r][1][3])
            gl, gr = pair_of[r]
            crosses = b[0] < gr - 1 and b[2] > gl + 1
            near = b[1] - lines[r][1][3] < 2.5 * (b[3] - b[1])
            if near and not crosses:
                in_region.add(i)
                rows.append(i)
                pair_of[i] = pair_of[r]
                rows.sort(key=lambda i: lines[i][1][1])
        # Split into regions where the vertical gap between lines is large.
        ordered = sorted(in_region, key=lambda i: lines[i][1][1])
        cur = [ordered[0]]
        for i in ordered[1:]:
            prev_bottom = max(lines[j][1][3] for j in cur)
            if lines[i][1][1] - prev_bottom > 3 * (lines[i][1][3] - lines[i][1][1]):
                regions.append(sorted(cur))
                cur = []
            cur.append(i)
        regions.append(sorted(cur))
    # A region needs at least one shared row of real text on both sides.
    return [r for r in regions if len(r) >= 2]


def all_regions(pdf: str) -> list[tuple[int, list[int]]]:
    """(page, line indices) for every region in a PDF."""
    out = []
    for page in range(len(L.doc(pdf))):
        out += [(page, r) for r in page_regions(pdf, page)]
    return out


def main() -> int:
    total = Counter()
    for pdf in sorted(p.name for p in L.PDF_DIR.glob("*.pdf")):
        regs = all_regions(pdf)
        n = sum(len(r) for _, r in regs)
        total[pdf] = n
        print(f"{pdf[:42]:42} regions {len(regs):4}  lines {n:5}  pages {len({p for p, _ in regs}):4}")
    print(f"{'all':42} lines {sum(total.values()):5}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
