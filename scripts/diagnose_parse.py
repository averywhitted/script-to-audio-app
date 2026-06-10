#!/usr/bin/env python3
"""Diagnostic tool: run the spatial parser against a PDF and report what comes out.

Usage:
    .venv/bin/python3 scripts/diagnose_parse.py path/to/script.pdf [--full]

    --full    Print every classified line (very verbose)
    --zones   Print zone detection detail
    --page N  Only show lines from page N (0-based)
"""
import sys
import os
import argparse
from collections import Counter, defaultdict

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "backend"))
import parser as p  # noqa: E402


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("pdf", help="Path to PDF")
    ap.add_argument("--full", action="store_true", help="Print every classified line")
    ap.add_argument("--zones", action="store_true", help="Show zone detection detail")
    ap.add_argument("--page", type=int, default=None, help="Filter to page N (0-based)")
    ap.add_argument("--narrator", action="store_true", help="Show only no-speaker dialog lines")
    args = ap.parse_args()

    pdf_path = os.path.expanduser(args.pdf)
    if not os.path.exists(pdf_path):
        print(f"ERROR: file not found: {pdf_path}", file=sys.stderr)
        sys.exit(1)

    print(f"\n{'='*70}")
    print(f"PDF: {os.path.basename(pdf_path)}")
    print(f"{'='*70}\n")

    # --- Extract structured lines ---
    print("Extracting lines from PDF...")
    lines = p._extract_structured_lines(pdf_path)
    print(f"  {len(lines)} structured lines extracted")

    # --- Infer layout zones ---
    zones = p._infer_layout_zones(lines)
    if zones is None:
        print("  WARNING: zone detection failed — no bimodal x-distribution found")
    else:
        print(f"  Zones: dialog_x={zones.dialog_x:.1f}  cue_x={zones.cue_x:.1f}  "
              f"threshold={zones.threshold:.1f}  scene_heading_x={zones.scene_heading_x}")
        if args.zones:
            from collections import Counter as C
            bucket_counts = C(round(float(sl.x or 0) / 5) * 5
                              for sl in lines if sl.x is not None and sl.text)
            top = sorted(bucket_counts.items(), key=lambda kv: -kv[1])[:10]
            print("  Top x-buckets (pt, count):")
            for b, c in top:
                print(f"    x={b:6.1f}  n={c}")

    print()

    # --- Classify ---
    classified = p._classify_lines(lines, zones=zones)

    # Filter to page if requested
    if args.page is not None:
        classified = [cl for cl in classified if cl.line.page == args.page]
        print(f"Filtered to page {args.page}: {len(classified)} lines\n")

    # --- Role summary ---
    role_counts = Counter(cl.role for cl in classified)
    print("Role counts:")
    for role, n in sorted(role_counts.items(), key=lambda kv: -kv[1]):
        print(f"  {role:20s} {n}")
    print()

    # --- Speaker summary ---
    dialog_lines = [cl for cl in classified if cl.role == "dialog"]
    speaker_counts: Counter = Counter(cl.speaker or "(no speaker)" for cl in dialog_lines)
    print(f"Dialog lines: {len(dialog_lines)} total")
    print("By speaker:")
    for spk, n in sorted(speaker_counts.items(), key=lambda kv: -kv[1]):
        marker = "  *** NARRATOR/UNATTRIBUTED ***" if spk == "(no speaker)" else ""
        print(f"  {spk:30s} {n:4d}{marker}")
    print()

    # --- Narrator / unattributed lines ---
    no_speaker = [cl for cl in dialog_lines if not cl.speaker]
    if no_speaker:
        print(f"{'!'*70}")
        print(f"  {len(no_speaker)} UNATTRIBUTED (narrator) dialog line(s):")
        print(f"{'!'*70}")
        for cl in no_speaker:
            idx = classified.index(cl)
            context = classified[max(0, idx - 4):idx + 1]
            print()
            for ctx in context:
                arrow = " >>>" if ctx is cl else "    "
                spk = ctx.speaker or ""
                print(f"{arrow} p{ctx.line.page:02d} x={str(ctx.line.x or ''):6s} "
                      f"[{ctx.role:15s}] [{spk:20s}] {ctx.line.text[:60]}")
        print()
    else:
        print("No unattributed (narrator) dialog lines. Parser looks clean.")
        print()

    # --- Full dump ---
    if args.full or args.narrator:
        target = no_speaker if args.narrator else classified
        print(f"\n{'─'*70}")
        print("FULL LINE DUMP:" if args.full else "NARRATOR LINES:")
        print(f"{'─'*70}")
        for cl in target:
            spk = cl.speaker or ""
            pb = " [PAGE BREAK]" if cl.line.is_page_break else ""
            print(f"p{cl.line.page:02d} x={str(cl.line.x or ''):6s} "
                  f"[{cl.role:15s}] [{spk:20s}] {cl.line.text[:70]}{pb}")

    # --- Page-break attribution audit ---
    print(f"\n{'─'*70}")
    print("Page-break attribution audit (last speaker before / first dialog after):")
    print(f"{'─'*70}")
    pb_indices = [i for i, cl in enumerate(classified) if cl.line.is_page_break]
    for pb_idx in pb_indices:
        # last dialog/speaker before break
        before = [(i, cl) for i, cl in enumerate(classified[:pb_idx])
                  if cl.role in ("dialog", "speaker_cue")]
        after = [(i, cl) for i, cl in enumerate(classified[pb_idx:], start=pb_idx)
                 if cl.role in ("dialog", "speaker_cue")]
        last_spk = before[-1][1].speaker if before else None
        first_after = after[0][1] if after else None
        first_spk = first_after.speaker if first_after else None
        match = "✓" if last_spk and first_spk and last_spk == first_spk else (
                "→" if first_spk and last_spk != first_spk else "?")
        page = classified[pb_idx].line.page
        print(f"  page {page:2d}→{page+1:<2d}  before={str(last_spk or '?'):20s}  "
              f"after={str(first_spk or '?'):20s}  {match}")


if __name__ == "__main__":
    main()
