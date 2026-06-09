"""
test_pipeline.py
================

Integration tests for the parser → corrections (Review step) → render pipeline.

Three layers, from fastest to most integrated:

  1. Pure data  — _apply_corrections and _inject_user_elements
                  (no I/O, runs in milliseconds)
  2. Render graph — _build_render_chunks voice-routing after corrections
                    (no I/O, runs in milliseconds)
  3. Full render  — generate_script with synthesis mocked out so only
                    afconvert (WAV→M4A) runs; verifies files are produced
                    correctly after corrections/injections flow through
                    (~1 s per scene, skipped if afconvert unavailable)

Run via:
    bash scripts/test.sh python
"""

from __future__ import annotations

import shutil
import sys
import tempfile
from pathlib import Path
from typing import Any, Dict, List
from unittest.mock import patch

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import audio_worker as aw
import parser as p
from audio_pipeline import _build_render_chunks, _mix_wavs, _synthesize_overlap_into, generate_script
from tts_engines import TTSEngine, VoiceInfo
from voice_assignment import NARRATOR_KEY, auto_assign


# ---------------------------------------------------------------------------
# Shared fixtures
# ---------------------------------------------------------------------------

# A minimal set of dummy voices — enough for auto_assign to work.
_VOICES = [
    VoiceInfo("v_narrator", "Narrator", gender="N", locale="en_US", note="narrator"),
    VoiceInfo("v_alice",    "Alice",    gender="F", locale="en_US"),
    VoiceInfo("v_bob",      "Bob",      gender="M", locale="en_US"),
]


def _make_script(n_scenes: int = 2) -> p.Script:
    """Build a synthetic 2-character script — no PDF parsing required."""
    script = p.Script(title="Test Play")
    script.characters = [
        p.Character(name="ALICE", gender_hint="F"),
        p.Character(name="BOB",   gender_hint="M"),
    ]
    script.scenes = [
        p.Scene(number=i, title=f"Scene {i}", elements=[
            p.Element(kind="dialog",          speaker="ALICE", text=f"Hello from scene {i}."),
            p.Element(kind="dialog",          speaker="BOB",   text=f"Hello back from scene {i}."),
            p.Element(kind="stage_direction", speaker=None,    text="They both pause."),
        ])
        for i in range(1, n_scenes + 1)
    ]
    return script


# ---------------------------------------------------------------------------
# Stub engine for render integration tests
# ---------------------------------------------------------------------------

class _StubEngine(TTSEngine):
    """No-op engine; synthesize() is patched out in the integration tests."""
    name = "stub"
    audio_extension = ".aiff"

    def is_available(self) -> bool:
        return True

    def list_voices(self) -> List[VoiceInfo]:
        return list(_VOICES)

    def synthesize(self, text: str, voice_id: str, out_path: str) -> None:  # pragma: no cover
        raise NotImplementedError("should be patched out in tests")


def _silent_synthesize_into(writer, text, voice_id, engine, work_dir, tag):
    """Replacement for audio_pipeline._synthesize_into: writes 0.1 s of silence
    directly into the wave writer — no subprocess, no TTS engine called."""
    n_frames = 2205  # 0.1 s at 22 050 Hz (16-bit mono = 2 bytes/frame)
    writer.writeframes(b"\x00" * n_frames * 2)


def _silent_overlap_synthesize_into(writer, text, voice_ids, engine, work_dir, tag):
    """Replacement for audio_pipeline._synthesize_overlap_into in tests."""
    n_frames = 2205
    writer.writeframes(b"\x00" * n_frames * 2)


# Skip the full-render tests if afconvert isn't available (non-macOS CI).
needs_afconvert = pytest.mark.skipif(
    not shutil.which("afconvert"),
    reason="afconvert not available — skipping render integration tests",
)


# ===========================================================================
# 1. Pure-data: _apply_corrections
# ===========================================================================

