#!/usr/bin/env python3
"""real_score.py — score the parser against your hand-labelled sample of real PDFs.

Reads Test PDFs/reference/real_sample.json (made with label_sample.py), parses
each PDF, and checks every labelled line the same way synth_score.py checks a
generated one: was it read by the right voice? Dialogue by its character,
directions and asides by the narrator, names, headings and page junk not at all.
Lines labelled "mixed" or "can't tell" are left out and counted.

Every script contributes the same number of lines, so the overall figure is
what a typical script gets, not what the longest ones get. The 95% range is a
Wilson interval: the true accuracy on lines like these lies inside it 95% of
the time.

Usage:
  python scripts/real_score.py
  python scripts/real_score.py --errors 5     # plus examples of the mistakes
"""
from __future__ import annotations

import argparse
import logging
import math
import sys
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "backend"))
sys.path.insert(0, str(ROOT / "scripts"))

import label_sample as L  # noqa: E402
import synth_score as S  # noqa: E402

EXCLUDED = {"mixed", "unsure"}
UNKNOWN = "?"   # dialogue whose speaker couldn't be seen: scored as "read by some character"


def expected(item: dict) -> str:
    if item["label"] == "dialog":
        return UNKNOWN if item["speaker"] == UNKNOWN else S.norm_speaker(item["speaker"])
    if item["label"] in ("stage_direction", "parenthetical"):
        return S.NARRATOR
    return S.SILENT


def wilson(ok: int, n: int, z: float = 1.96) -> tuple[float, float]:
    if not n:
        return (0.0, 0.0)
    p = ok / n
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return (c - h, c + h)


def score_pdf(pdf: str, items: list[dict]) -> list[dict]:
    from parser import parse_pdf

    d = L.doc(pdf)
    stream, t_words, t_line = [], [], []
    for pg in range(len(d)):
        for i, (text, _) in enumerate(L.page_lines(d[pg])):
            for w in S.words(text):
                t_words.append(w)
                t_line.append((pg, i))
    found = S.align(t_words, S.output_elements(parse_pdf(str(L.PDF_DIR / pdf))))
    by_line = defaultdict(list)
    for k, key in enumerate(t_line):
        by_line[key].append(k)
    rows = []
    for it in items:
        idx = by_line.get((it["page"], it["line"]), [])
        hits = [found[k] for k in idx if k in found]
        if not idx:          # no words (e.g. a lone "..."): nothing to read, nothing to score
            continue
        got = S.SILENT if len(hits) * 2 < len(idx) else Counter(v for v, _ in hits).most_common(1)[0][0]
        exp = expected(it)
        ok = got not in (S.SILENT, S.NARRATOR) if exp == UNKNOWN else got == exp
        rows.append({"item": it, "expected": exp, "got": got, "ok": ok})
    return rows


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--errors", type=int, default=0)
    args = ap.parse_args()
    logging.disable(logging.CRITICAL)
    if not L.LABELS.exists():
        print("No labels yet. Run: python scripts/label_sample.py")
        return 1
    items = L.load()["items"]
    stale = [it for it in items if it["label"] and L.line_text(it) is None]
    flagged = [it for it in items if it["label"] and L.needs_review(it) and not it.get("reviewed")]
    if flagged:
        print(f"Note: {len(flagged)} labels look like slips and are counted as labelled. "
              "Confirm or fix them with: python scripts/label_sample.py --review\n")
    usable = [it for it in items if it["label"] and it["label"] not in EXCLUDED and it not in stale]
    by_pdf = defaultdict(list)
    for it in usable:
        by_pdf[it["pdf"]].append(it)

    print(f"{'script':42} {'lines':>5} {'right voice':>11}")
    print("-" * 62)
    all_rows = []
    for pdf in sorted(by_pdf):
        rows = score_pdf(pdf, by_pdf[pdf])
        all_rows.extend(rows)
        ok = sum(r["ok"] for r in rows)
        print(f"{pdf[:42]:42} {len(rows):>5} {100 * ok / len(rows):>10.1f}%")
        for r in [r for r in rows if not r["ok"]][:args.errors]:
            text = L.line_text(r["item"]) or ""
            print(f"      {r['item']['label']:15} expected {r['expected']:12} got {r['got']:12} | {text[:55]}")
    print("-" * 62)
    ok, n = sum(r["ok"] for r in all_rows), len(all_rows)
    if n:
        lo, hi = wilson(ok, n)
        print(f"{'ALL':42} {n:>5} {100 * ok / n:>10.1f}%   (95% range {100 * lo:.1f}-{100 * hi:.1f}%)")
        kinds = defaultdict(lambda: [0, 0])
        for r in all_rows:
            kinds[r["item"]["label"]][0] += r["ok"]
            kinds[r["item"]["label"]][1] += 1
        print("\nBy what the line is:")
        for k, (a, b) in sorted(kinds.items(), key=lambda kv: -kv[1][1]):
            print(f"  {k:16} {b:4} lines  {100 * a / b:5.1f}% right")
    left_out = sum(1 for it in items if it["label"] in EXCLUDED)
    wordless = sum(1 for it in usable if not S.words(L.line_text(it) or ""))
    if wordless:
        print(f"{wordless} labelled lines have no words to read (e.g. a lone \"...\") and aren't scored.")
    todo = sum(1 for it in items if not it["label"])
    print(f"\n{left_out} lines marked mixed/can't tell (left out), {todo} not labelled yet, "
          f"{len(stale)} no longer match their PDF.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
