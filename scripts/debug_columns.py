#!/usr/bin/env python3
"""debug_columns.py — inspect two-column PDF layout for Table Read diagnostics.

Usage:
    python scripts/debug_columns.py path/to/script.pdf [--pages 5-10]

Prints every page's rows that pdfplumber sees as two-column, showing the
left and right text alongside x-coordinates so you can tune column detection.

Also prints the first 80 chars of every line that would be emitted by the
column-aware extractor (with | marking the column boundary).

Options:
    --pages N-M     Only inspect pages N through M (1-based, inclusive).
    --gap-pct N     Minimum column gap as % of page width (default: 12).
    --show-all      Also print single-column rows (verbose).
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Optional

# Allow running from repo root: python scripts/debug_columns.py
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "backend"))

import pdfplumber  # noqa: E402 — after sys.path insert


def _group_words_into_rows(words: list[dict], y_tolerance: float = 3.0) -> list[list[dict]]:
    if not words:
        return []
    sorted_words = sorted(words, key=lambda w: (w["top"], w["x0"]))
    rows: list[list[dict]] = [[sorted_words[0]]]
    for word in sorted_words[1:]:
        if abs(word["top"] - rows[-1][0]["top"]) <= y_tolerance:
            rows[-1].append(word)
        else:
            rows.append([word])
    return rows


def _detect_column_split(row_words: list[dict], page_width: float, gap_pct: float) -> Optional[float]:
    if len(row_words) < 2:
        return None
    by_x = sorted(row_words, key=lambda w: w["x0"])
    max_gap = 0.0
    gap_mid: Optional[float] = None
    for i in range(len(by_x) - 1):
        gap = by_x[i + 1]["x0"] - by_x[i]["x1"]
        if gap > max_gap:
            max_gap = gap
            gap_mid = (by_x[i]["x1"] + by_x[i + 1]["x0"]) / 2.0
    if gap_mid is None:
        return None
    if max_gap < page_width * (gap_pct / 100.0):
        return None
    if not (page_width * 0.20 <= gap_mid <= page_width * 0.80):
        return None
    return gap_mid


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("pdf", help="Path to the PDF file")
    parser.add_argument("--pages", default=None,
                        help="Page range to inspect, e.g. 5-10 (1-based, inclusive)")
    parser.add_argument("--gap-pct", type=float, default=12.0,
                        help="Min gap as %% of page width to count as two-column (default 12)")
    parser.add_argument("--show-all", action="store_true",
                        help="Also print single-column rows")
    args = parser.parse_args()

    page_range: Optional[range] = None
    if args.pages:
        lo, _, hi = args.pages.partition("-")
        page_range = range(int(lo) - 1, int(hi))  # 0-based

    two_col_count = 0
    line_count = 0

    with pdfplumber.open(args.pdf) as pdf:
        for pg_idx, page in enumerate(pdf.pages):
            if page_range is not None and pg_idx not in page_range:
                continue

            page_width = float(page.width or 612)
            words = page.extract_words(x_tolerance=3, y_tolerance=3) or []
            rows = _group_words_into_rows(words)

            pg_header_printed = False
            for row in rows:
                col_x = _detect_column_split(row, page_width, args.gap_pct)
                if col_x is not None:
                    if not pg_header_printed:
                        print(f"\n{'='*60}")
                        print(f"  Page {pg_idx + 1}  (width={page_width:.0f} pt)")
                        print(f"{'='*60}")
                        pg_header_printed = True
                    two_col_count += 1

                    by_x = sorted(row, key=lambda w: w["x0"])
                    left_words  = [w for w in by_x if w["x1"] <= col_x]
                    right_words = [w for w in by_x if w["x0"] >= col_x]
                    left_text  = " ".join(w["text"] for w in left_words)
                    right_text = " ".join(w["text"] for w in right_words)
                    gap = (right_words[0]["x0"] - left_words[-1]["x1"]) if (left_words and right_words) else 0.0

                    print(f"  y={row[0]['top']:6.1f}  gap={gap:5.1f}pt  col@{col_x:5.1f}")
                    print(f"    LEFT : {left_text[:70]!r}")
                    print(f"    RIGHT: {right_text[:70]!r}")
                    print(f"    EMIT : {(left_text + ' | ' + right_text)[:80]!r}")
                elif args.show_all:
                    if not pg_header_printed:
                        print(f"\n  -- Page {pg_idx + 1} --")
                        pg_header_printed = True
                    by_x = sorted(row, key=lambda w: w["x0"])
                    text = " ".join(w["text"] for w in by_x)
                    print(f"  y={row[0]['top']:6.1f}  single: {text[:70]!r}")
                line_count += 1

    print(f"\n{'─'*60}")
    print(f"Total rows scanned : {line_count}")
    print(f"Two-column rows    : {two_col_count}")
    if two_col_count == 0:
        print()
        print("No two-column rows found.  Try lowering --gap-pct (currently"
              f" {args.gap_pct}%) or check that the right pages are in scope.")
        print("Re-run with --show-all to see all rows with their x-positions.")


if __name__ == "__main__":
    main()