class TestApplyCorrections:

    def test_no_op_with_empty_list(self):
        script = _make_script(1)
        original_texts = [e.text for e in script.scenes[0].elements]
        aw._apply_corrections(script, [])
        assert [e.text for e in script.scenes[0].elements] == original_texts

    def test_speaker_renamed(self):
        script = _make_script(1)
        el = script.scenes[0].elements[0]
        assert el.speaker == "ALICE"
        aw._apply_corrections(script, [
            {"sceneNumber": 1, "textPrefix": el.text[:60], "correctedSpeaker": "CHARLIE"},
        ])
        assert script.scenes[0].elements[0].speaker == "CHARLIE"

    def test_speaker_set_to_narrator_via_empty_string(self):
        """correctedSpeaker="" means "assign to narrator" (speaker → None)."""
        script = _make_script(1)
        el = script.scenes[0].elements[0]
        aw._apply_corrections(script, [
            {"sceneNumber": 1, "textPrefix": el.text[:60], "correctedSpeaker": ""},
        ])
        assert script.scenes[0].elements[0].speaker is None

    def test_text_rewritten(self):
        script = _make_script(1)
        el = script.scenes[0].elements[0]
        aw._apply_corrections(script, [
            {"sceneNumber": 1, "textPrefix": el.text[:60], "correctedText": "Rewritten line."},
        ])
        assert script.scenes[0].elements[0].text == "Rewritten line."

    def test_kind_changed(self):
        script = _make_script(1)
        el = script.scenes[0].elements[0]
        assert el.kind == "dialog"
        aw._apply_corrections(script, [
            {"sceneNumber": 1, "textPrefix": el.text[:60], "correctedKind": "stage_direction"},
        ])
        assert script.scenes[0].elements[0].kind == "stage_direction"

    def test_noise_removes_element(self):
        script = _make_script(1)
        orig_count = len(script.scenes[0].elements)
        el = script.scenes[0].elements[0]
        aw._apply_corrections(script, [
            {"sceneNumber": 1, "textPrefix": el.text[:60], "markedAsNoise": True},
        ])
        remaining = script.scenes[0].elements
        assert len(remaining) == orig_count - 1
        assert all(e.text != el.text for e in remaining)

    def test_wrong_scene_number_is_ignored(self):
        script = _make_script(2)
        el = script.scenes[0].elements[0]
        aw._apply_corrections(script, [
            {"sceneNumber": 99, "textPrefix": el.text[:60], "correctedSpeaker": "GHOST"},
        ])
        assert script.scenes[0].elements[0].speaker == "ALICE"

    def test_multiple_corrections_across_scenes(self):
        script = _make_script(2)
        el0 = script.scenes[0].elements[0]
        el1 = script.scenes[1].elements[1]
        aw._apply_corrections(script, [
            {"sceneNumber": 1, "textPrefix": el0.text[:60], "correctedSpeaker": "X"},
            {"sceneNumber": 2, "textPrefix": el1.text[:60], "correctedSpeaker": "Y"},
        ])
        assert script.scenes[0].elements[0].speaker == "X"
        assert script.scenes[1].elements[1].speaker == "Y"

    def test_returns_script_for_chaining(self):
        script = _make_script(1)
        result = aw._apply_corrections(script, [])
        assert result is script

    # -- manual overlap (makeSimultaneous in the Review UI) -------------------

    def test_manual_overlap_merges_two_elements(self):
        """manualOverlapPartnerKey merges two solo elements into a simultaneous pair."""
        script = _make_script(1)
        el_a = script.scenes[0].elements[0]  # ALICE line
        el_b = script.scenes[0].elements[1]  # BOB line
        orig_count = len(script.scenes[0].elements)
        aw._apply_corrections(script, [
            {
                "sceneNumber": 1,
                "textPrefix": el_a.text[:60],
                "manualOverlapPartnerKey": el_b.text[:60],
            }
        ])
        elements = script.scenes[0].elements
        # Secondary (el_b) absorbed → one fewer element
        assert len(elements) == orig_count - 1
        primary = next(e for e in elements if e.text == el_a.text)
        assert primary.overlap_cue == ["ALICE", "BOB"]
        assert primary.overlap_texts == [el_a.text, el_b.text]

    def test_manual_overlap_secondary_not_in_output(self):
        """The absorbed secondary element must not appear in the scene."""
        script = _make_script(1)
        el_a = script.scenes[0].elements[0]
        el_b = script.scenes[0].elements[1]
        aw._apply_corrections(script, [
            {
                "sceneNumber": 1,
                "textPrefix": el_a.text[:60],
                "manualOverlapPartnerKey": el_b.text[:60],
            }
        ])
        texts = [e.text for e in script.scenes[0].elements]
        # el_b's text should not appear as a standalone element
        assert el_b.text not in texts

    def test_manual_overlap_uses_corrected_speaker(self):
        """If the primary has a correctedSpeaker, that name wins in the overlap cue."""
        script = _make_script(1)
        el_a = script.scenes[0].elements[0]
        el_b = script.scenes[0].elements[1]
        aw._apply_corrections(script, [
            {
                "sceneNumber": 1,
                "textPrefix": el_a.text[:60],
                "correctedSpeaker": "ALICE-RENAMED",
                "manualOverlapPartnerKey": el_b.text[:60],
            }
        ])
        primary = script.scenes[0].elements[0]
        assert primary.overlap_cue[0] == "ALICE-RENAMED"

    # -- correctedOverlapSpeakers (parser-detected overlap editing) -----------

    def test_corrected_overlap_speakers_updates_cue(self):
        """correctedOverlapSpeakers replaces overlap_cue on a parser-detected overlap."""
        import parser as p
        script = _make_script(1)
        el = p.Element(kind="dialog", speaker="ALICE", text="We speak together!")
        el.overlap_cue = ["ALICE", "BOB"]
        script.scenes[0].elements.insert(0, el)
        aw._apply_corrections(script, [
            {
                "sceneNumber": 1,
                "textPrefix": el.text[:60],
                "correctedOverlapSpeakers": ["ALICE", "CAROL"],
            }
        ])
        updated = next(e for e in script.scenes[0].elements if e.text == el.text)
        assert updated.overlap_cue == ["ALICE", "CAROL"]

    # -- removedVoiceIndex (soft-remove one or both overlap voices) -----------

    def test_removed_voice_index_0_keeps_right(self):
        """removedVoiceIndex=0 strips the left voice, keeping the right as solo dialog."""
        import parser as p
        script = _make_script(1)
        el = p.Element(kind="dialog", speaker="ALICE", text="Together we go!")
        el.overlap_cue = ["ALICE", "BOB"]
        el.overlap_texts = ["Alice's line.", "Bob's line."]
        script.scenes[0].elements.insert(0, el)
        aw._apply_corrections(script, [
            {
                "sceneNumber": 1,
                "textPrefix": el.text[:60],
                "removedVoiceIndex": 0,
                "correctedOverlapSpeakers": ["ALICE", "BOB"],
                "correctedOverlapTexts": ["Alice's line.", "Bob's line."],
            }
        ])
        updated = next(e for e in script.scenes[0].elements if (e.speaker or "").upper() == "BOB")
        assert updated.overlap_cue is None
        assert updated.speaker == "BOB"
        assert updated.text == "Bob's line."

    def test_removed_voice_index_1_keeps_left(self):
        """removedVoiceIndex=1 strips the right voice, keeping the left as solo dialog."""
        import parser as p
        script = _make_script(1)
        el = p.Element(kind="dialog", speaker="ALICE", text="Together we go!")
        el.overlap_cue = ["ALICE", "BOB"]
        el.overlap_texts = ["Alice's line.", "Bob's line."]
        script.scenes[0].elements.insert(0, el)
        aw._apply_corrections(script, [
            {
                "sceneNumber": 1,
                "textPrefix": el.text[:60],
                "removedVoiceIndex": 1,
                "correctedOverlapSpeakers": ["ALICE", "BOB"],
                "correctedOverlapTexts": ["Alice's line.", "Bob's line."],
            }
        ])
        updated = next(e for e in script.scenes[0].elements if (e.speaker or "").upper() == "ALICE")
        assert updated.overlap_cue is None
        assert updated.speaker == "ALICE"
        assert updated.text == "Alice's line."

    def test_removed_voice_index_2_suppresses_element(self):
        """removedVoiceIndex=2 (both removed) removes the element entirely."""
        import parser as p
        script = _make_script(1)
        el = p.Element(kind="dialog", speaker="ALICE", text="Together we go!")
        el.overlap_cue = ["ALICE", "BOB"]
        orig_count = len(script.scenes[0].elements)
        script.scenes[0].elements.insert(0, el)
        aw._apply_corrections(script, [
            {
                "sceneNumber": 1,
                "textPrefix": el.text[:60],
                "removedVoiceIndex": 2,
                "correctedOverlapSpeakers": ["ALICE", "BOB"],
            }
        ])
        assert len(script.scenes[0].elements) == orig_count
        assert all(e.text != el.text for e in script.scenes[0].elements)


