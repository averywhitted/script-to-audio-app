#!/usr/bin/env python3
"""build_dataset.py — derive labelled training data from the existing ground truth.

No hand-labelling. The corpus already holds 21,807 reviewed ground-truth elements
in ``Test PDFs/reference/*_independent.json``; this script aligns extracted blocks
to them and emits (features → label) rows.

Alignment reuses ``scorecard.py``'s ``_sig`` / ``_build_lookup`` / ``_lookup``
VERBATIM. That is deliberate: if training used a different notion of "this block
matches that ground-truth element" than the oracle does, the model could look
excellent on this dataset and still score badly on the scorecard, and the
discrepancy would be almost impossible to debug.

LABEL PROVENANCE — read this before trusting an accuracy number.

  authoritative  dialog / stage_direction / parenthetical, from the hand-reviewed
                 independent references. Real ground truth.
  derived        character_cue and scene_heading, inferred from the parser's own
                 cast lexicon and heading regex, because the independent
                 references never label them (cues are consumed into the
                 `speaker` field; headings become scene titles).
  weak           noise, from page-furniture detection.

On `derived`/`weak` classes the labels ARE the current parser's opinion, so a model
trained on them can at best reproduce the parser there — never beat it. Genuine
headroom is confined to the three authoritative kinds plus generalisation to
formats outside this corpus. The coverage report prints the split so this stays
visible rather than being quietly assumed away.

Usage:
  python ml/build_dataset.py                 # all scripts → ml/data/dataset.csv
  python ml/build_dataset.py TheHarvest      # one script
  python ml/build_dataset.py --report-only   # coverage stats, write nothing
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

import features as F  # noqa: E402
from scorecard import CASES, REF_DIR, PDF_DIR, _sig, _build_lookup, _lookup, _MIN_SIG_LEN  # noqa: E402

OUT_DIR = ROOT / "ml" / "data"
OUT_CSV = OUT_DIR / "dataset.csv"

# Label vocabulary — matches parser.py's _BTYPES so the model's output can be
# dropped straight into the classification pipeline without translation.
LABELS = ("character_cue", "dialog", "stage_direction", "parenthetical",
          "scene_heading", "noise")

AUTHORITATIVE = {"dialog", "stage_direction", "parenthetical"}

# Provenance tags, strongest evidence first.
AUTHORITATIVE_SOURCES = ("authoritative", "authoritative_short",
                         "authoritative_normalized")
PROVENANCE_ORDER = AUTHORITATIVE_SOURCES + (
    "derived_cast", "derived_regex", "weak_furniture")


def build_short_sig_lookup(ind_elements: list[dict]) -> dict[str, set]:
    """Exact-match table for sigs BELOW ``_MIN_SIG_LEN``.

    The scorecard drops short sigs because they are unsafe for *prefix* matching —
    a 2-char sig prefixes half the document. But an *exact* match on a short sig
    that carries exactly one kind across the whole reference is still sound, and
    recovering those matters a lot here: the floor hides 35% of ground-truth
    dialog, 40% of stage directions and 64% of parentheticals. Training only above
    the floor would produce a model that has essentially never seen a short line —
    which is precisely where classification is hardest.

    This affects TRAINING DATA ONLY. The scorecard's own matching is untouched.

    Sigs with no alphabetic character are excluded. A sig like "1" or "4" is a
    page number's fingerprint, not a line's, and matching on it is how a GT defect
    propagates: MercuryFur's reference labels bare page numbers as
    ``stage_direction``, so sigs "1".."9" all map to that kind. Accepting them
    would have taught the model that a lone digit is a stage direction, from 166
    bogus examples in that script alone.
    """
    table: dict[str, set] = {}
    for el in ind_elements:
        s = el.get("sig", "")
        if s and len(s) < _MIN_SIG_LEN and any(c.isalpha() for c in s):
            table.setdefault(s, set()).add(el.get("kind"))
    return table


def reference_distinguishes_parenthetical(ind_elements: list[dict]) -> bool:
    """Does this reference use ``parenthetical`` as a category at all?

    Two of the seven references (MercuryFur, AgainstTheHillside) do not: their
    extractors file bracketed asides under ``stage_direction``. MercuryFur alone
    has 504 such elements. The other five do distinguish them, and the app renders
    ``parenthetical`` as its own "Aside" kind — so those two references are simply
    coarser, not following a different-but-valid convention.

    Left unhandled this poisons leave-one-script-out: a model trained on the five
    consistent scripts correctly predicts "parenthetical" for MercuryFur's
    bracketed lines and is scored WRONG 504 times, which is most of why the
    parenthetical F1 looked catastrophic (0.23) in the first evaluation.
    """
    return any(e.get("kind") == "parenthetical" for e in ind_elements)


def label_block(block, feat, model, gt_kind_lookup, gt_sigs, short_lookup=None,
                normalize_parenthetical: bool = False) -> tuple[str | None, str]:
    """Return (label, provenance) for one block, or (None, reason) if unlabelled.

    Precedence is deliberate. Cue detection runs FIRST because the independent
    references contain no cue elements at all — a cue's text was folded into the
    following dialog's `speaker` field — so a cue can only ever match ground truth
    by coincidence. (In practice cue sigs are 1-2 chars, e.g. "ADA" → "A", and are
    dropped by the _MIN_SIG_LEN floor anyway.)
    """
    from parser import _SCENE_HEADING_BLOCK_RE, _PAGE_MARKER_RE, _cue_candidate_name

    text = (block.text or "").strip()
    if not text:
        return None, "empty"

    def _resolve(kind: str, provenance: str) -> tuple[str, str]:
        """Map a coarse stage_direction onto parenthetical where the reference
        does not make that distinction but the text plainly does."""
        if (normalize_parenthetical and kind == "stage_direction"
                and block.starts_with_paren and block.ends_with_paren):
            return "parenthetical", "authoritative_normalized"
        return kind, provenance

    # 1. Speaker cue — derived from the document's own learned cast.
    name = _cue_candidate_name(block)
    if name and model.is_cast(name):
        return "character_cue", "derived_cast"

    # 2. Ground truth by full signature (>= 4 chars, prefix-tolerant). Strongest.
    s = _sig(text)
    if len(s) >= _MIN_SIG_LEN:
        kinds = _lookup(s, gt_kind_lookup, gt_sigs)
        if kinds is not None:
            if len(kinds) == 1:
                return _resolve(next(iter(kinds)), "authoritative")
            # Same signature carries two different kinds in the reference; the
            # label is genuinely ambiguous, so drop rather than guess.
            return None, "ambiguous_gt"

    # 3. Page furniture / page markers. Deliberately ahead of the short-signature
    # lookup: a repeated y-pinned header or a bare page number is identified
    # structurally with high confidence, whereas a 1-3 char signature is weak
    # evidence that can (and does) false-match against reference defects.
    if model.is_furniture(block) or _PAGE_MARKER_RE.match(text):
        return "noise", "weak_furniture"

    # 4. Scene heading — derived from the parser's heading regex.
    if _SCENE_HEADING_BLOCK_RE.match(text):
        return "scene_heading", "derived_regex"

    # 5. Ground truth by short signature — exact match, unambiguous only.
    if short_lookup and len(s) < _MIN_SIG_LEN:
        kinds = short_lookup.get(s)
        if kinds is not None:
            if len(kinds) == 1:
                return _resolve(next(iter(kinds)), "authoritative_short")
            return None, "ambiguous_gt_short"

    return None, "no_gt_match"


def build_one(name: str, pdf_name: str) -> tuple[list[dict], Counter, Counter]:
    pdf_path = PDF_DIR / pdf_name
    ind_path = REF_DIR / f"{name}_independent.json"
    if not pdf_path.exists() or not ind_path.exists():
        print(f"  SKIP {name}: PDF or reference missing")
        return [], Counter(), Counter()

    with open(ind_path, encoding="utf-8") as f:
        ind_ref = json.load(f)
    elements = ind_ref.get("elements", [])
    _, gt_kind_lookup, gt_sigs = _build_lookup(elements)
    short_lookup = build_short_sig_lookup(elements)
    normalize = not reference_distinguishes_parenthetical(elements)
    if normalize:
        print(f"      {name}: reference has no parenthetical category — "
              f"normalising bracketed stage directions")

    doc = F.features_for_pdf(str(pdf_path))

    rows: list[dict] = []
    prov = Counter()
    labels = Counter()

    for block, feat in zip(doc.blocks, doc.features):
        label, provenance = label_block(
            block, feat, doc.model, gt_kind_lookup, gt_sigs, short_lookup,
            normalize_parenthetical=normalize)
        prov[provenance] += 1
        if label is None:
            continue
        labels[label] += 1
        row = feat.to_dict()
        row["label"] = label
        row["label_source"] = provenance
        row["script"] = name
        row["sig"] = _sig(block.text)
        rows.append(row)

    total = len(doc.blocks)
    labelled = len(rows)
    print(f"  OK  {name}: {labelled}/{total} blocks labelled ({labelled/total*100:.0f}%)")
    return rows, prov, labels


def main() -> int:
    args = sys.argv[1:]
    report_only = "--report-only" in args
    names = [a for a in args if not a.startswith("--")]
    cases = [(n, p) for n, p in CASES if not names or n in names]

    all_rows: list[dict] = []
    prov_total = Counter()
    label_total = Counter()
    per_script_labels: dict[str, Counter] = {}

    for name, pdf_name in cases:
        rows, prov, labels = build_one(name, pdf_name)
        all_rows.extend(rows)
        prov_total.update(prov)
        label_total.update(labels)
        if labels:
            per_script_labels[name] = labels

    if not all_rows:
        print("\nNo rows produced — are the corpus PDFs present?")
        return 1

    # ---- coverage report ----
    total_blocks = sum(prov_total.values())
    print(f"\n{'='*66}\nDATASET COVERAGE\n{'='*66}")
    print(f"Blocks seen:      {total_blocks:,}")
    print(f"Blocks labelled:  {len(all_rows):,} ({len(all_rows)/total_blocks*100:.1f}%)")

    print("\nWhy blocks were dropped:")
    for reason, n in prov_total.most_common():
        if reason in PROVENANCE_ORDER:
            continue
        print(f"  {reason:<20} {n:>7,}")

    print("\nLabel counts by provenance:")
    by_prov = defaultdict(Counter)
    for r in all_rows:
        by_prov[r["label_source"]][r["label"]] += 1
    auth_n = sum(n for p, c in by_prov.items() if p in AUTHORITATIVE_SOURCES
                 for n in c.values())
    for prov_name in PROVENANCE_ORDER:
        c = by_prov.get(prov_name)
        if not c:
            continue
        tag = "GROUND TRUTH" if prov_name in AUTHORITATIVE_SOURCES else "parser-derived"
        print(f"  {prov_name} ({tag}):")
        for lbl, n in c.most_common():
            print(f"      {lbl:<18} {n:>7,}")
    print(f"\n  authoritative rows: {auth_n:,} / {len(all_rows):,} "
          f"({auth_n/len(all_rows)*100:.1f}%)")
    print("  → on parser-derived classes the model can match the parser, not beat it.")

    # Short vs long balance per class. The sig floor hides 35% of GT dialog and
    # 64% of GT parentheticals, so if a class is all-long here the model will
    # never have seen the short case — exactly where classification is hardest.
    print("\nShort-line coverage (word_count <= 3) by label:")
    short_by_label = Counter()
    for r in all_rows:
        if float(r["word_count"]) <= 3:
            short_by_label[r["label"]] += 1
    for lbl, n in label_total.most_common():
        s = short_by_label.get(lbl, 0)
        print(f"  {lbl:<18} {s:>7,} / {n:>7,}  ({s/n*100:>4.0f}% short)")

    print("\nClass balance (all sources):")
    for lbl, n in label_total.most_common():
        print(f"  {lbl:<18} {n:>7,}  ({n/len(all_rows)*100:.1f}%)")

    print("\nPer-script label counts (leave-one-script-out folds):")
    hdr = f"  {'script':<20}" + "".join(f"{l[:9]:>10}" for l in LABELS)
    print(hdr)
    for name, c in per_script_labels.items():
        print(f"  {name:<20}" + "".join(f"{c.get(l, 0):>10,}" for l in LABELS))

    if report_only:
        print("\n(--report-only: nothing written)")
        return 0

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    fieldnames = list(F.FEATURE_NAMES) + ["label", "label_source", "script", "sig"]
    with open(OUT_CSV, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        w.writerows(all_rows)
    print(f"\nWrote {len(all_rows):,} rows → {OUT_CSV.relative_to(ROOT)}")
    print(f"Feature schema v{F.FEATURE_SCHEMA_VERSION} ({len(F.FEATURE_NAMES)} features)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
