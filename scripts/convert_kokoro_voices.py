#!/usr/bin/env python3
"""
convert_kokoro_voices.py
========================

Converts Kokoro's voices-v1.0.bin (numpy npz, voices shaped [510, 1, 256])
into per-voice flat binary files readable by KokoroVoiceStore.swift.

Output format (.kokoro files):
  Bytes 0–3:   ASCII magic "KOKR"
  Byte  4:     Format version 0x01
  Bytes 5–6:   uint16 LE — row count (always 510)
  Bytes 7–8:   uint16 LE — column count (always 256)
  Bytes 9…:    float32 LE values, row-major (510 × 256 × 4 = 523,264 bytes)

Usage:
  python3 scripts/convert_kokoro_voices.py
  python3 scripts/convert_kokoro_voices.py --voices-bin /path/to/voices-v1.0.bin
  python3 scripts/convert_kokoro_voices.py --output-dir /path/to/output

The generated files should be placed in:
  ~/Library/Application Support/TableRead/kokoro-voices/
on the iOS device (or simulator), or bundled as on-demand resources.
"""

import argparse
import struct
import sys
from pathlib import Path

import numpy as np

DEFAULT_VOICES_BIN = Path.home() / ".cache" / "tableread" / "kokoro" / "voices-v1.0.bin"
DEFAULT_OUTPUT_DIR = Path.home() / "Library" / "Application Support" / "TableRead" / "kokoro-voices"

MAGIC = b"KOKR"
VERSION = 0x01


def convert(voices_bin: Path, output_dir: Path, voices: list[str] | None) -> None:
    if not voices_bin.exists():
        print(f"ERROR: voices file not found: {voices_bin}", file=sys.stderr)
        print("Download it first:", file=sys.stderr)
        print("  wget https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin", file=sys.stderr)
        sys.exit(1)

    output_dir.mkdir(parents=True, exist_ok=True)

    all_voices = np.load(voices_bin)
    names = list(all_voices.keys())

    if voices:
        names = [n for n in names if n in voices]
        missing = set(voices) - set(names)
        if missing:
            print(f"WARNING: requested voices not found in file: {sorted(missing)}")

    print(f"Converting {len(names)} voice(s) from {voices_bin.name} → {output_dir}")

    for name in sorted(names):
        arr = all_voices[name]  # shape (510, 1, 256), dtype float32
        if arr.ndim == 3 and arr.shape[1] == 1:
            arr = arr.squeeze(axis=1)   # → (510, 256)
        elif arr.ndim != 2 or arr.shape != (510, 256):
            print(f"  SKIP {name}: unexpected shape {arr.shape}")
            continue

        arr = arr.astype(np.float32)
        rows, cols = arr.shape

        header = (
            MAGIC
            + bytes([VERSION])
            + struct.pack("<H", rows)
            + struct.pack("<H", cols)
        )
        out_path = output_dir / f"{name}.kokoro"
        with open(out_path, "wb") as f:
            f.write(header)
            f.write(arr.tobytes())   # row-major float32 LE

        size_kb = out_path.stat().st_size // 1024
        print(f"  {name}.kokoro  ({size_kb} KB)")

    print(f"\nDone. {len(names)} file(s) written to {output_dir}")
    print("\nTo use on iOS Simulator, copy to:")
    print(f"  xcrun simctl get_app_container <device-id> com.yourcompany.TableRead data")
    print("  and place files in Library/Application Support/TableRead/kokoro-voices/")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--voices-bin", type=Path, default=DEFAULT_VOICES_BIN,
                        help=f"Path to voices-v1.0.bin (default: {DEFAULT_VOICES_BIN})")
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR,
                        help=f"Output directory (default: {DEFAULT_OUTPUT_DIR})")
    parser.add_argument("--voice", action="append", dest="voices", metavar="VOICE_ID",
                        help="Convert only this voice (may be repeated). Default: all voices.")
    args = parser.parse_args()

    convert(args.voices_bin, args.output_dir, args.voices)


if __name__ == "__main__":
    main()