# ===========================================================================
# 2. Pure-data: _inject_user_elements
# ===========================================================================

class TestInjectUserElements:

    def test_element_inserted_after_anchor(self):
        script = _make_script(1)
        anchor = script.scenes[0].elements[0]
        aw._inject_user_elements(script, {1: [{
            "afterElementTextKey": anchor.text[:60],
            "speaker": "CAROL",
            "text": "Interjection!",
            "kind": "dialog",
        }]})
        texts = [e.text for e in script.scenes[0].elements]
        assert "Interjection!" in texts
        assert texts.index("Interjection!") == texts.index(anchor.text) + 1

    def test_multiple_injections_after_same_anchor(self):
        script = _make_script(1)
        anchor = script.scenes[0].elements[0]
        aw._inject_user_elements(script, {1: [
            {"afterElementTextKey": anchor.text[:60], "speaker": "CAROL", "text": "First.", "kind": "dialog"},
            {"afterElementTextKey": anchor.text[:60], "speaker": "DAVE",  "text": "Second.", "kind": "dialog"},
        ]})
        texts = [e.text for e in script.scenes[0].elements]
        idx_anchor = texts.index(anchor.text)
        assert texts[idx_anchor + 1] == "First."
        assert texts[idx_anchor + 2] == "Second."

    def test_narrator_speaker_values_mapped_to_none(self):
        """Empty string, 'Narrator', and '__NARRATOR__' all become speaker=None."""
        for narrator_val in ("", "Narrator", "__NARRATOR__"):
            script = _make_script(1)
            anchor = script.scenes[0].elements[0]
            aw._inject_user_elements(script, {1: [{
                "afterElementTextKey": anchor.text[:60],
                "speaker": narrator_val,
                "text": "Narrated aside.",
                "kind": "stage_direction",
            }]})
            injected = [e for e in script.scenes[0].elements if e.text == "Narrated aside."]
            assert len(injected) == 1, f"Expected 1 injected element for narrator_val={narrator_val!r}"
            assert injected[0].speaker is None, f"Expected speaker=None for narrator_val={narrator_val!r}"

    def test_unmatched_anchor_key_is_skipped(self):
        script = _make_script(1)
        orig_count = len(script.scenes[0].elements)
        aw._inject_user_elements(script, {1: [{
            "afterElementTextKey": "NO SUCH TEXT IN SCRIPT",
            "speaker": "ALICE",
            "text": "Should not appear.",
            "kind": "dialog",
        }]})
        assert len(script.scenes[0].elements) == orig_count

    def test_whitespace_only_text_is_skipped(self):
        script = _make_script(1)
        anchor = script.scenes[0].elements[0]
        orig_count = len(script.scenes[0].elements)
        aw._inject_user_elements(script, {1: [{
            "afterElementTextKey": anchor.text[:60],
            "speaker": "ALICE",
            "text": "   ",
            "kind": "dialog",
        }]})
        assert len(script.scenes[0].elements) == orig_count

    def test_warn_fn_called_for_unmatched(self):
        script = _make_script(1)
        warnings: List[str] = []
        aw._inject_user_elements(
            script,
            {1: [{"afterElementTextKey": "MISSING KEY", "speaker": "X", "text": "Oops.", "kind": "dialog"}]},
            warn_fn=warnings.append,
        )
        assert len(warnings) == 1
        assert "Scene 1" in warnings[0]

    def test_returns_script_and_count(self):
        script = _make_script(1)
        anchor = script.scenes[0].elements[0]
        result_script, count = aw._inject_user_elements(script, {1: [
            {"afterElementTextKey": anchor.text[:60], "speaker": "BOB", "text": "Extra.", "kind": "dialog"},
        ]})
        assert result_script is script
        assert count == 1

    def test_empty_map_is_no_op(self):
        script = _make_script(2)
        orig_counts = [len(s.elements) for s in script.scenes]
        aw._inject_user_elements(script, {})
        assert [len(s.elements) for s in script.scenes] == orig_counts


