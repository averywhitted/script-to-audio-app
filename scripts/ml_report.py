#!/usr/bin/env python3
"""ml_report.py — per-block forensics for the element classifier.

The point of this tool is to make parser bugs findable from a terminal instead of
by clicking through the app. For any corpus script it emits, per block: the text,
every feature, the predicted kind, the confidence, the ground-truth kind, and
whether the prediction was right — plus aggregate views over that table.

Usage:
  python scripts/ml_report.py                       # every corpus script, summary
  python scripts/ml_report.py TheHarvest            # one script
  python scripts/ml_report.py EMMA --errors         # worst confusions, with text
  python scripts/ml_report.py EMMA --low-confidence # what the review flag would catch
  python scripts/ml_report.py --csv reports/        # dump full per-block tables
  python scripts/ml_report.py --paren-audit         # cross-script label consistency
"""
from __future__ import annotations

import csv
import json
import sys
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).parent.parent
sys.path.insert(0, str(ROOT / "backend"))
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "ml"))

import features as F  # noqa: E402
from element_classifier import ScriptElementClassifier  # noqa: E402
from scorecard import CASES, REF_DIR, PDF_DIR, _sig, _build_lookup  # noqa: E402
from build_dataset import build_short_sig_lookup, label_block  # noqa: E402


def analyse(name: str, pdf_name: str, model_clf) -> list[dict] | None:
    pdf_path = PDF_DIR / pdf_name
    ind_path = REF_DIR / f"{name}_independent.json"
    if not pdf_path.exists() or not ind_path.exists():
        return None

    with open(ind_path, encoding="utf-8") as f:
        ind = json.load(f)
    elements = ind.get("elements", [])
    _, kind_lookup, sigs = _build_lookup(elements)
    short_lookup = build_short_sig_lookup(elements)

    doc = F.features_for_pdf(str(pdf_path))
    rows = []
    for block, feat in zip(doc.blocks, doc.features):
        truth, provenance = label_block(
            block, feat, doc.model, kind_lookup, sigs, short_lookup)
        pred, conf = (model_clf.predict_features(feat) if model_clf else (None, 0.0))
        rows.append({
            "script": name,
            "text": (block.text or "").strip()[:120],
            "sig": _sig(block.text),
            "truth": truth or "",
            "provenance": provenance,
            "pred": pred or "",
            "confidence": round(conf, 4),
            "correct": (truth is not None and pred == truth),
            "scoreable": truth is not None,
            **feat.to_dict(),
        })
    return rows


def summarise(rows: list[dict]) -> None:
    scoreable = [r for r in rows if r["scoreable"]]
    if not scoreable:
        print("  (no labelled blocks)")
        return
    acc = sum(r["correct"] for r in scoreable) / len(scoreable)
    print(f"  blocks={len(rows):,}  labelled={len(scoreable):,}  accuracy={acc*100:.1f}%")


def show_errors(rows: list[dict], limit: int = 12) -> None:
    errs = [r for r in rows if r["scoreable"] and not r["correct"]]
    if not errs:
        print("  no errors on labelled blocks")
        return
    pairs = Counter((r["truth"], r["pred"]) for r in errs)
    print(f"\n  {len(errs):,} errors. Most common confusions:")
    for (t, p), n in pairs.most_common(6):
        print(f"    {t:>16} → {p:<16} {n:>5,}")
    print(f"\n  Lowest-confidence errors (the review flag would catch these):")
    for r in sorted(errs, key=lambda r: r["confidence"])[:limit]:
        print(f"    [{r['confidence']:.2f}] {r['truth']:>15} → {r['pred']:<15} "
              f"{r['text'][:62]!r}")
    print(f"\n  HIGH-confidence errors (dangerous — flag will NOT catch these):")
    high = [r for r in errs if r["confidence"] >= 0.9]
    for r in sorted(high, key=lambda r: -r["confidence"])[:limit]:
        print(f"    [{r['confidence']:.2f}] {r['truth']:>15} → {r['pred']:<15} "
              f"{r['text'][:62]!r}")
    if not high:
        print("    (none — every error is low-confidence, which is the ideal case)")


def show_low_confidence(rows: list[dict], threshold: float) -> None:
    flagged = [r for r in rows if r["confidence"] < threshold and r["pred"]]
    scoreable = [r for r in flagged if r["scoreable"]]
    print(f"\n  threshold {threshold:.2f}: {len(flagged):,}/{len(rows):,} blocks flagged "
          f"({len(flagged)/len(rows)*100:.1f}%)")
    if scoreable:
        wrong = sum(1 for r in scoreable if not r["correct"])
        print(f"  of {len(scoreable):,} flagged-and-labelled, {wrong:,} are actually "
              f"wrong ({wrong/len(scoreable)*100:.0f}% precision)")
    for r in sorted(flagged, key=lambda r: r["confidence"])[:15]:
        mark = "" if not r["scoreable"] else ("  ✓" if r["correct"] else "  ✗")
        print(f"    [{r['confidence']:.2f}] {r['pred']:<15} {r['text'][:60]!r}{mark}")


