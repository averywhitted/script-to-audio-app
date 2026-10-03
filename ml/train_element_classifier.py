#!/usr/bin/env python3
"""train_element_classifier.py — train, honestly evaluate, and export the model.

Trains a random forest on ml/data/dataset.csv and exports it as PLAIN JSON, not
CoreML or a pickle. That choice is load-bearing:

  * The shipped app runs the parser on the bundled CPython 3.12 in vendor/python.
    Requiring scikit-learn at inference time would add ~100 MB (scipy included) to
    the app bundle for what is arithmetic over decision trees.
  * coremltools cannot help here anyway — v9 caps scikit-learn at 1.5.1 (we need
    the current release) and ships no binary wheels for the 3.14 dev interpreter.
  * A random forest is an average of leaf distributions. Evaluating it is ~100
    lines with no dependencies, in Python OR in Swift — so the iOS port needs
    neither scikit-learn nor CoreML, just this JSON and the feature contract.

``backend/element_classifier.py`` holds the pure-Python evaluator; --check-parity
asserts it reproduces scikit-learn's predictions exactly, so the dependency-free
runtime is not a re-implementation anyone has to take on faith.

EVALUATION — leave-one-script-out, always.
Training and testing on the same 7 scripts would report a memorised score. Each
fold trains on 6 scripts and tests on the 7th, which is the only number here that
estimates behaviour on a script the model has never seen.

Usage:
  python ml/train_element_classifier.py            # LOSO evaluation + export
  python ml/train_element_classifier.py --eval-only
  python ml/train_element_classifier.py --check-parity
"""
from __future__ import annotations

import json
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).parent.parent
sys.path.insert(0, str(ROOT / "backend"))

import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402
from sklearn.ensemble import RandomForestClassifier  # noqa: E402
from sklearn.metrics import classification_report, confusion_matrix  # noqa: E402

import features as F  # noqa: E402

DATA = ROOT / "ml" / "data" / "dataset.csv"
MODEL_DIR = ROOT / "ml" / "models"
MODEL_JSON = MODEL_DIR / "script_element_classifier.json"

# Kept deliberately modest: deeper/wider forests inflate the exported JSON (which
# ships in the app) for negligible gain on 21k rows of low-dimensional features.
FOREST_KWARGS = dict(
    n_estimators=120,
    max_depth=14,
    min_samples_leaf=4,
    class_weight="balanced",   # parenthetical is 0.9% of rows; without this the
                               # model can score well by never predicting it
    random_state=42,
    n_jobs=-1,
)


def load() -> pd.DataFrame:
    if not DATA.exists():
        raise SystemExit(f"No dataset at {DATA}. Run: python ml/build_dataset.py")
    df = pd.read_csv(DATA)
    missing = [c for c in F.FEATURE_NAMES if c not in df.columns]
    if missing:
        raise SystemExit(
            f"Dataset is missing {len(missing)} feature columns (e.g. {missing[:3]}). "
            "It was probably built against a different FEATURE_SCHEMA_VERSION — "
            "rebuild with `python ml/build_dataset.py`.")
    return df


def loso_evaluate(df: pd.DataFrame) -> dict:
    """Leave-one-script-out cross-validation — the headline number."""
    X = df[list(F.FEATURE_NAMES)].to_numpy(dtype=np.float64)
    y = df["label"].to_numpy()
    groups = df["script"].to_numpy()
    scripts = sorted(set(groups))

    all_true, all_pred, all_conf, all_script = [], [], [], []
    per_script = {}

    print(f"{'='*72}\nLEAVE-ONE-SCRIPT-OUT CROSS-VALIDATION\n{'='*72}")
    print(f"{'held-out script':<22}{'train n':>9}{'test n':>8}{'accuracy':>10}")
    for s in scripts:
        te = groups == s
        tr = ~te
        clf = RandomForestClassifier(**FOREST_KWARGS).fit(X[tr], y[tr])
        proba = clf.predict_proba(X[te])
        pred = clf.classes_[proba.argmax(axis=1)]
        conf = proba.max(axis=1)
        acc = (pred == y[te]).mean()
        per_script[s] = acc
        print(f"{s:<22}{tr.sum():>9,}{te.sum():>8,}{acc*100:>9.1f}%")
        all_true.extend(y[te]); all_pred.extend(pred)
        all_conf.extend(conf); all_script.extend([s] * te.sum())

    all_true = np.array(all_true); all_pred = np.array(all_pred)
    all_conf = np.array(all_conf)
    overall = (all_true == all_pred).mean()
    print(f"{'-'*49}\n{'MEAN (per-script)':<22}{'':>9}{'':>8}"
          f"{np.mean(list(per_script.values()))*100:>9.1f}%")
    print(f"{'POOLED':<22}{'':>9}{len(all_true):>8,}{overall*100:>9.1f}%")

    print(f"\n{'='*72}\nPER-CLASS (pooled across folds)\n{'='*72}")
    print(classification_report(all_true, all_pred, zero_division=0, digits=3))

    labels = sorted(set(all_true) | set(all_pred))
    cm = confusion_matrix(all_true, all_pred, labels=labels)
    print(f"{'='*72}\nCONFUSION MATRIX  (rows = true, cols = predicted)\n{'='*72}")
    print(f"{'':<18}" + "".join(f"{l[:9]:>11}" for l in labels))
    for i, l in enumerate(labels):
        print(f"{l:<18}" + "".join(f"{cm[i][j]:>11,}" for j in range(len(labels))))

    return {
        "true": all_true, "pred": all_pred, "conf": all_conf,
        "script": np.array(all_script), "per_script": per_script,
        "overall": overall, "labels": labels,
    }


