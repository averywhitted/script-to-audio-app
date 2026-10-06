#!/usr/bin/env python3
"""synth_score.py — score the parser against generated scripts with exact answers.

Runs `parse_pdf` on every script made by `synth_generate.py` and checks each unit
(a speech, a direction, a character name, a page number...) against what was
actually typeset. The question asked of every unit is the one a listener hears:
**was it read by the right voice?**

  dialogue          -> read by its character
  stage direction   -> read by the narrator      (parentheticals too; bare
                                                  "Beat." / "(pause)" not at all)
  everything else   -> not read at all           (names, headings, page junk,
                                                  title page, cast list)

Matching is exact, not guessed. The parser never invents text, so every word it
outputs comes from somewhere in the typeset stream. Each output element is
placed, in order, as the tightest run of typeset words that spells it (see
`align`), so a repeated word — a line ending "...Nadia?" right before the name
NADIA — is credited to the unit it actually belongs to. Each typeset word is
then either found, with the voice and kind the parser gave it, or missing. A
unit counts as read by voice V when most of its words were found and most of
those were given voice V. Every unit is scored, short lines included: there is
no minimum length and no lookup by fingerprint.

The scorer is itself tested (backend/tests/test_synth_score.py): a perfect parse
of every generated script must score exactly 100%.

Usage:
  python scripts/synth_score.py                  # table for every generated script
  python scripts/synth_score.py --errors 15      # plus 15 example mistakes per script
  python scripts/synth_score.py inline_name_times centered_parens
"""
from __future__ import annotations

import argparse
import json
import logging
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SYNTH_DIR = ROOT / "Test PDFs" / "synthetic"
sys.path.insert(0, str(ROOT / "backend"))

NARRATOR = "NARRATOR"
SILENT = "(not read)"
SILENT_KINDS = {"character_cue", "scene_heading", "transition", "page_furniture", "front_matter"}

# Bare timing beats are never read aloud (decided by the user, Oct 2026): "Beat.",
# "PAUSE", "A long pause.", "(beat)". Directions that say more than that, like
# "(beat; softer)" or "Silence falls.", are still read by the narrator.
_TIMING_BEAT = re.compile(r"^\(?\s*(?:a\s+)?(?:long\s+|short\s+|brief\s+|tiny\s+)?(?:beat|pause)s?\s*[.!]?\s*\)?$",
                          re.IGNORECASE)


def is_timing_beat(text: str) -> bool:
    return bool(_TIMING_BEAT.match(text.strip()))
_WORD = re.compile(r"[a-z0-9']+")


def words(text: str) -> list[str]:
    text = text.lower().replace("’", "'").replace("‘", "'")
    return _WORD.findall(text)


def norm_speaker(name: str | None) -> str:
    name = re.sub(r"\(.*?\)", "", name or "").strip().rstrip(":.").upper()
    return re.sub(r"\s+", " ", name)


def expected_voice(unit: dict) -> str:
    if unit["kind"] == "dialog":
        return norm_speaker(unit["speaker"])
    if unit["kind"] in ("stage_direction", "parenthetical"):
        return SILENT if is_timing_beat(unit["text"]) else NARRATOR
    return SILENT


def output_elements(script) -> list[tuple[list[str], str, str]]:
    """(words, voice, kind) for every element the parser will read aloud."""
    out = []
    for scene in script.scenes:
        for el in scene.elements:
            if el.kind == "dialog":
                voice = (" & ".join(norm_speaker(s) for s in el.overlap_cue)
                         if el.overlap_cue else norm_speaker(el.speaker) or NARRATOR)
            else:
                voice = NARRATOR
            ws = words(el.text)
            if ws:
                out.append((ws, voice, el.kind))
    return out


WINDOW = 600   # how far ahead of the last placed element to look for the next one
MAX_GAP = 12   # most typeset words an element may skip between two of its own words
               # (dropped page numbers, a (MORE), a name merged out of the text)


def _fit(t_words: list[str], used: list[bool], start: int, ws: list[str]) -> tuple[int, int, list[int]]:
    """Greedily spell `ws` in the typeset stream from `start`.

    Returns (words placed, typeset words skipped, positions). An output word
    that can't be found within MAX_GAP of the previous one is left unplaced
    rather than allowed to jump ahead and drag the rest of the element with it.
    """
    pos, placed, skipped, at = start - 1, 0, 0, []
    for k, w in enumerate(ws):
        lo = start if k == 0 else pos + 1
        hi = min(len(t_words), lo + (1 if k == 0 else MAX_GAP + 1))
        for j in range(lo, hi):
            if not used[j] and t_words[j] == w:
                if k:
                    skipped += j - pos - 1
                pos, placed = j, placed + 1
                at.append(j)
                break
    return placed, skipped, at


def align(t_words: list[str], elements: list[tuple[list[str], str, str]]) -> dict[int, tuple[str, str]]:
    """Map typeset word index -> (voice, kind) for every word the parser read.

    Elements are placed in output order. For each, every occurrence of its first
    word within WINDOW of the last placement is tried as a start, and the
    placement that spells the most of the element with the fewest skipped
    typeset words wins (earliest on ties). Contiguity is what resolves repeated
    words correctly. An element that fits nowhere in the window (text the parser
    read out of order) is placed anywhere in the stream by the same rule.
    """
    used = [False] * len(t_words)
    found: dict[int, tuple[str, str]] = {}
    cursor = 0
    for ws, voice, kind in elements:
        best = None
        for scope in (range(cursor, min(len(t_words), cursor + WINDOW)), range(len(t_words))):
            for st in scope:
                if used[st] or t_words[st] != ws[0]:
                    continue
                placed, skipped, at = _fit(t_words, used, st, ws)
                key = (placed, -skipped)
                if best is None or key > best[0]:
                    best = (key, at)
                    if placed == len(ws) and skipped == 0:
                        break
            if best and best[0][0] * 2 >= len(ws):
                break
        if not best:
            continue
        for j in best[1]:
            used[j] = True
            found[j] = (voice, kind)
        if best[1]:
            cursor = max(cursor, best[1][-1] + 1) if best[1][0] >= cursor else cursor
    return found


