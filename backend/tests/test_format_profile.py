"""
Unit tests for the per-project FormatProfile override layer in parser.py.

These tests are deliberately outside scripts/scorecard.py's guarded corpus —
FormatProfile is a per-project, opt-in override, never a change to the shared
CONVENTIONS scorer or corrections_config.json. See CLAUDE.md's "Parser change
protocol" for why that separation matters.

Run from the repo root:
    .venv/bin/python -m pytest backend/tests/test_format_profile.py -v
"""

import sys
import types
from pathlib import Path

import pytest

# Make backend/ importable
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import parser as p


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _block(x0, text, *, page=0, y0=100.0, is_bold=False, is_italic=False, caps_ratio=None, width=100.0):
    """Build a minimal TextBlock for unit tests, deriving the boilerplate
    geometry/derived fields from the given text so tests only need to specify
    what's relevant to the behavior under test."""
    if caps_ratio is None:
        alpha = [c for c in text if c.isalpha()]
        caps_ratio = (sum(1 for c in alpha if c.isupper()) / len(alpha)) if alpha else 0.0
    return p.TextBlock(
        x0=x0, y0=y0, x1=x0 + width, y1=y0 + 12.0, page=page,
        lines=[[p.TextSpan(text=text, bold=is_bold, italic=is_italic, font="Courier", size=12.0)]],
        text=text, caps_ratio=caps_ratio, center_x=x0 + width / 2, width=width, height=12.0,
        line_count=1, char_count=len(text), starts_with_paren=text.startswith("("),
        ends_with_paren=text.endswith(")"), is_italic=is_italic, is_bold=is_bold,
    )


def _example(role, x0, x1=None, caps_ratio=1.0, is_bold=False, is_italic=False, text=""):
    return p.TaggedExample(
        role=role, x0=x0, x1=x1 if x1 is not None else x0 + 60.0,
        caps_ratio=caps_ratio, is_bold=is_bold, is_italic=is_italic, text=text,
    )


def _find(classified, text):
    return [cb for cb in classified if cb.block.text == text][0]


# ---------------------------------------------------------------------------
# derive_format_profile — aggregation rules
# ---------------------------------------------------------------------------


def test_derive_format_profile_basic_roles():
    examples = [
        _example("character_cue", 200.0, 260.0, caps_ratio=1.0, is_bold=True, text="JOSH"),
        _example("character_cue", 204.0, 264.0, caps_ratio=1.0, is_bold=True, text="MARY"),
        _example("dialog", 90.0, 400.0, caps_ratio=0.1, is_bold=False, text="hello there"),
    ]
    profile = p.derive_format_profile(examples, source_pdf_identifier="/tmp/x.pdf")

    assert set(profile.roles.keys()) == {"character_cue", "dialog"}
    cc = profile.roles["character_cue"]
    assert cc.x_min == pytest.approx(200.0 - p._PROFILE_X_PAD)
    assert cc.x_max == pytest.approx(204.0 + p._PROFILE_X_PAD)
    assert cc.caps_ratio_min == pytest.approx(0.95)
    assert cc.is_bold is True
    assert cc.is_italic is False  # unanimous non-italic
    assert cc.sample_count == 2
    assert profile.source_pdf_identifier == "/tmp/x.pdf"


def test_derive_format_profile_missing_role_omitted():
    examples = [_example("character_cue", 200.0, text="JOSH")]
    profile = p.derive_format_profile(examples)
    assert "dialog" not in profile.roles
    assert "stage_direction" not in profile.roles


def test_derive_format_profile_mixed_style_yields_none():
    examples = [
        _example("dialog", 90.0, is_bold=True, text="a"),
        _example("dialog", 92.0, is_bold=False, text="b"),
    ]
    profile = p.derive_format_profile(examples)
    assert profile.roles["dialog"].is_bold is None


def test_derive_format_profile_mixed_case_caps_ratio_unconstrained():
    # One example is mixed-case (< 0.5) -> caps_ratio_min must stay unset so a
    # legitimately mixed-case role is never falsely constrained to all-caps.
    examples = [
        _example("dialog", 90.0, caps_ratio=1.0, text="LOUD"),
        _example("dialog", 92.0, caps_ratio=0.1, text="quiet"),
    ]
    profile = p.derive_format_profile(examples)
    assert profile.roles["dialog"].caps_ratio_min is None


def test_derive_format_profile_ignores_unknown_role():
    examples = [_example("not_a_real_role", 90.0)]
    profile = p.derive_format_profile(examples)
    assert profile.roles == {}


