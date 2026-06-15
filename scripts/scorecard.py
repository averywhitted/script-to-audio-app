#!/usr/bin/env python3
"""scorecard.py — the parser correctness oracle.

Runs ``parse_pdf()`` on each corpus PDF and scores its output against the locked
independent ground-truth references (``Test PDFs/reference/{Name}_independent.json``),
which are produced with NO dependency on ``parser.py``.

Unlike ``backend/tests/test_reference.py`` — which compares the parser against
*parser-generated* baselines and can therefore only detect *change* — this script
measures *correctness*: how much of each script the parser actually gets right. It
is the instrument that tells whether a parser change is a net improvement or a
regression, across the whole corpus at once.

Metrics per script (all higher-is-better except noSpk):
  attrib%   of dialog elements matchable in ground truth, % attributed to the
            correct speaker. THIS is the headline number.
  kind%     of elements matchable by text signature, % whose kind matches.
  noSpk     count of dialog elements with no speaker (a bug signal — lower better).
  scenes    parser scene count.
  cover%    fraction of parser dialog elements checkable against ground truth.
  overlaps  count of overlap_cue elements emitted.

The text "signature" (sig) is the first character of each whitespace-separated
token, preserving case — the same compact fingerprint used by the reference tests.
Matching tolerates the parser merging consecutive lines into one element via prefix
matching (a parser sig that starts with a ground-truth sig is a match).

Usage:
  python scripts/scorecard.py                # table for all scripts
  python scripts/scorecard.py TheHarvest      # one script
  python scripts/scorecard.py --save          # write current metrics as the watermark
  python scripts/scorecard.py --check         # compare to watermark; exit 1 on regression
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).parent.parent
REF_DIR = ROOT / "Test PDFs" / "reference"
PDF_DIR = ROOT / "Test PDFs"
WATERMARK_PATH = REF_DIR / ".watermark.json"

sys.path.insert(0, str(ROOT / "backend"))
from parser import parse_pdf  # noqa: E402

# Every script that has (or should have) an independent ground-truth reference.
CASES = [
    ("TheHarvest",         "TheHarvest(3.0).pdf"),
    ("KillFloor",          "Kill Floor (LCT Reading Draft).pdf"),
    ("NoneOfUs",           "5.0 None of Us Are Getting Out of This Alive (2).pdf"),
    ("MercuryFur",         "Mercury Fur-13 f Draft-June 10-2013.pdf"),
    ("AgainstTheHillside", "Against the Hillside 11.20.17.pdf"),
    ("EMMA",               "EMMA Script (2).pdf"),
    ("Stereophonic",       "4.10.24_Stereophonic (2).pdf"),
]

_MIN_SIG_LEN = 4  # shorter sigs are too ambiguous to attribute reliably
# A script regresses if attribution drops by more than this, or noSpk rises.
_ATTRIB_TOLERANCE = 0.005


def _sig(text: str) -> str:
    """First character of each whitespace-separated token, preserving case."""
    return "".join(w[0] for w in (text or "").split() if w)


def _build_lookup(ind_elements: list[dict]) -> tuple[dict, dict, list]:
    """Build (speaker_lookup, kind_lookup, sigs_by_len_desc) from ground truth.

    speaker_lookup: sig -> set of valid speakers (dialog elements only)
    kind_lookup:    sig -> set of valid kinds (all elements)
    sigs_by_len_desc: all sigs (>= _MIN_SIG_LEN) sorted longest-first for prefix match
    """
    speaker_lookup: dict[str, set] = {}
    kind_lookup: dict[str, set] = {}
    for el in ind_elements:
        s = el.get("sig", "")
        if len(s) < _MIN_SIG_LEN:
            continue
        kind_lookup.setdefault(s, set()).add(el.get("kind"))
        if el.get("kind") == "dialog":
            speaker_lookup.setdefault(s, set()).add(el.get("speaker"))
    all_sigs = sorted(kind_lookup.keys(), key=len, reverse=True)
    return speaker_lookup, kind_lookup, all_sigs


def _lookup(sig: str, table: dict, sigs_by_len_desc: list) -> set | None:
    """Exact match, else longest ground-truth sig that is a prefix of ``sig``."""
    if sig in table:
        return table[sig]
    for ind_sig in sigs_by_len_desc:
        if sig.startswith(ind_sig) and ind_sig in table:
            return table[ind_sig]
    return None


def score_one(name: str, pdf_name: str) -> dict | None:
    """Return a metrics dict for one script, or None if PDF/reference is missing."""
    pdf_path = PDF_DIR / pdf_name
    ind_path = REF_DIR / f"{name}_independent.json"
    if not pdf_path.exists() or not ind_path.exists():
        return None

    with open(ind_path, encoding="utf-8") as f:
        ind_ref = json.load(f)
    spk_lookup, kind_lookup, sigs = _build_lookup(ind_ref.get("elements", []))

    script = parse_pdf(str(pdf_path))
    els = [el for scene in script.scenes for el in scene.elements]

    dialog = [el for el in els if el.kind == "dialog"]
    no_speaker = sum(1 for el in dialog if not el.speaker)
    overlaps = sum(1 for el in els if el.overlap_cue)

    attrib_checked = attrib_ok = 0
    kind_checked = kind_ok = 0
    for el in els:
        s = _sig(el.text)
        if len(s) < _MIN_SIG_LEN:
            continue
        valid_kinds = _lookup(s, kind_lookup, sigs)
        if valid_kinds is not None:
            kind_checked += 1
            kind_ok += el.kind in valid_kinds
        if el.kind == "dialog":
            valid_spk = _lookup(s, spk_lookup, sigs)
            if valid_spk is not None:
                attrib_checked += 1
                attrib_ok += el.speaker in valid_spk

    return {
        "attrib": attrib_ok / attrib_checked if attrib_checked else 0.0,
        "kind": kind_ok / kind_checked if kind_checked else 0.0,
        "noSpk": no_speaker,
        "scenes": len(script.scenes),
        "cover": attrib_checked / len(dialog) if dialog else 0.0,
        "overlaps": overlaps,
        "dialog": len(dialog),
        "locked": bool(ind_ref.get("_meta", {}).get("locked")),
        # Some references (two-column scripts with no SD font signal) have
        # reliable attribution but provisional kind labels — guard attrib only.
        "provisional_kind": bool(ind_ref.get("_meta", {}).get("provisional_kind")),
    }


def collect() -> dict[str, dict]:
    results: dict[str, dict] = {}
    for name, pdf_name in CASES:
        m = score_one(name, pdf_name)
        if m is not None:
            results[name] = m
    return results


def print_table(results: dict[str, dict]) -> None:
    hdr = (f"{'script':<20} {'attrib':>7} {'kind':>6} {'noSpk':>6} "
           f"{'scenes':>7} {'cover':>6} {'ovlp':>5} {'lock':>5}")
    print(hdr)
    print("-" * len(hdr))
    attribs = []
    for name, _ in CASES:
        if name not in results:
            print(f"{name:<20} {'(no reference / PDF)':>40}")
            continue
        m = results[name]
        attribs.append(m["attrib"])
        print(f"{name:<20} {m['attrib']*100:>6.1f}% {m['kind']*100:>5.0f}% "
              f"{m['noSpk']:>6} {m['scenes']:>7} {m['cover']*100:>5.0f}% "
              f"{m['overlaps']:>5} {'yes' if m['locked'] else 'no':>5}")
    print("-" * len(hdr))
    if attribs:
        print(f"{'AGGREGATE attrib':<20} {sum(attribs)/len(attribs)*100:>6.1f}%  "
              f"({len(attribs)} scripts scored)")


def save_watermark(results: dict[str, dict]) -> None:
    payload = {name: {k: m[k] for k in ("attrib", "kind", "noSpk", "scenes", "overlaps")}
               for name, m in results.items()}
    with open(WATERMARK_PATH, "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2)
    print(f"\nWatermark saved → {WATERMARK_PATH.name} ({len(payload)} scripts)")


def check_watermark(results: dict[str, dict]) -> int:
    if not WATERMARK_PATH.exists():
        print("\nNo watermark yet. Run `python scripts/scorecard.py --save` first.")
        return 0
    with open(WATERMARK_PATH, encoding="utf-8") as f:
        base = json.load(f)

    regressions: list[str] = []
    for name, m in results.items():
        b = base.get(name)
        if b is None:
            continue
        if m["attrib"] < b["attrib"] - _ATTRIB_TOLERANCE:
            regressions.append(
                f"  {name}: attrib {b['attrib']*100:.1f}% → {m['attrib']*100:.1f}%")
        if not m["provisional_kind"] and m["kind"] < b["kind"] - _ATTRIB_TOLERANCE:
            regressions.append(
                f"  {name}: kind {b['kind']*100:.1f}% → {m['kind']*100:.1f}%")
        if m["noSpk"] > b["noSpk"]:
            regressions.append(
                f"  {name}: noSpk {b['noSpk']} → {m['noSpk']} (more unattributed dialog)")

    if regressions:
        print("\n✗ REGRESSION vs watermark:")
        print("\n".join(regressions))
        return 1
    print("\n✓ No regression vs watermark.")
    return 0


def main() -> int:
    args = sys.argv[1:]
    do_save = "--save" in args
    do_check = "--check" in args
    names = [a for a in args if not a.startswith("--")]

    global CASES
    if names:
        CASES = [(n, p) for n, p in CASES if n in names]

    results = collect()
    print_table(results)

    if do_save:
        save_watermark(results)
    if do_check:
        return check_watermark(results)
    return 0


if __name__ == "__main__":
    sys.exit(main())
