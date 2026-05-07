"""
tts_engines.py
==============

TTS backends with a common interface:

    engine = MacSayEngine()        # offline, ships with macOS
    engine = KokoroEngine()        # offline, neural quality, Apache-licensed
    engine = OpenAIEngine(api_key) # cloud, higher quality, paid

    engine.list_voices() -> list[VoiceInfo]
    engine.synthesize(text, voice_id, out_path) -> writes audio at out_path
    engine.audio_extension -> ".aiff" / ".wav" / ".mp3"
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import threading
import time
from dataclasses import dataclass
from pathlib import Path
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


class TTSFatalError(RuntimeError):
    """A synthesis error that should stop the run instead of skipping a line."""


class TTSQuotaError(TTSFatalError):
    """The cloud provider says the account has no usable quota."""


class TTSRateLimitError(TTSFatalError):
    """The cloud provider kept rate-limiting after retries."""


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
# Kokoro local neural engine
# ---------------------------------------------------------------------------

# Module-level Kokoro instance cache — loading the ONNX model takes a few
# seconds; we keep it alive for the lifetime of the worker process.
_kokoro_instance: Optional[object] = None

# Model files are hosted as public GitHub release assets — no HuggingFace
# account or token needed.
_KOKORO_RELEASE = "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0"
_KOKORO_FILES = {
    "kokoro-v1.0.int8.onnx": "kokoro-v1.0.int8.onnx",
    "voices-v1.0.bin":       "voices-v1.0.bin",
}
_KOKORO_CACHE_DIR = Path.home() / ".cache" / "tableread" / "kokoro"


def _download_kokoro_files() -> tuple[str, str]:
    """Download (or return cached) Kokoro ONNX model and voices files."""
    import urllib.request

    _KOKORO_CACHE_DIR.mkdir(parents=True, exist_ok=True)
    paths = {}
    for filename in _KOKORO_FILES:
        dest = _KOKORO_CACHE_DIR / filename
        if not dest.exists():
            url = f"{_KOKORO_RELEASE}/{filename}"
            print(f"Downloading {filename} from {url} …", flush=True)
            urllib.request.urlretrieve(url, dest)
        paths[filename] = str(dest)
    return paths["kokoro-v1.0.int8.onnx"], paths["voices-v1.0.bin"]


def _get_kokoro() -> object:
    """Return a cached Kokoro (kokoro-onnx) instance, downloading model files
    on first call if not already cached locally."""
    global _kokoro_instance
    if _kokoro_instance is not None:
        return _kokoro_instance

    try:
        from kokoro_onnx import Kokoro
    except ImportError as exc:
        raise RuntimeError(
            "kokoro-onnx is not installed. "
            "Run: pip install kokoro-onnx soundfile"
        ) from exc

    onnx_path, voices_path = _download_kokoro_files()
    _kokoro_instance = Kokoro(onnx_path, voices_path)
    return _kokoro_instance


class KokoroEngine(TTSEngine):
    """Apache-2.0-licensed neural TTS via kokoro-onnx.

    Uses the ONNX-exported Kokoro-82M model from the public kokoro-onnx
    GitHub releases. The quantized model (~88 MB) is downloaded on first
    synthesis and cached permanently at ~/.cache/tableread/kokoro/.
    Works on Python 3.9+ including 3.14.

    Prerequisites:
        pip install kokoro-onnx soundfile
    """

    name = "Kokoro (local neural)"
    audio_extension = ".wav"   # soundfile writes PCM WAV; afconvert resamples

    # Voice IDs are a focused English subset from the Kokoro v1.0 voice file.
    # Prefix convention: af_ = American female, am_ = American male,
    #                    bf_ = British female,  bm_ = British male.
    VOICES = [
        VoiceInfo("af_heart",    "Heart",    gender="F", locale="en_US", note="warm narrator"),
        VoiceInfo("af_alloy",    "Alloy",    gender="F", locale="en_US", note="neutral"),
        VoiceInfo("af_aoede",    "Aoede",    gender="F", locale="en_US"),
        VoiceInfo("af_bella",    "Bella",    gender="F", locale="en_US", note="expressive"),
        VoiceInfo("af_jessica",  "Jessica",  gender="F", locale="en_US"),
        VoiceInfo("af_kore",     "Kore",     gender="F", locale="en_US"),
        VoiceInfo("af_nicole",   "Nicole",   gender="F", locale="en_US", note="asmr"),
        VoiceInfo("af_nova",     "Nova",     gender="F", locale="en_US", note="bright"),
        VoiceInfo("af_river",    "River",    gender="F", locale="en_US"),
        VoiceInfo("af_sarah",    "Sarah",    gender="F", locale="en_US"),
        VoiceInfo("af_sky",      "Sky",      gender="F", locale="en_US", note="bright"),
        VoiceInfo("am_adam",     "Adam",     gender="M", locale="en_US"),
        VoiceInfo("am_echo",     "Echo",     gender="M", locale="en_US"),
        VoiceInfo("am_eric",     "Eric",     gender="M", locale="en_US"),
        VoiceInfo("am_fenrir",   "Fenrir",   gender="M", locale="en_US"),
        VoiceInfo("am_liam",     "Liam",     gender="M", locale="en_US"),
        VoiceInfo("am_michael",  "Michael",  gender="M", locale="en_US", note="warm"),
        VoiceInfo("am_onyx",     "Onyx",     gender="M", locale="en_US", note="deep"),
        VoiceInfo("am_puck",     "Puck",     gender="M", locale="en_US"),
        VoiceInfo("bf_alice",    "Alice",    gender="F", locale="en_GB"),
        VoiceInfo("bf_emma",     "Emma",     gender="F", locale="en_GB"),
        VoiceInfo("bf_isabella", "Isabella", gender="F", locale="en_GB"),
        VoiceInfo("bf_lily",     "Lily",     gender="F", locale="en_GB"),
        VoiceInfo("bm_daniel",   "Daniel",   gender="M", locale="en_GB", note="narrator"),
        VoiceInfo("bm_fable",    "Fable",    gender="M", locale="en_GB", note="narrator"),
        VoiceInfo("bm_george",   "George",   gender="M", locale="en_GB"),
        VoiceInfo("bm_lewis",    "Lewis",    gender="M", locale="en_GB"),
    ]

    _VOICE_FALLBACKS = {
        # Older builds exposed a synthetic "af" blend that is not present in
        # Kokoro v1.0 voice files. Keep stale UI assignments rendering.
        "af": "af_heart",
    }

    # Map voice-ID prefix → kokoro-onnx lang string
    _LANG_MAP = {
        "af": "en-us",
        "am": "en-us",
        "bf": "en-gb",
        "bm": "en-gb",
    }

    def is_available(self) -> bool:
        try:
            import kokoro_onnx       # noqa: F401
            import soundfile         # noqa: F401
            return True
        except ImportError:
            return False

    def list_voices(self) -> List[VoiceInfo]:
        return list(self.VOICES)

    def _resolve_voice_id(self, voice_id: str, kokoro: object) -> str:
        available = getattr(kokoro, "voices", None)
        if available is not None and voice_id in available:
            return voice_id

        fallback = self._VOICE_FALLBACKS.get(voice_id)
        if fallback and available is not None and fallback in available:
            return fallback

        first_voice = self.VOICES[0].id
        if available is not None and first_voice in available:
            return first_voice

        return voice_id

    def synthesize(self, text: str, voice_id: str, out_path: str) -> None:
        try:
            import soundfile as sf
        except ImportError as exc:
            raise RuntimeError(
                "soundfile is not installed. Run: pip install soundfile"
            ) from exc

        kokoro = _get_kokoro()

        resolved_voice_id = self._resolve_voice_id(voice_id, kokoro)

        # Derive lang from the two-letter prefix (e.g. "af_bella" -> "af" -> "en-us")
        prefix = resolved_voice_id.split("_")[0] if "_" in resolved_voice_id else resolved_voice_id
        lang = self._LANG_MAP.get(prefix, "en-us")

        try:
            samples, sample_rate = kokoro.create(
                text, voice=resolved_voice_id, speed=1.0, lang=lang
            )
        except Exception as exc:
            raise RuntimeError(
                f"Kokoro synthesis failed for voice {voice_id!r}: {exc}"
            ) from exc

        if samples is None or len(samples) == 0:
            raise RuntimeError(
                f"Kokoro returned no audio for voice {voice_id!r}. "
                "The text may be empty or contain unsupported characters."
            )

        # kokoro-onnx returns float32 at 24 kHz; write as 16-bit WAV so
        # afconvert can resample it to the pipeline's 22.05 kHz PCM format.
        sf.write(out_path, samples, samplerate=sample_rate, subtype="PCM_16")


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

    REQUESTS_PER_MINUTE = 3
    MAX_RATE_LIMIT_RETRIES = 6

    def __init__(self, api_key: Optional[str] = None, model: Optional[str] = None):
        self.api_key = api_key or os.environ.get("OPENAI_API_KEY")
        self.model = model or self.DEFAULT_MODEL
        self.requests_per_minute = self.REQUESTS_PER_MINUTE
        self._min_request_interval = 60.0 / max(self.requests_per_minute, 1)
        self._last_request_at = 0.0
        self._lock = threading.Lock()

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
        import urllib.error
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
        for attempt in range(self.MAX_RATE_LIMIT_RETRIES + 1):
            self._wait_for_rate_slot()
            try:
                with urllib.request.urlopen(req, timeout=120) as resp:
                    with open(out_path, "wb") as f:
                        f.write(resp.read())
                    return
            except urllib.error.HTTPError as e:
                body = e.read().decode("utf-8", errors="replace") if e.fp else ""
                if e.code == 429 and self._is_quota_error(body):
                    raise TTSQuotaError(self._format_openai_error(e.code, body)) from e
                if e.code == 429 and attempt < self.MAX_RATE_LIMIT_RETRIES:
                    wait = self._retry_wait_seconds(e, body)
                    time.sleep(wait)
                    continue
                if e.code == 429:
                    raise TTSRateLimitError(self._format_openai_error(e.code, body)) from e
                raise RuntimeError(self._format_openai_error(e.code, body)) from e

    def _wait_for_rate_slot(self) -> None:
        with self._lock:
            now = time.monotonic()
            wait = self._min_request_interval - (now - self._last_request_at)
            if wait > 0:
                time.sleep(wait)
            self._last_request_at = time.monotonic()

    def _retry_wait_seconds(self, err, body: str) -> float:
        header = err.headers.get("retry-after") if getattr(err, "headers", None) else None
        if header:
            try:
                return max(float(header), self._min_request_interval)
            except ValueError:
                pass
        m = re.search(r"try again in\s+(\d+(?:\.\d+)?)s", body, re.I)
        if m:
            return max(float(m.group(1)) + 1.0, self._min_request_interval)
        return self._min_request_interval + 1.0

    def _is_quota_error(self, body: str) -> bool:
        low = body.lower()
        return "insufficient_quota" in low or "exceeded your current quota" in low

    def _format_openai_error(self, code: int, body: str) -> str:
        try:
            import json
            data = json.loads(body)
            message = data.get("error", {}).get("message")
            if message:
                return f"OpenAI TTS failed ({code}): {message}"
        except Exception:
            pass
        return f"OpenAI TTS failed ({code}): {body[:300]}"


# ---------------------------------------------------------------------------
# Convenience
# ---------------------------------------------------------------------------


def list_engines() -> List[TTSEngine]:
    return [MacSayEngine(), KokoroEngine(), OpenAIEngine()]


if __name__ == "__main__":
    eng = MacSayEngine()
    if eng.is_available():
        voices = eng.list_voices()
        print(f"macOS voices ({len(voices)}):")
        for v in voices[:20]:
            print(f"  {v.display}")
    else:
        print("macOS `say` not available")