def test_derive_format_profile_computes_width_hint():
    examples = [
        _example("character_cue", 72.0, 72.0 + 39.0, text="David."),
        _example("character_cue", 70.0, 70.0 + 41.0, text="Miriam."),
    ]
    profile = p.derive_format_profile(examples)
    assert profile.roles["character_cue"].width_hint == pytest.approx(40.0)


# ---------------------------------------------------------------------------
# _classify_block_by_profile — forced-role matching
# ---------------------------------------------------------------------------


def test_classify_block_by_profile_unambiguous_match():
    profile = p.FormatProfile(roles={
        "character_cue": p.RoleGeometry(x_min=190.0, x_max=210.0, caps_ratio_min=0.9),
    })
    block = _block(200.0, "JOSH", caps_ratio=1.0)
    assert p._classify_block_by_profile(block, profile) == "character_cue"


def test_classify_block_by_profile_no_match_returns_none():
    profile = p.FormatProfile(roles={
        "character_cue": p.RoleGeometry(x_min=190.0, x_max=210.0, caps_ratio_min=0.9),
    })
    block = _block(400.0, "JOSH", caps_ratio=1.0)
    assert p._classify_block_by_profile(block, profile) is None


def test_classify_block_by_profile_ambiguous_returns_none():
    # Two roles' geometry both cover this block's x0 -> never force a guess.
    profile = p.FormatProfile(roles={
        "character_cue": p.RoleGeometry(x_min=190.0, x_max=260.0),
        "stage_direction": p.RoleGeometry(x_min=190.0, x_max=260.0),
    })
    block = _block(200.0, "JOSH")
    assert p._classify_block_by_profile(block, profile) is None


def test_classify_block_by_profile_style_mismatch_excludes_match():
    profile = p.FormatProfile(roles={
        "character_cue": p.RoleGeometry(x_min=190.0, x_max=210.0, is_bold=True),
    })
    block = _block(200.0, "JOSH", is_bold=False)
    assert p._classify_block_by_profile(block, profile) is None


def test_classify_block_by_profile_ambiguous_broken_by_width_hint():
    # Mirrors a real stage-play manuscript: a short "NAME." cue and a full
    # stage-direction paragraph share the same left margin and are both
    # bold, so x/caps/bold/italic alone can't tell them apart. width_hint
    # (derived from each role's own tagged-example width) breaks the tie.
    profile = p.FormatProfile(roles={
        "character_cue": p.RoleGeometry(x_min=60.0, x_max=90.0, is_bold=True, width_hint=35.0),
        "stage_direction": p.RoleGeometry(x_min=60.0, x_max=90.0, is_bold=True, width_hint=280.0),
    })
    narrow_block = _block(72.0, "David.", is_bold=True, width=39.0)
    wide_block = _block(
        72.0, "Miriam removes scarf, it's bloody and gross under there.",
        is_bold=True, width=294.0,
    )
    assert p._classify_block_by_profile(narrow_block, profile) == "character_cue"
    assert p._classify_block_by_profile(wide_block, profile) == "stage_direction"


def test_classify_block_by_profile_ambiguous_without_width_hint_still_gives_up():
    # A profile decoded from before width_hint existed (None on every role,
    # exactly like test_classify_block_by_profile_ambiguous_returns_none)
    # must keep today's give-up-on-ambiguity behavior — the explicit
    # backward-compatibility guarantee for already-saved templates.
    profile = p.FormatProfile(roles={
        "character_cue": p.RoleGeometry(x_min=60.0, x_max=90.0, is_bold=True),
        "stage_direction": p.RoleGeometry(x_min=60.0, x_max=90.0, is_bold=True),
    })
    block = _block(72.0, "David.", is_bold=True, width=39.0)
    assert p._classify_block_by_profile(block, profile) is None


# ---------------------------------------------------------------------------
# _apply_format_profile_to_model — seeding cue/dialog columns
# ---------------------------------------------------------------------------


def test_apply_format_profile_to_model_seeds_columns_when_cast_empty():
    layout = p.LayoutProfile(speaker_x=100.0, dialog_x=150.0, stage_dir_x=None,
                              page_width=612.0, is_split_layout=False)
    model = p.DocumentModel(
        profile=layout, cast_lexicon={}, cast=set(),
        cue_columns=[], dialog_columns=[], furniture=set(),
    )
    profile = p.FormatProfile(roles={
        "character_cue": p.RoleGeometry(x_min=390.0, x_max=410.0),
        "dialog": p.RoleGeometry(x_min=440.0, x_max=460.0),
    })

    result = p._apply_format_profile_to_model(model, profile)

    assert 400.0 in result.cue_columns
    assert 450.0 in result.dialog_columns
    assert result.profile.speaker_x == pytest.approx(400.0)
    assert result.profile.dialog_x == pytest.approx(450.0)
    # Original model is untouched (dataclasses.replace returns a new instance).
    assert model.cue_columns == []


