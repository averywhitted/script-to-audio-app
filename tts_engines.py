"""
tts_engines.py
==============

Two TTS backends with a common interface:

    engine = MacSayEngine()        # offline, ships with macOS
    engine = OpenAIEngine(api_key) # cloud, higher quality, paid

    engine.list_voices() -> list[VoiceInfo]
    engine.synthesize(text, voice_id, out_path) -> writes audio at out_path
    engine.audio_extension -> ".aiff" / ".mp3"
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
from dataclasses import dataclass
from typing import List, Optional


@dataclass
class VoiceInfo:
    """A voice option exposed to the UI."""
    id: str            # engine-specific identifier (passed to synthesize)
    label: str         # human-friendly display name
    gender: Optional[str] = None  # 'M', 'F', or None
    locale: Optional[str] = None  # e.g. 'en_US'
    note: Optional[str] = None    # extra info shown to user (style, etc.)

    @property
    def display(self) -> str:
        bits = [self.label]
        if self.gender:
            bits.append(f"({self.gender})")
        if self.locale:
            bits.append(self.locale)
        if self.note:
            bits.append(f"– {self.note}")
        return " ".join(bits)


class TTSEngine:
    name: str = "tts"
    audio_extension: str = ".aiff"
    needs_setup: bool = False  # if True, GUI prompts for an API key

    def is_available(self) -> bool:
        raise NotImplementedError

    def list_voices(self) -> List[VoiceInfo]:
        raise NotImplementedError

    def synthesize(self, text: str, voice_id: str, out_path: str) -> None:
        raise NotImplementedError


# ---------------------------------------------------------------------------
# macOS `say` engine
# ---------------------------------------------------------------------------


class MacSayEngine(TTSEngine):
    """Uses the macOS `say` command. Outputs AIFF.

    Voice list is enumerated dynamically via `say -v ?`. We prefer English
    voices; the GUI will let the user choose the locale they want."""

    name = "macOS (built-in)"
    audio_extension = ".aiff"

    # Voices flagged as the higher-quality "Premium"/"Enhanced" Siri voices.
    # The user installs these via System Settings -> Accessibility -> Spoken
    # Content -> System Voice -> Manage Voices. They're free.
    PREFERRED_PREMIUM = [
        # Mac voices that tend to have good premium variants installed by default
        "Ava", "Tom", "Jamie", "Daniel", "Moira", "Karen", "Samantha",
        "Allison", "Susan", "Rishi", "Zoe", "Joelle", "Evan", "Nathan",
        "Serena", "Fiona", "Tessa", "Veena",
    ]

    # Heuristic gender map for common voices (since `say -v ?` doesn't expose it)
    _GENDER_MAP = {
        # Female English
        "Ava": "F", "Allison": "F", "Susan": "F", "Samantha": "F",
        "Karen": "F", "Moira": "F", "Tessa": "F", "Fiona": "F",
        "Veena": "F", "Zoe": "F", "Serena": "F", "Joelle": "F",
        "Sandy": "F", "Kate": "F", "Vicki": "F", "Victoria": "F",
        "Princess": "F", "Whisper": "F",
        # Male English
        "Tom": "M", "Daniel": "M", "Jamie": "M", "Rishi": "M",
        "Evan": "M", "Nathan": "M", "Fred": "M", "Alex": "M",
        "Aaron": "M", "Albert": "M", "Bahh": "M", "Bells": "M",
        "Boing": "M", "Bubbles": "M", "Cellos": "M", "Junior": "M",
        "Ralph": "M", "Bad News": "M", "Good News": "M", "Hysterical": "M",
        "Pipe Organ": "M", "Trinoids": "M", "Zarvox": "M",
    }

    def is_available(self) -> bool:
        return shutil.which("say") is not None

    def list_voices(self) -> List[VoiceInfo]:
        if not self.is_available():
            return []
        try:
            out = subprocess.run(
                ["say", "-v", "?"], check=True, capture_output=True, text=True
            ).stdout
        except subprocess.CalledProcessError:
            return []

        voices: List[VoiceInfo] = []
        # Lines look like:  "Ava (Premium)         en_US    # Hello, my name is Ava."
        for line in out.splitlines():
            m = re.match(r"^\s*(.+?)\s{2,}([a-z]{2}_[A-Z]{2})\s*#", line)
            if not m:
                continue
            full_name = m.group(1).strip()
            locale = m.group(2)
            # Only English by default — keeps the picker focused. Other
            # locales remain available if the user manually selects them by
            # editing the voice id; we just don't surface them.
            if not locale.startswith("en"):
                continue
            # Filter out novelty/joke voices ("Bad News", "Bells", "Bubbles", etc.)
            base = re.sub(r"\s*\((Premium|Enhanced)\)\s*$", "", full_name).strip()
            if base in {"Bad News", "Bells", "Boing", "Bubbles", "Cellos",
                        "Good News", "Hysterical", "Pipe Organ", "Trinoids",
                        "Zarvox", "Bahh", "Albert", "Whisper", "Junior",
                        "Princess", "Deranged", "Organ", "Wobble", "Jester",
                        "Superstar", "Reed", "Rocko", "Sandy", "Eddy",
                        "Flo", "Grandma", "Grandpa", "Shelley", "Marilyn"}:
                continue

            note = None
            if "Premium" in full_name:
                note = "Premium"
            elif "Enhanced" in full_name:
                note = "Enhanced"
            voices.append(VoiceInfo(
                # `say -v` wants the base name, not the "(Premium)" suffix.
                # If the user has the Premium variant installed, say will use
                # it automatically when given just the base name.
                id=base,
                label=base,
                gender=self._GENDER_MAP.get(base),
                locale=locale,
                note=note,
            ))

        # Sort: premium first, then alphabetical
        def sort_key(v: VoiceInfo):
            tier = 0 if v.note == "Premium" else 1 if v.note == "Enhanced" else 2
            return (tier, v.label.lower())
        voices.sort(key=sort_key)
        return voices

    def synthesize(self, text: str, voice_id: str, out_path: str) -> None:
        # Keep the say invocation minimal: just voice + output + text.
        # The pipeline normalizes the AIFF afterward via afconvert, so we
        # don't need to constrain the format here. Some flag combinations
        # (e.g., --data-format) silently fail on certain macOS versions.
        # If the chosen voice fails (e.g., it isn't installed), fall back
        # to the system default voice rather than failing the whole line.
        # (Build tag: minimal-say-v3 — visible in error logs to confirm the
        # running code is up to date.)
        cmd = ["say", "-v", voice_id, "-o", out_path, text]
        # 30s timeout per line. If `say` hangs (e.g., Premium voice still
        # downloading on first use), don't freeze the whole pipeline.
        try:
            result = subprocess.run(cmd, capture_output=True, text=True,
                                    timeout=30)
        except subprocess.TimeoutExpired:
            raise RuntimeError(
                f"say timed out after 30s for voice {voice_id!r}. "
                f"Premium voices download on first use — try opening "
                f"System Settings → Accessibility → Spoken Content → "
                f"System Voice → Manage Voices and pre-download the voices "
                f"you want to use."
            )
        if result.returncode != 0:
            # Retry without -v in case the voice doesn't exist on this Mac
            fallback = ["say", "-o", out_path, text]
            try:
                result2 = subprocess.run(fallback, capture_output=True,
                                         text=True, timeout=30)
            except subprocess.TimeoutExpired:
                raise RuntimeError(
                    f"say (default voice fallback) timed out after 30s."
                )
            if result2.returncode != 0:
                raise RuntimeError(
                    f"say failed for voice {voice_id!r}. "
                    f"stderr: {result.stderr.strip() or '(empty)'}. "
                    f"Default-voice retry stderr: {result2.stderr.strip() or '(empty)'}"
                )


# ---------------------------------------------------------------------------
# OpenAI TTS engine
# ---------------------------------------------------------------------------


class OpenAIEngine(TTSEngine):
    """Uses the OpenAI text-to-speech API. Outputs MP3.

    Cost (approximate as of mid-2025): $15 per 1M characters with `tts-1`,
    $30 per 1M with `tts-1-hd`. A 100k-character play costs ~$1.50–$3.
    """

    name = "OpenAI TTS (cloud)"
    audio_extension = ".mp3"
    needs_setup = True  # requires API key

    # OpenAI voices in May 2026 (these have been stable since launch)
    VOICES = [
        VoiceInfo("alloy",   "Alloy",   gender="N", locale="multi", note="neutral"),
        VoiceInfo("ash",     "Ash",     gender="M", locale="multi", note="warm"),
        VoiceInfo("ballad",  "Ballad",  gender="M", locale="multi", note="brit, mellow"),
        VoiceInfo("coral",   "Coral",   gender="F", locale="multi", note="warm"),
        VoiceInfo("echo",    "Echo",    gender="M", locale="multi", note="serious"),
        VoiceInfo("fable",   "Fable",   gender="M", locale="multi", note="brit narrator"),
        VoiceInfo("nova",    "Nova",    gender="F", locale="multi", note="bright"),
        VoiceInfo("onyx",    "Onyx",    gender="M", locale="multi", note="deep"),
        VoiceInfo("sage",    "Sage",    gender="F", locale="multi", note="calm"),
        VoiceInfo("shimmer", "Shimmer", gender="F", locale="multi", note="soft"),
        VoiceInfo("verse",   "Verse",   gender="M", locale="multi", note="expressive"),
    ]

    DEFAULT_MODEL = "tts-1"  # tts-1 is fast and cheap; tts-1-hd is higher quality

    def __init__(self, api_key: Optional[str] = None, model: Optional[str] = None):
        self.api_key = api_key or os.environ.get("OPENAI_API_KEY")
        self.model = model or self.DEFAULT_MODEL

    def is_available(self) -> bool:
        return bool(self.api_key)

    def list_voices(self) -> List[VoiceInfo]:
        return list(self.VOICES)

    def synthesize(self, text: str, voice_id: str, out_path: str) -> None:
        if not self.api_key:
            raise RuntimeError("OpenAI API key not set")
        # Lazy import so the app runs without `requests` if user only uses
        # the macOS engine (we still ship requests in requirements.txt for
        # convenience, but this keeps imports lazy).
        import urllib.request
        import json
        payload = {
            "model": self.model,
            "voice": voice_id,
            "input": text,
            "response_format": "mp3",
        }
        req = urllib.request.Request(
            "https://api.openai.com/v1/audio/speech",
            data=json.dumps(payload).encode("utf-8"),
            method="POST",
            headers={
                "Authorization": f"Bearer {self.api_key}",
                "Content-Type": "application/json",
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                with open(out_path, "wb") as f:
                    f.write(resp.read())
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8", errors="replace") if e.fp else ""
            raise RuntimeError(
                f"OpenAI TTS failed ({e.code}): {body[:300]}"
            ) from e


# ---------------------------------------------------------------------------
# Convenience
# ---------------------------------------------------------------------------


def list_engines() -> List[TTSEngine]:
    return [MacSayEngine(), OpenAIEngine()]


if __name__ == "__main__":
    eng = MacSayEngine()
    if eng.is_available():
        voices = eng.list_voices()
        print(f"macOS voices ({len(voices)}):")
        for v in voices[:20]:
            print(f"  {v.display}")
    else:
        print("macOS `say` not available")
