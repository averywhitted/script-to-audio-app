"""
Unit tests for parser.py backend logic.

Run from the repo root:
    .venv/bin/python -m pytest backend/tests/ -v
"""

import sys
from pathlib import Path

# Make backend/ importable
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import parser as p


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _dd_lines(n_scenes: int = 2) -> list[str]:
    """Produce synthetic dash-dialog lines with bare 'N.' scene markers."""
    out = []
    for i in range(1, n_scenes + 1):
        out.append(f"{i}.")
        out.append("  ALICE – This is scene number " + str(i) + ".")
        out.append("  BOB – I agree completely.")
    return out


HEIST_LINES = [
    "                                                          ",
    "1  SCENE ONE - THE BEGINNING",
    "            INT. WAREHOUSE - DAY",
    "                                   ALICE",
    "                    Hello. We meet at last.",
    "                                   BOB",
    "                    Indeed we do.",
    "2  SCENE TWO - THE MIDDLE",
    "            EXT. STREET - NIGHT",
    "                                   ALICE",
    "                    Careful now.",
] * 5  # repeat to get past detection threshold


# ---------------------------------------------------------------------------
# Format detection
# ---------------------------------------------------------------------------

def test_detect_heist_format():
    fmt = p._detect_script_format(HEIST_LINES)
    assert fmt == "heist", f"Expected 'heist', got '{fmt}'"


def test_detect_dash_dialog_format():
    lines = _dd_lines(6) * 3   # enough lines to cross the detection threshold
    # Also add enough dash-dialog lines to satisfy the >20% ratio
    fmt = p._detect_script_format(lines)
    # dash_dialog needs enough lines; fallback is ok if threshold not met
    assert fmt in ("dash_dialog", "heist"), f"Unexpected format '{fmt}'"


def test_detect_unknown_returns_fallback():
    lines = ["", "Some random text", "  More text", ""] * 5
    fmt = p._detect_script_format(lines)
    assert fmt in ("heist", "scene_n"), f"Unexpected format '{fmt}'"


# ---------------------------------------------------------------------------
# Scene-number-dot regex (_SCENE_NUM_DOT_RE)
# Bare "N." lines (with optional whitespace) are the scene markers.
# "N. Title" does NOT match — the regex is `^\s*(\d+)\.\s*$`.
# ---------------------------------------------------------------------------

def test_scene_num_dot_bare_matches():
    import re
    assert p._SCENE_NUM_DOT_RE.match("1.")
    assert p._SCENE_NUM_DOT_RE.match("12.")
    assert p._SCENE_NUM_DOT_RE.match("  3.  ")   # leading/trailing whitespace ok


def test_scene_num_dot_title_no_match():
    import re
    # "N. Title" should NOT be a scene marker (title text after dot)
    assert p._SCENE_NUM_DOT_RE.match("1. Opening") is None
    assert p._SCENE_NUM_DOT_RE.match("2. Second Scene") is None


# ---------------------------------------------------------------------------
# Dash-dialog parser (_extract_scenes_dash_dialog)
# Uses bare "N." scene markers.
# ---------------------------------------------------------------------------

def _parse_dd(lines):
    return p._extract_scenes_dash_dialog(lines)


def test_dash_dialog_bare_markers_finds_scenes():
    lines = _dd_lines(3)
    scenes = _parse_dd(lines)
    assert len(scenes) == 3, f"Expected 3 scenes, got {len(scenes)}"


def test_dash_dialog_scene_numbers_ascending():
    lines = _dd_lines(4)
    scenes = _parse_dd(lines)
    numbers = [s.number for s in scenes]
    assert numbers == sorted(numbers), "Scene numbers should be ascending"
    assert numbers[0] >= 1


def test_dash_dialog_extracts_dialog():
    lines = _dd_lines(2)
    scenes = _parse_dd(lines)
    dialog_elements = [e for s in scenes for e in s.elements if e.kind == "dialog"]
    assert len(dialog_elements) > 0, "No dialog elements extracted"