def test_apply_format_profile_to_model_none_is_noop():
    layout = p.LayoutProfile(speaker_x=100.0, dialog_x=150.0, stage_dir_x=None,
                              page_width=612.0, is_split_layout=False)
    model = p.DocumentModel(
        profile=layout, cast_lexicon={}, cast=set(),
        cue_columns=[100.0], dialog_columns=[150.0], furniture=set(),
    )
    result = p._apply_format_profile_to_model(model, None)
    assert result is model


# ---------------------------------------------------------------------------
# End-to-end: profile changes classification for the failure mode this
# feature targets (a real but rarely-occurring speaker whose cue column
# automatic cast detection didn't confirm).
# ---------------------------------------------------------------------------


def _build_off_column_speaker_script():
    """ALICE is a confirmed, frequently-recurring speaker at x=100 (dialog at
    x=150). XANDER speaks once, off ALICE's column at x=250 — far enough that
    Phase 2's off-column safety check rejects it as a cue, but not so far that
    it triggers the two-column ("newspaper layout") reordering heuristic
    (that requires a >=200pt gap between dense cue columns)."""
    blocks = []
    for i in range(6):
        blocks.append(_block(100.0, "ALICE", page=i))
        blocks.append(_block(150.0, f"Hello there, this is line number {i}.", page=i, caps_ratio=0.1))
    blocks.append(_block(250.0, "XANDER", page=0))
    blocks.append(_block(250.0, "A single unique line of dialog for xander right here.",
                          page=0, caps_ratio=0.1))
    return blocks


def test_classify_blocks_without_profile_misses_off_column_speaker():
    blocks = _build_off_column_speaker_script()
    model = p._build_document_model(blocks, page_width=612.0)
    assert model.cue_columns == [100.0]  # XANDER never confirmed as cast
    classified = p._classify_blocks(blocks, model)
    assert _find(classified, "XANDER").role != "speaker_cue"


def test_classify_blocks_with_profile_recognizes_off_column_speaker():
    blocks = _build_off_column_speaker_script()
    format_profile = p.FormatProfile(roles={
        "character_cue": p.RoleGeometry(x_min=240.0, x_max=260.0, caps_ratio_min=0.9),
    })
    model = p._build_document_model(blocks, page_width=612.0, format_profile=format_profile)
    assert 250.0 in model.cue_columns

    classified = p._classify_blocks(blocks, model, format_profile=format_profile)
    xander = _find(classified, "XANDER")
    assert xander.role == "speaker_cue"
    assert xander.speaker == "XANDER"


# ---------------------------------------------------------------------------
# Backward compatibility: format_profile=None (the default) must be a no-op
# everywhere it's threaded through.
# ---------------------------------------------------------------------------


def test_build_document_model_default_signature_unaffected():
    blocks = _build_off_column_speaker_script()
    with_default = p._build_document_model(blocks, page_width=612.0)
    with_explicit_none = p._build_document_model(blocks, page_width=612.0, format_profile=None)
    assert with_default.cue_columns == with_explicit_none.cue_columns
    assert with_default.cast == with_explicit_none.cast


def test_classify_blocks_default_signature_unaffected():
    blocks = _build_off_column_speaker_script()
    model = p._build_document_model(blocks, page_width=612.0)
    with_default = p._classify_blocks(blocks, model)
    with_explicit_none = p._classify_blocks(blocks, model, format_profile=None)
    assert [cb.role for cb in with_default] == [cb.role for cb in with_explicit_none]
    assert [cb.speaker for cb in with_default] == [cb.speaker for cb in with_explicit_none]


# ---------------------------------------------------------------------------
# analyze_region — live per-box scan backing the rubber-band calibration UI
#
# Uses direct span-dict fixtures (the exact shape of PyMuPDF's
# page.get_text("dict")) via a fake `fitz` module rather than a real PDF, so
# these run in CI's fast job too (no PyMuPDF install needed) and pin down the
# span-flags/center-point logic exactly rather than depending on how a real
# renderer happens to set bold/italic flags for a given font.
# ---------------------------------------------------------------------------


def _span(text, x0, y0, x1, y1, bold=False, italic=False):
    flags = 0
    if bold:
        flags |= 1 << 4
    if italic:
        flags |= 1 << 1
    return {"text": text, "bbox": (x0, y0, x1, y1), "flags": flags}