# ===========================================================================
# 3. Render graph: _build_render_chunks voice routing
# ===========================================================================

class TestRenderChunks:

    def test_dialog_uses_character_voice(self):
        script = _make_script(1)
        assignment = auto_assign(script.characters, _VOICES)
        chunks = _build_render_chunks(script.scenes[0].elements, assignment)
        chunk_voices = {c.voice_id for c in chunks}
        assert assignment.voice_for("ALICE") in chunk_voices
        assert assignment.voice_for("BOB")   in chunk_voices

    def test_stage_direction_uses_narrator_voice(self):
        script = _make_script(1)
        assignment = auto_assign(script.characters, _VOICES)
        chunks = _build_render_chunks(script.scenes[0].elements, assignment)
        narrator_voice = assignment.voice_for(None)
        sd_chunks = [c for c in chunks if c.kind == "stage_direction"]
        assert sd_chunks, "Expected at least one stage-direction chunk"
        assert all(c.voice_id == narrator_voice for c in sd_chunks)

    def test_corrected_speaker_gets_new_voice(self):
        """After renaming a speaker via corrections, the render uses the new voice."""
        script = _make_script(1)
        script.characters.append(p.Character(name="CAROL", gender_hint="F"))
        voices = _VOICES + [VoiceInfo("v_carol", "Carol", gender="F", locale="en_US")]

        el = script.scenes[0].elements[0]  # ALICE's line
        aw._apply_corrections(script, [
            {"sceneNumber": 1, "textPrefix": el.text[:60], "correctedSpeaker": "CAROL"},
        ])

        assignment = auto_assign(script.characters, voices)
        chunks = _build_render_chunks(script.scenes[0].elements, assignment)

        carol_voice = assignment.voice_for("CAROL")
        # First chunk was ALICE's line, now corrected to CAROL
        first_dialog_chunk = next(c for c in chunks if c.kind == "dialog")
        assert first_dialog_chunk.voice_id == carol_voice

    def test_noise_removed_element_absent_from_chunks(self):
        script = _make_script(1)
        el = script.scenes[0].elements[0]
        removed_text = el.text
        aw._apply_corrections(script, [
            {"sceneNumber": 1, "textPrefix": el.text[:60], "markedAsNoise": True},
        ])
        assignment = auto_assign(script.characters, _VOICES)
        chunks = _build_render_chunks(script.scenes[0].elements, assignment)
        assert all(removed_text not in c.text for c in chunks)

    def test_injected_element_appears_in_chunks(self):
        script = _make_script(1)
        anchor = script.scenes[0].elements[-1]  # stage direction "They both pause."
        aw._inject_user_elements(script, {1: [{
            "afterElementTextKey": anchor.text[:60],
            "speaker": "ALICE",
            "text": "One last thought.",
            "kind": "dialog",
        }]})
        assignment = auto_assign(script.characters, _VOICES)
        chunks = _build_render_chunks(script.scenes[0].elements, assignment)
        all_text = " ".join(c.text for c in chunks)
        assert "One last thought." in all_text


# ===========================================================================
# 4. Full render integration (synthesis mocked; afconvert runs end-to-end)
# ===========================================================================