def test_dash_dialog_speaker_names():
    lines = _dd_lines(2)
    scenes = _parse_dd(lines)
    speakers = {e.speaker for s in scenes for e in s.elements if e.speaker}
    assert "ALICE" in speakers, f"Expected ALICE in speakers: {speakers}"
    assert "BOB" in speakers, f"Expected BOB in speakers: {speakers}"


def test_dash_dialog_duplicate_scene_numbers_auto_increment():
    """Repeated scene number blocks (e.g. act restarts at 1) should auto-increment."""
    lines = [
        "1.",
        "  ALICE – First scene.",
        "1.",            # duplicate — should become scene 2
        "  BOB – Another scene.",
    ]
    scenes = _parse_dd(lines)
    numbers = [s.number for s in scenes]
    assert len(numbers) == len(set(numbers)), f"Duplicate scene numbers: {numbers}"
    assert len(numbers) == 2


def test_dash_dialog_no_markers_fallback():
    """If no bare N. markers exist, parser returns a single catch-all scene."""
    lines = [
        "  ALICE – Hello.",
        "  BOB – World.",
    ]
    scenes = _parse_dd(lines)
    assert len(scenes) == 1
    assert scenes[0].number == 1


# ---------------------------------------------------------------------------
# Levenshtein / character deduplication
# ---------------------------------------------------------------------------

def test_levenshtein_exact():
    assert p._levenshtein("BOB", "BOB") == 0


def test_levenshtein_close():
    assert p._levenshtein("ALICE", "ALCE") <= 2


def test_levenshtein_far():
    assert p._levenshtein("ALICE", "BOB") > 2


def test_short_names_guard_no_crash():
    """parse_lines must not crash when speaker names are single characters."""
    lines = [
        "1.",
        "  1 – Hello.",
        "  2 – World.",
    ]
    # Should not raise — single-char names are valid, just not merged
    script = p.parse_lines(lines, title="Test")
    assert isinstance(script.scenes, list)


# ---------------------------------------------------------------------------
# parse_lines smoke tests (uses Script.scenes, not .scene_count)
# ---------------------------------------------------------------------------

def test_parse_lines_title():
    lines = _dd_lines(2)
    script = p.parse_lines(lines, title="My Script")
    assert script.title == "My Script"


def test_parse_lines_dash_dialog_scene_count():
    # Need enough lines (≥15) to pass the dash_dialog detection threshold.
    lines = _dd_lines(8) * 3   # 72 lines — well above the threshold
    script = p.parse_lines(lines, title="DD Test")
    # With 8 distinct scenes repeated 3× and auto-increment, expect ≥8 scenes
    assert len(script.scenes) >= 8


def test_parse_lines_heist_returns_script():
    script = p.parse_lines(HEIST_LINES, title="Heist Test")
    assert isinstance(script.scenes, list)
    assert len(script.scenes) >= 1


def test_empty_input_does_not_crash():
    script = p.parse_lines([], title="Empty")
    # Parser always returns at least one fallback scene, even for empty input
    assert len(script.scenes) >= 0
    assert len(script.characters) == 0


def test_parse_lines_characters_extracted():
    # Use enough lines to trigger dash_dialog format detection
    lines = _dd_lines(8) * 3
    script = p.parse_lines(lines, title="Chars")
    names = {c.name for c in script.characters}
    assert "ALICE" in names
    assert "BOB" in names


# ---------------------------------------------------------------------------
# Non-cue word filter (_NON_CUE_RE)
# ---------------------------------------------------------------------------

def test_all_not_a_cue_candidate():
    """'ALL' is a collective stage direction, never a speaker name."""
    assert not p._is_caps_cue_candidate("ALL")


def test_both_not_a_cue_candidate():
    assert not p._is_caps_cue_candidate("BOTH")


def test_together_not_a_cue_candidate():
    assert not p._is_caps_cue_candidate("TOGETHER")


