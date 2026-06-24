#!/usr/bin/env python3
"""Diagnostic tool: run the LIVE block parser against a PDF and report what comes out.

This targets the production path (`_extract_blocks` → `_infer_layout_profile` →
`_classify_blocks`), the same path `parse_pdf()` uses. (The old version of this
script diagnosed the now-dead pdfplumber spatial path, which never runs when
PyMuPDF is installed.)

Usage:
    .venv/bin/python3 scripts/diagnose_parse.py path/to/script.pdf [options]

    --full        Print every classified block (very verbose)
    --narrator    Print only no-speaker dialog blocks (the bug signal)
    --page N      Only show blocks from page N (0-based)
    --profile     Show the inferred layout profile + x-bucket distribution
"""
import argparse
import os
import sys
from collections import Counter

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "backend"))
import parser as p  # noqa: E402


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("pdf", help="Path to PDF")
    ap.add_argument("--full", action="store_true", help="Print every classified block")
    ap.add_argument("--narrator", action="store_true", help="Show only no-speaker dialog blocks")
    ap.add_argument("--page", type=int, default=None, help="Filter to page N (0-based)")
    ap.add_argument("--profile", action="store_true", help="Show layout profile + x-buckets")
    args = ap.parse_args()

    pdf_path = os.path.expanduser(args.pdf)
    if not os.path.exists(pdf_path):
        print(f"ERROR: file not found: {pdf_path}", file=sys.stderr)
        sys.exit(1)

    print(f"\n{'='*70}")
    print(f"PDF: {os.path.basename(pdf_path)}")
    print(f"{'='*70}\n")

    # --- Extract blocks (live PyMuPDF path) ---
    print("Extracting blocks (PyMuPDF)...")
    blocks = p._extract_blocks(pdf_path)
    if not blocks:
        print("  ERROR: no blocks — PyMuPDF not installed? (the live path is unavailable)")
        sys.exit(1)
    blocks = p._merge_open_parentheticals(blocks)
    print(f"  {len(blocks)} blocks extracted")

    # --- Build the document model (cast lexicon + columns + layout profile) ---
    page_widths = [b.x1 for b in blocks if b.x1 > 200]
    page_width = max(page_widths) + 90.0 if page_widths else 612.0
    model = p._build_document_model(blocks, page_width=page_width)
    profile = model.profile
    print(f"  Profile: speaker_x={profile.speaker_x:.0f}  dialog_x={profile.dialog_x:.0f}  "
          f"stage_dir_x={profile.stage_dir_x if profile.stage_dir_x is None else round(profile.stage_dir_x)}  "
          f"split_layout={profile.is_split_layout}")
    top_cast = sorted(model.cast, key=lambda n: -model.cast_lexicon[n])
    print(f"  Cast ({len(model.cast)}): " + ", ".join(f"{n}({model.cast_lexicon[n]})" for n in top_cast[:16]))
    print(f"  cue_columns={model.cue_columns}  dialog_columns={model.dialog_columns}")

    if args.profile:
        bucket_counts = Counter(round(b.x0 / 5) * 5 for b in blocks)
        print("  Top x-buckets (pt, count, mean caps):")
        for xb, n in sorted(bucket_counts.items(), key=lambda kv: -kv[1])[:12]:
            caps = [b.caps_ratio for b in blocks if round(b.x0 / 5) * 5 == xb]
            print(f"    x={xb:6.0f}  n={n:4d}  caps={sum(caps)/len(caps):.2f}")
    print()

    # --- Classify ---
    classified = p._classify_blocks(blocks, model)
    if args.page is not None:
        classified = [cb for cb in classified if cb.block.page == args.page]
        print(f"Filtered to page {args.page}: {len(classified)} blocks\n")

    # --- Role summary ---
    role_counts = Counter(cb.role for cb in classified)
    print("Role counts:")
    for role, n in sorted(role_counts.items(), key=lambda kv: -kv[1]):
        print(f"  {role:20s} {n}")
    print()

    # --- Speaker summary ---
    dialog = [cb for cb in classified if cb.role == "dialog"]
    speaker_counts = Counter(cb.speaker or "(no speaker)" for cb in dialog)
    print(f"Dialog blocks: {len(dialog)} total")
    print("By speaker:")
    for spk, n in sorted(speaker_counts.items(), key=lambda kv: -kv[1]):
        marker = "  *** UNATTRIBUTED ***" if spk == "(no speaker)" else ""
        print(f"  {spk:30s} {n:4d}{marker}")
    print()

    # --- Unattributed dialog (the bug signal) ---
    no_speaker = [cb for cb in dialog if not cb.speaker]
    if no_speaker:
        print(f"{'!'*70}")
        print(f"  {len(no_speaker)} UNATTRIBUTED dialog block(s):")
        print(f"{'!'*70}")
        for cb in no_speaker:
            idx = classified.index(cb)
            for ctx in classified[max(0, idx - 4):idx + 1]:
                arrow = " >>>" if ctx is cb else "    "
                spk = ctx.speaker or ""
                print(f"{arrow} p{ctx.block.page:02d} x={ctx.block.x0:6.0f} "
                      f"[{ctx.role:15s}] [{spk:20s}] {ctx.block.text[:60]}")
            print()
    else:
        print("No unattributed dialog blocks. Parser looks clean.")
        print()

    # --- Full / narrator dump ---
    if args.full or args.narrator:
        target = no_speaker if args.narrator else classified
        print(f"\n{'-'*70}")
        print("FULL BLOCK DUMP:" if args.full else "UNATTRIBUTED BLOCKS:")
        print(f"{'-'*70}")
        for cb in target:
            spk = cb.speaker or ""
            print(f"p{cb.block.page:02d} x={cb.block.x0:6.0f} "
                  f"[{cb.role:15s}] [{spk:20s}] {cb.block.text[:70]}")


if __name__ == "__main__":
    main()
