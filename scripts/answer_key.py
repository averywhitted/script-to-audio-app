#!/usr/bin/env python3
"""answer_key.py — the parser's regression gate, built on the two answer keys.

Replaces scorecard.py as the gate (Oct 2026). The scorecard compared against
rule-generated "ground truth" and could see only about half of each script;
these check what a listener hears, on every line:

  generated  synth_generate.py scripts, exact answers by construction
             (baseline committed: Test PDFs/reference/synth_baseline.json)
  real       your hand-labelled sample of real PDF lines (label_sample.py)
             (baseline kept local next to the labels: real_sample.baseline.json)

The rule for a parser change:
  - no generated unit that was read by the right voice may stop being so, and
  - no labelled real line that was right may go wrong,
unless we've looked at it and accepted it with --save. Every such unit/line is
listed by name, so a trade-off is a decision, never an accident.

Usage:
  python scripts/answer_key.py           # scores + changes vs baseline
  python scripts/answer_key.py --check   # same, exit 1 if anything got worse
  python scripts/answer_key.py --save    # accept the current results as baseline
"""
from __future__ import annotations

import argparse
import json
import logging
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "backend"))
sys.path.insert(0, str(ROOT / "scripts"))

import label_sample as L  # noqa: E402
import real_score as R  # noqa: E402
import synth_generate as G  # noqa: E402
import synth_score as S  # noqa: E402

SYNTH_BASELINE = ROOT / "Test PDFs" / "reference" / "synth_baseline.json"
REAL_BASELINE = ROOT / "Test PDFs" / "reference" / "real_sample.baseline.json"


def synth_results() -> dict[str, dict[str, bool]]:
    """{script: {unit id: read by the right voice?}} for every generated script."""
    names = [n for n, _ in G.standard_styles()]
    if not all((S.SYNTH_DIR / f"{n}.truth.json").exists() for n in names):
        print("Generating the answer-key scripts (first run)...")
        for n, style in G.standard_styles():
            G.write(n, style, seed=1)
    return {n: {str(r["unit"]["id"]): r["ok"] for r in S.score_one(n)["rows"]} for n in names}


def real_results() -> dict[str, bool] | None:
    """{sample index: right?} for every scorable labelled line, or None without labels."""
    if not L.LABELS.exists():
        return None
    items = L.load()["items"]
    by_pdf: dict[str, list[tuple[int, dict]]] = {}
    for n, it in enumerate(items):
        if it["label"] and it["label"] not in R.EXCLUDED and L.line_text(it) is not None:
            by_pdf.setdefault(it["pdf"], []).append((n, it))
    out = {}
    for pdf, pairs in by_pdf.items():
        if not (L.PDF_DIR / pdf).exists():
            continue
        rows = R.score_pdf(pdf, [it for _, it in pairs])
        index_of = {id(it): n for n, it in pairs}
        for r in rows:
            out[str(index_of[id(r["item"])])] = r["ok"]
    return out


def pct(ok: int, n: int) -> str:
    return f"{100 * ok / n:5.1f}%" if n else "  -  "


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--check", action="store_true")
    g.add_argument("--save", action="store_true")
    args = ap.parse_args()
    logging.disable(logging.CRITICAL)

    synth = synth_results()
    real = real_results()

    if args.save:
        SYNTH_BASELINE.write_text(json.dumps(synth, indent=0, sort_keys=True))
        print(f"Saved generated-script baseline → {SYNTH_BASELINE.relative_to(ROOT)}")
        if real is not None:
            REAL_BASELINE.write_text(json.dumps(real, indent=0, sort_keys=True))
            print(f"Saved real-sample baseline → {REAL_BASELINE.relative_to(ROOT)} (local only)")
        return 0

    worse = 0
    base = json.loads(SYNTH_BASELINE.read_text()) if SYNTH_BASELINE.exists() else {}
    print("Generated scripts — right voice")
    tot_ok = tot_n = 0
    for name, units in synth.items():
        ok, n = sum(units.values()), len(units)
        tot_ok, tot_n = tot_ok + ok, tot_n + n
        b = base.get(name, {})
        broke = [u for u, v in units.items() if b.get(u) and not v]
        fixed = [u for u, v in units.items() if b.get(u) is False and v]
        note = (f"  +{len(fixed)} fixed" if fixed else "") + (f"  -{len(broke)} BROKEN" if broke else "")
        print(f"  {name:24} {pct(ok, n)}{note}")
        if broke:
            worse += len(broke)
            truth = json.loads((S.SYNTH_DIR / f"{name}.truth.json").read_text())
            for u in broke[:5]:
                unit = truth["units"][int(u)]
                print(f"      broke: {unit['kind']:15} | {unit['text'][:60]}")
    print(f"  {'ALL':24} {pct(tot_ok, tot_n)}  ({tot_ok} of {tot_n})")

    if real is None:
        print("\nReal sample: no labels on this machine — skipped.")
    else:
        rbase = json.loads(REAL_BASELINE.read_text()) if REAL_BASELINE.exists() else {}
        ok, n = sum(real.values()), len(real)
        lo, hi = R.wilson(ok, n)
        broke = [i for i, v in real.items() if rbase.get(i) and not v]
        fixed = [i for i, v in real.items() if rbase.get(i) is False and v]
        print(f"\nReal sample — right voice {pct(ok, n)} of {n} lines (95% range {100 * lo:.1f}–{100 * hi:.1f}%)"
              + (f"  +{len(fixed)} fixed" if fixed else "") + (f"  -{len(broke)} BROKEN" if broke else ""))
        items = L.load()["items"]
        for i in broke:
            it = items[int(i)]
            print(f"      broke: {it['label']:15} {it['pdf'][:24]} p{it['page'] + 1} | {(L.line_text(it) or '')[:50]}")
        worse += len(broke)

    if not base:
        print("\nNo baseline yet. Run with --save to record one.")
    if args.check and worse:
        print(f"\n✗ {worse} unit(s)/line(s) went from right to wrong. Fix them, or if the trade-off is "
              "deliberate and reviewed, accept it with: python scripts/answer_key.py --save")
        return 1
    if args.check:
        print("\n✓ Nothing got worse.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
