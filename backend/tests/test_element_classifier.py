"""Tests for the ML element classifier and its parser integration.

Two things matter most here and both are about failing safely:

  * the runtime must DEGRADE to heuristics rather than raise when the model is
    missing or stale — a user parsing a script must never be blocked by an ML
    artefact;
  * ``shadow`` mode must not change classification at all, since that is the
    entire basis for claiming it carries no risk to the parser scorecard.

Tests that need the corpus PDFs skip when absent (they are gitignored), matching
the convention in test_reference.py.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).parent.parent.parent
sys.path.insert(0, str(ROOT / "backend"))

import features as F  # noqa: E402
from element_classifier import ScriptElementClassifier, _to_float32  # noqa: E402

MODEL_PATH = ROOT / "ml" / "models" / "script_element_classifier.json"
CORPUS_PDF = ROOT / "Test PDFs" / "TheHarvest(3.0).pdf"

requires_model = pytest.mark.skipif(
    not MODEL_PATH.exists(), reason="model not built (run ml/train_element_classifier.py)")
requires_pdf = pytest.mark.skipif(
    not CORPUS_PDF.exists(), reason="corpus PDF not present (gitignored)")


class TestFloat32Cast:
    """scikit-learn compares float32 feature values against float64 thresholds."""

    def test_rounds_to_single_precision(self):
        # 0.1 is not representable in binary; float32 and float64 differ.
        assert _to_float32(0.1) != 0.1
        assert abs(_to_float32(0.1) - 0.1) < 1e-7

    def test_exact_values_unchanged(self):
        for v in (0.0, 1.0, 0.5, -2.0, 0.25):
            assert _to_float32(v) == v


class TestDegradation:
    """A missing or stale model must never break parsing."""

    def test_missing_file_returns_none(self, monkeypatch):
        import element_classifier as ec
        monkeypatch.setattr(ec, "_DEFAULT_PATH", ROOT / "does" / "not" / "exist.json")
        assert ec.ScriptElementClassifier.load_default() is None

    @requires_model
    def test_schema_mismatch_refuses_to_load(self):
        # Feature order is positional: a model trained on a different feature
        # layout would produce confident nonsense rather than an error, so a
        # version mismatch must refuse rather than "work".
        assert ScriptElementClassifier.load_default(expected_schema=9999) is None

    @requires_model
    def test_matching_schema_loads(self):
        clf = ScriptElementClassifier.load_default(
            expected_schema=F.FEATURE_SCHEMA_VERSION)
        assert clf is not None
        assert clf.schema_version == F.FEATURE_SCHEMA_VERSION

    def test_malformed_json_returns_none(self, tmp_path, monkeypatch):
        bad = tmp_path / "bad.json"
        bad.write_text("{not json", encoding="utf-8")
        import element_classifier as ec
        monkeypatch.setattr(ec, "_DEFAULT_PATH", bad)
        assert ec.ScriptElementClassifier.load_default() is None


@requires_model
class TestInference:

    @pytest.fixture(scope="class")
    def clf(self):
        return ScriptElementClassifier.load(MODEL_PATH)

    def test_classes_match_parser_vocabulary(self, clf):
        from parser import _BTYPES
        assert set(clf.classes) <= set(_BTYPES), (
            "model emits a class the parser has no role for")

    def test_feature_names_match_contract(self, clf):
        assert clf.feature_names == list(F.FEATURE_NAMES)

    def test_probabilities_sum_to_one(self, clf):
        # Not exactly 1.0: leaf distributions are stored rounded to 6dp to keep
        # the shipped JSON small, so averaging 120 trees accumulates ~1.7e-8 of
        # error. (Split thresholds, by contrast, are stored at full precision —
        # rounding those flips branches, which is a real error, not noise.)
        proba = clf.predict_proba([0.0] * len(F.FEATURE_NAMES))
        assert abs(sum(proba) - 1.0) < 1e-6

    def test_prediction_is_a_known_class_with_valid_confidence(self, clf):
        kind, conf = clf.predict([0.0] * len(F.FEATURE_NAMES))
        assert kind in clf.classes
        assert 0.0 <= conf <= 1.0


@requires_pdf
@requires_model
class TestParserIntegration:
    """The load-bearing invariant: shadow mode observes without interfering."""

    @pytest.fixture(scope="class")
    def parses(self):
        from parser import parse_pdf
        return (parse_pdf(str(CORPUS_PDF), parser_mode="heuristic"),
                parse_pdf(str(CORPUS_PDF), parser_mode="shadow"))

    def test_shadow_does_not_change_classification(self, parses):
        heuristic, shadow = parses
        assert len(heuristic.scenes) == len(shadow.scenes)
        h = [(e.kind, e.speaker, e.text) for s in heuristic.scenes for e in s.elements]
        s = [(e.kind, e.speaker, e.text) for s_ in shadow.scenes for e in s_.elements]
        assert h == s, "shadow mode must observe only — it changed the parse"

    def test_shadow_populates_kind_confidence(self, parses):
        _, shadow = parses
        els = [e for s in shadow.scenes for e in s.elements]
        assessed = [e for e in els if e.kind_confidence < 1.0]
        assert assessed, "shadow mode produced no kind confidences at all"

    def test_heuristic_mode_leaves_confidence_unassessed(self, parses):
        heuristic, _ = parses
        els = [e for s in heuristic.scenes for e in s.elements]
        assert all(e.kind_confidence == 1.0 for e in els), (
            "heuristic mode must not consult the model")

    def test_flagged_lines_are_a_usable_fraction(self, parses):
        # A flag that fires on most of the script is not actionable, regardless
        # of whether it is technically well-calibrated.
        _, shadow = parses
        els = [e for s in shadow.scenes for e in s.elements]
        flagged = [e for e in els if e.kind_confidence < 0.6]
        assert 0 < len(flagged) / len(els) < 0.35


@requires_model
def test_exported_model_carries_a_threshold():
    payload = json.loads(MODEL_PATH.read_text(encoding="utf-8"))
    # The threshold is chosen from the calibration curve at training time; the UI
    # and parser both read it from here rather than hardcoding a number.
    assert payload.get("confidence_threshold") is not None
    assert 0.0 < payload["confidence_threshold"] < 1.0
