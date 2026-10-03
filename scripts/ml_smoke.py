#!/usr/bin/env python3
"""ml_smoke.py — generalisation smoke test on scripts with NO ground truth.

Six PDFs in `Test PDFs/` have no reference file, which means they were never used
to tune the heuristic parser and never seen by the model. They are the closest
thing available to "a script a real user just imported".

There is no ground truth, so this reports no accuracy. What it CAN catch, without
anyone opening the app:

  * crashes / empty parses on an unfamiliar format
  * degenerate output — everything collapsing into one kind, no speakers found
  * modes disagreeing wildly, which flags a format the model finds unfamiliar
  * whether the review flag would fire on a sane fraction of lines (a parse that
    flags 60% of its lines is useless to a user even if it is technically right)

Usage:
  python scripts/ml_smoke.py                 # all unlabelled scripts
  python scripts/ml_smoke.py --all           # include the 7 corpus scripts too
  python scripts/ml_smoke.py "Mr.-Burns"     # substring filter
"""
from __future__ import annotations

import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).parent.parent
sys.path.insert(0, str(ROOT / "backend"))
sys.path.insert(0, str(ROOT / "scripts"))

from parser import parse_pdf  # noqa: E402
from scorecard import CASES, PDF_DIR  # noqa: E402

CORPUS_PDFS = {pdf for _, pdf in CASES}


def unlabelled_pdfs() -> list[Path]:
    return sorted(p for p in PDF_DIR.glob("*.pdf") if p.name not in CORPUS_PDFS)


def run_one(pdf: Path, modes=("heuristic", "shadow")) -> dict:
    out: dict = {"pdf": pdf.name}
    per_mode = {}
    for mode in modes:
        try:
            script = parse_pdf(str(pdf), parser_mode=mode)
        except Exception as exc:  # noqa: BLE001 — reporting robustness IS the test
            per_mode[mode] = {"error": f"{type(exc).__name__}: {exc}"}
            continue
        els = [e for sc in script.scenes for e in sc.elements]
        kinds = Counter(e.kind for e in els)
        dialog = [e for e in els if e.kind == "dialog"]
        per_mode[mode] = {
            "scenes": len(script.scenes),
            "elements": len(els),
            "chars": len(script.characters),
            "kinds": kinds,
            "noSpk": sum(1 for e in dialog if not e.speaker),
            "flagged": sum(1 for e in els if e.kind_confidence < 0.6),
            "kinds_json": {k: v for k, v in kinds.items()},
        }
    out["modes"] = per_mode
    return out


def warnings_for(m: dict) -> list[str]:
    """Structural red flags that need no ground truth to detect."""
    warn = []
    if "error" in m:
        return [f"PARSE FAILED — {m['error']}"]
    if m["elements"] == 0:
        warn.append("no elements extracted")
    if m["chars"] == 0:
        warn.append("no characters found")
    if m["noSpk"] > 0:
        warn.append(f"{m['noSpk']} unattributed dialog lines")
    if m["elements"]:
        top_kind, top_n = m["kinds"].most_common(1)[0]
        if top_n / m["elements"] > 0.95:
            warn.append(f"degenerate: {top_n/m['elements']*100:.0f}% of elements are {top_kind}")
        frac = m["flagged"] / m["elements"]
        if frac > 0.35:
            warn.append(f"{frac*100:.0f}% of lines flagged — too noisy to act on")
    return warn


def main() -> int:
    args = sys.argv[1:]
    include_corpus = "--all" in args
    filters = [a for a in args if not a.startswith("--")]

    pdfs = unlabelled_pdfs()
    if include_corpus:
        pdfs += [PDF_DIR / p for _, p in CASES if (PDF_DIR / p).exists()]
    if filters:
        pdfs = [p for p in pdfs if any(f.lower() in p.name.lower() for f in filters)]
    if not pdfs:
        print("No matching PDFs.")
        return 1

    print(f"Smoke-testing {len(pdfs)} script(s) with no ground truth.\n"
          f"No accuracy is reported — this catches crashes, degenerate parses and\n"
          f"unusable flag rates on formats nothing was tuned against.\n")

    any_warn = False
    for pdf in pdfs:
        res = run_one(pdf)
        print(f"── {pdf.name}")
        for mode, m in res["modes"].items():
            if "error" in m:
                print(f"   {mode:<10} ✗ {m['error']}")
                any_warn = True
                continue
            kinds = ", ".join(f"{k}={v}" for k, v in m["kinds"].most_common())
            print(f"   {mode:<10} scenes={m['scenes']:<4} elements={m['elements']:<6} "
                  f"chars={m['chars']:<4} flagged={m['flagged']:<5} {kinds}")
        # Modes must agree on structure — shadow changes nothing by construction,
        # so any divergence here is a bug in the shadow plumbing itself.
        h, s = res["modes"].get("heuristic"), res["modes"].get("shadow")
        if h and s and "error" not in h and "error" not in s:
            if h["kinds_json"] != s["kinds_json"] or h["scenes"] != s["scenes"]:
                print("   ⚠ shadow mode CHANGED the parse — it must not")
                any_warn = True
        for mode, m in res["modes"].items():
            for w in warnings_for(m):
                print(f"   ⚠ [{mode}] {w}")
                any_warn = True
        print()

    print("Some checks flagged issues above." if any_warn
          else "All scripts parsed cleanly with no structural red flags.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