def score_units(truth: dict, script) -> list[dict]:
    """One row per typeset unit: what voice it should get and what it got."""
    units = truth["units"]
    t_words, t_unit = [], []
    for unit_id, text in truth["stream"]:
        for w in words(text):
            t_words.append(w)
            t_unit.append(unit_id)
    found = align(t_words, output_elements(script))

    per_unit_words: dict[int, list[int]] = defaultdict(list)
    for i, u in enumerate(t_unit):
        per_unit_words[u].append(i)

    results = []
    for unit in units:
        idx = per_unit_words.get(unit["id"], [])
        if not idx:
            continue
        hits = [found[i] for i in idx if i in found]
        if len(hits) * 2 < len(idx):
            got_voice, got_kind = SILENT, None
        else:
            got_voice = Counter(v for v, _ in hits).most_common(1)[0][0]
            got_kind = Counter(k for _, k in hits).most_common(1)[0][0]
        exp = expected_voice(unit)
        results.append({"unit": unit, "expected": exp, "got": got_voice, "got_kind": got_kind,
                        "ok": got_voice == exp})
    return results


def score_one(name: str) -> dict:
    from parser import parse_pdf

    truth = json.loads((SYNTH_DIR / f"{name}.truth.json").read_text())
    script = parse_pdf(str(SYNTH_DIR / f"{name}.pdf"))
    results = score_units(truth, script)

    def rate(rows):
        return (sum(r["ok"] for r in rows) / len(rows)) if rows else None

    dialog = [r for r in results if r["unit"]["kind"] == "dialog"]
    narration = [r for r in results if r["unit"]["kind"] in ("stage_direction", "parenthetical")]
    silent = [r for r in results if r["unit"]["kind"] in SILENT_KINDS]
    voiced_read = [r for r in dialog + narration if r["got_kind"]]
    kind_ok = (sum(r["got_kind"] == r["unit"]["kind"] for r in voiced_read) / len(voiced_read)
               if voiced_read else None)

    errors = Counter()
    for r in results:
        if r["ok"]:
            continue
        k, got = r["unit"]["kind"], r["got"]
        if k == "dialog":
            label = ("dialogue not read" if got == SILENT else
                     "dialogue read by narrator" if got == NARRATOR else "dialogue, wrong character")
        elif k in ("stage_direction", "parenthetical"):
            label = ("beat or pause read aloud" if r["expected"] == SILENT else
                     "direction not read" if got == SILENT else "direction read by a character")
        else:
            label = f"{k.replace('_', ' ')} read aloud"
        errors[label] += 1

    return {
        "name": name, "family": truth["_meta"]["family"], "units": len(results),
        "right_voice": rate(results), "dialog": rate(dialog), "narration": rate(narration),
        "silent": rate(silent), "kind": kind_ok,
        "scenes": len(script.scenes), "true_scenes": len(truth["scenes"]),
        "errors": errors, "rows": results,
    }


def pct(x) -> str:
    return "  -  " if x is None else f"{x * 100:5.1f}"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("names", nargs="*")
    ap.add_argument("--errors", type=int, default=0, help="show N example mistakes per script")
    args = ap.parse_args()
    logging.disable(logging.CRITICAL)

    names = args.names or sorted(p.name[:-len(".truth.json")] for p in SYNTH_DIR.glob("*.truth.json"))
    if not names:
        print("No generated scripts. Run: python scripts/synth_generate.py")
        return 1

    print(f"{'script':24} {'right voice':>11} {'dialogue':>9} {'narration':>9} {'silent':>7} "
          f"{'kind':>6} {'scenes':>7}  biggest problem")
    print("-" * 110)
    all_rows, results = [], []
    for name in names:
        r = score_one(name)
        results.append(r)
        all_rows.extend(r["rows"])
        top = r["errors"].most_common(1)
        problem = f"{top[0][0]} ({top[0][1]})" if top else ""
        print(f"{name:24} {pct(r['right_voice']):>11} {pct(r['dialog']):>9} {pct(r['narration']):>9} "
              f"{pct(r['silent']):>7} {pct(r['kind']):>6} {r['scenes']:>3}/{r['true_scenes']:<3}  {problem}")
        if args.errors:
            for row in [x for x in r["rows"] if not x["ok"]][:args.errors]:
                u = row["unit"]
                print(f"      {u['kind']:15} expected {row['expected']:12} got {row['got']:12} | {u['text'][:60]}")
    print("-" * 110)
    ok = sum(r["ok"] for r in all_rows)
    print(f"{'ALL':24} {pct(ok / len(all_rows)):>11}   ({ok} of {len(all_rows)} units read by the right voice)")
    total = Counter()
    for r in results:
        total.update(r["errors"])
    if total:
        print("\nMistakes by type:")
        for label, n in total.most_common():
            print(f"  {n:6}  {label}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
