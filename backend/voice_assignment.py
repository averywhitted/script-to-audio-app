"""
voice_assignment.py
===================

Pick distinct voices for each character and the narrator.

The auto-assignment tries to:
1. Reserve a clearly-different voice for the narrator (stage directions).
2. Match a character's gender hint when available (from the cast list).
3. Spread out voices so adjacent characters don't sound similar.
4. Round-robin gracefully when there aren't enough voices to go fully unique.

Combined cues like "KRUGER/ANGIE" are resolved to a list of speakers
elsewhere; here we just need to pick a single voice per character entry.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Dict, List, Optional

from parser import Character
from tts_engines import VoiceInfo


NARRATOR_KEY = "__NARRATOR__"


@dataclass
class Assignment:
    """Voice mapping for a script.

    `mapping` keys are character names (and the special NARRATOR_KEY).
    Values are voice IDs (the engine-specific identifier).
    """
    mapping: Dict[str, str]
    voices_by_id: Dict[str, VoiceInfo]

    def voice_for(self, speaker: Optional[str]) -> str:
        if speaker is None:
            speaker = NARRATOR_KEY
        if speaker in self.mapping:
            return self.mapping[speaker]
        # Multi-cue like KRUGER/ANGIE: use the first known mapping
        if "/" in speaker:
            for part in speaker.split("/"):
                p = part.strip()
                if p in self.mapping:
                    return self.mapping[p]
        # Fall back to narrator
        return self.mapping[NARRATOR_KEY]

    def label_for(self, speaker_or_key: str) -> str:
        vid = self.mapping.get(speaker_or_key)
        if not vid:
            return "?"
        v = self.voices_by_id.get(vid)
        return v.label if v else vid


def auto_assign(
    characters: List[Character],
    voices: List[VoiceInfo],
    narrator_preference: Optional[str] = None,
) -> Assignment:
    """Build an Assignment for the given characters using available voices."""
    voices_by_id = {v.id: v for v in voices}

    # Group voices by gender for matching
    by_gender: Dict[str, List[VoiceInfo]] = {"M": [], "F": [], "N": [], "?": []}
    for v in voices:
        key = v.gender if v.gender in ("M", "F", "N") else "?"
        by_gender[key].append(v)
    pool_unknown = list(by_gender["?"]) + list(by_gender["N"])

    used_ids: set = set()

    def pick(buckets: List[List[VoiceInfo]]) -> Optional[VoiceInfo]:
        # First try unused voices in order of bucket priority
        for bucket in buckets:
            for v in bucket:
                if v.id not in used_ids:
                    used_ids.add(v.id)
                    return v
        # If everything is used, allow re-use but prefer least-recent
        for bucket in buckets:
            if bucket:
                return bucket[0]
        return None

    mapping: Dict[str, str] = {}

    # Step 1: pick narrator. Prefer a "neutral" or different voice from the
    # main characters. We pick a voice with note "narrator"/"calm"/"warm" if
    # available, else the first non-character voice we'd otherwise pick.
    narrator_voice: Optional[VoiceInfo] = None
    if narrator_preference:
        narrator_voice = voices_by_id.get(narrator_preference)
    if not narrator_voice:
        # Heuristic preferences: a "fable" / "narrator-y" voice, or the first
        # voice with a "narrator"/"calm"/"warm" note, else fall back.
        for keyword in ("narrator", "warm", "calm", "mellow"):
            for v in voices:
                if v.note and keyword in v.note.lower():
                    narrator_voice = v
                    break
            if narrator_voice:
                break
    if not narrator_voice and voices:
        # Use the first available voice (we'll claim it for narrator and
        # remove it from the character pool).
        narrator_voice = voices[0]

    if narrator_voice:
        used_ids.add(narrator_voice.id)
        mapping[NARRATOR_KEY] = narrator_voice.id

    # Step 2: assign voices to characters in cast-order (ordering matters
    # because main characters get the best voices first).
    for ch in characters:
        gender = ch.gender_hint
        if gender == "M":
            buckets = [by_gender["M"], pool_unknown, by_gender["F"]]
        elif gender == "F":
            buckets = [by_gender["F"], pool_unknown, by_gender["M"]]
        else:
            # No gender info — try unknown first, then alternate M/F to spread
            buckets = [pool_unknown, by_gender["F"], by_gender["M"]]
        v = pick(buckets)
        if v:
            mapping[ch.name] = v.id

    return Assignment(mapping=mapping, voices_by_id=voices_by_id)


if __name__ == "__main__":
    from parser import Character
    from tts_engines import OpenAIEngine
    chars = [
        Character("MARVIN", gender_hint="M"),
        Character("ANGIE", gender_hint="F"),
        Character("RYAN", gender_hint="M"),
        Character("KRUGER", gender_hint="M"),
        Character("FIONA", gender_hint="F"),
        Character("THE SPIDER", gender_hint="F"),
    ]
    a = auto_assign(chars, OpenAIEngine().list_voices())
    print("Narrator:", a.label_for(NARRATOR_KEY))
    for c in chars:
        print(f"  {c.name}: {a.label_for(c.name)}")