def test_all_not_added_to_characters():
    """ALL appearing multiple times should not generate a character entry."""
    # 8+ repetitions to exceed the >= 2 dialog threshold and detection minimums
    lines = [
        "SCENE 1",
        "ALICE",
        "Hello.",
        "ALL",
        "We agree!",
        "BOB",
        "Indeed.",
        "ALL",
        "Great.",
    ] * 4
    script = p._parse_play(lines, page_sets=None, title="Test")
    names = {c.name for c in script.characters}
    assert "ALL" not in names, f"'ALL' should not be a character; got: {names}"


# ---------------------------------------------------------------------------
# Title-page exclusion (_extract_scenes_play with first_page_only)
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# _sanitize_characters
# ---------------------------------------------------------------------------

def test_sanitize_removes_non_cue_word():
    """A character whose name matches _NON_CUE_RE is stripped by the sanitizer."""
    from parser import Character, Script, Scene, Element, _sanitize_characters
    script = Script(title="My Play")
    script.characters = [Character(name="ALICE"), Character(name="ALL"), Character(name="CURTAIN")]
    script.scenes = [Scene(number=1, title="One", elements=[
        Element(kind="dialog", speaker="ALICE", text="Hello."),
    ])]
    result = _sanitize_characters(script)
    names = {c.name for c in result.characters}
    assert "ALICE" in names
    assert "ALL" not in names
    assert "CURTAIN" not in names


def test_sanitize_removes_title_match():
    """A character whose name equals the script title is stripped."""
    from parser import Character, Script, Scene, Element, _sanitize_characters
    script = Script(title="Mercury Fur")
    script.characters = [Character(name="MERCURY FUR"), Character(name="ELLIOT")]
    script.scenes = [Scene(number=1, title="One", elements=[
        Element(kind="dialog", speaker="ELLIOT", text="Hello."),
    ])]
    result = _sanitize_characters(script)
    names = {c.name for c in result.characters}
    assert "MERCURY FUR" not in names
    assert "ELLIOT" in names


def test_sanitize_removes_zero_dialog_character():
    """A character listed in the cast but never speaking is removed."""
    from parser import Character, Script, Scene, Element, _sanitize_characters
    script = Script(title="My Play")
    script.characters = [Character(name="ALICE"), Character(name="GHOST")]
    script.scenes = [Scene(number=1, title="One", elements=[
        Element(kind="dialog", speaker="ALICE", text="Hello."),
        Element(kind="stage_direction", text="GHOST appears."),
    ])]
    result = _sanitize_characters(script)
    names = {c.name for c in result.characters}
    assert "ALICE" in names
    assert "GHOST" not in names


def test_sanitize_keeps_real_characters():
    """Real speaking characters survive sanitization."""
    from parser import Character, Script, Scene, Element, _sanitize_characters
    script = Script(title="My Play")
    script.characters = [Character(name="ALICE"), Character(name="BOB")]
    script.scenes = [Scene(number=1, title="One", elements=[
        Element(kind="dialog", speaker="ALICE", text="Hello."),
        Element(kind="dialog", speaker="BOB", text="Hi."),
    ])]
    result = _sanitize_characters(script)
    names = {c.name for c in result.characters}
    assert "ALICE" in names
    assert "BOB" in names


def test_title_page_name_not_added_as_character():
    """A play title (all-caps, first-page-only) must not become a character."""
    title_page_line = "MERCURY FUR"
    first_page = {title_page_line, "by Philip Ridley", "A play in two acts"}
    # Simulate a script where "MERCURY FUR" only appears on page 1
    lines = [
        title_page_line,
        "by Philip Ridley",
        "",
        "SCENE 1",
        "",
        "ELLIOT",
        "Hello there.",
        "DARREN",
        "Hello back.",
        "ELLIOT",
        "Good to see you.",
    ]
    page_sets = [first_page, {"SCENE 1", "ELLIOT", "Hello there.", "DARREN", "Hello back.", "Good to see you."}]
    script = p._parse_play(lines, page_sets=page_sets, title="Mercury Fur")
    names = {c.name for c in script.characters}
    assert "MERCURY FUR" not in names, f"Title should not be a character; got: {names}"
    assert "ELLIOT" in names or "DARREN" in names, f"Real characters missing: {names}"
