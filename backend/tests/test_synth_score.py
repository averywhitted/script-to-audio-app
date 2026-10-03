"""Tests for the generated-script scorer (scripts/synth_score.py).

The scorer is the answer key the parser is judged by, so it has to be right
first. These tests hand it parses whose mistakes are known exactly and check it
reports those mistakes and nothing else:

  - a perfect parse of every layout family scores 100%
  - merging a speech's lines, or dropping page junk, changes nothing
  - each deliberately planted mistake is reported, on exactly the planted unit
"""
from __future__ import annotations

import copy
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

fitz = pytest.importorskip("fitz")
import synth_generate as G  # noqa: E402
import synth_score as S  # noqa: E402
from parser import Element, Scene, Script  # noqa: E402


@pytest.fixture(scope="module")
def truths(tmp_path_factory):
    """One generated script per layout family, truth only (no parsing needed)."""
    out = tmp_path_factory.mktemp("synth")
    G.OUT_DIR = out
    seen, result = set(), {}
    for name, style in G.standard_styles():
        if style.family in seen:
            continue
        seen.add(style.family)
        G.write(name, style, seed=1)
        import json
        result[name] = json.loads((out / f"{name}.truth.json").read_text())
    return result


def perfect_parse(truth: dict) -> Script:
    """What a flawless parser would output: every read-aloud unit, in order."""
    els = []
    for u in truth["units"]:
        if u["kind"] == "dialog":
            els.append(Element(kind="dialog", text=u["text"], speaker=u["speaker"]))
        elif u["kind"] in ("stage_direction", "parenthetical"):
            els.append(Element(kind=u["kind"], text=u["text"]))
    return Script(title=truth["title"], scenes=[Scene(number=1, title="All", elements=els)])


def mistakes(truth: dict, script: Script) -> list[tuple[int, str]]:
    return [(r["unit"]["id"], r["got"]) for r in S.score_units(truth, script) if not r["ok"]]


def test_perfect_parse_scores_100_percent_in_every_family(truths):
    for name, truth in truths.items():
        assert mistakes(truth, perfect_parse(truth)) == [], name


def test_merging_a_speakers_consecutive_lines_is_not_penalised(truths):
    truth = truths["screenplay_letter"]
    script = perfect_parse(truth)
    els, merged = script.scenes[0].elements, []
    for el in els:
        if merged and el.kind == merged[-1].kind == "dialog" and el.speaker == merged[-1].speaker:
            merged[-1] = Element(kind="dialog", text=f"{merged[-1].text} {el.text}", speaker=el.speaker)
        else:
            merged.append(el)
    script.scenes[0].elements = merged
    assert mistakes(truth, script) == []


def test_each_planted_mistake_is_reported_on_exactly_that_unit(truths):
    truth = truths["stage_centered" if "stage_centered" in truths else "centered_parens"]
    units = truth["units"]
    dialog = [u for u in units if u["kind"] == "dialog" and len(u["text"].split()) > 3]
    short = [u for u in units if u["kind"] == "dialog" and len(u["text"].split()) == 1]
    direction = [u for u in units if u["kind"] == "stage_direction"]
    wrong_speaker, dropped, misread, short_wrong = dialog[5], dialog[9], direction[3], short[2]

    script = perfect_parse(truth)
    out = []
    for el, u in zip(script.scenes[0].elements, [u for u in units if u["kind"] in
                                                   ("dialog", "stage_direction", "parenthetical")]):
        el = copy.copy(el)
        if u is wrong_speaker or u is short_wrong:
            el.speaker = "SOMEONE ELSE"
        elif u is dropped:
            continue
        elif u is misread:
            el = Element(kind="dialog", text=el.text, speaker="SOMEONE ELSE")
        out.append(el)
    script.scenes[0].elements = out

    got = dict(mistakes(truth, script))
    assert got == {wrong_speaker["id"]: "SOMEONE ELSE", short_wrong["id"]: "SOMEONE ELSE",
                   dropped["id"]: S.SILENT, misread["id"]: "SOMEONE ELSE"}


def test_a_name_read_aloud_is_reported(truths):
    # A parser that voices a name does so in place, just before the speech.
    truth = truths["screenplay_letter"]
    voiced = [u for u in truth["units"] if u["kind"] in ("dialog", "stage_direction", "parenthetical")]
    script = perfect_parse(truth)
    cue = [u for u in truth["units"] if u["kind"] == "character_cue"][20]
    nxt = next(i for i, u in enumerate(voiced) if u["id"] > cue["id"])
    script.scenes[0].elements.insert(nxt, Element(kind="stage_direction", text=cue["text"]))
    assert mistakes(truth, script) == [(cue["id"], S.NARRATOR)]


def test_a_line_ending_in_the_next_speakers_name_is_credited_correctly():
    # "...Nadia?" followed by the cue NADIA: the parse is right, and the scorer
    # must not credit the spoken "Nadia" to the silent cue.
    truth = {
        "title": "t",
        "units": [
            {"id": 0, "kind": "character_cue", "speaker": None, "text": "DR. CHEN"},
            {"id": 1, "kind": "dialog", "speaker": "DR. CHEN", "text": "He lost the keys? Nadia?"},
            {"id": 2, "kind": "character_cue", "speaker": None, "text": "NADIA"},
            {"id": 3, "kind": "dialog", "speaker": "NADIA", "text": "Nadia is my name."},
        ],
        "stream": [[0, "DR. CHEN"], [1, "He lost the keys? Nadia?"], [2, "NADIA"], [3, "Nadia is my name."]],
    }
    assert mistakes(truth, perfect_parse(truth)) == []