def _page_dict(spans, image_blocks=0):
    blocks = [{"type": 0, "lines": [{"spans": spans}]}]
    for _ in range(image_blocks):
        blocks.append({"type": 1})
    return {"blocks": blocks}


def _install_fake_fitz(monkeypatch, pages):
    """pages: list of raw get_text('dict') payloads, one per page."""
    class _FakePage:
        def __init__(self, raw):
            self._raw = raw

        def get_text(self, kind):
            assert kind == "dict"
            return self._raw

    class _FakeDoc:
        def __init__(self):
            self._pages = [_FakePage(raw) for raw in pages]

        def __len__(self):
            return len(self._pages)

        def __getitem__(self, i):
            return self._pages[i]

        def __enter__(self):
            return self

        def __exit__(self, *exc):
            return False

    fake_fitz = types.ModuleType("fitz")
    fake_fitz.open = lambda path: _FakeDoc()
    monkeypatch.setitem(sys.modules, "fitz", fake_fitz)


def test_analyze_region_aggregates_matching_spans(monkeypatch):
    _install_fake_fitz(monkeypatch, [_page_dict([
        _span("JO", 200.0, 100.0, 220.0, 112.0),
        _span("SH", 220.0, 100.0, 240.0, 112.0),
    ])])
    region = p.analyze_region("/tmp/x.pdf", 0, 190.0, 90.0, 250.0, 120.0)
    assert region is not None
    assert region.text == "JOSH"
    assert region.x0 == pytest.approx(200.0)
    assert region.x1 == pytest.approx(240.0)
    assert region.caps_ratio == pytest.approx(1.0)
    assert region.is_bold is False
    assert region.is_italic is False


def test_analyze_region_empty_box_returns_none(monkeypatch):
    _install_fake_fitz(monkeypatch, [_page_dict([
        _span("JOSH", 200.0, 100.0, 240.0, 112.0),
    ])])
    region = p.analyze_region("/tmp/x.pdf", 0, 0.0, 0.0, 10.0, 10.0)
    assert region is None


def test_analyze_region_uses_span_center_point_not_bbox_overlap(monkeypatch):
    # A span whose bbox straddles the box edge but whose CENTER falls outside
    # is excluded; robust to a box drawn a little off from the true extent.
    _install_fake_fitz(monkeypatch, [_page_dict([
        _span("EDGE", 95.0, 100.0, 135.0, 112.0),   # center x=115, outside [0,110]
        _span("IN", 50.0, 100.0, 90.0, 112.0),      # center x=70, inside
    ])])
    region = p.analyze_region("/tmp/x.pdf", 0, 0.0, 90.0, 110.0, 120.0)
    assert region is not None
    assert region.text == "IN"


def test_analyze_region_mixed_bold_yields_is_bold_false(monkeypatch):
    _install_fake_fitz(monkeypatch, [_page_dict([
        _span("BOLD", 100.0, 100.0, 140.0, 112.0, bold=True),
        _span("PLAIN", 140.0, 100.0, 180.0, 112.0, bold=False),
    ])])
    region = p.analyze_region("/tmp/x.pdf", 0, 90.0, 90.0, 190.0, 120.0)
    assert region is not None
    assert region.is_bold is False


def test_analyze_region_unanimous_italic_true(monkeypatch):
    _install_fake_fitz(monkeypatch, [_page_dict([
        _span("A", 100.0, 100.0, 110.0, 112.0, italic=True),
        _span("B", 110.0, 100.0, 120.0, 112.0, italic=True),
    ])])
    region = p.analyze_region("/tmp/x.pdf", 0, 90.0, 90.0, 130.0, 120.0)
    assert region is not None
    assert region.is_italic is True


def test_analyze_region_ignores_non_text_blocks(monkeypatch):
    _install_fake_fitz(monkeypatch, [_page_dict(
        [_span("JOSH", 200.0, 100.0, 240.0, 112.0)], image_blocks=1,
    )])
    region = p.analyze_region("/tmp/x.pdf", 0, 190.0, 90.0, 250.0, 120.0)
    assert region is not None
    assert region.text == "JOSH"


def test_analyze_region_out_of_range_page_returns_none(monkeypatch):
    _install_fake_fitz(monkeypatch, [_page_dict([_span("JOSH", 200.0, 100.0, 240.0, 112.0)])])
    assert p.analyze_region("/tmp/x.pdf", 5, 190.0, 90.0, 250.0, 120.0) is None
    assert p.analyze_region("/tmp/x.pdf", -1, 190.0, 90.0, 250.0, 120.0) is None
