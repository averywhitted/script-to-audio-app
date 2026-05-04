"""
Linux-side smoke test for audio_pipeline.

Stubs:
  - The TTS engine: generates a short sine-wave WAV per line (different
    pitch per "voice"), simulating what a real engine would produce.
  - Replaces afconvert subprocess calls with ffmpeg-equivalent commands.

This is enough to validate the data flow end-to-end. The actual macOS
pipeline reuses the same code with real `say` / `afconvert`.
"""

from __future__ import annotations

import math
import os
import struct
import subprocess
import sys
import wave
from typing import List

# Make the stubs visible before importing the pipeline
import audio_pipeline as P
import tts_engines as T


# ---------------------------------------------------------------------------
# Stub afconvert -> ffmpeg
# ---------------------------------------------------------------------------


_real_run = subprocess.run

def _ffmpeg_run(cmd, *args, **kwargs):
    if cmd and cmd[0] == "afconvert":
        # Reinterpret afconvert arguments
        if "WAVE" in cmd:
            # WAV output
            src, dst = cmd[-2], cmd[-1]
            new_cmd = ["ffmpeg", "-y", "-loglevel", "error",
                       "-i", src,
                       "-ac", "1", "-ar", "22050", "-c:a", "pcm_s16le",
                       dst]
            return _real_run(new_cmd, *args, **kwargs)
        elif "m4af" in cmd:
            # M4A output via AAC
            src, dst = cmd[-2], cmd[-1]
            new_cmd = ["ffmpeg", "-y", "-loglevel", "error",
                       "-i", src,
                       "-ac", "1",
                       "-c:a", "aac",
                       "-b:a", "96k",
                       dst]
            return _real_run(new_cmd, *args, **kwargs)
    return _real_run(cmd, *args, **kwargs)


subprocess.run = _ffmpeg_run


# ---------------------------------------------------------------------------
# Stub TTS engine
# ---------------------------------------------------------------------------


class StubEngine(T.TTSEngine):
    """A pretend TTS engine: generates a 1-second sine wave per call,
    pitch deterministically derived from voice id. Outputs AIFF (which is
    what the real macOS engine uses) so the pipeline's afconvert step has
    a real source-to-destination conversion to do."""

    name = "stub"
    audio_extension = ".aiff"

    VOICES = [
        T.VoiceInfo(f"voice_{i}", f"Voice {i}",
                    gender="M" if i % 2 == 0 else "F",
                    locale="en_US",
                    note=("narrator" if i == 0 else None))
        for i in range(8)
    ]

    def is_available(self) -> bool:
        return True

    def list_voices(self) -> List[T.VoiceInfo]:
        return list(self.VOICES)

    def synthesize(self, text: str, voice_id: str, out_path: str) -> None:
        # Pitch derived from voice id
        seed = sum(ord(c) for c in voice_id)
        freq = 220 + (seed % 8) * 60  # 220..640 Hz
        words = max(1, len(text.split()))
        seconds = max(0.4, min(words * 0.18, 4.0))
        rate = 22050
        nframes = int(seconds * rate)
        # Write as AIFF using the aifc module (so the pipeline's afconvert
        # step has a real format conversion to do).
        import aifc
        with aifc.open(out_path, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(rate)
            buf = bytearray()
            for i in range(nframes):
                env = min(i, nframes - i, 1000) / 1000.0
                sample = int(env * 8000 * math.sin(2 * math.pi * freq * i / rate))
                # AIFF is big-endian
                buf.extend(struct.pack(">h", sample))
            w.writeframes(bytes(buf))


# ---------------------------------------------------------------------------
# Run the test
# ---------------------------------------------------------------------------


def main() -> int:
    import parser
    from voice_assignment import auto_assign

    pdf = "/sessions/cool-festive-carson/mnt/uploads/HEIST by Arun Lakra - Cincinnati Working Draft 1.0 - March 17th 26.pdf"
    if not os.path.exists(pdf):
        print(f"[FAIL] PDF not found at {pdf}")
        return 1

    print("Parsing...")
    script = parser.parse_pdf(pdf)
    print(f"  {len(script.scenes)} scenes, {len(script.characters)} characters")

    eng = StubEngine()
    voices = eng.list_voices()
    a = auto_assign(script.characters, voices)
    print(f"  narrator: {a.label_for('__NARRATOR__')}")
    for c in script.characters:
        print(f"  {c.name:<25} -> {a.label_for(c.name)}")

    # Render only a couple of scenes for speed
    out_dir = "/tmp/heist_test_audio"
    os.makedirs(out_dir, exist_ok=True)

    target = [4, 5, 18, 46]  # spread across the play

    def cb(p):
        if p.element_index >= 0:
            print(f"  scene {p.scene_index+1}/{p.total_scenes} "
                  f"el {p.element_index+1}/{p.total_elements_in_scene} "
                  f"{p.message}")
        else:
            print(f"  [scene-level] {p.message}")

    print(f"\nGenerating scenes {target} into {out_dir}...")
    res = P.generate_script(
        script=script,
        engine=eng,
        assignment=a,
        output_dir=out_dir,
        progress_cb=cb,
        scene_filter=target,
    )
    print(f"\nResult:")
    print(f"  files generated: {len(res.files)}")
    for f in res.files:
        size = os.path.getsize(f)
        # Verify it's a valid m4a by running ffprobe
        out = subprocess.run(["ffprobe", "-v", "error", "-show_entries",
                              "format=duration,bit_rate,format_name",
                              "-of", "default=noprint_wrappers=1", f],
                             capture_output=True, text=True)
        print(f"    {os.path.basename(f)}  ({size:,} bytes)")
        for line in out.stdout.strip().split("\n"):
            print(f"      {line}")
    print(f"  errors: {res.errors}")
    print(f"  skipped: {res.skipped_scenes}")
    if not res.files:
        print("[FAIL] no files generated")
        return 1
    print("[PASS]")
    return 0


if __name__ == "__main__":
    sys.exit(main())