class TestFullRender:

    @needs_afconvert
    def test_produces_one_m4a_per_scene(self):
        script = _make_script(n_scenes=2)
        assignment = auto_assign(script.characters, _VOICES)
        engine = _StubEngine()
        with patch("audio_pipeline._synthesize_into", _silent_synthesize_into):
            with tempfile.TemporaryDirectory() as out_dir:
                result = generate_script(script, engine, assignment, out_dir)
                assert result.errors == [], f"Unexpected errors: {result.errors}"
                assert len(result.files) == 2
                for f in result.files:
                    assert Path(f).exists()
                    assert f.endswith(".m4a")

    @needs_afconvert
    def test_corrections_flow_through_to_render(self):
        """Corrections applied before rendering must not crash the pipeline.

        Content correctness (which voice speaks which line) is verified in
        TestRenderChunks; this test confirms the full path runs without errors.
        """
        script = _make_script(n_scenes=1)
        el = script.scenes[0].elements[0]
        # Rename ALICE → narrator on the first line, mark BOB's line as noise.
        bob_el = script.scenes[0].elements[1]
        aw._apply_corrections(script, [
            {"sceneNumber": 1, "textPrefix": el.text[:60], "correctedSpeaker": ""},
            {"sceneNumber": 1, "textPrefix": bob_el.text[:60], "markedAsNoise": True},
        ])
        assignment = auto_assign(script.characters, _VOICES)
        engine = _StubEngine()
        with patch("audio_pipeline._synthesize_into", _silent_synthesize_into):
            with tempfile.TemporaryDirectory() as out_dir:
                result = generate_script(script, engine, assignment, out_dir)
        assert result.errors == []
        assert len(result.files) == 1

    @needs_afconvert
    def test_injected_elements_flow_through_to_render(self):
        """User-added elements injected before rendering must not crash the pipeline."""
        script = _make_script(n_scenes=1)
        anchor = script.scenes[0].elements[-1]
        aw._inject_user_elements(script, {1: [{
            "afterElementTextKey": anchor.text[:60],
            "speaker": "ALICE",
            "text": "One more thing before we go.",
            "kind": "dialog",
        }]})
        orig_element_count = len(script.scenes[0].elements)
        assert orig_element_count == 4  # 3 original + 1 injected
        assignment = auto_assign(script.characters, _VOICES)
        engine = _StubEngine()
        with patch("audio_pipeline._synthesize_into", _silent_synthesize_into):
            with tempfile.TemporaryDirectory() as out_dir:
                result = generate_script(script, engine, assignment, out_dir)
        assert result.errors == []
        assert len(result.files) == 1

    @needs_afconvert
    def test_scene_filter_renders_only_requested_scenes(self):
        script = _make_script(n_scenes=3)
        assignment = auto_assign(script.characters, _VOICES)
        engine = _StubEngine()
        with patch("audio_pipeline._synthesize_into", _silent_synthesize_into):
            with tempfile.TemporaryDirectory() as out_dir:
                result = generate_script(
                    script, engine, assignment, out_dir,
                    scene_filter=[1, 3],  # skip scene 2
                )
        assert result.errors == []
        assert len(result.files) == 2
        filenames = [Path(f).name for f in result.files]
        assert any("Scene_01" in n for n in filenames)
        assert any("Scene_03" in n for n in filenames)
        assert all("Scene_02" not in n for n in filenames)

    @needs_afconvert
    def test_empty_scene_is_skipped_not_errored(self):
        """A scene with no audible content should be skipped, not cause an error."""
        script = _make_script(n_scenes=2)
        # Wipe all elements from scene 1
        script.scenes[0].elements = []
        assignment = auto_assign(script.characters, _VOICES)
        engine = _StubEngine()
        with patch("audio_pipeline._synthesize_into", _silent_synthesize_into):
            with tempfile.TemporaryDirectory() as out_dir:
                result = generate_script(script, engine, assignment, out_dir)
        assert result.errors == []
        assert len(result.files) == 1          # only scene 2 produced a file
        assert len(result.skipped_scenes) == 1  # scene 1 was skipped


# ===========================================================================
# 5. Overlap / simultaneous-speech cue detection (#33 Phase 1)
# ===========================================================================

def _scenes_play(lines, known=("ALICE", "BOB")):
    """Shorthand: call _extract_scenes_play directly with a known-speaker set."""
    return p._extract_scenes_play(lines, set(known), noise=set())


