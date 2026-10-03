"""element_classifier.py — dependency-free inference for ScriptElementClassifier.

Loads the JSON forest exported by ``ml/train_element_classifier.py`` and evaluates
it with nothing but the standard library. No scikit-learn, no coremltools, no
numpy — which is what lets the model ship inside the app's bundled CPython
(vendor/python) without adding ~100 MB of scientific stack to the bundle.

A random forest is an average of per-tree leaf distributions, so inference is a
tree walk and a mean. ``ml/train_element_classifier.py --check-parity`` asserts
this reproduces scikit-learn's own predictions exactly (label match, confidence
within 1e-6), so "we reimplemented inference" is a verified claim rather than an
assumption.

The same JSON and the same ~40 lines of tree-walking port directly to Swift, so
an eventual iOS build needs neither CoreML nor a Python runtime — only this file's
logic and the feature contract in ``backend/features.py``.

Degradation is deliberate: if the model file is absent or its schema does not
match ``features.FEATURE_SCHEMA_VERSION``, ``load_default()`` returns None and the
parser stays on its heuristic path. A stale model is worse than no model, because
feature order is positional — vector slot 12 meaning something different than it
did at training time yields confident nonsense, not an error.
"""
from __future__ import annotations

import json
import logging
import struct
from pathlib import Path
from typing import List, Optional, Sequence, Tuple

logger = logging.getLogger(__name__)

_F32 = struct.Struct("f")


def _to_float32(x: float) -> float:
    """Round a double to float32 precision.

    scikit-learn's tree traversal casts the feature matrix to float32 (its
    internal DTYPE) while thresholds stay float64. Comparing an unrounded double
    against those thresholds therefore takes the opposite branch whenever a value
    sits between the float32 and float64 representations — which happened in
    exactly 1 tree of 120 and produced ~5e-3 of confidence error before this was
    matched. Any reimplementation (Swift included) must do the same: compare in
    32-bit, not 64-bit.
    """
    return _F32.unpack(_F32.pack(x))[0]

_DEFAULT_PATH = Path(__file__).parent.parent / "ml" / "models" / "script_element_classifier.json"


class ScriptElementClassifier:
    """A random forest evaluated in pure Python."""

    def __init__(self, payload: dict):
        self.classes: List[str] = payload["classes"]
        self.feature_names: List[str] = payload["feature_names"]
        self.schema_version: int = payload.get("schema_version", 0)
        self.confidence_threshold: Optional[float] = payload.get("confidence_threshold")
        self.trained_on: List[str] = payload.get("trained_on", [])
        self._trees = [
            (t["l"], t["r"], t["f"], t["t"], t["v"]) for t in payload["trees"]
        ]
        self._n_classes = len(self.classes)

    # -- loading ----------------------------------------------------------

    @classmethod
    def load(cls, path: Path | str) -> "ScriptElementClassifier":
        with open(path, encoding="utf-8") as f:
            return cls(json.load(f))

    @classmethod
    def load_default(cls, expected_schema: Optional[int] = None
                     ) -> Optional["ScriptElementClassifier"]:
        """Load the shipped model, or None if unavailable/stale.

        Never raises: a missing or mismatched model must degrade to the heuristic
        parser, not break parsing.
        """
        if not _DEFAULT_PATH.exists():
            logger.debug("No element classifier at %s — heuristic path only", _DEFAULT_PATH)
            return None
        try:
            model = cls.load(_DEFAULT_PATH)
        except (json.JSONDecodeError, OSError, KeyError) as exc:
            logger.warning("Element classifier unreadable (%s) — using heuristics", exc)
            return None
        if expected_schema is not None and model.schema_version != expected_schema:
            logger.warning(
                "Element classifier is schema v%s but features.py is v%s — refusing "
                "to load. Feature order is positional, so a stale model produces "
                "confident nonsense rather than an error. Retrain with "
                "`python ml/train_element_classifier.py`.",
                model.schema_version, expected_schema)
            return None
        return model

    # -- inference --------------------------------------------------------

    def predict_proba(self, vector: Sequence[float]) -> List[float]:
        """Mean of per-tree leaf distributions."""
        # Cast once, mirroring scikit-learn casting X to float32 before traversal.
        v = [_to_float32(x) for x in vector]
        totals = [0.0] * self._n_classes
        for left, right, feat, thresh, value in self._trees:
            node = 0
            # Leaves have children == -1 in scikit-learn's array layout.
            while left[node] != -1:
                node = left[node] if v[feat[node]] <= thresh[node] else right[node]
            leaf = value[node]
            for i in range(self._n_classes):
                totals[i] += leaf[i]
        n = len(self._trees)
        return [t / n for t in totals]

    def predict(self, vector: Sequence[float]) -> Tuple[str, float]:
        """Return (kind, confidence). Confidence is the winning class's mean probability."""
        proba = self.predict_proba(vector)
        best = max(range(self._n_classes), key=proba.__getitem__)
        return self.classes[best], proba[best]

    def predict_features(self, feat) -> Tuple[str, float]:
        """Convenience wrapper for a ``features.BlockFeatures``."""
        return self.predict(feat.to_vector())

    def __repr__(self) -> str:
        return (f"ScriptElementClassifier(schema=v{self.schema_version}, "
                f"{len(self._trees)} trees, {self._n_classes} classes, "
                f"threshold={self.confidence_threshold})")
