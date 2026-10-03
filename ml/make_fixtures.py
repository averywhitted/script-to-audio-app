#!/usr/bin/env python3
"""make_fixtures.py — golden feature fixtures, the iOS portability contract.

Writes ``ml/fixtures/{Name}_features.json`` for every corpus script. A future
Swift/PDFKit extractor is correct if and only if it reproduces these numbers for
the same PDFs — which is what lets extraction be reimplemented on a platform that
cannot run Python, without reimplementing (or trusting) anything else.

Each fixture holds:
  * a SHA-256 digest over every block's full feature vector — catches any drift
    anywhere in the document, including blocks the sample skips;
  * a deterministic 200-block sample with full per-feature values — so a mismatch
    can be diagnosed feature-by-feature instead of just "the hash differs".

Storing all ~2,800 blocks × 45 features × 7 scripts verbatim would be ~15 MB of
JSON; the digest gives full coverage at a fraction of that.

Usage:
  python ml/make_fixtures.py              # regenerate all
  python ml/make_fixtures.py TheHarvest   # one script
  python ml/make_fixtures.py --check      # verify without writing (exit 1 on drift)
"""
from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).parent.parent
sys.path.insert(0, str(ROOT / "backend"))
sys.path.insert(0, str(ROOT / "scripts"))

import features as F  # noqa: E402

OUT_DIR = ROOT / "ml" / "fixtures"
PDF_DIR = ROOT / "Test PDFs"

# Reuse the scorecard's corpus so the two can never disagree about what's in it.
from scorecard import CASES, _sig  # noqa: E402

SAMPLE_SIZE = 200
_ROUND = 6


def _vec(feat) -> list[float]:
    return [round(v, _ROUND) for v in feat.to_vector()]


def _digest(vectors: list[list[float]]) -> str:
    h = hashlib.sha256()
    for v in vectors:
        h.update(",".join(f"{x:.6f}" for x in v).encode())
        h.update(b"\n")
    return h.hexdigest()


def _sample_indices(n: int) -> list[int]:
    """First 50 blocks (front matter / title page) plus an even spread."""
    if n <= SAMPLE_SIZE:
        return list(range(n))
    head = list(range(50))
    step = max(1, (n - 50) // (SAMPLE_SIZE - 50))
    spread = list(range(50, n, step))[: SAMPLE_SIZE - 50]
    return sorted(set(head + spread))


def build(name: str, pdf_name: str) -> dict | None:
    pdf_path = PDF_DIR / pdf_name
    if not pdf_path.exists():
        print(f"  SKIP {name}: PDF not found")
        return None

    doc = F.features_for_pdf(str(pdf_path))
    vectors = [_vec(f) for f in doc.features]
    idxs = _sample_indices(len(vectors))

    return {
        "_meta": {
            "source_pdf": pdf_name,
            "schema_version": F.FEATURE_SCHEMA_VERSION,
            "block_count": len(vectors),
            "note": (
                "Golden feature fixture. A reimplemented extractor (e.g. Swift/PDFKit) "
                "is correct iff it reproduces full_digest for this PDF. The sample is "
                "for diagnosing WHICH feature drifted when it does not."
            ),
        },
        "feature_names": list(F.FEATURE_NAMES),
        "document_context": {
            "page_width": round(doc.context.page_width, _ROUND),
            "page_height": round(doc.context.page_height, _ROUND),
            "median_font_size": round(doc.context.median_font_size, _ROUND),
        },
        "layout_profile": {
            "speaker_x": round(doc.profile.speaker_x, _ROUND),
            "dialog_x": round(doc.profile.dialog_x, _ROUND),
            "stage_dir_x": (round(doc.profile.stage_dir_x, _ROUND)
                            if doc.profile.stage_dir_x is not None else None),
        },
        "full_digest": _digest(vectors),
        "sample": [
            {"index": i, "sig": _sig(doc.blocks[i].text), "features": vectors[i]}
            for i in idxs
        ],
    }


def main() -> int:
    args = sys.argv[1:]
    check_only = "--check" in args
    names = [a for a in args if not a.startswith("--")]
    cases = [(n, p) for n, p in CASES if not names or n in names]

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    drift = []

    for name, pdf_name in cases:
        fixture = build(name, pdf_name)
        if fixture is None:
            continue
        path = OUT_DIR / f"{name}_features.json"

        if check_only:
            if not path.exists():
                drift.append(f"  {name}: no fixture yet")
                continue
            prev = json.loads(path.read_text(encoding="utf-8"))
            if prev.get("_meta", {}).get("schema_version") != F.FEATURE_SCHEMA_VERSION:
                drift.append(
                    f"  {name}: schema v{prev.get('_meta', {}).get('schema_version')} "
                    f"→ v{F.FEATURE_SCHEMA_VERSION} (expected after a feature change; "
                    f"regenerate)")
            elif prev.get("full_digest") != fixture["full_digest"]:
                drift.append(f"  {name}: feature digest changed ({prev.get('block_count')} blocks)")
            else:
                print(f"  OK  {name}: {fixture['_meta']['block_count']} blocks, digest matches")
            continue

        path.write_text(json.dumps(fixture, indent=2), encoding="utf-8")
        print(f"  OK  {name}: {fixture['_meta']['block_count']} blocks "
              f"→ {path.name} (digest {fixture['full_digest'][:12]}…)")

    if drift:
        print("\n✗ Feature drift vs fixtures:")
        print("\n".join(drift))
        print("\nIf intentional (you changed features.py), bump FEATURE_SCHEMA_VERSION")
        print("and re-run `python ml/make_fixtures.py` — then RETRAIN, because any")
        print("existing model was fitted to the old vector layout.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