def paren_audit() -> None:
    """Is 'parenthetical' defined consistently across the corpus references?

    Checks the hypothesis that some scripts have no parenthetical category at all
    and file bracketed asides under stage_direction instead — which would make
    leave-one-script-out penalise the model for a corpus inconsistency rather than
    a modelling error.
    """
    print(f"{'='*76}\nPARENTHETICAL LABEL CONSISTENCY ACROSS REFERENCES\n{'='*76}")
    print(f"{'script':<22}{'paren':>8}{'stage_dir':>11}{'SD w/ ()':>10}{'verdict':>24}")
    for name, _ in CASES:
        p = REF_DIR / f"{name}_independent.json"
        if not p.exists():
            continue
        els = json.loads(p.read_text(encoding="utf-8")).get("elements", [])
        paren = sum(1 for e in els if e.get("kind") == "parenthetical")
        sd = [e for e in els if e.get("kind") == "stage_direction"]
        # A sig beginning with "(" means the line's first token started with one.
        sd_paren = sum(1 for e in sd if e.get("sig", "").startswith("("))
        if paren == 0 and sd_paren > 0:
            verdict = "NO paren category"
        elif paren == 0:
            verdict = "no parens at all"
        elif sd_paren > paren * 0.5:
            verdict = "mixed/inconsistent"
        else:
            verdict = "consistent"
        print(f"{name:<22}{paren:>8,}{len(sd):>11,}{sd_paren:>10,}{verdict:>24}")
    print("\n  'SD w/ ()' = elements labelled stage_direction whose text starts with '('.")
    print("  Where that is large and 'paren' is 0, the reference simply does not")
    print("  distinguish the two — the model cannot learn a distinction the corpus")
    print("  does not make, and LOSO will score it wrong for guessing either way.")


def main() -> int:
    args = sys.argv[1:]
    want_errors = "--errors" in args
    want_low = "--low-confidence" in args
    if "--paren-audit" in args:
        paren_audit()
        return 0

    csv_dir = None
    if "--csv" in args:
        i = args.index("--csv")
        csv_dir = ROOT / (args[i + 1] if i + 1 < len(args) else "reports")
        args = args[:i] + args[i + 2:]

    names = [a for a in args if not a.startswith("--")]
    cases = [(n, p) for n, p in CASES if not names or n in names]

    clf = ScriptElementClassifier.load_default(expected_schema=F.FEATURE_SCHEMA_VERSION)
    if clf is None:
        print("No usable model — run `python ml/train_element_classifier.py` first.\n"
              "(Continuing with ground-truth-only output.)")
    else:
        print(f"{clf}\n")

    threshold = (clf.confidence_threshold if clf and clf.confidence_threshold else 0.6)
    all_rows: list[dict] = []

    for name, pdf_name in cases:
        print(f"── {name} " + "─" * (60 - len(name)))
        rows = analyse(name, pdf_name, clf)
        if rows is None:
            print("  SKIP: PDF or reference missing")
            continue
        all_rows.extend(rows)
        summarise(rows)
        if want_errors:
            show_errors(rows)
        if want_low:
            show_low_confidence(rows, threshold)
        if csv_dir:
            csv_dir.mkdir(parents=True, exist_ok=True)
            out = csv_dir / f"{name}_blocks.csv"
            with open(out, "w", newline="", encoding="utf-8") as f:
                w = csv.DictWriter(f, fieldnames=list(rows[0]))
                w.writeheader(); w.writerows(rows)
            print(f"  → {out.relative_to(ROOT)}")

    if len(cases) > 1 and all_rows:
        sc = [r for r in all_rows if r["scoreable"]]
        print(f"\n{'='*76}\nCORPUS TOTAL: {len(all_rows):,} blocks, {len(sc):,} labelled, "
              f"accuracy {sum(r['correct'] for r in sc)/len(sc)*100:.1f}%")
        by_script = defaultdict(list)
        for r in sc:
            by_script[r["script"]].append(r["correct"])
        for s, v in sorted(by_script.items(), key=lambda kv: sum(kv[1]) / len(kv[1])):
            print(f"  {s:<22}{sum(v)/len(v)*100:>6.1f}%  ({len(v):,} labelled)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