def calibration_report(res: dict) -> float | None:
    """Does low confidence actually predict wrongness?

    This is a GATE, not a diagnostic. The whole point of surfacing confidence in
    the Review UI is to send the user to lines that are likely wrong. If accuracy
    is flat across confidence bins, the flag is noise that teaches people to
    ignore warnings, and it should not ship.

    Returns a suggested threshold, or None if confidence is not usable.
    """
    conf, correct = res["conf"], res["true"] == res["pred"]
    print(f"\n{'='*72}\nCONFIDENCE CALIBRATION\n{'='*72}")
    print(f"{'confidence bin':<18}{'n':>9}{'accuracy':>11}{'cumulative <= hi':>19}")

    edges = [0.0, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.95, 1.01]
    rows = []
    for lo, hi in zip(edges, edges[1:]):
        m = (conf >= lo) & (conf < hi)
        if not m.any():
            continue
        below = conf < hi
        rows.append((lo, hi, m.sum(), correct[m].mean(), correct[below].mean()))
        print(f"{f'{lo:.2f}–{hi:.2f}':<18}{m.sum():>9,}{correct[m].mean()*100:>10.1f}%"
              f"{correct[below].mean()*100:>18.1f}%")

    lo_acc = correct[conf < 0.7].mean() if (conf < 0.7).any() else float("nan")
    hi_acc = correct[conf >= 0.9].mean() if (conf >= 0.9).any() else float("nan")
    lift = hi_acc - lo_acc
    print(f"\n  accuracy at conf < 0.70 : {lo_acc*100:.1f}%")
    print(f"  accuracy at conf >= 0.90: {hi_acc*100:.1f}%")
    print(f"  separation              : {lift*100:.1f} points")

    if not (lift > 0.10):
        print("\n  ✗ GATE FAILED — confidence barely separates right from wrong.")
        print("    Do NOT ship the review-flagging UI on this signal; it would send")
        print("    users to arbitrary lines and train them to ignore the warning.")
        return None

    # Pick the threshold that flags the fewest lines while still catching a
    # majority of the errors — a flag nobody can act on is worthless.
    total_err = (~correct).sum()
    best = None
    for _, hi, _, _, _ in rows:
        flagged = conf < hi
        if not flagged.any():
            continue
        caught = (~correct & flagged).sum()
        precision = caught / flagged.sum()
        recall = caught / total_err if total_err else 0.0
        if recall >= 0.5 and (best is None or precision > best[1]):
            best = (hi, precision, recall, flagged.mean())
    print("\n  ✓ GATE PASSED — low confidence predicts misclassification.")
    if best:
        hi, prec, rec, frac = best
        print(f"    suggested threshold {hi:.2f}: flags {frac*100:.1f}% of lines, "
              f"{prec*100:.0f}% of flagged are actually wrong, catching {rec*100:.0f}% of all errors")
        return hi
    print("    (no threshold catches >=50% of errors; flag sparingly)")
    return None


