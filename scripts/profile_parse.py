#!/usr/bin/env python3
"""
profile_parse.py — parse-time profiler for parse_pdf().

Usage:
    python scripts/profile_parse.py "Test PDFs/4.10.24_Stereophonic (2).pdf"
    python scripts/profile_parse.py "Test PDFs/TheHarvest(3.0).pdf"

Prints two views:
  1. Per-phase exclusive wall-clock times for each top-level stage inside
     parse_pdf: derive_title / extract_blocks / merge_open_parentheticals /
     build_document_model / classify_blocks / build_script_from_blocks.
  2. cProfile top-30 rows (cumulative order) to show which internal helpers
     consume the most time.

Does NOT modify backend/parser.py.
"""
from __future__ import annotations

import cProfile
import io
import pstats
import sys
import time
from pathlib import Path
from typing import Any

ROOT = Path(__file__).parent.parent
sys.path.insert(0, str(ROOT / "backend"))

import parser as _parser  # noqa: E402

# ---------------------------------------------------------------------------
# Accumulated phase results (filled by the instrumented _block_parse)
# ---------------------------------------------------------------------------

_phases: list[tuple[str, float]] = []   # (phase_name, exclusive_seconds)
_meta: dict[str, Any] = {}              # block_count, etc.


# ---------------------------------------------------------------------------
# Patch _block_parse and _derive_title to collect per-stage timing
# ---------------------------------------------------------------------------

_orig_block_parse  = _parser._block_parse
_orig_derive_title = _parser._derive_title


def _instrumented_parse_pdf(pdf_path: str):
    """Replaces parse_pdf() with an instrumented version that records phases."""
    _phases.clear()
    _meta.clear()

    # ── _derive_title ────────────────────────────────────────────────────
    t0 = time.perf_counter()
    title = _orig_derive_title(pdf_path)
    _phases.append(("derive_title (pdfplumber)", time.perf_counter() - t0))

    # Load corrections config (fast, but measure it for completeness)
    t0 = time.perf_counter()
    config = _parser._load_corrections_config()
    _phases.append(("load_corrections_config", time.perf_counter() - t0))

    # Verify fitz available
    try:
        import fitz
    except ImportError:
        raise RuntimeError("PyMuPDF (fitz) required")

    # ── _extract_blocks ──────────────────────────────────────────────────
    t0 = time.perf_counter()
    blocks = _parser._extract_blocks(pdf_path)
    _phases.append(("extract_blocks (PyMuPDF)", time.perf_counter() - t0))

    if not blocks:
        raise RuntimeError("No text extracted from this PDF.")

    _meta["block_count"] = len(blocks)

    # ── _merge_open_parentheticals ───────────────────────────────────────
    t0 = time.perf_counter()
    blocks = _parser._merge_open_parentheticals(blocks)
    _phases.append(("merge_open_parentheticals", time.perf_counter() - t0))

    page_widths = [b.x1 for b in blocks if b.x1 > 200]
    page_width = max(page_widths) + 90.0 if page_widths else 612.0

    # ── _build_document_model ────────────────────────────────────────────
    t0 = time.perf_counter()
    model = _parser._build_document_model(blocks, page_width=page_width)
    _phases.append(("build_document_model", time.perf_counter() - t0))

    # ── _classify_blocks (includes _score_blocks internally) ─────────────
    t0 = time.perf_counter()
    classified = _parser._classify_blocks(blocks, model)
    _phases.append(("classify_blocks (incl. score_blocks)", time.perf_counter() - t0))

    # ── _build_script_from_blocks ────────────────────────────────────────
    t0 = time.perf_counter()
    result = _parser._build_script_from_blocks(
        classified, title=title, config=config, cast=model.cast
    )
    _phases.append(("build_script_from_blocks", time.perf_counter() - t0))

    if result is None:
        raise RuntimeError("Block parse returned None.")
    return result


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    if len(sys.argv) < 2:
        print("Usage: python scripts/profile_parse.py <pdf_path>")
        sys.exit(1)

    pdf_path = sys.argv[1]
    print(f"\nProfiling: {pdf_path}")
    print("=" * 65)

    # ── Run 1: phase-level timing ─────────────────────────────────────────
    t_start = time.perf_counter()
    script = _instrumented_parse_pdf(pdf_path)
    t_total = time.perf_counter() - t_start

    n_blocks = _meta.get("block_count", "?")
    n_scenes = len(script.scenes)
    n_els    = sum(len(s.elements) for s in script.scenes)

    print(f"\nScript : {script.title!r}")
    print(f"Metrics: {n_blocks} blocks → {n_els} elements in {n_scenes} scenes")
    print(f"Total  : {t_total:.3f} s\n")

    phases_sorted = sorted(_phases, key=lambda x: -x[1])

    print(f"{'Phase':<42} {'s':>8}  {'ms/block':>10}  {'%':>6}")
    print("-" * 72)
    nb = n_blocks if isinstance(n_blocks, int) else 1
    for name, dt in phases_sorted:
        pct  = 100 * dt / t_total if t_total else 0
        msb  = 1000 * dt / nb if nb else 0
        print(f"  {name:<40} {dt:>8.3f}  {msb:>10.4f}  {pct:>5.1f}%")
    print("-" * 72)
    measured = sum(dt for _, dt in _phases)
    unacct   = t_total - measured
    print(f"  {'(unaccounted — frame overhead)':<40} {unacct:>8.3f}  {'':>10}  "
          f"{100*unacct/t_total if t_total else 0:>5.1f}%")
    print()

    if phases_sorted:
        worst_name, worst_dt = phases_sorted[0]
        print(f">>> LIKELY BOTTLENECK: {worst_name}")
        print(f"    {worst_dt:.3f} s  ({100*worst_dt/t_total:.1f}% of total)\n")

    # ── Run 2: cProfile for function-level detail ─────────────────────────
    print("=" * 65)
    print("cProfile top-30 functions by cumulative time (2nd run):")
    print("=" * 65)

    pr = cProfile.Profile()
    pr.enable()
    _instrumented_parse_pdf(pdf_path)
    pr.disable()

    buf = io.StringIO()
    ps  = pstats.Stats(pr, stream=buf)
    ps.sort_stats("cumulative")
    ps.print_stats(30)
    raw = buf.getvalue()

    # Strip pstats boilerplate header, print from the column-header line
    for i, line in enumerate(raw.split("\n")):
        if "ncalls" in line:
            print("\n".join(raw.split("\n")[i:]))
            break
    else:
        print(raw)


if __name__ == "__main__":
    main()