class TestOverlapCues:
    """Parser correctly handles simultaneous-speech cues (Issue #33 Phase 1).

    Tests call _extract_scenes_play directly (same pattern as test_parser.py)
    to avoid depending on format-detection thresholds.
    """

    def test_slash_cue_sets_overlap_cue(self):
        """ALICE/BOB line: speaker = ALICE, overlap_cue = ['ALICE', 'BOB']."""
        scenes = _scenes_play([
            "SCENE 1",
            "ALICE/BOB",
            "We both say this.",
        ])
        joint = [e for sc in scenes for e in sc.elements if e.overlap_cue]
        assert joint, "Expected at least one element with overlap_cue set"
        el = joint[0]
        assert el.speaker == "ALICE"
        assert "BOB" in el.overlap_cue

    def test_slash_cue_speaker_is_first_part(self):
        """When slash cue fires, the primary speaker is the first name."""
        scenes = _scenes_play([
            "SCENE 1",
            "BOB/ALICE",  # reversed order this time
            "We both say this.",
        ])
        joint = [e for sc in scenes for e in sc.elements if e.overlap_cue]
        assert joint
        assert joint[0].speaker == "BOB"
        assert "ALICE" in joint[0].overlap_cue

    def test_slash_cue_not_added_as_character(self):
        """ALICE/BOB must not appear as a character in its own right."""
        # Use parse_lines with enough dialog to build a character list
        lines = (
            ["ALICE", "Hello.", "BOB", "Hi."] * 10
            + ["ALICE/BOB", "Together."] * 4
        )
        script = p.parse_lines(lines, title="Slash Test")
        names = {c.name for c in script.characters}
        assert "ALICE/BOB" not in names, f"Spurious joint character found: {names}"

    def test_slash_cue_first_speaker_gets_voice_assignment(self):
        """Voice assignment resolves ALICE/BOB to ALICE's voice (first part)."""
        chars = [p.Character(name="ALICE"), p.Character(name="BOB")]
        voices = [
            VoiceInfo("v_alice", "Alice", gender="F"),
            VoiceInfo("v_bob",   "Bob",   gender="M"),
        ]
        assignment = auto_assign(chars, voices)
        # Simulate what render uses: voice_for("ALICE/BOB") should resolve to ALICE's voice
        assert assignment.voice_for("ALICE/BOB") == assignment.voice_for("ALICE")

    def test_compound_space_cue_splits_known_speakers(self):
        """Two-column PDF artefact 'ALICE BOB' with both known → speaker=ALICE, overlap_cue."""
        scenes = _scenes_play([
            "SCENE 1",
            "ALICE BOB",
            "We both say this together.",
        ])
        joint = [e for sc in scenes for e in sc.elements if e.overlap_cue]
        assert joint, "Expected at least one element with overlap_cue set for compound cue"
        el = joint[0]
        assert el.speaker == "ALICE"
        assert el.overlap_cue == ["ALICE", "BOB"]

    def test_compound_space_cue_not_added_as_character(self):
        """'ALICE BOB' (space-compound) must not become a spurious 'ALICE BOB' character."""
        scenes = _scenes_play([
            "SCENE 1",
            "ALICE",
            "Solo line.",
            "ALICE BOB",
            "Together.",
        ])
        all_speakers = {e.speaker for sc in scenes for e in sc.elements if e.speaker}
        assert "ALICE BOB" not in all_speakers, \
            f"Spurious compound speaker found: {all_speakers}"

    def test_unknown_space_compound_not_split(self):
        """'ALICE STRANGER' where STRANGER is not a known speaker must NOT split."""
        scenes = _scenes_play([
            "SCENE 1",
            "ALICE STRANGER",   # STRANGER not in known_speakers
            "A line.",
        ], known=("ALICE", "BOB"))  # STRANGER deliberately absent
        joint = [e for sc in scenes for e in sc.elements if e.overlap_cue]
        assert not joint, "Should not split unknown compound"

    def test_split_compound_cue_helper_finds_split(self):
        """_split_compound_cue finds the binary split when both halves are known."""
        known = {"LEAH", "CREDIT CARD COMPANY", "ALICE", "BOB"}
        assert p._split_compound_cue("LEAH CREDIT CARD COMPANY", known) == \
               ["LEAH", "CREDIT CARD COMPANY"]
        assert p._split_compound_cue("ALICE BOB", known) == ["ALICE", "BOB"]

    def test_split_compound_cue_helper_returns_none_when_no_match(self):
        """_split_compound_cue returns None when no split finds two known speakers."""
        known = {"ALICE", "BOB"}
        assert p._split_compound_cue("ALICE SMITH", known) is None   # SMITH not known
        assert p._split_compound_cue("ALICE", known) is None          # no space → no split
        assert p._split_compound_cue("ALICE BOB CAROL", known) is None  # 3-way not in known

    def test_non_overlap_dialog_has_no_overlap_cue(self):
        """Regular solo-speaker dialog must have overlap_cue=None."""
        script = _make_script(1)
        for sc in script.scenes:
            for el in sc.elements:
                assert el.overlap_cue is None, \
                    f"Unexpected overlap_cue on solo line: {el}"


# ===========================================================================
# 6. Overlap audio rendering — _mix_wavs + _build_render_chunks overlap_voices
# ===========================================================================

def _write_silence_wav(path: str, n_frames: int = 2205) -> None:
    """Write a minimal valid silent WAV to `path` (0.1 s at 22 050 Hz, mono, 16-bit)."""
    import wave as _wave
    with _wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(22050)
        w.writeframes(b"\x00" * n_frames * 2)


def _write_tone_wav(path: str, amplitude: int, n_frames: int = 2205) -> None:
    """Write a WAV filled with a constant sample value (for testing mix arithmetic)."""
    import array, wave as _wave
    samples = array.array("h", [amplitude] * n_frames)
    with _wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(22050)
        w.writeframes(samples.tobytes())


def _read_wav_samples(path: str):
    """Return all 16-bit samples from a WAV as a list of ints."""
    import array, wave as _wave
    with _wave.open(path, "rb") as r:
        raw = r.readframes(r.getnframes())
    a = array.array("h")
    a.frombytes(raw)
    return list(a)