def export_json(df: pd.DataFrame, threshold: float | None) -> RandomForestClassifier:
    """Fit on ALL scripts and export the forest as dependency-free JSON."""
    X = df[list(F.FEATURE_NAMES)].to_numpy(dtype=np.float64)
    y = df["label"].to_numpy()
    clf = RandomForestClassifier(**FOREST_KWARGS).fit(X, y)

    trees = []
    for est in clf.estimators_:
        t = est.tree_
        # value is (n_nodes, 1, n_classes) of (weighted) class counts; normalise
        # each node to a distribution, which is what predict_proba averages.
        v = t.value.reshape(t.node_count, -1).astype(np.float64)
        totals = v.sum(axis=1, keepdims=True)
        probs = np.divide(v, totals, out=np.zeros_like(v), where=totals > 0)
        trees.append({
            "l": t.children_left.tolist(),
            "r": t.children_right.tolist(),
            "f": t.feature.tolist(),
            # Thresholds are stored at FULL double precision, deliberately.
            # Rounding them to 6dp lets a feature value sitting within 1e-6 of a
            # split take the wrong branch; one flipped branch swaps that tree's
            # whole leaf distribution, which across 120 trees is ~8e-3 of
            # confidence error per flip. Measured 1.5e-2 before this was fixed.
            "t": t.threshold.tolist(),
            # Leaf distributions only shift the averaged probability, so rounding
            # them is safe and keeps the file materially smaller.
            "v": [[round(x, 6) for x in row] for row in probs.tolist()],
        })

    payload = {
        "schema_version": F.FEATURE_SCHEMA_VERSION,
        "model_type": "random_forest",
        "classes": clf.classes_.tolist(),
        "feature_names": list(F.FEATURE_NAMES),
        "confidence_threshold": threshold,
        "n_trees": len(trees),
        "trained_on": sorted(set(df["script"])),
        "n_rows": int(len(df)),
        "note": (
            "Evaluate as: mean of per-tree leaf distributions, argmax = class, "
            "max = confidence. Leaf nodes have children == -1. Feature order is "
            "feature_names and is part of the contract."
        ),
        "trees": trees,
    }

    MODEL_DIR.mkdir(parents=True, exist_ok=True)
    MODEL_JSON.write_text(json.dumps(payload, separators=(",", ":")), encoding="utf-8")
    size_mb = MODEL_JSON.stat().st_size / 1e6
    print(f"\nExported → {MODEL_JSON.relative_to(ROOT)} "
          f"({len(trees)} trees, {size_mb:.1f} MB, schema v{F.FEATURE_SCHEMA_VERSION})")
    return clf


def check_parity(df: pd.DataFrame, sk: RandomForestClassifier | None = None) -> int:
    """Assert the pure-Python evaluator matches scikit-learn exactly.

    ``sk`` must be the SAME fitted estimator that was exported. Re-fitting a
    second forest here and comparing against it tests that two fits agree, not
    that the JSON round-trip is faithful — which is the actual claim being made.
    """
    from element_classifier import ScriptElementClassifier

    if not MODEL_JSON.exists():
        raise SystemExit("No exported model. Run without --check-parity first.")
    clf_json = ScriptElementClassifier.load(MODEL_JSON)

    X = df[list(F.FEATURE_NAMES)].to_numpy(dtype=np.float64)
    if sk is None:
        # Standalone invocation: refit with the same seed and data. Determinism
        # comes from random_state, so this reproduces the exported forest.
        sk = RandomForestClassifier(**FOREST_KWARGS).fit(X, df["label"].to_numpy())

    n = min(3000, len(X))
    rng = np.random.default_rng(0)
    idx = rng.choice(len(X), n, replace=False)

    sk_proba = sk.predict_proba(X[idx])
    sk_pred = sk.classes_[sk_proba.argmax(axis=1)]

    mismatches = 0
    max_dp = 0.0
    for k, i in enumerate(idx):
        kind, conf = clf_json.predict(X[i].tolist())
        if kind != sk_pred[k]:
            mismatches += 1
        max_dp = max(max_dp, abs(conf - sk_proba[k].max()))

    print(f"\n{'='*72}\nPARITY: pure-Python evaluator vs scikit-learn\n{'='*72}")
    print(f"  samples checked        : {n:,}")
    print(f"  label mismatches       : {mismatches}")
    print(f"  max confidence delta   : {max_dp:.2e}")
    if mismatches or max_dp > 1e-6:
        print("  ✗ FAIL — the runtime evaluator does not reproduce the trained model.")
        return 1
    print("  ✓ PASS — runtime inference is exact; no scikit-learn needed to ship.")
    return 0


def main() -> int:
    args = sys.argv[1:]
    df = load()
    print(f"Dataset: {len(df):,} rows, {len(F.FEATURE_NAMES)} features, "
          f"{df['script'].nunique()} scripts")
    print("Class balance: " + ", ".join(
        f"{k}={v:,}" for k, v in Counter(df["label"]).most_common()))

    if "--check-parity" in args:
        return check_parity(df)

    res = loso_evaluate(df)
    threshold = calibration_report(res)

    if "--eval-only" in args:
        print("\n(--eval-only: no model exported)")
        return 0

    clf = export_json(df, threshold)
    return check_parity(df, clf)


if __name__ == "__main__":
    sys.exit(main())
