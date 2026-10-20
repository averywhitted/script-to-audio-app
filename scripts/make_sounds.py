#!/usr/bin/env python3
"""Makes the app's optional sound effects (app/assets/sounds/*.wav).

Synthesized here so there are no third-party recordings or licences to track.
Both are short and quiet: they mark a moment, they don't announce it.

  slate.wav  a wooden "clack" for a scene that finishes rendering
             (a clapper slate on set, or a stage manager's knock)
  page.wav   a soft paper turn when playback moves to another scene

Run:  python3 scripts/make_sounds.py
"""

import math
import os
import random
import struct
import wave

RATE = 44100
OUT = os.path.join(os.path.dirname(__file__), "..", "app", "assets", "sounds")


def _write(name: str, samples: list) -> None:
    peak = max(1e-9, max(abs(x) for x in samples))
    gain = 0.32 / peak  # about -10 dBFS peak; the app plays at 60% volume on top
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, name)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, x * gain)) * 32767)) for x in samples))
    print(f"wrote {os.path.relpath(path)} ({len(samples) / RATE * 1000:.0f} ms)")


def _fade(samples: list, ms: float = 4) -> list:
    n = int(RATE * ms / 1000)
    for i in range(min(n, len(samples))):
        samples[i] *= i / n
        samples[-1 - i] *= i / n
    return samples


def slate() -> list:
    rng = random.Random(7)
    n = int(RATE * 0.16)
    out = []
    lp = 0.0
    for i in range(n):
        t = i / RATE
        # Wooden body: a few quickly damped resonances.
        body = sum(a * math.sin(2 * math.pi * f * t) * math.exp(-t * d)
                   for f, a, d in ((820, 1.0, 55), (1730, 0.6, 70), (2950, 0.35, 90)))
        # The strike: a few milliseconds of softened noise.
        lp += 0.35 * (rng.uniform(-1, 1) - lp)
        strike = lp * math.exp(-t * 260)
        out.append(0.8 * body + 1.4 * strike)
    return _fade(out, 2)


def page() -> list:
    rng = random.Random(11)
    n = int(RATE * 0.26)
    out = []
    lp1 = lp2 = 0.0
    for i in range(n):
        x = i / n
        # Rises, then falls away: the sheet lifting and settling.
        env = math.sin(math.pi * min(1.0, x * 1.25)) ** 2 * (1 - x) ** 0.6
        noise = rng.uniform(-1, 1)
        # Two one-pole low-passes: soft paper, not hiss.
        cutoff = 0.05 + 0.12 * env
        lp1 += cutoff * (noise - lp1)
        lp2 += cutoff * (lp1 - lp2)
        crackle = rng.uniform(-1, 1) * 0.25 if rng.random() < 0.004 else 0.0
        out.append((lp2 * 3.0 + crackle) * env)
    return _fade(out, 6)


if __name__ == "__main__":
    _write("slate.wav", slate())
    _write("page.wav", page())