class TestOverlapRendering:
    """Audio mixing (_mix_wavs) and overlap render path in generate_scene."""

    # ---- _mix_wavs unit tests (pure Python, no subprocess) ----

    def test_mix_single_source_copies_unchanged(self, tmp_path):
        src = str(tmp_path / "src.wav")
        dst = str(tmp_path / "dst.wav")
        _write_silence_wav(src)
        _mix_wavs([src], dst)
        assert Path(dst).exists()
        assert _read_wav_samples(dst) == _read_wav_samples(src)

    def test_mix_two_identical_tones_doubles_amplitude(self, tmp_path):
        """Mixing two files with the same constant sample should double it (up to clamp)."""
        src1 = str(tmp_path / "s1.wav")
        src2 = str(tmp_path / "s2.wav")
        dst  = str(tmp_path / "mix.wav")
        _write_tone_wav(src1, amplitude=100)
        _write_tone_wav(src2, amplitude=100)
        _mix_wavs([src1, src2], dst)
        samples = _read_wav_samples(dst)
        assert all(s == 200 for s in samples), f"Expected 200 everywhere, got {set(samples)}"

    def test_mix_clamps_at_max_positive(self, tmp_path):
        """Sum that exceeds 32 767 is clamped, not wrapped."""
        src1 = str(tmp_path / "s1.wav")
        src2 = str(tmp_path / "s2.wav")
        dst  = str(tmp_path / "mix.wav")
        _write_tone_wav(src1, amplitude=30000)
        _write_tone_wav(src2, amplitude=30000)  # sum = 60 000, must clamp to 32 767
        _mix_wavs([src1, src2], dst)
        samples = _read_wav_samples(dst)
        assert all(s == 32767 for s in samples), f"Expected 32767 (clamped), got {set(samples)}"

    def test_mix_clamps_at_max_negative(self, tmp_path):
        """Sum that goes below -32 768 is clamped."""
        src1 = str(tmp_path / "s1.wav")
        src2 = str(tmp_path / "s2.wav")
        dst  = str(tmp_path / "mix.wav")
        _write_tone_wav(src1, amplitude=-30000)
        _write_tone_wav(src2, amplitude=-30000)
        _mix_wavs([src1, src2], dst)
        samples = _read_wav_samples(dst)
        assert all(s == -32768 for s in samples)

    def test_mix_shorter_source_zero_padded(self, tmp_path):
        """Shorter source is zero-padded; output is as long as the longest input."""
        long_src  = str(tmp_path / "long.wav")
        short_src = str(tmp_path / "short.wav")
        dst       = str(tmp_path / "mix.wav")
        _write_tone_wav(long_src,  amplitude=100, n_frames=4410)  # 0.2 s
        _write_tone_wav(short_src, amplitude=100, n_frames=2205)  # 0.1 s
        _mix_wavs([long_src, short_src], dst)
        samples = _read_wav_samples(dst)
        assert len(samples) == 4410
        # First half: 100 + 100 = 200; second half: 100 + 0 = 100
        assert all(s == 200 for s in samples[:2205])
        assert all(s == 100 for s in samples[2205:])

    # ---- _build_render_chunks overlap_voices propagation ----

    def test_overlap_chunk_carries_overlap_voices(self):
        """An element with overlap_cue gets a RenderChunk with overlap_voices set."""
        el = p.Element(
            kind="dialog", speaker="ALICE", text="Together now.",
            overlap_cue=["ALICE", "BOB"]
        )
        chars  = [p.Character(name="ALICE"), p.Character(name="BOB")]
        voices = [VoiceInfo("v_alice", "Alice", gender="F"),
                  VoiceInfo("v_bob",   "Bob",   gender="M")]
        assignment = auto_assign(chars, voices)
        chunks = _build_render_chunks([el], assignment)
        assert len(chunks) == 1
        assert chunks[0].overlap_voices is not None
        assert len(chunks[0].overlap_voices) == 2
        assert assignment.voice_for("ALICE") in chunks[0].overlap_voices
        assert assignment.voice_for("BOB")   in chunks[0].overlap_voices

    def test_overlap_chunks_not_merged(self):
        """Two consecutive overlap elements are never merged into one chunk."""
        els = [
            p.Element(kind="dialog", speaker="ALICE", text="First.", overlap_cue=["ALICE", "BOB"]),
            p.Element(kind="dialog", speaker="ALICE", text="Second.", overlap_cue=["ALICE", "BOB"]),
        ]
        chars  = [p.Character(name="ALICE"), p.Character(name="BOB")]
        voices = [VoiceInfo("v_alice", "Alice"), VoiceInfo("v_bob", "Bob")]
        assignment = auto_assign(chars, voices)
        chunks = _build_render_chunks(els, assignment)
        assert len(chunks) == 2, "Overlap chunks must not be merged"

    def test_solo_chunk_no_overlap_voices(self):
        """A regular solo element has overlap_voices=None in its chunk."""
        el = p.Element(kind="dialog", speaker="ALICE", text="Just me.")
        chars  = [p.Character(name="ALICE")]
        voices = [VoiceInfo("v_alice", "Alice", gender="F")]
        assignment = auto_assign(chars, voices)
        chunks = _build_render_chunks([el], assignment)
        assert chunks[0].overlap_voices is None

    # ---- Full render integration with overlap elements ----

    @needs_afconvert
    def test_overlap_element_renders_without_error(self):
        """A scene containing an overlap element completes successfully."""
        script = p.Script(title="Overlap Test")
        script.characters = [
            p.Character(name="ALICE", gender_hint="F"),
            p.Character(name="BOB",   gender_hint="M"),
        ]
        script.scenes = [p.Scene(number=1, title="Scene 1", elements=[
            p.Element(kind="dialog",  speaker="ALICE", text="Solo line."),
            p.Element(kind="dialog",  speaker="ALICE", text="Together!",
                      overlap_cue=["ALICE", "BOB"]),
            p.Element(kind="dialog",  speaker="BOB",   text="Another solo."),
        ])]
        assignment = auto_assign(script.characters, _VOICES)
        engine = _StubEngine()
        with patch("audio_pipeline._synthesize_into", _silent_synthesize_into), \
             patch("audio_pipeline._synthesize_overlap_into", _silent_overlap_synthesize_into):
            with tempfile.TemporaryDirectory() as out_dir:
                result = generate_script(script, engine, assignment, out_dir)
        assert result.errors == []
        assert len(result.files) == 1


