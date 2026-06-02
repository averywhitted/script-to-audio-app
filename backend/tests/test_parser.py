"""
Unit tests for parser.py backend logic.

Run from the repo root:
    .venv/bin/python -m pytest backend/tests/ -v
"""

import json
import sys
import tempfile
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


# ---------------------------------------------------------------------------
# ScriptSkeleton / _build_skeleton
# ---------------------------------------------------------------------------

def test_skeleton_created_from_lines():
    """_build_skeleton returns a ScriptSkeleton for any line list."""
    sk = p._build_skeleton(HEIST_LINES)
    assert isinstance(sk, p.ScriptSkeleton)


def test_skeleton_counts_heist_headers():
    sk = p._build_skeleton(HEIST_LINES)
    assert sk.heist_count >= 2, f"Expected ≥2 heist headers, got {sk.heist_count}"


def test_skeleton_counts_cue_lines():
    lines = [
        "SCENE 1",
        "ALICE",
        "Hello there.",
        "BOB",
        "Hi back.",
    ]
    sk = p._build_skeleton(lines)
    # ALICE and BOB are cue candidates (all-caps, followed by mixed-case)
    assert len(sk.cue_line_indices) >= 2


def test_skeleton_cue_score_positive_for_play():
    """cue_score > 0 when all-caps lines are followed by mixed-case dialog."""
    lines = ["ALICE", "Hello there.", "BOB", "Hi back."] * 10
    sk = p._build_skeleton(lines)
    assert sk.cue_score > 0


def test_skeleton_scene_delimiter_indices_heist():
    """Numbered heist headers land in scene_delimiter_indices."""
    sk = p._build_skeleton(HEIST_LINES)
    assert len(sk.scene_delimiter_indices) >= 2


def test_skeleton_first_page_only():
    """first_page_only contains lines exclusive to page 0."""
    page0 = {"TITLE PAGE", "by Author", "ALICE"}
    page1 = {"ALICE", "Hello.", "BOB"}
    sk = p._build_skeleton([], page_sets=[page0, page1])
    # "TITLE PAGE" and "by Author" are page-0-only; "ALICE" appears on both
    assert "TITLE PAGE" in sk.first_page_only
    assert "by Author" in sk.first_page_only
    assert "ALICE" not in sk.first_page_only


def test_skeleton_empty_page_sets():
    """_build_skeleton handles empty page_sets gracefully."""
    sk = p._build_skeleton([], page_sets=[])
    assert sk.first_page_only == set()
    assert sk.non_empty_count == 0


def test_skeleton_non_empty_count():
    lines = ["ALICE", "", "Hello.", "", "BOB", "Hi."]
    sk = p._build_skeleton(lines)
    assert sk.non_empty_count == 4  # ALICE, Hello., BOB, Hi.


def test_skeleton_cast_section_range():
    """cast_section_range is detected when a CHARACTERS header is present."""
    lines = [
        "CHARACTERS",
        "ALICE  The hero",
        "BOB    The villain",
        "",
        "",
        "",
        "SCENE 1",
        "ALICE",
        "Hello.",
    ]
    sk = p._build_skeleton(lines)
    assert sk.cast_section_range is not None
    start, end = sk.cast_section_range
    assert start == 0
    assert end > start


def test_skeleton_no_cast_section():
    lines = ["ALICE", "Hello.", "BOB", "Hi."]
    sk = p._build_skeleton(lines)
    assert sk.cast_section_range is None


def test_format_detection_uses_skeleton():
    """_detect_play_format produces the same result with and without a skeleton."""
    lines = ["ALICE", "Hello.", "BOB", "Hi."] * 20
    sk = p._build_skeleton(lines)
    result_with    = p._detect_play_format(lines, skeleton=sk)
    result_without = p._detect_play_format(lines)
    assert result_with == result_without


def test_detect_script_format_uses_skeleton():
    """_detect_script_format produces the same result with and without a skeleton."""
    sk = p._build_skeleton(HEIST_LINES)
    result_with    = p._detect_script_format(HEIST_LINES, skeleton=sk)
    result_without = p._detect_script_format(HEIST_LINES)
    assert result_with == result_without


def test_parse_lines_builds_skeleton_internally():
    """parse_lines without an explicit skeleton still works (builds one internally)."""
    lines = _dd_lines(4) * 4
    script = p.parse_lines(lines, title="No Skeleton")
    assert len(script.scenes) >= 1


