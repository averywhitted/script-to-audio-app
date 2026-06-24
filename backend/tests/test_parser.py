"""
Unit tests for parser.py backend logic.

Run from the repo root:
    .venv/bin/python -m pytest backend/tests/ -v
"""

import json
import sys
import tempfile
from pathlib import Path

import pytest

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


# ---------------------------------------------------------------------------
# Scene-number-dot regex (_SCENE_NUM_DOT_RE)
# Bare "N." lines (with optional whitespace) are the scene markers.
# "N. Title" does NOT match — the regex is `^\s*(\d+)\.\s*$`.
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# Dash-dialog parser (_extract_scenes_dash_dialog)
# Uses bare "N." scene markers.
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# Levenshtein / character deduplication
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# parse_lines smoke tests (uses Script.scenes, not .scene_count)
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# Non-cue word filter (_NON_CUE_RE)
# ---------------------------------------------------------------------------


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


# ---------------------------------------------------------------------------
# ScriptSkeleton / _build_skeleton
# ---------------------------------------------------------------------------


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


def test_apply_corrections_config_non_cue_retagged_as_stage_direction():
    """Elements whose speaker is a removed non-cue name are re-tagged as stage_direction."""
    script = p.Script(
        title="Test",
        characters=[p.Character(name="CROWD"), p.Character(name="ANNA")],
        scenes=[p.Scene(number=1, title="S1", elements=[
            p.Element(kind="dialog", speaker="CROWD", text="Roars of approval."),
            p.Element(kind="dialog", speaker="ANNA", text="Thank you all!"),
        ])]
    )
    config = {"speaker_aliases": {}, "non_cue_words": ["CROWD"],
              "noise_line_patterns": []}
    result = p._apply_corrections_config(script, config)
    elements = result.scenes[0].elements
    crowd_el = elements[0]
    assert crowd_el.kind == "stage_direction"
    assert crowd_el.speaker is None
    # ANNA should be unaffected
    anna_el = elements[1]
    assert anna_el.kind == "dialog"
    assert anna_el.speaker == "ANNA"


def test_apply_corrections_config_noise_pattern_retagged():
    """Elements matching a noise_line_pattern are re-tagged as stage_direction."""
    import re
    script = p.Script(
        title="Test",
        characters=[p.Character(name="BOB")],
        scenes=[p.Scene(number=1, title="S1", elements=[
            p.Element(kind="dialog", speaker="BOB", text="(laughs)"),
            p.Element(kind="dialog", speaker="BOB", text="Not a noise line."),
        ])]
    )
    config = {"speaker_aliases": {}, "non_cue_words": [],
              "noise_line_patterns": [re.compile(r"^\(laughs\)$")]}
    result = p._apply_corrections_config(script, config)
    elements = result.scenes[0].elements
    assert elements[0].kind == "stage_direction"
    assert elements[0].speaker is None
    assert elements[1].kind == "dialog"


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
    # non_cue_words now holds ONLY true non-speakers (sound effects / environment),
    # which are dropped to stage_direction.
    assert "MUSIC" in cfg["non_cue_words"]
    assert "DOORBELL" in cfg["non_cue_words"]
    assert "SIREN" in cfg["non_cue_words"]
    # Generic SPEAKING roles must NOT be here — they are voiced (at low confidence,
    # flagged for review) via parser._GENERIC_ROLES, not silently dropped.
    assert "VOICE" not in cfg["non_cue_words"]
    assert "CROWD" not in cfg["non_cue_words"]
    assert "MAN" not in cfg["non_cue_words"]
    assert {"VOICE", "CROWD", "CHORUS", "MAN", "WOMAN"} <= p._GENERIC_ROLES
    # Noise patterns should be compiled regexes
    assert all(hasattr(p_, "search") for p_ in cfg["noise_line_patterns"])


# ---------------------------------------------------------------------------
# Element confidence scoring
# ---------------------------------------------------------------------------


def test_element_confidence_defaults_to_one():
    """Freshly constructed Element always starts at confidence 1.0."""
    el = p.Element(kind="dialog", text="Hello", speaker="ALICE")
    assert el.confidence == 1.0


def test_single_occurrence_unknown_speaker_gets_reduced_confidence():
    """A speaker who appears only once and isn't in the cast list should be flagged."""
    script = p.Script(
        title="Test",
        characters=[p.Character(name="ALICE"), p.Character(name="BOB")],
        scenes=[p.Scene(number=1, title="Scene 1", elements=[
            p.Element(kind="dialog", speaker="ALICE", text="Hello.", confidence=1.0),
            p.Element(kind="dialog", speaker="PHANTOM", text="Boo.", confidence=0.7),
        ])]
    )
    p._mark_single_occurrence_confidence(script)
    phantom_el = next(e for sc in script.scenes for e in sc.elements if e.speaker == "PHANTOM")
    assert phantom_el.confidence <= 0.7


def test_known_single_occurrence_speaker_keeps_full_confidence():
    """A cast member who speaks only once should NOT be flagged — they're in the declared cast."""
    script = p.Script(
        title="Test",
        characters=[p.Character(name="ALICE"), p.Character(name="BOB")],
        scenes=[p.Scene(number=1, title="Scene 1", elements=[
            p.Element(kind="dialog", speaker="ALICE", text="Hello.", confidence=1.0),
            p.Element(kind="dialog", speaker="BOB", text="Hi.", confidence=1.0),
        ])]
    )
    p._mark_single_occurrence_confidence(script)
    bob_el = next(e for sc in script.scenes for e in sc.elements if e.speaker == "BOB")
    assert bob_el.confidence == 1.0


# ---------------------------------------------------------------------------
# DR.-prefix speaker names (issue: period in name was blocking cue detection)
# ---------------------------------------------------------------------------


def _play_lines_with_cast(**kwargs):
    """Build minimal play lines: CHARACTERS section + SCENE ONE + dialog."""
    cast_lines = ["Cast of Characters"]
    for name, gender in kwargs.items():
        cast_lines.append(f"{name} {gender}.")
    scene_lines = ["SCENE ONE"] + cast_lines[1:]  # reuse cast text to avoid empty scene
    return cast_lines


# ---------------------------------------------------------------------------
# Cast row parser: "NAME Male/Female description" format
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# _split_compound_cue: prefix matching for abbreviated names
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# Ampersand overlap cues: "MARA & EDDIE"
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# Orphan speaker: known-name orphans must NOT become stage directions
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# Page number noise + row-stripping tests
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# Parenthetical attribution after blank-line-separated cue
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# Spatial x-zone tests (Phase 1 parser spatial refactor)
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# Phase-2 infrastructure: StructuredLine, ClassifiedLine, helpers
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# LayoutZones dataclass + properties
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# _infer_layout_zones
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# _build_script_from_classified
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# _classify_lines — zones kwarg wires into speaker/dialog bounds
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# _try_spatial_parse — graceful failure on missing/corrupt PDF
# ---------------------------------------------------------------------------