# ---------------------------------------------------------------------------
# Per-voice overlap text: compound cues split, chorus cues do not
# ---------------------------------------------------------------------------

class TestOverlapTexts:
    """_split_overlap_text helper and end-to-end per-voice text routing."""

    def test_split_simple_two_sentence(self):
        """Classic two-column: 'Alice line. Bob line.' splits at the period."""
        result = p._split_overlap_text("Alice's line. Bob's answer.", n_voices=2)
        assert result is not None
        assert len(result) == 2
        assert "Alice" in result[0]
        assert "Bob" in result[1]

    def test_split_question_mark(self):
        """A question mark is a valid split boundary."""
        result = p._split_overlap_text("What do you mean? I don't know.", n_voices=2)
        assert result is not None
        assert result[0].rstrip() == "What do you mean?"
        assert "don't know" in result[1]

    def test_split_ellipsis_as_unit(self):
        """Ellipsis '. . .' treated as a terminal; split is AFTER the full run."""
        result = p._split_overlap_text("That's a nice . . . So why did . . .", n_voices=2)
        assert result is not None
        assert result[0] == "That's a nice . . ."
        assert result[1] == "So why did . . ."

    def test_no_split_too_short(self):
        """Very short text with no usable boundary returns None → chorus mode."""
        result = p._split_overlap_text("What?!", n_voices=2)
        assert result is None

    def test_no_split_single_sentence(self):
        """A single sentence with no internal boundary returns None."""
        result = p._split_overlap_text("We're in this together!", n_voices=2)
        assert result is None

    def test_compound_cue_element_has_overlap_texts(self):
        """Two-column space-compound cue produces non-None overlap_texts."""
        lines = [
            "SCENE ONE",
            "ALICE BOB",
            "First half. Second half.",
        ]
        known = {"ALICE", "BOB"}
        scenes = p._extract_scenes_play(lines, known, set())
        overlap_els = [e for sc in scenes for e in sc.elements if e.overlap_cue]
        assert overlap_els, "Expected at least one overlap element"
        el = overlap_els[0]
        assert el.overlap_texts is not None
        assert len(el.overlap_texts) == 2
        assert "First half" in el.overlap_texts[0]
        assert "Second half" in el.overlap_texts[1]

    def test_slash_cue_has_no_overlap_texts(self):
        """Slash cue (chorus) must NOT produce overlap_texts — both voices read same text."""
        lines = [
            "SCENE ONE",
            "ALICE/BOB",
            "Together now.",
        ]
        known = {"ALICE", "BOB"}
        scenes = p._extract_scenes_play(lines, known, set())
        overlap_els = [e for sc in scenes for e in sc.elements if e.overlap_cue]
        assert overlap_els
        el = overlap_els[0]
        assert el.overlap_texts is None, "Slash cue should have no per-voice split"

    def test_ampersand_cue_has_no_overlap_texts(self):
        """Ampersand cue (chorus) must NOT produce overlap_texts."""
        lines = [
            "SCENE ONE",
            "ALICE & BOB",
            "What?!",
        ]
        known = {"ALICE", "BOB"}
        scenes = p._extract_scenes_play(lines, known, set())
        overlap_els = [e for sc in scenes for e in sc.elements if e.overlap_cue]
        assert overlap_els
        el = overlap_els[0]
        assert el.overlap_texts is None, "Ampersand cue should have no per-voice split"

    def test_overlap_texts_flows_to_render_chunk(self):
        """overlap_texts from an Element is passed through to the RenderChunk."""
        from audio_pipeline import _build_render_chunks
        from parser import Element
        from voice_assignment import Assignment
        from tts_engines import VoiceInfo

        el = Element(
            kind="dialog",
            speaker="ALICE",
            text="First part. Second part.",
            overlap_cue=["ALICE", "BOB"],
            overlap_texts=["First part.", "Second part."],
        )
        vm = {"ALICE": "voice_a", "BOB": "voice_b", "__NARRATOR__": "voice_n"}
        vi = {v: VoiceInfo(id=v, label=v) for v in vm.values()}
        assign = Assignment(mapping=vm, voices_by_id=vi)
        chunks = _build_render_chunks([el], assign)
        assert chunks
        chunk = chunks[0]
        assert chunk.overlap_texts == ["First part.", "Second part."]

    def test_chorus_overlap_texts_is_none_in_chunk(self):
        """When overlap_texts is None (chorus), the chunk also has None."""
        from audio_pipeline import _build_render_chunks
        from parser import Element
        from voice_assignment import Assignment
        from tts_engines import VoiceInfo

        el = Element(
            kind="dialog",
            speaker="ALICE",
            text="Together now.",
            overlap_cue=["ALICE", "BOB"],
            overlap_texts=None,
        )
        vm = {"ALICE": "voice_a", "BOB": "voice_b", "__NARRATOR__": "voice_n"}
        vi = {v: VoiceInfo(id=v, label=v) for v in vm.values()}
        assign = Assignment(mapping=vm, voices_by_id=vi)
        chunks = _build_render_chunks([el], assign)
        assert chunks
        assert chunks[0].overlap_texts is None