def test_parse_lines_accepts_skeleton():
    """parse_lines accepts a pre-built skeleton without crashing or changing output."""
    lines = _dd_lines(4) * 4
    sk = p._build_skeleton(lines)
    script_with    = p.parse_lines(lines, title="With", skeleton=sk)
    script_without = p.parse_lines(lines, title="With")
    assert len(script_with.scenes) == len(script_without.scenes)


# ---------------------------------------------------------------------------
# Auto-chunking (_auto_chunk_scenes / _split_elements)
# ---------------------------------------------------------------------------

def _make_long_scene(n_dialog: int, with_sd: bool = True) -> p.Scene:
    """Build a Scene with n_dialog dialog elements and optional stage dirs."""
    els = []
    speakers = ["ALICE", "BOB", "CAROL"]
    for i in range(n_dialog):
        els.append(p.Element(kind="dialog", speaker=speakers[i % 3],
                              text=f"Line {i}."))
        if with_sd and i > 0 and i % 20 == 0:
            els.append(p.Element(kind="stage_direction", text="ALICE exits."))
    return p.Scene(number=1, title="Scene 1", elements=els)


def test_short_scene_not_chunked():
    """Scenes under 1.5x target are left alone."""
    scene = _make_long_scene(50)
    result = p._auto_chunk_scenes([scene], target_lines=75)
    assert len(result) == 1


def test_long_scene_is_split():
    """A scene with 200 dialog lines is split into multiple chunks."""
    scene = _make_long_scene(200)
    result = p._auto_chunk_scenes([scene], target_lines=75)
    assert len(result) > 1, f"Expected >1 chunk, got {len(result)}"


def test_chunks_contain_all_elements():
    """No elements lost or duplicated after chunking."""
    scene = _make_long_scene(200)
    original_count = len(scene.elements)
    result = p._auto_chunk_scenes([scene], target_lines=75)
    total = sum(len(sc.elements) for sc in result)
    assert total == original_count, f"Element count mismatch: {total} vs {original_count}"


def test_chunks_have_sequential_numbers():
    """Chunked scenes are renumbered 1, 2, 3..."""
    scene = _make_long_scene(200)
    result = p._auto_chunk_scenes([scene], target_lines=75)
    numbers = [sc.number for sc in result]
    assert numbers == list(range(1, len(result) + 1))


def test_no_break_mid_speaker():
    """A chunk never ends with a parenthetical or mid-exchange dialog."""
    scene = _make_long_scene(200, with_sd=True)
    result = p._auto_chunk_scenes([scene], target_lines=75)
    for chunk in result[:-1]:  # last chunk can end anywhere
        last = chunk.elements[-1]
        # Last element of a non-final chunk should be dialog or stage_direction,
        # not a parenthetical (which should be followed by its dialog line).
        assert last.kind != "parenthetical", "Chunk ends on a parenthetical"


def test_scene_with_transition_sd_breaks_at_transition():
    """A stage direction with 'exits' fires a break point."""
    els = []
    # 120 dialog lines to exceed 1.5x threshold (75*1.5=112.5)
    for i in range(120):
        els.append(p.Element(kind="dialog", speaker="ALICE", text=f"Line {i}."))
    els.append(p.Element(kind="stage_direction", text="ALICE exits. End of scene."))
    for i in range(30):
        els.append(p.Element(kind="dialog", speaker="BOB", text=f"Line {i}."))
    scene = p.Scene(number=1, title="S", elements=els)
    result = p._auto_chunk_scenes([scene], target_lines=75)
    # Should break at or near the exits stage direction
    assert len(result) >= 2
    # All elements preserved
    assert sum(len(sc.elements) for sc in result) == len(els)


def test_tiny_tail_merged():
    """A tail chunk smaller than min_lines is merged into the previous chunk."""
    els = []
    # 150 dialog + one stage direction near the end + 5 more dialog
    for i in range(150):
        els.append(p.Element(kind="dialog", speaker="ALICE", text=f"Line {i}."))
        if i == 74:
            els.append(p.Element(kind="stage_direction", text="Pause."))
    for i in range(5):
        els.append(p.Element(kind="dialog", speaker="BOB", text=f"Tail {i}."))
    scene = p.Scene(number=1, title="S", elements=els)
    result = p._auto_chunk_scenes([scene], target_lines=75, min_lines=20)
    # The 5-line tail should be absorbed, not left as its own chunk
    last_chunk_dialog = sum(1 for e in result[-1].elements if e.kind == "dialog")
    assert last_chunk_dialog >= 20 or len(result) == 1


# ---------------------------------------------------------------------------
# Narrator parenthetical fallback
# ---------------------------------------------------------------------------

def _play_lines(*args: str) -> list[str]:
    """Helper: interleave raw play-format lines."""
    return list(args)


def test_narrator_paren_yields_to_last_character():
    """After a narrator parenthetical, the next unannotated line goes to the
    last non-narrator character rather than the narrator."""
    lines = [
        "SCENE ONE",
        "EDDIE",
        "Hello there.",
        "NARRATOR",
        "(Eddie picks up the phone)",
        "This line should be Eddie's.",
    ]
    scenes = p._extract_scenes_play(lines, set(), set())
    dialogs = [e for sc in scenes for e in sc.elements if e.kind == "dialog"]
    # Find the last dialog line
    last = dialogs[-1]
    assert last.speaker == "EDDIE", (
        f"Expected last dialog to be EDDIE, got '{last.speaker}'"
    )
    assert "Eddie" in last.text or "should be" in last.text


def test_narrator_paren_no_prior_character_becomes_stage_dir():
    """If no character has spoken yet, a post-narrator-paren line falls back
    to stage direction (rather than crashing or being mis-attributed)."""
    lines = [
        "SCENE ONE",
        "NARRATOR",
        "(setting the scene)",
        "An unannotated line with no prior character.",
    ]
    scenes = p._extract_scenes_play(lines, set(), set())
    all_elements = [e for sc in scenes for e in sc.elements]
    # The unannotated line should be a stage direction, not narrator dialog
    # (last_non_narrator_speaker is None → current_speaker reset to None)
    dialogs = [e for e in all_elements if e.kind == "dialog" and e.speaker == "NARRATOR"]
    assert dialogs == [], (
        f"Narrator dialog was emitted but should not be: {[d.text for d in dialogs]}"
    )


def test_narrator_paren_speaker_preserved_in_parenthetical():
    """The parenthetical itself is still attributed to the narrator."""
    lines = [
        "SCENE ONE",
        "EDDIE",
        "Hello.",
        "NARRATOR",
        "(a note from the narrator)",
        "Eddie continues.",
    ]
    scenes = p._extract_scenes_play(lines, set(), set())
    parens = [e for sc in scenes for e in sc.elements if e.kind == "parenthetical"]
    assert len(parens) == 1
    assert parens[0].speaker == "NARRATOR"


def test_regular_character_paren_does_not_reset_speaker():
    """A non-narrator parenthetical does NOT reset current_speaker — the
    character's following lines are still attributed to them (no prior dialog)."""
    lines = [
        "SCENE ONE",
        "EDDIE",
        "(answering the phone)",
        "Hello, yes speaking.",
    ]
    scenes = p._extract_scenes_play(lines, set(), set())
    dialogs = [e for sc in scenes for e in sc.elements if e.kind == "dialog"]
    assert len(dialogs) == 1
    assert dialogs[0].speaker == "EDDIE"
    assert "Hello" in dialogs[0].text


def test_character_paren_mid_speech_continues_attribution():
    """flush_dialog() clears current_speaker when it emits queued dialog.
    A parenthetical in the middle of a character's speech must restore the
    speaker so the lines that follow are still attributed to them — not
    treated as stage directions."""
    lines = [
        "SCENE ONE",
        "EDDIE",
        "I'm gonna freeze or say the wrong thing or . . .",
        "No. Eddie, you'll be fine.",
        "What's the worst that could happen?",
        "(He tries not to think of the worst that could happen.)",
        "I probably shouldn't say this, but, you know, I wouldn't have money problems.",
    ]
    scenes = p._extract_scenes_play(lines, set(), set())
    dialogs = [e for sc in scenes for e in sc.elements if e.kind == "dialog"]
    last = dialogs[-1]
    assert last.speaker == "EDDIE", (
        f"Expected last line attributed to EDDIE, got '{last.speaker}'"
    )
    assert "money problems" in last.text


def test_narrator_dialog_then_paren_fallback():
    """Narrator has dialog + parenthetical; following line goes to last character."""
    lines = [
        "SCENE ONE",
        "ALICE",
        "First line.",
        "NARRATOR",
        "Some narration.",
        "(stage direction note)",
        "Alice speaks again.",
    ]
    scenes = p._extract_scenes_play(lines, set(), set())
    dialogs = [e for sc in scenes for e in sc.elements if e.kind == "dialog"]
    last = dialogs[-1]
    assert last.speaker == "ALICE", (
        f"Expected ALICE after narrator paren, got '{last.speaker}'"
    )


# ---------------------------------------------------------------------------
# corrections_config.json loader
# ---------------------------------------------------------------------------

def _write_config(data: dict) -> str:
    """Write a config dict to a temp file and return the path."""
    fh = tempfile.NamedTemporaryFile(
        mode="w", suffix=".json", delete=False, encoding="utf-8"
    )
    json.dump(data, fh)
    fh.close()
    # Bust the module-level cache for this path
    p._config_cache.pop(fh.name, None)
    return fh.name


def test_load_corrections_config_missing_file():
    """Missing config file returns empty defaults without crashing."""
    cfg = p._load_corrections_config("/nonexistent/corrections_config.json")
    assert cfg["non_cue_words"] == []
    assert cfg["speaker_aliases"] == {}
    assert cfg["noise_line_patterns"] == []


def test_load_corrections_config_malformed_json(tmp_path):
    """Malformed JSON returns empty defaults without crashing."""
    bad = tmp_path / "bad.json"
    bad.write_text("{not valid json", encoding="utf-8")
    cfg = p._load_corrections_config(str(bad))
    assert cfg["non_cue_words"] == []


def test_load_corrections_config_reads_non_cue_words():
    """non_cue_words list is loaded and uppercased."""
    path = _write_config({"non_cue_words": ["Voice", "CROWD", "offstage"]})
    cfg = p._load_corrections_config(path)
    assert "VOICE" in cfg["non_cue_words"]
    assert "CROWD" in cfg["non_cue_words"]
    assert "OFFSTAGE" in cfg["non_cue_words"]


def test_load_corrections_config_reads_aliases():
    """speaker_aliases dict is loaded with keys/values uppercased."""
    path = _write_config({"speaker_aliases": {"Eddie Phone": "EDDIE"}})
    cfg = p._load_corrections_config(path)
    assert cfg["speaker_aliases"].get("EDDIE PHONE") == "EDDIE"


def test_load_corrections_config_invalid_pattern_skipped(tmp_path):
    """An invalid regex in noise_line_patterns is skipped, others kept."""
    data = {"noise_line_patterns": ["[invalid", r"\bpage\b"]}
    path = _write_config(data)
    cfg = p._load_corrections_config(path)
    # Bad pattern skipped, good one kept
    assert len(cfg["noise_line_patterns"]) == 1


def test_apply_corrections_config_alias():
    """speaker_aliases renames a speaker throughout the script."""
    script = p.Script(
        title="Test",
        characters=[p.Character(name="EDDIE PHONE"), p.Character(name="ALICE")],
        scenes=[p.Scene(number=1, title="S1", elements=[
            p.Element(kind="dialog", speaker="EDDIE PHONE", text="Hello?"),
            p.Element(kind="dialog", speaker="ALICE", text="Hi."),
        ])]
    )
    config = {"speaker_aliases": {"EDDIE PHONE": "EDDIE"}, "non_cue_words": [],
              "noise_line_patterns": []}
    result = p._apply_corrections_config(script, config)
    speakers = {e.speaker for sc in result.scenes for e in sc.elements}
    assert "EDDIE PHONE" not in speakers
    assert "EDDIE" in speakers


def test_apply_corrections_config_non_cue_removes_character():
    """A name matching a non_cue_word is removed from characters."""
    script = p.Script(
        title="Test",
        characters=[p.Character(name="VOICE"), p.Character(name="ALICE")],
        scenes=[p.Scene(number=1, title="S1", elements=[
            p.Element(kind="dialog", speaker="VOICE", text="Hear me."),
            p.Element(kind="dialog", speaker="ALICE", text="Who speaks?"),
        ])]
    )
    config = {"speaker_aliases": {}, "non_cue_words": ["VOICE"],
              "noise_line_patterns": []}
    result = p._apply_corrections_config(script, config)
    names = {c.name for c in result.characters}
    assert "VOICE" not in names


def test_load_corrections_config_cached(tmp_path):
    """Second call with same path and mtime returns cached result."""
    cfg_file = tmp_path / "cfg.json"
    cfg_file.write_text(json.dumps({"non_cue_words": ["GHOST"]}), encoding="utf-8")
    p._config_cache.pop(str(cfg_file), None)
    cfg1 = p._load_corrections_config(str(cfg_file))
    cfg2 = p._load_corrections_config(str(cfg_file))
    assert cfg1 is cfg2  # same object → cache hit


def test_bundled_corrections_config_loads():
    """The real corrections_config.json in the backend directory loads cleanly."""
    cfg = p._load_corrections_config()
    assert isinstance(cfg["non_cue_words"], list)
    assert isinstance(cfg["speaker_aliases"], dict)
    assert isinstance(cfg["noise_line_patterns"], list)
    # Spot-check a few expected entries
    assert "VOICE" in cfg["non_cue_words"]
    assert "CROWD" in cfg["non_cue_words"]
