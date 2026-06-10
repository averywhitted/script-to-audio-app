"""
parser.py
=========

Parse a PDF script (play / screenplay) into a structured representation:

    Script
      ├── characters: list of Character (name, gender_hint, role_hint, age_hint)
      └── scenes: list of Scene
            ├── number: int
            ├── title: str
            └── elements: list of Element
                  ├── kind: 'dialog' | 'stage_direction' | 'parenthetical'
                  ├── speaker: str | None      # for dialog/parenthetical
                  └── text: str

Supported formats (auto-detected):

  play          — Standard theatrical play: speaker name on its own line (ALL-CAPS),
                  dialog on following lines. Scene markers: SCENE N, N., ACT N,
                  - N -, PART N. Works for the majority of published American plays.
                  Parsed from plain (non-layout) text extraction.

  colon_play    — TRW / two-column format (e.g. Kate Hamill adaptations): speaker
                  appears as SPEAKER: (with colon). Often a two-column PDF where
                  pdfplumber merges columns into "...left-text  SPEAKER:" lines.

  heist         — Numbered scene headers at low indent ("1  SCENE NAME").
                  Character cues at wide indent (~col 35). Dialog at ~col 12.
                  Parsed from layout-preserving (layout=True) extraction.

  scene_n       — INT./EXT. scene headers, indent-based cues. Screenplay style.
                  Parsed from layout-preserving extraction.

  dash_dialog   — Inline "SPEAKER – dialog text" on each line. Bare "N." scene
                  markers. Parsed from layout-preserving extraction.

PDF font artifacts (some exporters double every character, e.g. "VVIINNNNYY")
are transparently normalized before parsing.
"""

from __future__ import annotations

import json
import logging
import os
import re
from collections import Counter
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Set, Tuple

import pdfplumber

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Data classes
# ---------------------------------------------------------------------------


@dataclass
class Character:
    name: str
    gender_hint: Optional[str] = None  # 'M', 'F', or None
    role_hint: Optional[str] = None
    age_hint: Optional[str] = None


@dataclass
class Element:
    kind: str  # 'dialog' | 'stage_direction' | 'parenthetical'
    text: str
    speaker: Optional[str] = None
    overlap_cue: Optional[List[str]] = None   # set when multiple speakers share a line simultaneously
    overlap_texts: Optional[List[str]] = None # per-voice texts (parallel with overlap_cue); None = all voices read .text
    confidence: float = 1.0  # 1.0 = known speaker / strong evidence; 0.7 = unknown speaker; 0.4 = fallback


@dataclass
class Scene:
    number: int
    title: str
    elements: List[Element] = field(default_factory=list)


@dataclass
class Script:
    title: str
    characters: List[Character] = field(default_factory=list)
    scenes: List[Scene] = field(default_factory=list)


@dataclass
class StructuredLine:
    """A single logical line with full spatial and typographic metadata.

    Extracted from pdfplumber char-level data during Phase-2 parsing.
    ``x`` and ``y`` are in PDF points (72 pt = 1 inch).  Both are ``None``
    when spatial data is unavailable (e.g. the pypdfium2 fallback path).
    ``page`` is 0-based.  ``is_page_break`` marks the sentinel blank line
    inserted between pages so callers can detect page boundaries.
    """

    text: str
    x: Optional[float]      # left edge x0 of the first word (PDF points)
    y: Optional[float]      # top y-coordinate of the line (PDF points)
    is_italic: bool = False
    is_bold: bool = False
    page: int = 0
    is_page_break: bool = False


@dataclass
class ClassifiedLine:
    """A :class:`StructuredLine` with a predicted structural role.

    Roles mirror the :class:`Element` kinds plus two extras:

    * ``'speaker_cue'``     – all-caps speaker attribution line
    * ``'dialog'``          – spoken text following a speaker cue
    * ``'stage_direction'`` – action / description (non-dialog, non-cue)
    * ``'parenthetical'``   – ``(…)`` modifier inside a dialog block
    * ``'scene_heading'``   – scene or act boundary header
    * ``'noise'``           – decorative separator, page number, etc.
    * ``'blank'``           – empty line (including page-break sentinels)

    ``speaker`` is populated only for ``'speaker_cue'`` lines (the raw cue
    text, not yet normalised / aliased).
    """

    line: StructuredLine
    role: str               # one of the seven role strings above
    speaker: Optional[str] = None


@dataclass
class ScriptSkeleton:
    """Pre-computed structural analysis of raw script lines.

    Built once before format detection so every format parser shares the same
    single pass over the text rather than each re-deriving the universal
    invariants independently.

    Universal invariants captured here:
      1. Speaker identification — all-caps lines that pass _is_caps_cue_candidate
      2. Scene delimiters — lines matching any known boundary pattern
      3. Page-region classification — title/front-matter vs. script body
    """

    # --- Line-level sets (indices into the raw lines list) ---
    cue_line_indices: Set[int]          # candidate speaker-cue lines
    scene_delimiter_indices: Set[int]   # candidate scene/act boundary lines

    # --- Page-level structure ---
    page_sets: List[Set[str]]           # per-page content sets (from extraction)
    first_page_only: Set[str]           # lines exclusive to page 0 (title page)
    body_start_line: int                # first line of actual script content
    cast_section_range: Optional[Tuple[int, int]]  # (start, end) if CAST found

    # --- Format detection scores (pre-computed, avoid rescan) ---
    heist_count: int        # numbered "N  SCENE TITLE" headers
    int_ext_count: int      # INT./EXT. sluglines
    scene_n_count: int      # SCENE N markers
    dash_count: int         # SPEAKER – dialog inline lines
    cue_score: int          # standalone ALL-CAPS → mixed-case next line
    colon_score: int        # ALLCAPS: cue pattern count
    non_empty_count: int    # total non-blank lines (denominator for ratios)
    all_caps_count: int     # lines with no lowercase (for all-caps-doc filter)


# ---------------------------------------------------------------------------
# Default indent zones (calibrated for HEIST-style; overridden by auto-detect)
# ---------------------------------------------------------------------------

SCENE_HEADER_MAX_INDENT = 15
DIALOG_INDENT_MIN = 5
DIALOG_INDENT_MAX = 22
PARENTHETICAL_INDENT_MIN = 18
PARENTHETICAL_INDENT_MAX = 32
CUE_INDENT_MIN = 28
PAGE_NUMBER_INDENT_MIN = 60


# Regex helpers — heist / scene_n / dash_dialog formats
SCENE_HEADER_RE = re.compile(
    r"""^\s*(?P<num>\d+)\s+(?P<title>[A-Z0-9][^a-z]*?)\s*$"""
)
SCENE_NUM_RE = re.compile(r"""^\s*SCENE\s+(?P<num>\d+)\s*$""", re.I)
INT_EXT_RE = re.compile(r"""^\s*(INT|EXT)\.?\s+(?P<loc>.+)""", re.I)
ACT_RE = re.compile(r"""^\s*(?:ACT\s+[\dIVX]+|END\s+OF\s+ACT)""", re.I)
PAGE_FOOTER_RE = re.compile(r"^\s*\d+\.\s*\.?\s*$")
_DRAFT_DATE_RE = re.compile(
    r"""^\s*(?:
        \d{1,2}[/.\-]\d{1,2}[/.\-]\d{2,4}        # 4/1/19  4.1.19
      | (?:Rev(?:ision)?\.?\s*)?\d{1,2}[/.\-]\d{1,2}[/.\-]\d{2,4}  # Rev. 4/1/19
      | Rev(?:ised?|ision)?\.?\s+\w                # Rev. A  Revised  REVISED
      | DRAFT\s*[-—]?\s*\d                         # DRAFT 1  DRAFT – 2
      | \d+\s*(?:st|nd|rd|th)\s+DRAFT              # 2nd DRAFT
    )\s*$""",
    re.VERBOSE | re.IGNORECASE,
)
PARENTHETICAL_RE = re.compile(r"^\s*\(.*\)\s*$")
CONTD_RE = re.compile(r"\s*\([^)]*CONT['']?D[^)]*\)", re.I)

# Heuristics for detecting a stage-direction line that has leaked into a dialog buffer.
# Checked per-line (at buffer time) and on the combined text (at flush time).
_SD_IN_DIALOG_LINE_RE = re.compile(
    r"^\([^)]+\)$"                                        # whole line is a parenthetical
    r"|^\s*(?:BEAT|PAUSE|SILENCE|ASIDE|BEAT\.|PAUSE\.)\s*$"  # common bare direction words
    r"|^(?:He|She|They|We|It)\s+\w"                       # third-person action sentence
    r"|^(?:Lights?|Music|Sound|Blackout|Crossfade)\s",    # technical/production direction
    re.IGNORECASE,
)

# Matches stage directions of the form "CHARACTER NAME verb..." where the subject
# is one or more ALL-CAPS words (≥2 chars each) followed by a lowercase word.
# Examples: "JOSH opens his eyes.", "MARCUS smiles at DENISE.", "TOM AND ALICE exit."
# Does NOT match: plain dialog, short exclamations ("WHAT?"), lines with no
# lowercase follow-on.  Case-sensitive by design — character-name subjects in
# stage directions are always printed in ALL CAPS in play format.
_SD_CAPS_SUBJECT_RE = re.compile(
    r"^[A-Z]{2}[A-Z]*(?:\s+[A-Z]{2}[A-Z]*)*\s+[a-z]"
)

# Embedded parenthetical direction in the combined dialog text (≥8 chars inside parens).
_EMBEDDED_PAREN_DIR_RE = re.compile(r"\([^)]{8,}\)")

# Page-marker / draft-watermark lines that appear on every page of a script draft.
# These should be silently dropped rather than attributed to a character as dialog.
# Matches patterns like:
#   "[Draft 3.0] 4"   "[DRAFT] 12"   "[v2.1] 100"   "[Final] 3"
# Also matches bare page numbers (1–4 digits) that appear alone on a line.
_PAGE_MARKER_RE = re.compile(
    r"^\[.{1,40}\]\s*\d{1,4}\.?\s*$"  # bracket-enclosed metadata + page number
    r"|^\d{1,4}\.?\s*$",               # bare page number, with or without trailing dot
)


def _looks_like_stage_direction(text: str) -> bool:
    """Return True when a line inside a dialog block is almost certainly a stage direction.

    Used in both :func:`_extract_scenes_play` and :func:`_classify_lines` to
    immediately flush dialog and emit a ``stage_direction`` element for lines
    that sit at the same x-position as ordinary dialog text (left margin) and
    therefore cannot be identified spatially.

    **Deliberately conservative** — only patterns with a near-zero false
    positive rate are included here.  The broader :data:`_SD_IN_DIALOG_LINE_RE`
    (which includes He/She/They/We/It and technical-direction patterns) is
    intentionally **excluded** because those patterns fire on common dialog
    phrases ("We both say this.", "It continues…") and produce too many
    false positives when used as hard routing triggers.

    Patterns included:

    * Whole-line parenthetical ``(…)`` — unambiguously a stage direction.
    * Bare direction words on their own line: ``BEAT``, ``PAUSE``,
      ``SILENCE`` (with or without trailing period).  These words never
      appear alone as a character's spoken line.
    * :data:`_SD_CAPS_SUBJECT_RE` — ALL-CAPS character name(s) as the
      grammatical subject followed immediately by a lowercase verb ("JOSH
      opens his eyes, looks at TOM.", "MARCUS smiles at DENISE lovingly.").
      This is the dominant pattern for inline stage directions in published
      American play scripts and has a very low false-positive rate because
      a speaking character's own dialog almost never starts with another
      character's ALL-CAPS name.
    """
    t = text.strip()
    # Whole-line parenthetical
    if t.startswith("(") and t.endswith(")"):
        return True
    # Bare direction words (BEAT / PAUSE / SILENCE alone on the line)
    if re.match(r"^\s*(?:BEAT|PAUSE|SILENCE)\.?\s*$", t, re.IGNORECASE):
        return True
    # ALL-CAPS character name + lowercase action verb
    if _SD_CAPS_SUBJECT_RE.match(t):
        return True
    return False

# Dash-dialog format ("SPEAKER – text" inline on one line)
_DASH_DIALOG_LINE_RE = re.compile(
    r"^([A-Z0-9][A-Z0-9 /&]*?)\s*[–\-]\s*(.+)$"
)
_SCENE_NUM_DOT_RE = re.compile(r"^\s*(\d+)\.\s*$")
_INLINE_PAREN_RE = re.compile(r"^\(([^)]+)\)\s*(.*)$")

# ---------------------------------------------------------------------------
# Play-format regex constants
# ---------------------------------------------------------------------------

# Narrator speaker names — used to detect when the "narrator" turn should yield
# back to the last character speaker after a parenthetical.  Matches "NARRATOR",
# "NARRATOR 1", "NARRATOR (V.O.)", etc.
_NARRATOR_NAME_RE = re.compile(r"^NARRATOR\b", re.IGNORECASE)

# All-caps tokens that are stage directions / structural markers, never speaker cues
_NON_CUE_RE = re.compile(
    r"""^(
        (?:THE\s+)?END(\s+OF\s+(ACT|PLAY|SCENE))?
       |FINIS|CURTAIN
       |BLACK\s*OUT|WHITE\s*OUT|FADE\s*(IN|OUT|TO\s+BLACK)
       |LIGHTS?\s*(UP|DOWN|OUT|FADE|RISE|FALL)
       |SILENCE|BLACKOUT|WHITEOUT
       |INTERMISSION|ENTR.?ACTE|INTERVAL
       |PRESET|PRESHOW
       |PROLOGUE|EPILOGUE|OVERTURE|PRELUDE|CODA
       |SCENE\b|ACT\b|PART\b|SECTION\b
       |CONTINUED|CONT.D|MORE
       |CHARACTERS?\b|CAST\b|SETTING\b|SYNOPSIS\b
       |NOTES?\b|TIME\b|PLACE\b|LOCATION\b
       |PRODUCTION\b|ADVISORY\b|ATTRIBUTION\b
       |COPYRIGHT\b|WARNING\b|DRAMATIS\b|PERSONAE\b
       |PAUSE\b|BEAT\b|WAIT\b|STOP\b  # common stage directions
       |ALL\b|BOTH\b|TOGETHER\b|EVERYONE\b|ENSEMBLE\b  # collective-speaker markers
       |.*\s+DAYS?\s*$    # time-section headers: "DEPARTURE DAY", "OPENING DAY"
    )""",
    re.VERBOSE | re.IGNORECASE,
)

# Scene boundary in play format
# NOTE: bare "N." (e.g. "2.") is deliberately excluded — it matches page
# numbers in virtually every modern script. Dash-dialog scripts have their own
# _SCENE_NUM_DOT_RE. Add "N. TITLE" (with mandatory title text) if a specific
# format requires it.
_PLAY_SCENE_RE = re.compile(
    r"""^
    (?:
        (?:SCENE|Scene|SCENE)\s+(\d+)          # SCENE 1 / Scene 1
      | ACT\s+([IVXivx]+|\d+)                  # ACT I / ACT 1
      | -{1,3}\s*(\d+)\s*-{1,3}               # - 1 - / -- 2 --
      | PART\s+([IVXivx]+|\d+)                 # PART 1 / PART I
    )
    [\s:—\-]*(.*)$                             # optional colon / dash / title text
    """,
    re.VERBOSE | re.IGNORECASE,
)

# "The First Act" / "The Second Act" ordinal format (e.g. Mr. Burns)
# ACT must be at end of line to avoid matching mid-sentence "the third act finale..."
_ORDINAL_ACT_RE = re.compile(
    r"^(?:THE\s+)?(FIRST|SECOND|THIRD|FOURTH|FIFTH|SIXTH|SEVENTH|EIGHTH|NINTH|TENTH)\s+ACT\s*$",
    re.IGNORECASE,
)
_ORDINAL_TO_INT = {
    "FIRST": 1, "SECOND": 2, "THIRD": 3, "FOURTH": 4, "FIFTH": 5,
    "SIXTH": 6, "SEVENTH": 7, "EIGHTH": 8, "NINTH": 9, "TENTH": 10,
}

# "SCENE ONE" / "SCENE TWO" etc. — cardinal word-form scene numbers.
# Many plays use this instead of "SCENE 1". Matched before _NON_CUE_RE's bare
# "SCENE\b" guard so the boundary is recognised rather than filtered.
_CARDINAL_WORDS = (
    "ONE|TWO|THREE|FOUR|FIVE|SIX|SEVEN|EIGHT|NINE|TEN|"
    "ELEVEN|TWELVE|THIRTEEN|FOURTEEN|FIFTEEN|SIXTEEN|SEVENTEEN|EIGHTEEN|NINETEEN|"
    "TWENTY(?:[-\\s](?:ONE|TWO|THREE|FOUR|FIVE|SIX|SEVEN|EIGHT|NINE))?"
)
_ORDINAL_SCENE_RE = re.compile(
    rf"^SCENE\s+({_CARDINAL_WORDS})\s*$",
    re.IGNORECASE,
)
_SCENE_CARDINAL_TO_INT: Dict[str, int] = {
    "ONE": 1, "TWO": 2, "THREE": 3, "FOUR": 4, "FIVE": 5,
    "SIX": 6, "SEVEN": 7, "EIGHT": 8, "NINE": 9, "TEN": 10,
    "ELEVEN": 11, "TWELVE": 12, "THIRTEEN": 13, "FOURTEEN": 14, "FIFTEEN": 15,
    "SIXTEEN": 16, "SEVENTEEN": 17, "EIGHTEEN": 18, "NINETEEN": 19, "TWENTY": 20,
    **{f"TWENTY-{w}": 20 + i for i, w in enumerate(
        ["ONE","TWO","THREE","FOUR","FIVE","SIX","SEVEN","EIGHT","NINE"], 1)},
    **{f"TWENTY {w}": 20 + i for i, w in enumerate(
        ["ONE","TWO","THREE","FOUR","FIVE","SIX","SEVEN","EIGHT","NINE"], 1)},
}

# Time-based section headers: "THREE DAYS TO DEPARTURE", "ONE DAY UNTIL X"
_TIME_SECTION_RE = re.compile(
    r"^(?:ONE|TWO|THREE|FOUR|FIVE|SIX|SEVEN|EIGHT|NINE|TEN|\d+)\s+DAYS?\s+(?:TO|UNTIL|BEFORE|AFTER)\b",
    re.IGNORECASE,
)

# Speaker cue in colon-play format: "SPEAKER:" or "SPEAKER: inline dialog"
_COLON_CUE_RE = re.compile(
    r"""(?:^|(?<=\s))([A-Z][A-Z\s\.\']{0,35}?)\s*:\s*(.*)$"""
)


# ---------------------------------------------------------------------------
# Doubled-character normalization
# ---------------------------------------------------------------------------


def _undouble(line: str) -> str:
    """Remove doubled-character artifacts from PDF font rendering."""
    stripped = line.lstrip(" ")
    if not stripped:
        return line
    leading = line[: len(line) - len(stripped)]
    return leading + _undouble_content(stripped)


def _undouble_content(s: str) -> str:
    """Normalize doubled characters in a string with no leading spaces."""
    if len(s) < 4:
        return s
    pairs = 0
    singles = 0
    i = 0
    while i < len(s):
        if i + 1 < len(s) and s[i] == s[i + 1]:
            pairs += 1
            i += 2
        else:
            singles += 1
            i += 1
    total = pairs + singles
    if total == 0 or pairs / total < 0.70:
        return s
    result: List[str] = []
    i = 0
    while i < len(s):
        result.append(s[i])
        if i + 1 < len(s) and s[i] == s[i + 1]:
            i += 2
        else:
            i += 1
    return "".join(result)


# ---------------------------------------------------------------------------
# Text extraction
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# Garbled-font decoder for pypdfium2 output
# ---------------------------------------------------------------------------
#
# Some PDFs use a custom font whose ToUnicode CMap is offset by -29.  When
# pypdfium2 extracts text it reads the wrong codepoints, producing output like
# ":KDW·V" for "What's" and "DLYLVLRQ·V" for "division's".  The decoding
# rule is simply: add 29 to each character whose codepoint is in the ranges
# 58-61 (→ W-Z) or 68-93 (→ a-z).  The anchor characters · (183), ´ (180),
# and µ (181) represent apostrophe and smart quotes respectively; they never
# appear in legitimate English screenplay text, so they are reliable markers
# that a word — and any contiguous run of similarly-decodable words around
# it — is garbled.

_GFD: Dict[int, str] = {
    183: "'",        # · → apostrophe
    180: "‘",   # ´ → ' (left single quote)
    181: "’",   # µ → ' (right single quote)
}
for _cp in list(range(58, 62)) + list(range(68, 94)):
    _gd = chr(_cp + 29)
    if _gd.isalpha():
        _GFD[_cp] = _gd

_GFD_ANCHORS: frozenset = frozenset({183, 180, 181})


_VOWELS: frozenset = frozenset("aeiouAEIOU")

# Codepoints 68-70 (D, E, F) decode to 'a', 'b', 'c' via +29 shift.  When
# one of these opens a garbled word AND the remainder (decoded chars 2+)
# contains a vowel, the opener came from the regular (non-shifted) font and
# should be kept verbatim rather than shifted.
_GFD_AMBIGUOUS_OPENERS: frozenset = frozenset({68, 69, 70})  # D, E, F


def _gfd_decode_word(word: str) -> Optional[str]:
    """Decode a single non-space token. Returns None if any char can't decode."""
    out: List[str] = []
    for i, ch in enumerate(word):
        cp = ord(ch)
        if cp in _GFD:
            out.append(_GFD[cp])
        elif 65 <= cp <= 67:      # A, B, C — stored as literal in this encoding
            out.append(ch)
        elif not ch.isalpha():    # punctuation/digits at token boundary
            out.append(ch)
        else:
            return None

    if not out:
        return "".join(out)

    # Vowel-in-remainder heuristic: if the first source character is one of the
    # ambiguous openers (D/E/F) and the decoded remainder contains a vowel,
    # the opener belongs to the regular font — keep it as the original letter.
    first_cp = ord(word[0])
    if first_cp in _GFD_AMBIGUOUS_OPENERS and len(out) > 1:
        remainder = "".join(out[1:])
        if any(c in _VOWELS for c in remainder):
            out[0] = word[0]   # restore original uppercase letter

    return "".join(out)


def _fix_garbled_pypdfium2(line: str) -> str:
    """Decode a text line from a PDF whose font has a +29-shifted encoding.

    Splits the line into whitespace-separated tokens, groups consecutive
    fully-decodable tokens into runs, and decodes any run that contains at
    least one anchor character (·, ´, µ).  Runs without an anchor are left
    unchanged, preventing false positives on intentional all-caps words.
    """
    # Tokenise, preserving whitespace
    parts: List[str] = re.split(r"(\s+)", line)

    decoded: List[Optional[str]] = []
    is_anchor: List[bool] = []
    for part in parts:
        if not part or part.isspace():
            decoded.append(part)      # spaces pass through verbatim
            is_anchor.append(False)
        else:
            decoded.append(_gfd_decode_word(part))
            is_anchor.append(any(ord(c) in _GFD_ANCHORS for c in part))

    # Walk parts, collecting contiguous decodable-token runs.
    result: List[str] = list(parts)
    n = len(parts)
    i = 0
    while i < n:
        p = parts[i]
        if not p or p.isspace() or decoded[i] is None:
            i += 1
            continue

        # Start of a decodable run.  Collect run indices (spaces included as
        # pass-through items; they don't break the run but must be followed
        # by another decodable token to be included).
        run: List[int] = []
        anchor = False
        j = i
        while j < n:
            if not parts[j] or parts[j].isspace():
                # Include space only if the next non-empty part is decodable
                k = j + 1
                while k < n and (not parts[k] or parts[k].isspace()):
                    k += 1
                if k < n and decoded[k] is not None:
                    run.append(j)   # include the space
                    j += 1
                else:
                    break
            elif decoded[j] is not None:
                run.append(j)
                anchor = anchor or is_anchor[j]
                j += 1
            else:
                break

        if anchor:
            for k in run:
                result[k] = decoded[k]  # decoded[k] is the space itself for spaces

        i = j if j > i else i + 1

    return "".join(result)


def _cid_density(text: str) -> float:
    """Return fraction of characters that are (cid:N) artifacts."""
    total = len(text)
    if total == 0:
        return 0.0
    cid_chars = sum(len(m.group()) for m in re.finditer(r"\(cid:\d+\)", text))
    return cid_chars / total


def _pdf_has_cid_artifacts(pdf_path: str) -> bool:
    """Return True if any of the first few content pages have heavy CID artifacts."""
    with pdfplumber.open(pdf_path) as pdf:
        checked = 0
        for page in pdf.pages:
            text = page.extract_text() or ""
            if len(text) < 100:
                continue
            if _cid_density(text) > 0.03:
                return True
            checked += 1
            if checked >= 8:
                break
    return False


def _extract_layout_pypdfium2(pdf_path: str) -> List[str]:
    """Layout-preserving extraction via pypdfium2 — fallback for CID-heavy PDFs.

    Reconstructs indentation by using the x-position of each line's first
    character, calibrated to standard US Letter screenplay margins.
    """
    import pypdfium2 as pdfium  # optional dependency — only imported when needed

    LEFT_MARGIN = 54.0   # 0.75-inch left margin in PDF points
    CHAR_WIDTH  = 7.2    # Courier 12pt character width in PDF points

    out: List[str] = []
    pdf = pdfium.PdfDocument(pdf_path)
    for page_idx in range(len(pdf)):
        page = pdf[page_idx]
        textpage = page.get_textpage()
        page_height = page.get_height()
        n = textpage.count_chars()

        line_chars: List[str] = []
        line_xs: List[float] = []

        def _flush_line() -> None:
            if not line_chars:
                return
            x_start = min(line_xs)
            text = _fix_garbled_pypdfium2("".join(line_chars))
            indent = max(0, round((x_start - LEFT_MARGIN) / CHAR_WIDTH))
            out.append(" " * indent + text)
            line_chars.clear()
            line_xs.clear()

        for i in range(n):
            box = textpage.get_charbox(i, loose=False)
            x = box[0]
            ch = textpage.get_text_range(i, 1)
            if ch in ("\r", "\n"):
                _flush_line()
            else:
                line_chars.append(ch)
                line_xs.append(x)
        _flush_line()

    return out


def extract_layout_lines(pdf_path: str) -> List[str]:
    """Return layout-preserving lines (layout=True). Best for heist/screenplay."""
    if _pdf_has_cid_artifacts(pdf_path):
        try:
            return _extract_layout_pypdfium2(pdf_path)
        except Exception:
            pass  # pypdfium2 unavailable or failed — fall through to pdfplumber

    all_lines: List[str] = []
    page_sets: List[Set[str]] = []
    with pdfplumber.open(pdf_path) as pdf:
        for page in pdf.pages:
            text = page.extract_text(layout=True, x_tolerance=2) or ""
            pg_set: Set[str] = set()
            for line in text.split("\n"):
                undoubled = _undouble(line)
                all_lines.append(undoubled)
                s = undoubled.strip()
                if s:
                    pg_set.add(s)
            page_sets.append(pg_set)

    noise = _layout_page_noise(page_sets)
    if noise:
        return [l for l in all_lines if l.strip() not in noise]
    return all_lines


def _layout_page_noise(page_sets: List[Set[str]]) -> Set[str]:
    """Identify running headers/footers that appear on most pages.

    These are typically the script title, draft date, and revision marks
    that repeat in the header/footer of every page.
    """
    if len(page_sets) < 4:
        return set()
    total_pages = len(page_sets)
    threshold = max(4, total_pages * 0.55)
    noise: Set[str] = set()
    candidates: Set[str] = set().union(*page_sets)
    for s in candidates:
        if len(s) > 100:
            continue
        count = sum(1 for pg in page_sets if s in pg)
        if count < threshold:
            continue
        # Single all-caps words are likely frequent speaker names, not headers
        if re.fullmatch(r"[A-Z][A-Z0-9]{1,24}", s):
            continue
        noise.add(s)
    return noise


def _group_words_into_rows(words: List[dict], y_tolerance: float = 3.0) -> List[List[dict]]:
    """Group pdfplumber word dicts into horizontal rows by their top y-coordinate.

    Words within *y_tolerance* PDF points of the first word in a row are
    considered co-linear.  Rows are returned sorted top-to-bottom.
    """
    if not words:
        return []
    sorted_words = sorted(words, key=lambda w: (w["top"], w["x0"]))
    rows: List[List[dict]] = [[sorted_words[0]]]
    for word in sorted_words[1:]:
        if abs(word["top"] - rows[-1][0]["top"]) <= y_tolerance:
            rows[-1].append(word)
        else:
            rows.append([word])
    return rows


def _strip_page_number_words(row: List[dict], page_width: float) -> List[dict]:
    """Remove far-right digit-only words (page number candidates) from a word row.

    Page numbers appear at x0 > 75 % of page width and consist only of digits
    with an optional trailing period (e.g. "3", "22", "3.", "186.").  Stripping
    them before column detection prevents ``_detect_column_split_with_hint`` from
    false-splitting a single-column dialog row whose last word happens to share a
    y-coordinate with the far-right page number.
    """
    threshold = page_width * 0.75
    return [
        w for w in row
        if not (w["x0"] >= threshold and re.fullmatch(r"\d+\.?", w["text"]))
    ]


def _detect_column_split(row_words: List[dict], page_width: float,
                         min_gap_pct: float = 0.08) -> Optional[float]:
    """Return the x midpoint of a two-column gap, or None for single-column rows.

    A two-column gap must satisfy all of:
      • Both left and right clusters have at least one word.
      • The gap (empty horizontal space) is ≥ ``min_gap_pct`` × page width
        (default 8 %; normal word spacing is ≤ 3 %, so 8 % is safe against
        false positives while catching tightly-typeset column layouts).
      • The midpoint of the gap falls in the 20 – 80 % horizontal zone
        (rules out "body text + page number" layouts where the gap is far right).
      • All word x-coordinates are plausibly within the page bounds (rejects
        PDFs with broken coordinate data where x > page_width * 1.5).
    """
    if len(row_words) < 2:
        return None

    # Sanity-check: reject rows where any word is wildly outside page bounds.
    if any(w["x0"] < -10 or w["x1"] > page_width * 1.5 for w in row_words):
        return None

    by_x = sorted(row_words, key=lambda w: w["x0"])
    max_gap = 0.0
    gap_mid: Optional[float] = None
    for i in range(len(by_x) - 1):
        gap = by_x[i + 1]["x0"] - by_x[i]["x1"]
        if gap > max_gap:
            max_gap = gap
            gap_mid = (by_x[i]["x1"] + by_x[i + 1]["x0"]) / 2.0

    if gap_mid is None:
        return None
    if max_gap < page_width * min_gap_pct:
        return None
    if not (page_width * 0.20 <= gap_mid <= page_width * 0.80):
        return None
    return gap_mid


def _detect_column_split_with_hint(row_words: List[dict], page_width: float,
                                    hint_col_x: float,
                                    min_gap_pct: float = 0.05) -> Optional[float]:
    """Split a row at *hint_col_x* if words appear on both sides with a visible gap.

    Used for per-page column tracking: once we've established a column x-position
    from a clearly-split row, we apply it to ambiguous rows (long left-column text
    that narrows the physical gap below the primary threshold).  The secondary
    threshold is 5 % of page width — far above normal inter-word spacing (< 1 %).

    Words are assigned to left/right by their *centre* x-coordinate so that words
    which straddle the column boundary are attributed to their dominant side rather
    than excluded from both groups (which would create a spuriously large gap in
    single-column lines).

    Returns *hint_col_x* if the split is valid, else None.
    """
    if len(row_words) < 2:
        return None
    if any(w["x0"] < -10 or w["x1"] > page_width * 1.5 for w in row_words):
        return None

    # Assign each word to the side whose column centre it is closest to.
    # Using word-centre avoids false splits when a word straddles hint_col_x.
    left_words  = [w for w in row_words if (w["x0"] + w["x1"]) / 2 < hint_col_x]
    right_words = [w for w in row_words if (w["x0"] + w["x1"]) / 2 >= hint_col_x]
    if not left_words or not right_words:
        return None

    # Measure the actual physical gap between the rightmost left word and the
    # leftmost right word (using x1 / x0, not centres).
    left_max_x1  = max(w["x1"] for w in left_words)
    right_min_x0 = min(w["x0"] for w in right_words)
    gap = right_min_x0 - left_max_x1
    if gap < page_width * min_gap_pct:
        return None
    return hint_col_x


def _detect_column_split_at_boundary(
    row_words: List[dict],
    page_width: float,
    right_col_start: float,
    align_tolerance: float = 15.0,
    left_margin_pct: float = 0.25,
) -> Optional[float]:
    """Split at *right_col_start* when the leftmost right-side word starts near that boundary.

    Used as a last-resort detector for two-column rows where the left-column
    text is so long that the gap between columns is nearly zero (< 1 % of
    page width).  Two discriminators together reject single-column false positives:

    1. **Right-side alignment** — the leftmost word with ``x0 >= right_col_start``
       must start within *align_tolerance* (15 pt) of the known column edge.
       Rejects mid-sentence words that happen to cross the threshold far from
       the actual column start.

    2. **Left-side margin check** — the leftmost left-side word must start in
       the left *left_margin_pct* (25 %) of the page.  This rejects indented
       single-column text (stage directions, parentheticals) whose words span
       across *right_col_start* mid-sentence but don't start near the left margin
       that genuine left-column dialog uses.

    Returns *right_col_start* if both tests pass, else None.
    """
    if len(row_words) < 2:
        return None
    if any(w["x0"] < -10 or w["x1"] > page_width * 1.5 for w in row_words):
        return None

    right_words = [w for w in row_words if w["x0"] >= right_col_start]
    left_words  = [w for w in row_words if w["x0"] <  right_col_start]

    if not right_words or not left_words:
        return None

    # Discriminator 1: leftmost right-side word must start near the column edge.
    right_min_x0 = min(w["x0"] for w in right_words)
    if right_min_x0 > right_col_start + align_tolerance:
        return None

    # Discriminator 2: leftmost left-side word must start near the page's left
    # margin.  Genuine dialog (left column) starts close to the left edge;
    # indented stage directions start much further right and would otherwise
    # produce false positives when their text happens to span right_col_start.
    left_min_x0 = min(w["x0"] for w in left_words)
    if left_min_x0 > page_width * left_margin_pct:
        return None

    return right_col_start


# Sentinel character used to separate left- and right-column text on two-column rows.
# Must be a character that never appears in normal script text.
_COL_SEP = "\x01"


def _is_italic_font(fontname: str) -> bool:
    """Return True if the font name indicates italic or oblique style."""
    fn = fontname.lower()
    return (
        "italic" in fn
        or "oblique" in fn
        or "slanted" in fn
        or fn.endswith("-it")
        or fn.endswith("-i")
        or "-ital" in fn
        or "ital-" in fn
    )


def _is_bold_font(fontname: str) -> bool:
    """Return True if the font name indicates bold weight.

    Covers the most common naming conventions used by PDF font subsetting:
    ``ArialMT,Bold``, ``Arial-BoldMT``, ``Arial-Bold``, ``Arial-BoldOblique``,
    ``TimesNewRomanPS-BoldMT``, ``Helvetica-Bold``, ``ABCDEF+Helvetica-Bold``,
    ``NimbusSanL-Bold``, etc.  Does not false-positive on ``boldly``.
    """
    # Strip common PDF subset prefix (e.g. "ABCDEF+HelveticaNeue-Bold").
    fn = re.sub(r"^[A-Z]{6}\+", "", fontname).lower()
    # Match whole-word "bold" or canonical suffix/prefix forms.
    return bool(
        re.search(r"\bbold\b", fn)          # "bold" as its own token
        or fn.endswith("-bd")               # some condensed naming
        or fn.endswith("-b")                # rare but seen in PDFLib fonts
        or "-bold" in fn                    # e.g. helvetica-boldoblique
        or "bold-" in fn
        or ",bold" in fn                    # e.g. arialmt,bold
    )


def _find_italic_lines(pdf_path: str) -> Set[str]:
    """Return stripped line-text strings that are predominantly italic in the PDF.

    Uses pdfplumber character-level font info.  A line is considered italic when
    more than half of its printable characters are in an italic/oblique font.
    Falls back to an empty set if the PDF has no font data or cannot be opened.
    """
    italic_texts: Set[str] = set()
    try:
        with pdfplumber.open(pdf_path) as pdf:
            for page in pdf.pages:
                chars = page.chars
                if not chars:
                    continue
                # Group non-whitespace characters by y-position bucket (2 pt tolerance).
                buckets: Dict[int, List[dict]] = {}
                for ch in chars:
                    if not ch.get("text", "").strip():
                        continue
                    y_key = round(float(ch.get("top", 0)) / 2)
                    buckets.setdefault(y_key, []).append(ch)
                for chars_in_line in buckets.values():
                    text = " ".join("".join(c["text"] for c in chars_in_line).split()).strip()
                    if not text:
                        continue
                    italic_count = sum(
                        1 for c in chars_in_line
                        if _is_italic_font(c.get("fontname", ""))
                    )
                    if italic_count / len(chars_in_line) > 0.5:
                        italic_texts.add(text)
    except Exception:
        pass
    return italic_texts


def _extract_structured_lines(pdf_path: str) -> List[StructuredLine]:
    """Extract lines with full spatial and typographic metadata.

    Phase-2 parser foundation.  Uses pdfplumber char-level data to record
    ``x`` (left edge), ``y`` (top), ``is_italic``, ``is_bold``, and ``page``
    for every logical line.  Falls back gracefully when font or spatial data
    is absent.

    The function mirrors the blank-line insertion logic of
    :func:`_extract_plain_lines_with_pages` so that downstream classifiers
    can use the same vertical-gap heuristics.  Page boundaries are flagged
    with ``is_page_break=True`` on an empty-text sentinel line so callers
    can detect page transitions without relying on line-index arithmetic.

    Algorithm
    ---------
    1. For each PDF page, group characters into y-buckets (2 pt tolerance).
    2. Sort buckets by y (top → bottom).
    3. Insert a blank-line sentinel when the vertical gap exceeds
       ~1.6× estimated line height (same threshold as plain extraction).
    4. For each bucket, compute:
       * ``text``      — joined characters, whitespace-normalised
       * ``x``         — minimum ``x0`` of non-whitespace chars
       * ``y``         — the bucket's y value × 2 (un-bucketed)
       * ``is_italic`` — majority of chars use an italic font
       * ``is_bold``   — majority of chars use a bold font
    5. Append a page-break sentinel between pages.
    """
    result: List[StructuredLine] = []
    try:
        with pdfplumber.open(pdf_path) as pdf:
            for page_idx, page in enumerate(pdf.pages):
                chars = page.chars
                if not chars:
                    # Empty page — emit page-break sentinel and continue.
                    result.append(StructuredLine(
                        text="", x=None, y=None,
                        page=page_idx, is_page_break=True,
                    ))
                    continue

                # -----------------------------------------------------------------
                # 1. Group non-whitespace chars into y-buckets (2 pt tolerance).
                # -----------------------------------------------------------------
                buckets: Dict[int, List[dict]] = {}
                for ch in chars:
                    if not ch.get("text", "").strip():
                        continue
                    y_key = round(float(ch.get("top", 0)) / 2)
                    buckets.setdefault(y_key, []).append(ch)

                if not buckets:
                    result.append(StructuredLine(
                        text="", x=None, y=None,
                        page=page_idx, is_page_break=True,
                    ))
                    continue

                # -----------------------------------------------------------------
                # 2. Sort buckets top → bottom.
                # -----------------------------------------------------------------
                sorted_keys = sorted(buckets.keys())

                # -----------------------------------------------------------------
                # 3. Estimate line height for blank-gap detection.
                #    Each bucket key is y/2, so actual y ≈ key*2.
                # -----------------------------------------------------------------
                if len(sorted_keys) >= 3:
                    gaps = [
                        (sorted_keys[i + 1] - sorted_keys[i]) * 2
                        for i in range(len(sorted_keys) - 1)
                        if sorted_keys[i + 1] > sorted_keys[i]
                    ]
                    avg_gap = sum(gaps) / len(gaps) if gaps else 14.0
                else:
                    avg_gap = 14.0
                blank_threshold = max(avg_gap * 1.6, 18.0)

                prev_y_key: Optional[int] = None

                for y_key in sorted_keys:
                    chars_in_line = buckets[y_key]

                    # -----------------------------------------------------------------
                    # 3 (cont). Insert blank sentinel for large vertical gaps.
                    # -----------------------------------------------------------------
                    if prev_y_key is not None:
                        gap_pts = (y_key - prev_y_key) * 2
                        if gap_pts >= blank_threshold:
                            result.append(StructuredLine(
                                text="", x=None, y=float(prev_y_key * 2 + avg_gap),
                                page=page_idx,
                            ))
                    prev_y_key = y_key

                    # -----------------------------------------------------------------
                    # 4. Compute per-line text and metadata.
                    #
                    # PDF files do NOT encode word spaces as whitespace characters —
                    # they represent spaces by leaving a horizontal gap between the
                    # last character of one word and the first character of the next.
                    # Simply concatenating chars produces "InJesusnamewepray." instead
                    # of "In Jesus name we pray."
                    #
                    # Fix: sort chars left-to-right by x0 and insert a space whenever
                    # the gap between consecutive chars exceeds 40 % of the average
                    # character width.  This matches what pdfplumber's extract_words()
                    # does internally.
                    # -----------------------------------------------------------------
                    chars_sorted = sorted(
                        chars_in_line, key=lambda c: float(c.get("x0", 0))
                    )
                    if chars_sorted:
                        avg_w = sum(
                            float(c.get("width", 6)) for c in chars_sorted
                        ) / len(chars_sorted)
                        word_gap = max(avg_w * 0.4, 1.5)  # floor at 1.5 pt
                        parts: List[str] = [chars_sorted[0].get("text", "")]
                        for i in range(1, len(chars_sorted)):
                            prev_c = chars_sorted[i - 1]
                            curr_c = chars_sorted[i]
                            prev_x1 = float(prev_c.get("x0", 0)) + float(
                                prev_c.get("width", 0)
                            )
                            curr_x0 = float(curr_c.get("x0", 0))
                            if curr_x0 - prev_x1 > word_gap:
                                parts.append(" ")
                            parts.append(curr_c.get("text", ""))
                        text = "".join(parts).strip()
                    else:
                        text = ""
                    if not text:
                        continue

                    # Left edge: minimum x0 of all chars in this line.
                    x_vals = [float(c["x0"]) for c in chars_in_line if "x0" in c]
                    x: Optional[float] = min(x_vals) if x_vals else None

                    y_val: float = float(y_key) * 2  # un-bucket to PDF points

                    italic_count = sum(
                        1 for c in chars_in_line
                        if _is_italic_font(c.get("fontname", ""))
                    )
                    bold_count = sum(
                        1 for c in chars_in_line
                        if _is_bold_font(c.get("fontname", ""))
                    )
                    n = len(chars_in_line)
                    is_italic = italic_count / n > 0.5
                    is_bold   = bold_count   / n > 0.5

                    result.append(StructuredLine(
                        text=text, x=x, y=y_val,
                        is_italic=is_italic, is_bold=is_bold,
                        page=page_idx,
                    ))

                # End-of-page sentinel.
                result.append(StructuredLine(
                    text="", x=None, y=None,
                    page=page_idx, is_page_break=True,
                ))

    except Exception:
        # On any failure return an empty list so callers can fall back safely.
        return []

    return result


# ---------------------------------------------------------------------------
# Scene-heading patterns used by _classify_lines
# ---------------------------------------------------------------------------

_SCENE_HEADING_RE = re.compile(
    r"""
    ^(?:
        (?:INT|EXT|INT\.\/EXT|EXT\.\/INT)[\.\s]  # screenplay INT./EXT.
        | SCENE\s+\w+                             # SCENE 3 / SCENE IV / SCENE ONE
        | ACT\s+\w+                               # ACT I / ACT 1 / ACT TWO
        | PART\s+\w+                              # PART ONE / PART 2 / PART IV
        | PROLOGUE\b | EPILOGUE\b                 # special sections
    )
    """,
    re.IGNORECASE | re.VERBOSE,
)

# A line is a speaker-cue candidate if it:
#   • Is not empty
#   • Is predominantly uppercase (≥ 85 % alpha chars are upper)
#   • Is short (≤ 60 chars)
#   • Does not look like a stage direction or scene heading
_LOWER_RE = re.compile(r"[a-z]")
_ALPHA_RE = re.compile(r"[A-Za-z]")


def _caps_ratio(text: str) -> float:
    """Fraction of alphabetic chars that are uppercase."""
    alpha = _ALPHA_RE.findall(text)
    if not alpha:
        return 0.0
    return sum(1 for c in alpha if c.isupper()) / len(alpha)


def _classify_lines(
    lines: List[StructuredLine],
    *,
    zones: Optional["LayoutZones"] = None,
    speaker_x_min: Optional[float] = None,
    speaker_x_max: Optional[float] = None,
    dialog_x_min: Optional[float] = None,
    dialog_x_max: Optional[float] = None,
) -> List[ClassifiedLine]:
    """Assign a structural role to every :class:`StructuredLine`.

    This is the **Phase-2 classifier** — a single-pass heuristic that uses
    x-position, capitalisation, punctuation, and typographic weight to label
    each line.  It does *not* replace any existing parser; it is an additive
    layer whose output will gradually inform format-specific parsers.

    Spatial zones can be supplied either as a :class:`LayoutZones` object
    (preferred — populated automatically by :func:`_infer_layout_zones`) or
    as explicit ``speaker_x_min/max`` / ``dialog_x_min/max`` keyword args
    (kept for backwards-compatibility with the existing test suite and the
    Phase-1 play-parser integration).  When both are present, the explicit
    kwargs take precedence over the derived zone bounds.

    Role assignment rules (first match wins):

    0. **noise** — page-marker / draft watermark (``[Draft 3.0] 4``) → ``'noise'``
    1. **blank / page_break** — empty text → ``'blank'``
    2. **scene_heading** — matches :data:`_SCENE_HEADING_RE` *or* (when zones
       are provided) bold + short + x within ±20 pt of
       ``zones.scene_heading_x`` → ``'scene_heading'``
    3. **parenthetical** — stripped text starts with ``(`` and ends with ``)``
       → ``'parenthetical'``
    4. **speaker_cue** — all of:
       * caps_ratio ≥ 0.85
       * len ≤ 60
       * not a noise/separator line
       * x within ``[speaker_x_min, speaker_x_max]`` (if provided)
       → ``'speaker_cue'``, ``speaker`` set to the text
    5. **dialog** — x within ``[dialog_x_min, dialog_x_max]`` (if provided),
       or follows a speaker_cue with no intervening blank line → ``'dialog'``
    6. **stage_direction** — default for anything not matched above.

    When no zone bounds are provided the classifier falls back to
    pure-text heuristics and works reasonably well for standard play formats.
    """
    # Derive zone bounds from the LayoutZones object when present.
    if zones is not None:
        if speaker_x_min is None:
            speaker_x_min = zones.cue_range[0]
        if speaker_x_max is None:
            speaker_x_max = zones.cue_range[1]
        if dialog_x_min is None:
            dialog_x_min = zones.dialog_range[0]
        if dialog_x_max is None:
            dialog_x_max = zones.dialog_range[1]
    classified: List[ClassifiedLine] = []
    last_role: str = "stage_direction"  # tracks context for dialog inference
    pending_speaker: Optional[str] = None  # set when we see a speaker_cue
    in_paren_block: bool = False  # True while inside a multi-line (stage direction)
    crossed_page_break: bool = False  # True through blanks that follow a page break

    for sl in lines:
        text = sl.text.strip()

        # ------------------------------------------------------------------
        # Rule 0 — noise / page marker
        #
        # Page-number watermarks appear on every page of a draft script
        # (e.g. "[Draft 3.0] 4") and must be dropped regardless of x-zone
        # or speaker context — they would otherwise be absorbed into the
        # preceding character's dialog.
        # ------------------------------------------------------------------
        if text and _PAGE_MARKER_RE.match(text):
            classified.append(ClassifiedLine(line=sl, role="noise"))
            continue

        # ------------------------------------------------------------------
        # Rule 1 — blank
        # ------------------------------------------------------------------
        if not text:
            classified.append(ClassifiedLine(line=sl, role="blank"))
            if sl.is_page_break:
                # Mark that any following blanks belong to a page-break gap
                # so pending_speaker is preserved across the full gap.
                crossed_page_break = True
            elif crossed_page_break:
                # Blank padding after a page break — keep speaker context alive
                # so dialog that resumes without a fresh attribution line still
                # gets the right speaker.
                pass
            else:
                # An ordinary blank line ends the current speaker context.
                pending_speaker = None
                in_paren_block = False
            last_role = "blank"
            continue

        # Any non-blank content ends the page-break grace window.
        crossed_page_break = False

        # ------------------------------------------------------------------
        # Rule 2 — scene heading
        # Two detection paths (first match wins):
        #   a) Keyword pattern (INT./EXT., ACT N, SCENE N, etc.)
        #   b) Spatial+typographic: bold + short + near scene_heading_x zone
        # ------------------------------------------------------------------
        is_scene_heading = _SCENE_HEADING_RE.match(text) is not None
        if (
            not is_scene_heading
            and zones is not None
            and zones.scene_heading_x is not None
            and sl.is_bold
            and len(text) <= 60
            and sl.x is not None
            and abs(sl.x - zones.scene_heading_x) <= 30.0
        ):
            is_scene_heading = True
        if is_scene_heading:
            classified.append(ClassifiedLine(line=sl, role="scene_heading"))
            pending_speaker = None
            last_role = "scene_heading"
            continue

        # ------------------------------------------------------------------
        # Rule 3 — parenthetical (single-line)
        # ------------------------------------------------------------------
        if text.startswith("(") and text.endswith(")"):
            in_paren_block = False  # clean up any stale open block
            classified.append(ClassifiedLine(
                line=sl, role="parenthetical",
                speaker=pending_speaker,
            ))
            last_role = "parenthetical"
            continue

        # ------------------------------------------------------------------
        # Rule 3b — multi-line parenthetical block: continuation
        #
        # If we are already inside an open "(" block, every line until the
        # closing ")" is a stage direction embedded in the character's speech.
        # We do NOT clear pending_speaker so the line after ")" is still
        # attributed to the same character.
        # ------------------------------------------------------------------
        if in_paren_block:
            if text.endswith(")"):
                in_paren_block = False
            classified.append(ClassifiedLine(line=sl, role="stage_direction"))
            last_role = "stage_direction"
            # pending_speaker intentionally preserved
            continue

        # ------------------------------------------------------------------
        # Rule 3c — multi-line parenthetical block: opening
        #
        # A line that starts with "(" but does NOT close on the same line
        # opens a multi-line stage direction block.  All subsequent lines are
        # handled by Rule 3b until a ")" closes it.
        # ------------------------------------------------------------------
        if text.startswith("("):
            in_paren_block = True
            classified.append(ClassifiedLine(line=sl, role="stage_direction"))
            last_role = "stage_direction"
            # pending_speaker intentionally preserved
            continue

        # ------------------------------------------------------------------
        # Rule 4 — speaker cue
        #
        # Standard scripts annotate character names with short parenthetical
        # suffixes: "ALICE (cont.)", "TOM (V.O.)", "JOSH (CONT'D)",
        # "DENISE (on phone)".  These fail the bare caps-ratio test because
        # of the lowercase suffix, so we strip any trailing parenthetical of
        # ≤ 20 chars before testing — then use the stripped name as the
        # canonical speaker.
        # ------------------------------------------------------------------
        cue_text = re.sub(r"\s*\([^)]{1,20}\)\s*$", "", text).strip()
        cr = _caps_ratio(cue_text or text)
        is_short = len(cue_text or text) <= 60
        in_speaker_zone = (
            speaker_x_min is None
            or speaker_x_max is None
            or sl.x is None
            or (speaker_x_min <= sl.x <= speaker_x_max)
        )
        if cr >= 0.85 and is_short and in_speaker_zone:
            speaker_name = cue_text if cue_text else text
            pending_speaker = speaker_name
            classified.append(ClassifiedLine(
                line=sl, role="speaker_cue", speaker=speaker_name,
            ))
            last_role = "speaker_cue"
            continue

        # ------------------------------------------------------------------
        # Rule 4b — cue-zone stage direction (spatial override)
        #
        # When spatial zones are active (speaker_x_min is set), a line that:
        #   • sits at x ≥ the cue-zone lower bound (speaker_x_min ≈ threshold)
        #   • is NOT all-caps (already handled by Rule 4 above)
        #   • is NOT a parenthetical (already handled by Rule 3 above)
        # …is a stage direction masquerading in the cue column — the root
        # cause of the TheHarvest bug where "MARCUS smiles at DENISE." gets
        # appended to the preceding character's dialog.
        #
        # This check fires BEFORE Rule 5 (dialog) so that even when a
        # pending_speaker is active, prose in the cue zone is correctly
        # routed to stage_direction instead.
        # ------------------------------------------------------------------
        in_cue_zone = (
            speaker_x_min is not None
            and sl.x is not None
            and sl.x >= speaker_x_min
        )
        if in_cue_zone and cr < 0.85:
            # Mixed-case line in cue zone → stage direction.
            # Clear pending_speaker so following dialog lines know the SD
            # interrupted the dialog block (mirrors Phase-1 behavior).
            classified.append(ClassifiedLine(line=sl, role="stage_direction"))
            pending_speaker = None
            last_role = "stage_direction"
            continue

        # ------------------------------------------------------------------
        # Rule 4c — content-based stage direction (dialog-zone SDs)
        #
        # Catches stage directions that sit at the same x-position as dialog
        # text (left margin) and cannot be identified spatially.  Fires even
        # when a pending_speaker is active so lines like "Pause." and
        # "JOSH opens his eyes, looks at TOM." are not absorbed into the
        # preceding character's speech.
        #
        # Only active when a speaker/dialog context exists (pending_speaker
        # or last_role in dialog family) — without that context the line
        # would already fall through to stage_direction via Rule 6 anyway.
        # ------------------------------------------------------------------
        in_dialog_context = (
            pending_speaker is not None
            or last_role in ("dialog", "speaker_cue", "parenthetical")
        )
        if in_dialog_context and _looks_like_stage_direction(text):
            classified.append(ClassifiedLine(line=sl, role="stage_direction"))
            pending_speaker = None
            last_role = "stage_direction"
            continue

        # ------------------------------------------------------------------
        # Rule 5 — dialog
        # ------------------------------------------------------------------
        in_dialog_zone = (
            dialog_x_min is None
            or dialog_x_max is None
            or sl.x is None
            or (dialog_x_min <= sl.x <= dialog_x_max)
        )
        if pending_speaker is not None or (last_role in ("dialog", "speaker_cue", "parenthetical") and in_dialog_zone):
            classified.append(ClassifiedLine(
                line=sl, role="dialog",
                speaker=pending_speaker,
            ))
            last_role = "dialog"
            continue

        # ------------------------------------------------------------------
        # Rule 6 — stage direction (default)
        # ------------------------------------------------------------------
        classified.append(ClassifiedLine(line=sl, role="stage_direction"))
        pending_speaker = None
        last_role = "stage_direction"

    return classified


@dataclass
class LayoutZones:
    """Spatial layout zones inferred from a PDF's x-position distribution.

    All values are in PDF points (72 pt = 1 inch).

    ``dialog_x``  — median x of the low-x cluster (dialog text).
    ``cue_x``     — median x of the high-x cluster (speaker cues / SD).
    ``threshold`` — x value that splits the two clusters.

    ``scene_heading_x`` is the median x of lines that are both bold and
    short (≤ 40 chars), if a meaningful cluster was found; ``None`` otherwise.

    ``is_bimodal`` is True when two distinct x-clusters were found.
    Single-column documents (all text at the same indent) have
    ``is_bimodal=False`` and no meaningful spatial classification is possible.
    """

    dialog_x: float
    cue_x: float
    threshold: float
    is_bimodal: bool = True
    scene_heading_x: Optional[float] = None

    @property
    def dialog_range(self) -> Tuple[float, float]:
        """(min, max) x range for dialog lines (low cluster ± 15 pt tolerance)."""
        return (max(0.0, self.dialog_x - 15.0), self.threshold)

    @property
    def cue_range(self) -> Tuple[float, float]:
        """(min, max) x range for cue/SD lines (high cluster, lower-bounded)."""
        return (self.threshold, self.cue_x + 60.0)


def _infer_layout_zones(
    lines: List[StructuredLine],
    *,
    min_samples: int = 20,
    min_gap_pt: float = 30.0,
) -> Optional[LayoutZones]:
    """Infer spatial layout zones from a list of :class:`StructuredLine` objects.

    Phase-2 companion to :func:`_infer_x_zones`.  Uses a bimodal-gap algorithm
    that operates on :class:`StructuredLine` metadata directly, which lets it:

    * Skip page-break sentinels and blank lines automatically.
    * Optionally weight lines by typographic properties (future extension).
    * Detect a ``scene_heading_x`` zone from bold+short lines.

    Returns ``None`` when:

    * Fewer than ``min_samples`` valid x-positions are available.
    * The largest gap between *significant* x-buckets is < ``min_gap_pt``
      (unimodal → single column → no spatial classification possible).
    * Either the low or high cluster is empty after splitting.

    Parameters
    ----------
    lines:
        Output of :func:`_extract_structured_lines`.
    min_samples:
        Minimum number of non-blank lines with x data required to proceed.
    min_gap_pt:
        Minimum gap (PDF points) between x-buckets to consider the
        distribution bimodal.
    """
    # -----------------------------------------------------------------
    # 1. Collect valid x values from content lines.
    # -----------------------------------------------------------------
    x_vals: List[float] = [
        sl.x
        for sl in lines
        if sl.x is not None and sl.x > 0 and not sl.is_page_break and sl.text
    ]
    if len(x_vals) < min_samples:
        return None

    # -----------------------------------------------------------------
    # 2. Bucket into 5 pt bins.
    #
    #    Only consider buckets that are "significant" — meaning they hold
    #    at least 1 % of total lines (floor of 5).  This filters out stray
    #    clusters from page headers, right-margin page numbers, or a few
    #    oddly-indented lines that would otherwise split the main dialog/cue
    #    gap and mislead the threshold calculation.
    # -----------------------------------------------------------------
    bucket_counts: dict = {}
    for v in x_vals:
        b = round(v / 5.0) * 5.0
        bucket_counts[b] = bucket_counts.get(b, 0) + 1

    min_bucket_count = max(5, int(len(x_vals) * 0.01))
    sig_buckets = sorted(b for b, c in bucket_counts.items() if c >= min_bucket_count)

    if len(sig_buckets) < 2:
        return None

    # Find the largest gap between adjacent *significant* buckets.
    max_gap = 0.0
    threshold: Optional[float] = None
    for i in range(len(sig_buckets) - 1):
        gap = sig_buckets[i + 1] - sig_buckets[i]
        if gap > max_gap:
            max_gap = gap
            threshold = (sig_buckets[i] + sig_buckets[i + 1]) / 2.0

    if threshold is None or max_gap < min_gap_pt:
        return None

    low_vals  = sorted(v for v in x_vals if v <  threshold)
    high_vals = sorted(v for v in x_vals if v >= threshold)
    if not low_vals or not high_vals:
        return None

    dialog_x = low_vals[len(low_vals) // 2]
    cue_x    = high_vals[len(high_vals) // 2]

    # -----------------------------------------------------------------
    # 3. Scene-heading x: median x of bold + short lines.
    # -----------------------------------------------------------------
    bold_short_x: List[float] = [
        sl.x
        for sl in lines
        if sl.x is not None
        and sl.is_bold
        and len(sl.text.strip()) <= 40
        and not sl.is_page_break
    ]
    scene_heading_x: Optional[float] = None
    if len(bold_short_x) >= 3:
        bold_short_x.sort()
        scene_heading_x = bold_short_x[len(bold_short_x) // 2]

    return LayoutZones(
        dialog_x=dialog_x,
        cue_x=cue_x,
        threshold=threshold,
        is_bimodal=True,
        scene_heading_x=scene_heading_x,
    )


def _build_script_from_classified(
    classified: List[ClassifiedLine],
    title: str = "",
    *,
    default_scene_title: str = "Scene",
) -> Script:
    """Convert a list of :class:`ClassifiedLine` objects into a :class:`Script`.

    Phase-2 counterpart to the format-specific ``_extract_scenes_*`` functions.
    Produces a ``Script`` in the same shape as the existing parsers so
    downstream code (``audio_pipeline.py``, Swift bridge) needs no changes.

    Scene boundary detection
    ------------------------
    A new scene starts whenever a ``'scene_heading'`` line is encountered.
    If the document has no scene headings at all, the entire content is
    wrapped in a single scene (number 1).

    Element production
    ------------------
    * ``'speaker_cue'``     — updates ``current_speaker``; no Element emitted.
    * ``'dialog'``          — ``Element(kind='dialog', speaker=..., text=...)``
    * ``'stage_direction'`` — ``Element(kind='stage_direction', text=...)``
    * ``'parenthetical'``   — ``Element(kind='parenthetical', speaker=..., text=...)``
    * ``'scene_heading'``   — starts a new :class:`Scene`; no Element emitted.
    * ``'noise'`` / ``'blank'`` — skipped.

    Consecutive same-kind same-speaker lines are folded together with a
    space separator (mirrors the existing parser's dialog accumulation).

    Parameters
    ----------
    classified:
        Output of :func:`_classify_lines`.
    title:
        Script title (propagated from the caller, typically the PDF filename).
    default_scene_title:
        Title used for the synthetic Scene 1 when no headings are found.
    """
    scenes: List[Scene] = []
    current_scene: Optional[Scene] = None
    scene_counter = 0

    # Pending accumulation buffers (fold consecutive same-speaker dialog).
    acc_kind: Optional[str] = None
    acc_speaker: Optional[str] = None
    acc_texts: List[str] = []

    def flush_acc() -> None:
        nonlocal acc_kind, acc_speaker, acc_texts
        if not acc_texts or not acc_kind or not current_scene:
            acc_texts = []
            acc_kind = None
            acc_speaker = None
            return
        text = " ".join(acc_texts).strip()
        if text:
            current_scene.elements.append(Element(
                kind=acc_kind,
                text=text,
                speaker=acc_speaker,
            ))
        acc_texts = []
        acc_kind = None
        acc_speaker = None

    def ensure_scene(heading: str = "") -> None:
        nonlocal current_scene, scene_counter
        flush_acc()
        scene_counter += 1
        s = Scene(number=scene_counter, title=heading or f"{default_scene_title} {scene_counter}")
        scenes.append(s)
        current_scene = s

    for cl in classified:
        role = cl.role
        text = cl.line.text.strip()

        # ------------------------------------------------------------------
        # Skip noise, blanks, and page-break sentinels.
        # ------------------------------------------------------------------
        if role in ("blank", "noise") or not text:
            continue

        # ------------------------------------------------------------------
        # Scene headings open a new scene.
        # ------------------------------------------------------------------
        if role == "scene_heading":
            ensure_scene(text)
            continue

        # ------------------------------------------------------------------
        # Lazily create scene 1 if the document has no headings.
        # ------------------------------------------------------------------
        if current_scene is None:
            ensure_scene(default_scene_title)

        # ------------------------------------------------------------------
        # Speaker cues update current speaker; nothing emitted.
        # ------------------------------------------------------------------
        if role == "speaker_cue":
            # A new speaker cue flushes any accumulated dialog from the prior
            # speaker before switching.
            flush_acc()
            # (speaker stored in cl.speaker; no Element)
            continue

        # ------------------------------------------------------------------
        # Dialog, stage direction, parenthetical — accumulate or flush+start.
        # ------------------------------------------------------------------
        speaker = cl.speaker
        if role == acc_kind and speaker == acc_speaker:
            # Continue accumulating same-speaker same-kind run.
            acc_texts.append(text)
        else:
            flush_acc()
            acc_kind = role
            acc_speaker = speaker
            acc_texts = [text]

    # Final flush.
    flush_acc()

    # ------------------------------------------------------------------
    # Build character list from all dialog speaker names.
    # ------------------------------------------------------------------
    seen_speakers: Dict[str, int] = {}  # speaker → dialog count
    for sc in scenes:
        for el in sc.elements:
            if el.kind == "dialog" and el.speaker:
                seen_speakers[el.speaker] = seen_speakers.get(el.speaker, 0) + 1

    characters = [
        Character(name=name)
        for name, _count in sorted(seen_speakers.items(), key=lambda kv: (-kv[1], kv[0]))
    ]

    return Script(title=title, characters=characters, scenes=scenes)


def _extract_plain_lines(pdf_path: str) -> List[str]:
    """Return plain (non-layout) lines. Best for standard play format."""
    lines, _, _ = _extract_plain_lines_with_pages(pdf_path)
    return lines


def _extract_plain_lines_with_pages(pdf_path: str) -> Tuple[List[str], List[Set[str]], List[Optional[float]]]:
    """Return (all_lines, per_page_content_sets, line_x_positions) for play parsing.

    Two-column rows (simultaneous-speech overlap sections common in published
    play PDFs) are emitted as a single line with ``_COL_SEP`` (``\\x01``)
    separating the left- and right-column text::

        "EDDIE\\x01LEAH"
        "Hello there.\\x01I'm fine."

    The play-format parser recognises these markers and reconstructs per-voice
    dialog instead of falling back to the sentence-boundary heuristic.

    ``line_x_positions`` is parallel to ``all_lines``: each entry is the
    minimum x0 (in PDF points) of the words on that row, or ``None`` for
    blank/padding lines and pages where spatial data is unavailable.
    """
    if _pdf_has_cid_artifacts(pdf_path):
        try:
            import pypdfium2 as pdfium
            plain_lines: List[str] = []
            pypdf_page_sets: List[Set[str]] = []
            pdf_doc = pdfium.PdfDocument(pdf_path)
            for page_idx in range(len(pdf_doc)):
                page = pdf_doc[page_idx]
                textpage = page.get_textpage()
                text = textpage.get_text_range()
                pg_set: Set[str] = set()
                for line in text.splitlines():
                    normalized = _fix_garbled_pypdfium2(_undouble(line))
                    plain_lines.append(normalized)
                    s = normalized.strip()
                    if s:
                        pg_set.add(s)
                pypdf_page_sets.append(pg_set)
            # pypdfium2 path: no per-line x0 available
            return plain_lines, pypdf_page_sets, [None] * len(plain_lines)
        except Exception:
            pass  # fall through to pdfplumber

    all_lines: List[str] = []
    page_sets: List[Set[str]] = []
    positions: List[Optional[float]] = []
    with pdfplumber.open(pdf_path) as pdf:
        for page in pdf.pages:
            page_width = float(page.width or 612)
            words = page.extract_words(x_tolerance=3, y_tolerance=3) or []
            page_content: Set[str] = set()

            if not words:
                all_lines.append("")
                positions.append(-1.0)  # page-break sentinel (empty page)
                page_sets.append(page_content)
                continue

            # Sanity-check word coordinates.  Some PDFs have malformed glyph
            # positioning (x > 3000 on a 612pt page, negative y, etc.) that
            # makes extract_words() useless.  Fall back to extract_text() for
            # those pages so column detection doesn't fire on garbage data.
            median_x = sorted(w["x0"] for w in words)[len(words) // 2]
            if median_x > page_width * 1.2 or median_x < -10:
                text = page.extract_text() or ""
                for line in text.split("\n"):
                    normalized = _undouble(line)
                    all_lines.append(normalized)
                    positions.append(None)  # no reliable x0 for malformed-coord pages
                    s = normalized.strip()
                    if s:
                        page_content.add(s)
                all_lines.append("")
                positions.append(-1.0)  # page-break sentinel (malformed-coord fallback)
                page_sets.append(page_content)
                continue

            rows = _group_words_into_rows(words)

            # Estimate the dominant line height for this page so we can detect
            # paragraph breaks (vertical gaps > 1.5× line height → blank line).
            if len(rows) >= 3:
                gaps = []
                for ri in range(len(rows) - 1):
                    this_bottom = max(w.get("bottom", w["top"]) for w in rows[ri])
                    next_top    = rows[ri + 1][0]["top"]
                    g = next_top - this_bottom
                    if g > 0:
                        gaps.append(g)
                avg_gap = sum(gaps) / len(gaps) if gaps else 14.0
            else:
                avg_gap = 14.0
            BLANK_GAP_THRESHOLD = max(avg_gap * 1.6, 18.0)

            # Per-page column tracking: detect a consensus column x-position from
            # clearly-split rows, then reuse it for rows where the left-column text
            # is long enough to narrow the gap below the primary threshold.
            # Also track right_col_start = minimum x0 of right-side words across
            # detected rows — used by the last-resort boundary detector for rows
            # where the gap is near zero but the right column starts at a fixed x.
            col_x_values: List[float] = []
            right_col_start_values: List[float] = []
            for _row in rows:
                _stripped = _strip_page_number_words(_row, page_width)
                if not _stripped:
                    continue
                _cx = _detect_column_split(_stripped, page_width)
                if _cx is not None:
                    col_x_values.append(_cx)
                    _rw = [w for w in _stripped if w["x0"] >= _cx]
                    if _rw:
                        right_col_start_values.append(min(w["x0"] for w in _rw))
            consensus_col_x: Optional[float] = None
            if col_x_values:
                col_x_values.sort()
                consensus_col_x = col_x_values[len(col_x_values) // 2]
            right_col_start: Optional[float] = None
            if right_col_start_values:
                right_col_start = min(right_col_start_values)

            prev_bottom: Optional[float] = None
            for row in rows:
                row_top    = row[0]["top"]
                row_bottom = max(w.get("bottom", w["top"]) for w in row)

                # Emit a blank line when the vertical gap signals a paragraph break.
                if prev_bottom is not None and (row_top - prev_bottom) >= BLANK_GAP_THRESHOLD:
                    all_lines.append("")
                    positions.append(None)
                prev_bottom = row_bottom

                # Strip far-right digit-only words (page numbers) before column
                # detection so a page number sharing a y-coordinate with the
                # first dialog line on the page doesn't trigger a false split.
                content_row = _strip_page_number_words(row, page_width)
                if not content_row:
                    # Row was pure page number — skip text emission; prev_bottom
                    # is already updated so blank-line logic stays correct.
                    continue

                # x0 for this row: minimum left edge across all content words.
                row_x0: float = min(w["x0"] for w in content_row)

                col_x = _detect_column_split(content_row, page_width)
                # If the primary detector didn't fire but we know the column x,
                # try the secondary (lower-threshold) detector.
                if col_x is None and consensus_col_x is not None:
                    col_x = _detect_column_split_with_hint(content_row, page_width, consensus_col_x)
                # Last resort: when the left-column text is so long that the gap
                # between columns is near zero, use the known right-column start
                # position directly (tolerance check filters single-column false positives).
                if col_x is None and right_col_start is not None:
                    col_x = _detect_column_split_at_boundary(content_row, page_width, right_col_start)
                if col_x is not None:
                    # Use x0 (not x1) for the left-side filter so words that
                    # straddle the column boundary are attributed to their
                    # dominant (left) side rather than dropped.
                    left_words  = sorted((w for w in content_row if w["x0"] <  col_x), key=lambda w: w["x0"])
                    right_words = sorted((w for w in content_row if w["x0"] >= col_x), key=lambda w: w["x0"])
                    left_text  = _undouble(" ".join(w["text"] for w in left_words))
                    right_text = _undouble(" ".join(w["text"] for w in right_words))
                    if left_text and right_text:
                        line = f"{left_text}{_COL_SEP}{right_text}"
                        all_lines.append(line)
                        positions.append(row_x0)
                        page_content.add(left_text.strip())
                        page_content.add(right_text.strip())
                    else:
                        # Only one side non-empty — treat as single column
                        text = _undouble((left_text or right_text).strip())
                        all_lines.append(text)
                        positions.append(row_x0)
                        if text.strip():
                            page_content.add(text.strip())
                else:
                    by_x = sorted(content_row, key=lambda w: w["x0"])
                    text = _undouble(" ".join(w["text"] for w in by_x))
                    # If every word's centre is to the right of the consensus
                    # column x, this row belongs to the right column only
                    # (e.g. the right voice has more lines than the left in a
                    # two-column overlap block).  Mark it "\x01text" so the
                    # scene parser can route it to the right voice exclusively
                    # rather than adding it to both L and R text.
                    if (
                        consensus_col_x is not None
                        and text.strip()
                        and all(
                            (w["x0"] + w["x1"]) / 2 >= consensus_col_x
                            for w in content_row
                        )
                    ):
                        all_lines.append(f"{_COL_SEP}{text}")
                        positions.append(row_x0)
                        page_content.add(text.strip())
                    else:
                        all_lines.append(text)
                        positions.append(row_x0)
                        if text.strip():
                            page_content.add(text.strip())

            # Blank line between pages (mirrors extract_text() behaviour).
            # Use -1.0 as a sentinel so the play parser can distinguish page-break
            # blanks (speaker context should be preserved) from intra-page paragraph
            # gaps (speaker context should be cleared).
            all_lines.append("")
            positions.append(-1.0)
            page_sets.append(page_content)
    return all_lines, page_sets, positions


def _infer_x_zones(
    positions: List[Optional[float]],
) -> Optional[Tuple[float, float, float]]:
    """Return (dialog_x, cue_x, threshold) by finding the largest gap in x0 values.

    Clusters line x-positions into a low group (dialog) and a high group
    (speaker cues / stage directions) by locating the biggest gap in the
    sorted distribution of unique 5-pt bucket positions.

    Returns None when:
      - fewer than 20 valid positions (not enough data)
      - the largest gap is < 30 pt (distribution is unimodal — one zone only)
      - either cluster is empty after splitting at the threshold
    """
    vals: List[float] = [p for p in positions if p is not None and p > 0]
    if len(vals) < 20:
        return None

    # Bucket into 5 pt bins to cluster nearby positions
    buckets = sorted(set(round(v / 5.0) * 5.0 for v in vals))
    if len(buckets) < 2:
        return None

    # Find the largest gap between consecutive bucket values
    max_gap = 0.0
    threshold: Optional[float] = None
    for i in range(len(buckets) - 1):
        gap = buckets[i + 1] - buckets[i]
        if gap > max_gap:
            max_gap = gap
            threshold = (buckets[i] + buckets[i + 1]) / 2.0

    # Gap must be meaningful (> 30 pt ≈ 0.4 inch) to indicate two distinct zones
    if threshold is None or max_gap < 30.0:
        return None

    low_vals = [v for v in vals if v < threshold]
    high_vals = [v for v in vals if v >= threshold]
    if not low_vals or not high_vals:
        return None

    low_vals.sort()
    high_vals.sort()
    dialog_x = low_vals[len(low_vals) // 2]
    cue_x = high_vals[len(high_vals) // 2]
    return (dialog_x, cue_x, threshold)


# ---------------------------------------------------------------------------
# Indent-zone auto-calibration (heist / scene_n formats)
# ---------------------------------------------------------------------------


def _detect_indent_zones(lines: List[str]) -> Dict[str, int]:
    """Analyse a script's indentation to calibrate zone thresholds."""
    cue_indents: List[int] = []
    lower_indents: List[int] = []

    for raw in lines:
        s = raw.strip()
        if not s or len(s) < 3:
            continue
        indent = len(raw) - len(raw.lstrip(" "))
        if indent > 70:
            continue
        if re.fullmatch(r"[\d\.\s]+", s):
            continue

        base = re.sub(r"\s*\([^)]*\)\s*$", "", s).strip()
        if (
            re.fullmatch(r"[A-Z][A-Z0-9 \-/'']+", base)
            and 2 <= len(base) <= 35
            and not base.endswith(".")
        ):
            cue_indents.append(indent)
        elif re.search(r"[a-z]", s) and len(s) >= 10:
            lower_indents.append(indent)

    if len(cue_indents) < 8 or len(lower_indents) < 8:
        return {}

    cue_mode = Counter(cue_indents).most_common(1)[0][0]

    below_cue = [d for d in lower_indents if d < cue_mode - 3]
    if len(below_cue) < 5:
        return {}

    # Dialog typically sits closest to the cue zone (above stage directions).
    # When two strong peaks exist (e.g. stage dirs at indent 24, dialog at 41),
    # prefer the HIGHER-INDENT peak.  Use 25% of the most-common count as the
    # significance threshold for a peak to be considered.
    lc_counts = Counter(below_cue)
    top_peaks = lc_counts.most_common(6)
    max_freq = top_peaks[0][1]
    significant = [ind for ind, freq in top_peaks if freq >= max_freq * 0.25]
    dialog_mode = max(significant)

    if dialog_mode >= cue_mode:
        return {}

    return {
        "DIALOG_INDENT_MIN": max(0, dialog_mode - 8),
        "DIALOG_INDENT_MAX": min(cue_mode - 4, dialog_mode + 10),
        "CUE_INDENT_MIN": max(dialog_mode + 6, cue_mode - 5),
        "PARENTHETICAL_INDENT_MIN": dialog_mode + 3,
        "PARENTHETICAL_INDENT_MAX": cue_mode + 8,
        "PAGE_NUMBER_INDENT_MIN": max(55, cue_mode + 20),
    }


def _make_zones(overrides: Dict[str, int]) -> Dict[str, int]:
    return {
        "DIALOG_INDENT_MIN": overrides.get("DIALOG_INDENT_MIN", DIALOG_INDENT_MIN),
        "DIALOG_INDENT_MAX": overrides.get("DIALOG_INDENT_MAX", DIALOG_INDENT_MAX),
        "CUE_INDENT_MIN": overrides.get("CUE_INDENT_MIN", CUE_INDENT_MIN),
        "PARENTHETICAL_INDENT_MIN": overrides.get(
            "PARENTHETICAL_INDENT_MIN", PARENTHETICAL_INDENT_MIN
        ),
        "PARENTHETICAL_INDENT_MAX": overrides.get(
            "PARENTHETICAL_INDENT_MAX", PARENTHETICAL_INDENT_MAX
        ),
        "PAGE_NUMBER_INDENT_MIN": overrides.get(
            "PAGE_NUMBER_INDENT_MIN", PAGE_NUMBER_INDENT_MIN
        ),
    }


# ---------------------------------------------------------------------------
# Auto-chunking for scene-less scripts
# ---------------------------------------------------------------------------

# Stage-direction text that strongly signals a scene/location transition.
_SCENE_CHANGE_SD_RE = re.compile(
    r"\b(exit|exits|exiting|enter|enters|entering|"
    r"lights?\s+(?:up|down|out|fade|change|shift)|"
    r"blackout|fade\s+(?:to|out|in)|"
    r"(?:the\s+)?(?:next|following)\s+(?:day|morning|night|afternoon|evening)|"
    r"(?:an?|one|two|several|many)\s+(?:hour|day|week|month|year)s?\s+later|"
    r"later\b|meanwhile\b|elsewhere\b)\b",
    re.IGNORECASE,
)

# Target and minimum dialog-line counts per auto-chunk.
_CHUNK_TARGET_LINES = 75
_CHUNK_MIN_LINES    = 20


def _auto_chunk_scenes(
    scenes: List[Scene],
    target_lines: int = _CHUNK_TARGET_LINES,
    min_lines: int    = _CHUNK_MIN_LINES,
) -> List[Scene]:
    """Split over-long scenes at logical break points.

    Called when a script has no (or very few) explicit scene boundaries,
    resulting in a single enormous scene.  Splits it into chunks of roughly
    *target_lines* dialog lines, always breaking *between* elements so no
    line is ever cut mid-speech.

    Break-point priority:
      1. Stage direction that mentions a location/time transition (strongest)
      2. Any stage direction (natural pause in the action)
      3. Speaker change when we are significantly over the target (last resort)

    Chunks smaller than *min_lines* are merged into the previous chunk rather
    than left as tiny orphans.
    """
    result: List[Scene] = []
    for scene in scenes:
        dialog_count = sum(1 for e in scene.elements if e.kind == "dialog")
        # Only chunk scenes that are substantially over the target.
        if dialog_count <= target_lines * 1.5:
            result.append(scene)
            continue

        chunks = _split_elements(scene.elements, target_lines, min_lines)
        base_title = scene.title
        for idx, chunk_els in enumerate(chunks):
            num   = len(result) + 1
            title = base_title if idx == 0 else f"{base_title} (part {idx + 1})"
            result.append(Scene(number=num, title=title, elements=chunk_els))

    # Re-number sequentially so scene numbers stay contiguous.
    for i, sc in enumerate(result):
        sc.number = i + 1
    return result


def _split_elements(
    elements: List[Element],
    target: int,
    min_lines: int,
) -> List[List[Element]]:
    """Core splitting logic — returns a list of element-lists (chunks)."""
    chunks: List[List[Element]] = []
    current: List[Element] = []
    dialog_count = 0
    n = len(elements)

    for i, el in enumerate(elements):
        current.append(el)
        if el.kind == "dialog":
            dialog_count += 1

        if dialog_count < target:
            continue

        # We have reached the target.  Look for a break point.

        # Priority 1 — stage direction with a transition signal.
        if el.kind == "stage_direction" and _SCENE_CHANGE_SD_RE.search(el.text):
            chunks.append(current[:])
            current = []
            dialog_count = 0
            continue

        # Priority 2 — any stage direction (weaker natural pause).
        if el.kind == "stage_direction" and dialog_count >= target:
            chunks.append(current[:])
            current = []
            dialog_count = 0
            continue

        # Priority 3 — speaker change when heavily over target.
        if dialog_count >= target * 2 and el.kind == "dialog":
            next_el = elements[i + 1] if i + 1 < n else None
            # Break after this line if the next element is a different speaker
            # or a stage direction — avoid splitting mid-exchange.
            if next_el is None or next_el.kind == "stage_direction" or (
                next_el.kind == "dialog" and next_el.speaker != el.speaker
            ):
                chunks.append(current[:])
                current = []
                dialog_count = 0

    # Handle any remaining elements.
    if current:
        if chunks and dialog_count < min_lines:
            # Merge tiny tail into the last chunk rather than making an orphan.
            chunks[-1].extend(current)
        else:
            chunks.append(current)

    return chunks or [elements]


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def _build_skeleton(
    lines: List[str],
    page_sets: Optional[List[Set[str]]] = None,
) -> ScriptSkeleton:
    """Single-pass structural analysis — the universal pre-pass.

    Scans raw lines once and produces a ScriptSkeleton that all format parsers
    and the format detector can consume without rescanning.  Covers the three
    invariants every script format shares:

      1. Speaker identification  — every all-caps, name-like line
      2. Scene delimiters        — every line matching a known boundary pattern
      3. Page-region structure   — title page, cast section, body start
    """
    if page_sets is None:
        page_sets = []

    # --- Page-region structure -------------------------------------------
    first_page_only: Set[str] = set()
    if len(page_sets) >= 2:
        later: Set[str] = set().union(*page_sets[1:])
        first_page_only = page_sets[0] - later
    elif len(page_sets) == 1:
        first_page_only = set(page_sets[0])

    # --- Single line scan ------------------------------------------------
    content: List[str] = [l.strip() for l in lines]
    total = len(content)

    cue_line_indices: Set[int] = set()
    scene_delimiter_indices: Set[int] = set()
    heist_count = 0
    int_ext_count = 0
    scene_n_count = 0
    dash_count = 0
    cue_score = 0
    colon_score = 0
    non_empty_count = 0
    all_caps_count = 0

    for i in range(total):
        raw = lines[i]
        s = content[i]
        if not s:
            continue
        non_empty_count += 1
        if not re.search(r"[a-z]", s):
            all_caps_count += 1

        # Scene delimiter patterns
        if _is_heist_scene_header(raw):
            heist_count += 1
            scene_delimiter_indices.add(i)
        if INT_EXT_RE.match(s):
            int_ext_count += 1
            scene_delimiter_indices.add(i)
        if SCENE_NUM_RE.match(s):
            scene_n_count += 1
            scene_delimiter_indices.add(i)
        if _match_play_scene(s) is not None:
            scene_delimiter_indices.add(i)
        if _SCENE_NUM_DOT_RE.match(s):
            scene_delimiter_indices.add(i)

        # Dash-dialog lines
        if _is_dash_dialog_line(raw):
            dash_count += 1

        # Colon-cue score (all lines, not just cue candidates — same logic as
        # original _detect_play_format to keep scores identical)
        if re.search(r"(?:^|(?<=\s))([A-Z][A-Z\s\.\']{1,30}):\s*$", s):
            colon_score += 1
        elif re.match(r"^([A-Z][A-Z\s\.\']{1,30}):\s+\S", s):
            colon_score += 1

        # Speaker-cue candidates + play cue score
        if _is_caps_cue_candidate(s):
            cue_line_indices.add(i)
            for j in range(i + 1, min(i + 4, total)):
                nxt = content[j]
                if nxt:
                    if re.search(r"[a-z]", nxt) and len(nxt) >= 3:
                        cue_score += 1
                    break

    # --- Cast section range ----------------------------------------------
    _CAST_HEADERS: Set[str] = {
        "CAST", "CHARACTERS", "CAST OF CHARACTERS", "DRAMATIS PERSONAE",
        "CHARACTER LIST", "CHARACTER DESCRIPTIONS", "CHARACTERS:",
    }
    cast_section_range: Optional[Tuple[int, int]] = None
    for i in range(total):
        if content[i].upper() in _CAST_HEADERS:
            end = i + 1
            blanks = 0
            while end < total:
                ns = content[end]
                if not ns:
                    blanks += 1
                    if blanks >= 3:
                        break
                else:
                    blanks = 0
                    if (SCENE_HEADER_RE.match(lines[end])
                            or SCENE_NUM_RE.match(ns)
                            or INT_EXT_RE.match(ns)):
                        break
                end += 1
            cast_section_range = (i, end)
            break

    # --- Body start estimate ---------------------------------------------
    body_start_line = 0
    if cast_section_range:
        body_start_line = cast_section_range[1]
    if scene_delimiter_indices:
        first_delim = min(scene_delimiter_indices)
        body_start_line = max(body_start_line, first_delim)

    return ScriptSkeleton(
        cue_line_indices=cue_line_indices,
        scene_delimiter_indices=scene_delimiter_indices,
        page_sets=page_sets,
        first_page_only=first_page_only,
        body_start_line=body_start_line,
        cast_section_range=cast_section_range,
        heist_count=heist_count,
        int_ext_count=int_ext_count,
        scene_n_count=scene_n_count,
        dash_count=dash_count,
        cue_score=cue_score,
        colon_score=colon_score,
        non_empty_count=non_empty_count,
        all_caps_count=all_caps_count,
    )


def _sanitize_characters(script: Script) -> Script:
    """Post-parse character list hygiene — remove high-confidence false positives.

    Three narrow, low-false-positive checks applied after all parsing is done:

    1. Name matches _NON_CUE_RE — structural / stage-direction word that slipped
       through (e.g. a format variant not yet covered by the per-parser guards).
    2. Name equals the script title — play title on the cover page mistaken for
       a speaker (the "MERCURY FUR" class of bug).
    3. Character never appears as a dialog speaker in any parsed scene — can
       happen when _extract_cast picks up a non-speaking character from the
       DRAMATIS PERSONAE, or when a spurious name was added to known_speakers
       before scene parsing began.

    This is intentionally narrow. It does NOT apply frequency thresholds or
    length heuristics; those carry real false-positive risk for edge-case
    characters (one-line cameos, two-letter names, etc.).
    """
    # Collect every name that actually speaks dialog in the parsed scenes.
    dialog_speakers: Set[str] = set()
    for sc in script.scenes:
        for el in sc.elements:
            if el.kind == "dialog" and el.speaker:
                dialog_speakers.add(el.speaker)

    title_upper = script.title.strip().upper()

    def _keep(c: Character) -> bool:
        name = c.name.strip()
        if _NON_CUE_RE.match(name):
            return False
        if name == title_upper:
            return False
        if name not in dialog_speakers:
            return False
        return True

    script.characters = [c for c in script.characters if _keep(c)]
    return script


def _mark_single_occurrence_confidence(script: Script) -> None:
    """Lower confidence on dialog/parenthetical elements whose speaker appears only once
    and is not in the declared cast list. Single-occurrence unknowns are likely misattributions."""
    known = {c.name for c in script.characters}
    counts: Dict[str, int] = {}
    for scene in script.scenes:
        for el in scene.elements:
            if el.kind in ("dialog", "parenthetical") and el.speaker:
                counts[el.speaker] = counts.get(el.speaker, 0) + 1
    for scene in script.scenes:
        for el in scene.elements:
            if el.kind in ("dialog", "parenthetical") and el.speaker:
                if counts.get(el.speaker, 0) == 1 and el.speaker not in known:
                    el.confidence = min(el.confidence, 0.7)


def _finalise(script: Script) -> Script:
    """Apply post-parse finishing passes in order:
      1. Auto-chunk over-long scenes that have no structural boundaries.
      2. Sanitize the character list.
      3. Flag single-occurrence unknown speakers as uncertain.
    """
    script.scenes = _auto_chunk_scenes(script.scenes)
    script = _sanitize_characters(script)
    _mark_single_occurrence_confidence(script)
    return script


# ---------------------------------------------------------------------------
# Corrections config — data-driven rule extensions
# ---------------------------------------------------------------------------

# Default search path: corrections_config.json next to this file.
_DEFAULT_CONFIG_PATH = os.path.join(os.path.dirname(__file__), "corrections_config.json")

# Module-level cache: (path, mtime) → parsed config dict.  Reloaded whenever
# the file changes on disk so edits take effect without restarting the process.
_config_cache: Dict[str, object] = {}


def _load_corrections_config(path: str = _DEFAULT_CONFIG_PATH) -> Dict:
    """Load and cache corrections_config.json.

    Returns a dict with keys:
      non_cue_words        — list[str]: extra words to block as speaker cues
      speaker_aliases      — dict[str, str]: wrong → correct name mapping
      noise_line_patterns  — list[str]: extra regex patterns for layout noise

    Gracefully returns an empty config if the file is missing or malformed
    so parsing never hard-fails due to a config problem.
    """
    global _config_cache

    # Fast path: file unchanged since last load.
    try:
        mtime = os.path.getmtime(path)
    except OSError:
        mtime = None

    cache_key = path
    cached = _config_cache.get(cache_key)
    if cached and cached.get("_mtime") == mtime:
        return cached

    empty: Dict = {
        "non_cue_words": [],
        "speaker_aliases": {},
        "noise_line_patterns": [],
        "_mtime": mtime,
    }

    if mtime is None:
        # File doesn't exist — not an error, just no config.
        _config_cache[cache_key] = empty
        return empty

    try:
        with open(path, encoding="utf-8") as fh:
            raw = json.load(fh)
    except (json.JSONDecodeError, OSError) as exc:
        logger.warning("corrections_config: failed to load %s — %s", path, exc)
        _config_cache[cache_key] = empty
        return empty

    config: Dict = {
        "non_cue_words": [],
        "speaker_aliases": {},
        "noise_line_patterns": [],
        "_mtime": mtime,
    }

    # non_cue_words: list of strings
    words = raw.get("non_cue_words", [])
    if isinstance(words, list):
        config["non_cue_words"] = [
            str(w).strip().upper()
            for w in words
            if isinstance(w, str) and w.strip()
        ]

    # speaker_aliases: dict mapping wrong → correct (both uppercased)
    aliases = raw.get("speaker_aliases", {})
    if isinstance(aliases, dict):
        config["speaker_aliases"] = {
            str(k).strip().upper(): str(v).strip().upper()
            for k, v in aliases.items()
            if isinstance(k, str) and isinstance(v, str) and k.strip()
        }

    # noise_line_patterns: list of regex strings
    patterns = raw.get("noise_line_patterns", [])
    if isinstance(patterns, list):
        compiled = []
        for p in patterns:
            if not isinstance(p, str) or not p.strip():
                continue
            try:
                compiled.append(re.compile(p, re.IGNORECASE))
            except re.error as exc:
                logger.warning("corrections_config: invalid pattern %r — %s", p, exc)
        config["noise_line_patterns"] = compiled

    _config_cache[cache_key] = config
    return config


def _apply_corrections_config(script: Script, config: Dict) -> Script:
    """Apply data-driven corrections from corrections_config.json to a parsed script.

    Runs as a post-parse pass so the format parsers stay unchanged.  Three
    operations:

      1. Speaker aliases — rename any speaker that appears in the alias map
         (e.g. "EDDIE PHONE" → "EDDIE" for a discovered two-column artifact).

      2. Non-cue word filter — remove characters whose names match any of the
         extra words from the config (same logic as _sanitize_characters but
         using the config-supplied word list rather than _NON_CUE_RE).

      3. Noise line patterns — re-tag elements whose text matches a noise
         pattern as stage_direction so they don't get voiced.
    """
    aliases: Dict[str, str] = config.get("speaker_aliases", {})
    extra_words: List[str] = config.get("non_cue_words", [])
    noise_patterns = config.get("noise_line_patterns", [])

    # Build extra-words set for O(1) lookup (whole-word match via re)
    extra_word_re: Optional[re.Pattern] = None
    if extra_words:
        pat = r"^(?:" + "|".join(re.escape(w) + r"\b" for w in extra_words) + r")"
        extra_word_re = re.compile(pat, re.IGNORECASE)

    # 1 + 3: walk every element, apply alias and noise-pattern fixes
    for sc in script.scenes:
        for el in sc.elements:
            if el.speaker and el.speaker in aliases:
                el.speaker = aliases[el.speaker]
            if noise_patterns and el.kind == "dialog":
                if any(p.search(el.text) for p in noise_patterns):
                    el.kind = "stage_direction"
                    el.speaker = None

    # 2: remove config-flagged names from character list and re-tag their elements
    if extra_word_re:
        # Collect the names BEFORE filtering so we can re-tag elements below.
        removed: Set[str] = {
            c.name for c in script.characters
            if extra_word_re.match(c.name)
        }
        script.characters = [
            c for c in script.characters
            if c.name not in removed
        ]
        # Re-tag any element whose speaker is in the removed set.
        for sc in script.scenes:
            for el in sc.elements:
                if el.speaker in removed:
                    el.kind = "stage_direction"
                    el.speaker = None

    return script


def _try_spatial_parse(
    pdf_path: str,
    title: str,
    config: Dict,
    *,
    min_scenes: int = 1,
    min_characters: int = 1,
) -> Optional[Script]:
    """Attempt Phase-2 spatial parse.  Returns None to signal "fall back".

    Workflow
    --------
    1. Extract :class:`StructuredLine` objects (char-level pdfplumber data).
    2. Infer :class:`LayoutZones` from the x-position distribution.
    3. If not bimodal (single-column script), return ``None`` immediately so
       the caller falls back to Phase-1 text-based parsing.
    4. Classify lines with :func:`_classify_lines` using the inferred zones.
    5. Build a :class:`Script` from the classified lines.
    6. Sanity-check: must have ≥ ``min_scenes`` scenes and ≥ ``min_characters``
       characters, otherwise return ``None`` (parse produced too little content).
    7. Apply data-driven corrections and return.

    This function is called opportunistically before the Phase-1 path in
    :func:`parse_pdf`.  It is intentionally conservative — any hint of failure
    causes a graceful fallback rather than a partial or empty script.

    Parameters
    ----------
    pdf_path:
        Path to the PDF file to parse.
    title:
        Script title (typically derived from the filename by the caller).
    config:
        Pre-loaded corrections config dict from :func:`_load_corrections_config`.
    min_scenes:
        Minimum number of scenes required for the result to be accepted.
    min_characters:
        Minimum number of characters required for the result to be accepted.
    """
    try:
        structured = _extract_structured_lines(pdf_path)
        if not structured:
            return None

        zones = _infer_layout_zones(structured)
        if zones is None:
            # Unimodal x-distribution — spatial classification won't help.
            return None

        classified = _classify_lines(structured, zones=zones)
        script = _build_script_from_classified(classified, title=title)

        if len(script.scenes) < min_scenes or len(script.characters) < min_characters:
            logger.debug(
                "_try_spatial_parse: insufficient output "
                "(%d scenes, %d chars) — falling back",
                len(script.scenes), len(script.characters),
            )
            return None

        script = _finalise(script)
        script = _apply_corrections_config(script, config)
        logger.debug(
            "_try_spatial_parse: accepted (%d scenes, %d chars)",
            len(script.scenes), len(script.characters),
        )
        return script

    except Exception as exc:  # never let experimental path crash the app
        logger.warning("_try_spatial_parse failed (%s) — falling back", exc)
        return None


def parse_pdf(pdf_path: str) -> Script:
    """Parse a PDF script into a Script object.

    Detection priority:
      0. Phase-2 spatial parse (experimental) — tried first for typeset play
         PDFs that have a bimodal x-position distribution.  Falls back silently
         when the PDF is single-column or produces insufficient output.
      1. heist (numbered scene headers, very distinctive) → layout-based
      2. colon_play / play (pattern-based, plain text)
      3. scene_n / dash_dialog (indent-based, layout text)

    A ScriptSkeleton is built once from the plain-text extraction and passed
    to both the format detector and the format-specific parser, so no step
    needs to rescan the raw lines for universal structural features.
    """
    title = _derive_title(pdf_path)
    # plain_lines_col: column-annotated lines (_COL_SEP on two-column rows).
    # clean_lines: _COL_SEP replaced by space — safe for all structural consumers.
    # line_positions: per-line x0 (PDF points), parallel to plain_lines_col; None for blank/padding rows.
    plain_lines_col, page_sets, line_positions = _extract_plain_lines_with_pages(pdf_path)
    clean_lines = [l.replace(_COL_SEP, " ") for l in plain_lines_col]

    # Load data-driven corrections (cached; reloaded only when file changes).
    config = _load_corrections_config()

    # Single structural scan — shared by format detection and all parsers.
    # Use clean_lines so \x01 markers don't confuse cue-counting heuristics.
    skeleton = _build_skeleton(clean_lines, page_sets)

    # Heist format: numbered "N  SCENE TITLE" headers are unambiguous and must
    # win over the play detector (which also fires on all-caps character cues).
    if skeleton.heist_count >= 2:
        layout_lines = extract_layout_lines(pdf_path)
        layout_skeleton = _build_skeleton(layout_lines, page_sets)
        script = _finalise(parse_lines(layout_lines, title=title,
                                       skeleton=layout_skeleton))
        return _apply_corrections_config(script, config)

    # Play formats — skeleton replaces raw line rescanning in format detection.
    # _parse_play / _parse_colon_play receive the column-annotated lines so
    # _extract_scenes_play can reconstruct per-voice dialog for two-column overlaps.
    # Those functions strip _COL_SEP internally before passing to cast/noise consumers.
    play_fmt = _detect_play_format(clean_lines, skeleton=skeleton)
    if play_fmt == "play":
        # Phase-2 spatial parse: try first for typeset play PDFs.
        # Falls back to Phase-1 (italic + x-zone aware play parser) on failure.
        spatial = _try_spatial_parse(pdf_path, title, config)
        if spatial is not None:
            return spatial

        italic_lines = _find_italic_lines(pdf_path)
        script = _finalise(_parse_play(plain_lines_col, page_sets, title,
                                       skeleton=skeleton,
                                       italic_lines=italic_lines,
                                       line_positions=line_positions))
        return _apply_corrections_config(script, config)
    if play_fmt == "colon_play":
        script = _finalise(_parse_colon_play(plain_lines_col, page_sets, title,
                                             skeleton=skeleton))
        return _apply_corrections_config(script, config)

    # Indent-based fallback (scene_n, dash_dialog, heist fallback).
    layout_lines = extract_layout_lines(pdf_path)
    layout_skeleton = _build_skeleton(layout_lines, page_sets)
    script = _finalise(parse_lines(layout_lines, title=title,
                                   skeleton=layout_skeleton))
    return _apply_corrections_config(script, config)


def parse_lines(
    lines: List[str],
    title: str = "Script",
    skeleton: Optional["ScriptSkeleton"] = None,
) -> Script:
    """Parse pre-extracted layout lines (heist / scene_n / dash_dialog formats).

    If a pre-built skeleton is provided (e.g. from parse_pdf), it is used for
    format detection and any structural data the parsers can consume.  When
    called directly (e.g. from tests), a skeleton is built on-demand.
    """
    script = Script(title=title)

    if skeleton is None:
        skeleton = _build_skeleton(lines)

    overrides = _detect_indent_zones(lines)
    zones = _make_zones(overrides)

    fmt = _detect_script_format(lines, skeleton=skeleton)

    script.characters = _extract_cast(lines)
    known_speaker_set = {c.name for c in script.characters}

    script.scenes = _extract_scenes(lines, known_speaker_set, zones, fmt)

    # Fuzzy-normalize against known cast
    if known_speaker_set:
        for sc in script.scenes:
            for el in sc.elements:
                if el.speaker and el.speaker not in known_speaker_set:
                    matched = _closest_known_speaker(el.speaker, known_speaker_set)
                    if matched != el.speaker:
                        el.speaker = matched

    # Cross-normalize among discovered speakers
    speaker_counts: Dict[str, int] = {}
    for sc in script.scenes:
        for el in sc.elements:
            if el.speaker:
                speaker_counts[el.speaker] = speaker_counts.get(el.speaker, 0) + 1

    all_speakers = set(speaker_counts) | known_speaker_set
    alias_map: Dict[str, str] = {}
    for name, count in sorted(speaker_counts.items(), key=lambda x: -x[1]):
        if name in alias_map:
            continue
        for other in all_speakers:
            if other == name or other in alias_map:
                continue
            if len(name) < 3 or len(other) < 3:
                continue
            if _levenshtein(name, other) <= 2:
                other_count = speaker_counts.get(other, 0)
                if other in known_speaker_set:
                    alias_map[name] = other
                elif name in known_speaker_set:
                    alias_map[other] = name
                elif len(other) > len(name):
                    alias_map[name] = other
                elif len(name) > len(other):
                    alias_map[other] = name
                elif other_count > count:
                    alias_map[name] = other
                else:
                    alias_map[other] = name
                break

    if alias_map:
        for sc in script.scenes:
            for el in sc.elements:
                if el.speaker and el.speaker in alias_map:
                    el.speaker = alias_map[el.speaker]

    discovered: set = set()
    for sc in script.scenes:
        for el in sc.elements:
            if el.speaker:
                discovered.add(el.speaker)
    for d in sorted(discovered):
        if d not in known_speaker_set and not _looks_like_chorus(d):
            script.characters.append(Character(name=d))

    return _finalise(script)


# ---------------------------------------------------------------------------
# Play-format detection
# ---------------------------------------------------------------------------


def _is_caps_cue_candidate(s: str) -> bool:
    """True if s looks like a speaker cue: all-caps, short, name-like."""
    # Strip trailing parenthetical: "AVA (she is awake)"
    base = re.sub(r"\s*\([^)]*\)\s*$", "", s).strip()
    if not base:
        return False
    if re.search(r"[a-z]", base):
        return False
    if not re.search(r"[A-Z]", base):
        return False
    if len(base) > 40:
        return False
    # Speaker names are 1–4 words max; longer = likely a stage direction fragment
    if len(base.split()) > 4:
        return False
    # Sentence punctuation or header markers → not a speaker name.
    # Exception: title abbreviations like "DR.", "MR.", "MRS.", "MS.", "PROF."
    # are valid name prefixes (e.g. "DR. WOODLE") — strip them before checking.
    _base_no_titles = re.sub(r"\b(?:DR|MR|MRS|MS|PROF|REV|SR|JR)\.\s*", "", base)
    if re.search(r"[.!?]", _base_no_titles):
        return False
    if base.endswith(":"):  # "AGENT CONTACT:" is a section header, not a cue
        return False
    if "," in base:  # Scene locations like "A ROOM IN X, Y" contain commas
        return False
    if _NON_CUE_RE.match(base):
        return False
    # Must look name-like (2+ uppercase chars forming a word pattern)
    if not re.search(r"[A-Z]{2,}", base) and not re.fullmatch(r"[A-Z]", base):
        return False
    # Reject things that look like stutter/sound effects (3+ repeated chars)
    if re.search(r"(.)\1{2,}", base):
        return False
    return True


def _detect_play_format(
    plain_lines: List[str],
    skeleton: Optional["ScriptSkeleton"] = None,
) -> Optional[str]:
    """Return 'play', 'colon_play', or None.

    When a skeleton is provided the pre-computed scores are used directly,
    avoiding a second full scan of the lines.  When called without one (e.g.
    from tests or legacy call sites) the scores are computed inline as before.
    """
    if skeleton is not None:
        total = skeleton.non_empty_count
        if total < 40:
            return None
        if skeleton.all_caps_count / total > 0.65:
            return None
        if skeleton.int_ext_count >= 2:
            return None
        cue_ratio   = skeleton.cue_score   / total
        colon_ratio = skeleton.colon_score / total
        if colon_ratio > 0.05 and skeleton.colon_score > skeleton.cue_score * 0.5:
            return "colon_play"
        if cue_ratio > 0.04:
            return "play"
        return None

    # --- Legacy path: no skeleton provided — compute inline (unchanged) ---
    content_lines = [l.strip() for l in plain_lines if l.strip()]
    total = len(content_lines)
    if total < 40:
        return None

    all_caps_count = sum(1 for s in content_lines if not re.search(r"[a-z]", s))
    if all_caps_count / total > 0.65:
        return None

    int_ext_count = sum(1 for s in content_lines if INT_EXT_RE.match(s))
    if int_ext_count >= 2:
        return None

    cue_score = 0
    colon_score = 0
    for i, s in enumerate(content_lines):
        if re.search(r"(?:^|(?<=\s))([A-Z][A-Z\s\.\']{1,30}):\s*$", s):
            colon_score += 1
        elif re.match(r"^([A-Z][A-Z\s\.\']{1,30}):\s+\S", s):
            colon_score += 1
        if _is_caps_cue_candidate(s):
            for j in range(i + 1, min(i + 4, total)):
                nxt = content_lines[j]
                if nxt:
                    if re.search(r"[a-z]", nxt) and len(nxt) >= 3:
                        cue_score += 1
                    break

    cue_ratio   = cue_score   / total
    colon_ratio = colon_score / total

    if colon_ratio > 0.05 and colon_score > cue_score * 0.5:
        return "colon_play"
    if cue_ratio > 0.04:
        return "play"
    return None


# ---------------------------------------------------------------------------
# Play-format page noise
# ---------------------------------------------------------------------------


def _collect_page_noise(plain_lines: List[str], page_sets: Optional[List[Set[str]]] = None) -> Set[str]:
    """Find likely page noise: page numbers, running headers/footers.

    Uses per-page occurrence counts when page_sets is provided (preferred):
    a line must appear on > 60% of pages to be considered a running header.
    All-caps tokens (speaker names) are never marked as noise regardless
    of frequency.
    """
    stripped = [l.strip() for l in plain_lines if l.strip()]
    noise: Set[str] = set()

    # Always noise: page-style numbers with period, dates, single chars, revision marks.
    # Bare integers (e.g. "1234") are intentionally NOT always-noised here: they could
    # be dialog numbers (a character saying a PIN, phone extension, etc.).  Far-right
    # positional page numbers (e.g. "22" at x0 > 75 % of page width) are stripped at
    # extraction time by _strip_page_number_words() before they ever reach this list.
    # Page numbers that appear on most pages are caught by the frequency check below.
    for s in stripped:
        if re.fullmatch(r"\d+\.", s):  # "3.", "22.", "186." style page numbers
            noise.add(s)
        elif re.fullmatch(r"\d+/\d+/\d+", s):
            noise.add(s)
        elif len(s) == 1:
            noise.add(s)
        elif re.match(r"Rev(ision)?\.?\s+\d", s, re.I):
            noise.add(s)

    def _is_all_caps_token(s: str) -> bool:
        """True if s is all-caps — likely a speaker name, never a running header."""
        return bool(re.fullmatch(r"[A-Z][A-Z0-9 '\-/\.]*", s)) and len(s) <= 40

    if page_sets and len(page_sets) >= 5:
        # Page-aware: mark lines appearing on > 60% of pages as noise
        total_pages = len(page_sets)
        threshold = max(4, total_pages * 0.60)
        candidates = set().union(*page_sets)
        for s in candidates:
            if s in noise or _is_all_caps_token(s):
                continue
            count = sum(1 for pg in page_sets if s in pg)
            if count >= threshold:
                noise.add(s)
    else:
        # Fallback (no page info): high threshold + never mark all-caps
        counts = Counter(stripped)
        for s, n in counts.items():
            if s in noise or _is_all_caps_token(s):
                continue
            if n >= 20 and len(s) <= 60:
                noise.add(s)

    return noise


# ---------------------------------------------------------------------------
# Standard play format parser
# ---------------------------------------------------------------------------


def _normalize_play_speaker(s: str) -> str:
    """Extract speaker name, stripping trailing parenthetical and CONT'D."""
    base = re.sub(r"\s*\([^)]*\)\s*$", "", s).strip()
    base = CONTD_RE.sub("", base).strip()
    base = re.sub(r"\s+", " ", base)
    return base


def _match_play_scene(s: str) -> Optional[Tuple[int, str]]:
    """If s is a scene boundary, return (scene_number_increment, title). Else None."""
    m = _PLAY_SCENE_RE.match(s)
    if m:
        groups = m.groups()  # (scene_N, act_N, dash_N, part_N, title_text)
        for g in groups[:4]:
            if g is not None:
                try:
                    return (int(g), (groups[4] or "").strip())
                except ValueError:
                    roman = {"I": 1, "II": 2, "III": 3, "IV": 4, "V": 5,
                             "VI": 6, "VII": 7, "VIII": 8, "IX": 9, "X": 10}
                    return (roman.get(g.upper(), 1), (groups[4] or "").strip())

    # "The First Act" / "Second Act" ordinal format
    m2 = _ORDINAL_ACT_RE.match(s)
    if m2:
        n = _ORDINAL_TO_INT.get(m2.group(1).upper(), 1)
        return (n, s.strip())

    # "SCENE ONE" / "SCENE TWO" etc. — cardinal word-form scene numbers
    m4 = _ORDINAL_SCENE_RE.match(s)
    if m4:
        word = m4.group(1).upper()
        n = _SCENE_CARDINAL_TO_INT.get(word, 1)
        return (n, s.strip())

    # "THREE DAYS TO DEPARTURE" / "ONE DAY UNTIL X" time-section format
    m3 = _TIME_SECTION_RE.match(s)
    if m3:
        return (1, s.strip())

    return None


def _parse_play(
    plain_lines: List[str],
    page_sets: Optional[List[Set[str]]] = None,
    title: str = "Script",
    skeleton: Optional["ScriptSkeleton"] = None,
    italic_lines: Optional[Set[str]] = None,
    line_positions: Optional[List[Optional[float]]] = None,
) -> Script:
    """Parse a standard play (speaker name on own line, dialog below).

    ``plain_lines`` may contain ``_COL_SEP`` (``\\x01``) markers on two-column
    rows.  Those are intentionally passed through to ``_extract_scenes_play``
    so it can reconstruct exact per-voice dialog text.  All other consumers
    (cast extraction, noise detection, skeleton) receive clean lines with
    ``_COL_SEP`` replaced by a space so they aren't confused by the marker.
    """
    script = Script(title=title)
    # Clean lines: _COL_SEP replaced by space.  Used for cast, noise, skeleton.
    clean_lines = [l.replace(_COL_SEP, " ") for l in plain_lines]

    noise = _collect_page_noise(clean_lines, page_sets)

    script.characters = _extract_cast(clean_lines)
    known_speakers = {c.name for c in script.characters}

    # first_page_only: lines exclusive to page 0 (title/author/production).
    # Use skeleton data when available; compute on the fly otherwise.
    if skeleton is not None:
        first_page_only = skeleton.first_page_only
    else:
        first_page_only = set()
        if page_sets and len(page_sets) >= 2:
            later = set().union(*page_sets[1:])
            first_page_only = page_sets[0] - later

    # Scene extraction uses the annotated lines so it can split two-column dialog.
    script.scenes = _extract_scenes_play(
        plain_lines, known_speakers, noise, first_page_only,
        italic_lines=italic_lines,
        line_positions=line_positions,
    )

    _apply_speaker_normalization(script, known_speakers)
    _discover_new_characters(script, known_speakers)
    return script


def _extract_scenes_play(
    lines: List[str], known_speakers: Set[str], noise: Set[str],
    first_page_only: Optional[Set[str]] = None,
    italic_lines: Optional[Set[str]] = None,
    line_positions: Optional[List[Optional[float]]] = None,
) -> List[Scene]:
    # Work with a local mutable copy so we can register abbreviated names
    # discovered during parsing (e.g. "CREDIT CARD COMPANY" from splitting
    # "LEAH CREDIT CARD COMPANY AUTOMATED VOICE") without mutating the caller's set.
    # Also expand slash- and ampersand-combined names (e.g. "SHELBY/TRINA" → "SHELBY",
    # "TRINA") so individual parts are recognised as known speakers.
    known_speakers = set(known_speakers)
    for name in list(known_speakers):
        if "/" in name:
            for part in name.split("/"):
                part = part.strip()
                if part:
                    known_speakers.add(part)
        elif " & " in name:
            for part in name.split(" & "):
                part = part.strip()
                if part:
                    known_speakers.add(part)

    # Infer spatial zones from x0 distribution (dialog vs cue/SD zone).
    # x_zones = (dialog_x, cue_x, threshold) or None if no bimodal structure found.
    x_zones = _infer_x_zones(line_positions) if line_positions else None

    scenes: List[Scene] = []
    scene_counter = 0
    scene_title = ""
    elements: List[Element] = []
    current_speaker: Optional[str] = None
    last_non_narrator_speaker: Optional[str] = None  # most recent non-NARRATOR speaker
    dialog_buf: List[str] = []  # may contain _COL_SEP-annotated lines for compound overlaps
    pending_overlap_cue: Optional[List[str]] = None  # set when cue is a joint/overlap line
    pending_is_compound: bool = False  # True only for two-column PDF space-compound cues
    _dialog_buf_uncertain: bool = False  # True when a suspicious line entered dialog_buf
    # Tracks the most recent speaker cue that had NO dialog before a blank line.
    # Used to reconstruct compound cues broken across page boundaries (e.g. an
    # overlap_cue in a PDF whose auto-page-break fires inside the first cell,
    # leaving the left-column speaker name on one page and the right-column name
    # on the next, separated by a page-boundary blank line).
    _prev_cue_no_dialog: Optional[str] = None
    # When a dialog line wraps onto the next PDF page, the page-boundary blank
    # line causes flush_dialog() to emit the partial dialog and clear
    # current_speaker, leaving the wrapped continuation as an orphan.  We track
    # the flushed speaker here so that a subsequent lowercase continuation line
    # (not a cue, not a stage direction) can be re-attributed to them.
    _pending_continuation_speaker: Optional[str] = None
    # The most recently seen cue, regardless of whether dialog has been emitted.
    # Blank lines between a character name and their first content (common in
    # PDF extraction) clear current_speaker; this lets parentheticals that arrive
    # after such a blank still be attributed to the right character.
    # Cleared when dialog is emitted (cue context consumed) or on scene boundary.
    _last_cue_speaker: Optional[str] = None

    def flush_dialog(keep_last_cue: bool = False) -> None:
        nonlocal current_speaker, dialog_buf, pending_overlap_cue, pending_is_compound, _last_cue_speaker, _dialog_buf_uncertain
        if current_speaker and dialog_buf:
            if pending_overlap_cue and pending_is_compound and any(_COL_SEP in ln for ln in dialog_buf):
                # Column-aware path: we have exact per-voice text from pdfplumber coordinates.
                # Split each buffered line at _COL_SEP to get left- and right-column fragments.
                left_parts: List[str] = []
                right_parts: List[str] = []
                _in_left_sd = False  # True while inside a multi-line SD in the left column
                for ln in dialog_buf:
                    if _COL_SEP in ln:
                        l_part, r_part = ln.split(_COL_SEP, 1)
                        l_part = l_part.strip()
                        r_part = r_part.strip()
                        # Detect multi-line stage directions in the left column.
                        # A left part that opens with "(" but doesn't close with ")"
                        # starts a stage direction that spans several rows.  Suppress
                        # all left-column content for those rows so the SD text doesn't
                        # pollute the left voice's dialog (right column still goes through).
                        if l_part.startswith("(") and not l_part.endswith(")"):
                            _in_left_sd = True
                        if _in_left_sd:
                            if l_part.endswith(")"):
                                _in_left_sd = False
                            # Suppress left-column content (it's SD), right column is dialog.
                        else:
                            if l_part and not l_part.startswith("("):
                                left_parts.append(l_part)
                            elif l_part and l_part.startswith("(") and l_part.endswith(")"):
                                # Single-line parenthetical in left column — suppress (SD noise)
                                pass
                        if r_part:
                            right_parts.append(r_part)
                    else:
                        # Ambiguous (not a two-column row) — add to whichever side is active.
                        stripped = ln.strip()
                        if stripped:
                            if _in_left_sd:
                                # Continuation of a left-column stage direction.
                                if stripped.endswith(")"):
                                    _in_left_sd = False
                                # Don't add to either side — it's SD text.
                            else:
                                left_parts.append(stripped)
                                right_parts.append(stripped)
                left_text  = _normalize_text(" ".join(left_parts))
                right_text = _normalize_text(" ".join(right_parts))
                # Use left column as the canonical text; right is the second voice.
                canonical = left_text or right_text
                ot: Optional[List[str]] = [left_text, right_text] if (left_text and right_text) else None
                if canonical:
                    conf = 1.0 if current_speaker in known_speakers else 0.7
                    if _dialog_buf_uncertain or _EMBEDDED_PAREN_DIR_RE.search(canonical):
                        conf = min(conf, 0.7)
                    elements.append(Element(
                        kind="dialog",
                        speaker=current_speaker,
                        text=canonical,
                        overlap_cue=pending_overlap_cue,
                        overlap_texts=ot,
                        confidence=conf,
                    ))
            else:
                text = _normalize_text(" ".join(
                    ln.split(_COL_SEP)[0] if _COL_SEP in ln else ln
                    for ln in dialog_buf
                ))
                if text:
                    # Heuristic split fallback for compound cues without coord data.
                    ot = None
                    if pending_overlap_cue and pending_is_compound:
                        ot = _split_overlap_text(text, len(pending_overlap_cue))
                    conf = 1.0 if current_speaker in known_speakers else 0.7
                    if _dialog_buf_uncertain or _EMBEDDED_PAREN_DIR_RE.search(text):
                        conf = min(conf, 0.7)
                    elements.append(Element(
                        kind="dialog",
                        speaker=current_speaker,
                        text=text,
                        overlap_cue=pending_overlap_cue,
                        overlap_texts=ot,
                        confidence=conf,
                    ))
            current_speaker = None  # Clear after emitting so flush_orphan_speaker doesn't double-emit
            pending_overlap_cue = None
            pending_is_compound = False
            if not keep_last_cue:
                _last_cue_speaker = None  # dialog emitted → cue context consumed
        _dialog_buf_uncertain = False
        dialog_buf.clear()

    def flush_orphan_speaker() -> None:
        """Speaker set but no dialog arrived.

        Emits the speaker name as a stage direction ONLY when it does NOT
        match a known character name.  Known-character orphans arise when a
        standalone parenthetical restores ``current_speaker`` and the next
        line is a different character's cue — emitting the character name as
        a stage direction would cause the narrator to read it aloud (the
        "narrator announces character names" bug).  Discarding known-name
        orphans is safe: real stage-direction text never equals a cast name.
        """
        nonlocal current_speaker
        if current_speaker and not dialog_buf:
            if current_speaker not in known_speakers:
                elements.append(Element(kind="stage_direction", text=current_speaker))
        current_speaker = None

    def commit_scene(is_final: bool = False) -> None:
        nonlocal scene_counter, scene_title, elements, _last_cue_speaker
        flush_dialog()
        _last_cue_speaker = None  # reset per-scene cue context
        # Discard pre-first-scene preamble (cover page / cast / title page).
        # At non-final commits, also skip scenes with no actual dialog (e.g.,
        # a TOC "Act 1" line fires a boundary before the real act header).
        if scene_counter > 0 or is_final:
            has_dialog = any(e.kind == "dialog" for e in elements)
            if has_dialog or is_final:
                num = len(scenes) + 1
                t = scene_title or f"Scene {num}"
                scenes.append(Scene(number=num, title=t, elements=elements[:]))
        elements.clear()

    prev_nonempty = ""  # last non-empty, non-noise stripped line

    for _line_idx, raw in enumerate(lines):
        s = raw.strip()
        if not s:
            # Remember if a cue was set with no dialog yet — it may be the
            # left-column speaker of a compound overlap broken across a page
            # boundary.  We'll use this to reconstruct the compound cue if the
            # very next block of dialog contains _COL_SEP markers.
            _prev_cue_no_dialog = (
                current_speaker if (current_speaker and not dialog_buf) else None
            )
            # Track page-boundary dialog continuation: if a dialog line wraps
            # onto the next PDF page, the blank line here would flush the partial
            # sentence and orphan the wrapped remainder.  Save the speaker so we
            # can re-attribute a subsequent lowercase continuation line.
            _SENTENCE_ENDERS = (".", "!", "?", "…", ")", '"', "'")
            if (
                dialog_buf
                and current_speaker
                and not dialog_buf[-1].rstrip().endswith(_SENTENCE_ENDERS)
            ):
                _pending_continuation_speaker = current_speaker
            else:
                _pending_continuation_speaker = None
            # keep_last_cue across page breaks only: a blank line at a PDF page
            # boundary is an artifact of extraction, not a real speaker transition.
            # If a character's parenthetical or dialog continues onto the next page,
            # the blank shouldn't clear the speaker context.
            # Page-break blanks are marked with position -1.0; intra-page gap blanks
            # have position None and use the old behavior (clear speaker context).
            _is_page_break = (
                line_positions is not None
                and _line_idx < len(line_positions)
                and line_positions[_line_idx] == -1.0
            )
            flush_dialog(keep_last_cue=_is_page_break)
            current_speaker = None
            continue

        if s in noise:
            continue

        # ── Page-boundary continuation restoration ────────────────────────────
        # If the previous blank line was a page boundary that split a dialog
        # line mid-sentence, and this non-blank line starts with a lowercase
        # letter (so it's almost certainly a continuation, not a new cue or
        # stage direction), restore current_speaker so the line joins the
        # same dialog block rather than falling through to stage_direction.
        if (
            _pending_continuation_speaker
            and not current_speaker
            and s and s[0].islower()
            and not _is_caps_cue_candidate(s)
            and _match_play_scene(s) is None
        ):
            current_speaker = _pending_continuation_speaker
        _pending_continuation_speaker = None  # one-shot: consume regardless

        # ── Column-separator pre-processing ──────────────────────────────────
        # Lines from two-column pages are emitted as "left\x01right".
        # Unpack them here so the rest of the loop sees a clean `s` (left column)
        # and a `_col_right` (right column, or None for single-column lines).
        _col_right: Optional[str] = None
        if _COL_SEP in s:
            _left, _right = s.split(_COL_SEP, 1)
            s = _left.strip()
            _col_right = _right.strip() or None
            if not s and _col_right:
                if pending_is_compound and pending_overlap_cue:
                    # Inside a compound overlap block: a "\x01text" row means
                    # only the right voice has content on this line.  Keep
                    # s="" and _col_right so flush_dialog routes it to the
                    # right voice exclusively, not both.
                    pass
                else:
                    # Outside an overlap: treat right-only content as a normal
                    # single-column line (e.g. a wrapped right-column cue name
                    # that pdfplumber tagged as column-offset).
                    s = _col_right
                    _col_right = None

        if not s and not _col_right:
            # Completely empty after unpacking — skip.
            # (When s="" but _col_right is set we have a right-column-only
            # dialog row inside an overlap block; let it fall through to the
            # dialog-buffer section below.)
            prev_nonempty = raw.strip()
            continue

        # Scene / act boundary
        sm = _match_play_scene(s)
        if sm is not None:
            commit_scene()
            scene_counter += 1
            raw_title = sm[1]
            scene_title = raw_title or f"Scene {scene_counter}"
            current_speaker = None
            prev_nonempty = s
            continue

        # Speaker cue (all-caps, name-like)
        if _is_caps_cue_candidate(s):
            # Single-char names only valid if known
            base = re.sub(r"\s*\([^)]*\)\s*$", "", s).strip()
            if len(base) == 1 and base not in known_speakers:
                # Treat as stage direction
                flush_dialog()
                current_speaker = None
                _append_stage_direction(elements, _normalize_text(s))
                prev_nonempty = s
                continue

            normalized = _normalize_play_speaker(s)

            # Title-page guard: before the first scene boundary, an all-caps line
            # that appears ONLY on the first page (not repeated in the script body)
            # is almost certainly title/author/production info — treat as stage dir.
            if (
                scene_counter == 0
                and normalized not in known_speakers
                and first_page_only
                and s in first_page_only
            ):
                flush_dialog()
                current_speaker = None
                _append_stage_direction(elements, _normalize_text(s))
                prev_nonempty = s
                continue

            # Guard: if the previous non-empty line ended with a "dangling"
            # function word (article, preposition), the line is an incomplete
            # sentence and the next line is its continuation, not a cue.
            # e.g., "...you're bloody producing the\nBLOODY ALBUM" or
            #        "...it's a little harder it's like\nBOOM BOOM".
            if dialog_buf and normalized not in known_speakers:
                prev_words = prev_nonempty.split() if prev_nonempty else []
                last_word = prev_words[-1].lower().rstrip("…") if prev_words else ""
                _DANGLING = frozenset({
                    "the", "a", "an", "of", "in", "on", "at", "to", "for",
                    "with", "and", "or", "but", "that", "which", "like",
                    "from", "by", "as", "into", "through", "about", "so",
                })
                if last_word in _DANGLING:
                    dialog_buf.append(s)
                    prev_nonempty = s
                    continue

            # Detect simultaneous/overlap cues before committing the speaker.
            #
            # (a) Column-separated — "EDDIE\x01LEAH": the PDF extraction gave us
            #     explicit left/right column speaker names.  Highest confidence.
            # (b) Slash cue  — "ALICE/BOB": chorus (all voices read same text).
            # (c) Ampersand  — "MARA & EDDIE": chorus (all voices read same text).
            # (d) Two-column compound — "LEAH CREDIT CARD COMPANY": old heuristic
            #     fallback for PDFs without detected column gaps.
            _joint: Optional[List[str]] = None
            _is_compound = False
            if _col_right and _is_caps_cue_candidate(_col_right):
                # (a) Column-separated speaker names — most accurate.
                right_norm = _normalize_play_speaker(_col_right)
                if right_norm:
                    _joint = [normalized, right_norm]
                    _is_compound = True
                    known_speakers.add(right_norm)
            elif "/" in normalized:
                parts = [p.strip() for p in normalized.split("/") if p.strip()]
                if len(parts) >= 2:
                    _joint = parts
                    normalized = parts[0]
            elif " & " in normalized:
                parts = [p.strip() for p in normalized.split(" & ") if p.strip()]
                if len(parts) >= 2:
                    _joint = parts
                    normalized = parts[0]
            elif " " in normalized:
                _compound = _split_compound_cue(normalized, known_speakers)
                if _compound:
                    _joint = _compound
                    normalized = _compound[0]
                    _is_compound = True  # two-column artifact → split dialog text later
                    # Register the abbreviated right-side name (e.g. "CREDIT CARD
                    # COMPANY" from "LEAH CREDIT CARD COMPANY AUTOMATED VOICE") so
                    # subsequent standalone cues and orphan-speaker checks recognise it.
                    known_speakers.add(_compound[1])

            flush_dialog()
            flush_orphan_speaker()
            current_speaker = normalized
            _last_cue_speaker = normalized  # remember cue even if blank lines follow
            pending_overlap_cue = _joint
            pending_is_compound = _is_compound
            # Track the most recent non-narrator speaker so we can fall back to
            # them after a narrator parenthetical (see parenthetical handler below).
            if not _NARRATOR_NAME_RE.match(normalized):
                last_non_narrator_speaker = normalized
            prev_nonempty = s
            continue

        # Standalone parenthetical with pending speaker.
        # Also accept when current_speaker was cleared by a blank line but we
        # have a recent cue with no dialog yet (_last_cue_speaker) — this handles
        # the common PDF pattern where pdfplumber inserts a blank line between
        # the character name row and the following parenthetical/dialog rows.
        _paren_speaker_candidate = current_speaker or (
            _last_cue_speaker if (not dialog_buf and _last_cue_speaker) else None
        )
        if (
            _paren_speaker_candidate
            and s.startswith("(")
            and s.endswith(")")
            and len(s) < 150
        ):
            # Within a two-column overlap block, parentheticals from either column
            # are stage-direction noise inside the simultaneous-speech passage.
            # They'd be read by the narrator mid-overlap, which sounds wrong.
            # Suppress them and keep the overlap state intact.
            if pending_is_compound and pending_overlap_cue:
                prev_nonempty = s
                continue

            # Save speaker NOW — flush_dialog() clears current_speaker when it
            # has queued dialog to emit, so we'd lose the attribution otherwise.
            paren_speaker = _paren_speaker_candidate
            # Preserve overlap context across the parenthetical flush.
            saved_overlap_cue = pending_overlap_cue
            saved_is_compound  = pending_is_compound
            flush_dialog()
            inner = s[1:-1].strip()
            elements.append(
                Element(kind="parenthetical", speaker=paren_speaker, text=inner)
            )
            # Restore speaker after the parenthetical so subsequent lines are
            # still attributed correctly.  flush_dialog() clears current_speaker
            # whenever it emits queued dialog, but a mid-speech parenthetical
            # must not drop the speaker's attribution for what follows.
            #
            # Special case: after a NARRATOR parenthetical, yield back to the
            # last non-narrator character — many scripts use narrator
            # parentheticals as stage-direction interludes between character
            # lines and don't re-announce the character afterward.
            if _NARRATOR_NAME_RE.match(paren_speaker):
                current_speaker = last_non_narrator_speaker
            else:
                current_speaker = paren_speaker
            # Restore overlap context so dialog after the parenthetical is still
            # attributed to the correct overlap voices.
            pending_overlap_cue = saved_overlap_cue
            pending_is_compound  = saved_is_compound
            prev_nonempty = s
            continue

        # Multi-line stage direction: a line that opens with "(" but doesn't close
        # with ")" is the start of a wrapped stage direction.  If a speaker is
        # active and accumulating dialog, flush that dialog first, then let the
        # stage-direction path below handle this line (and all following lines
        # until the closing ")" arrives — those naturally fall through to
        # stage_direction too because current_speaker will be None after the flush).
        # Guard: skip during compound overlaps where left-column SD lines are
        # handled differently (filtered in flush_dialog's column-aware path).
        if (
            current_speaker
            and s.startswith("(")
            and not s.endswith(")")
            and not (pending_is_compound and pending_overlap_cue)
        ):
            flush_dialog()
            # current_speaker is now None; fall through to stage_direction below.

        # Dialog content
        if current_speaker:
            # If this line is predominantly italic in the source PDF it is almost
            # certainly a stage direction that pdfplumber failed to separate from
            # the surrounding dialog.  Flush any accumulated dialog first, then
            # emit the line as a stage direction rather than attributing it to the
            # current speaker.
            if italic_lines and s.strip() in italic_lines:
                flush_dialog()
                _append_stage_direction(elements, _normalize_text(s))
                prev_nonempty = s
                continue
            # Spatial x-zone guard: if the line's x0 is in the cue/SD zone
            # (high x) and the text is mixed-case prose (not a speaker cue),
            # it is a stage direction that shares the right-margin column with
            # speaker cues.  This is the pattern seen in plays like TheHarvest
            # where stage directions and speaker names both sit at x≈270.
            # Only fire when we have reliable zone data AND we are NOT inside a
            # two-column overlap block (where both columns carry dialog).
            if (
                x_zones is not None
                and not (pending_is_compound and pending_overlap_cue)
                and line_positions is not None
                and _line_idx < len(line_positions)
            ):
                _lpos = line_positions[_line_idx]
                if _lpos is not None and _lpos >= x_zones[2]:
                    flush_dialog()
                    _append_stage_direction(elements, _normalize_text(s))
                    prev_nonempty = s
                    continue
            # Content-based stage-direction guard: catches SDs at dialog-x
            # (left margin) that cannot be separated spatially.  Typical
            # examples: "Pause.", "JOSH opens his eyes, looks at TOM.",
            # "She turns away." — these sit at the same indent as dialog but
            # are semantically stage directions.  Skip during compound-overlap
            # blocks where the narrator voice is handled separately.
            if (
                not (pending_is_compound and pending_overlap_cue)
                and _looks_like_stage_direction(s)
            ):
                flush_dialog()
                _append_stage_direction(elements, _normalize_text(s))
                prev_nonempty = s
                continue
            # Retroactive compound-cue reconstruction: if this is the first
            # dialog line for the current speaker, it has _COL_SEP content, and
            # a dangling left-column cue was remembered across a page-boundary
            # blank line, form a compound cue now.  This recovers overlap blocks
            # where the auto-page-break inside overlap_cue() left the two speaker
            # names on separate rows instead of as a two-column row.
            if (
                _col_right is not None
                and not dialog_buf
                and not pending_overlap_cue
                and _prev_cue_no_dialog
                and _prev_cue_no_dialog != current_speaker
            ):
                pending_overlap_cue = [_prev_cue_no_dialog, current_speaker]
                pending_is_compound = True
            _prev_cue_no_dialog = None  # consumed or no longer applicable
            # For two-column overlap blocks, keep the _COL_SEP marker so
            # flush_dialog can reconstruct exact per-voice text.
            if pending_is_compound and _col_right:
                dialog_buf.append(f"{s}{_COL_SEP}{_col_right}")
            else:
                dialog_buf.append(s)
            if s:  # don't overwrite prev_nonempty with an empty string
                prev_nonempty = s
            continue

        # Stage direction (no speaker set)
        # During a two-column overlap, pdfplumber merges column stage directions
        # into the dialog stream. Suppress them so the narrator doesn't interrupt
        # simultaneous speech. (The renderer has a second guard for narrator chunks
        # that slip through; this parser-level guard handles the common case.)
        if pending_is_compound and pending_overlap_cue and s.startswith("(") and s.endswith(")"):
            prev_nonempty = s
            continue
        _prev_cue_no_dialog = None  # a stage direction between two cues means they aren't partners
        _append_stage_direction(elements, _normalize_text(s))
        prev_nonempty = s

    # Flush final scene (is_final=True so scene-less scripts get one scene)
    commit_scene(is_final=True)

    return scenes


# ---------------------------------------------------------------------------
# Colon-cue play format parser (e.g. EMMA / TRW Plays)
# ---------------------------------------------------------------------------


def _parse_colon_play(
    plain_lines: List[str],
    page_sets: Optional[List[Set[str]]] = None,
    title: str = "Script",
    skeleton: Optional["ScriptSkeleton"] = None,
) -> Script:
    """Parse a colon-cue format script (SPEAKER: dialog text)."""
    script = Script(title=title)
    clean_lines = [l.replace(_COL_SEP, " ") for l in plain_lines]
    noise = _collect_page_noise(clean_lines, page_sets)

    script.characters = _extract_cast_colon(clean_lines)
    known_speakers = {c.name for c in script.characters}

    # Use skeleton's first_page_only if available (title-page cue guard).
    first_page_only: Set[str] = skeleton.first_page_only if skeleton is not None else set()

    script.scenes = _extract_scenes_colon(plain_lines, known_speakers, noise,
                                          first_page_only=first_page_only)

    _apply_speaker_normalization(script, known_speakers)
    _discover_new_characters(script, known_speakers)
    return script


def _extract_cast_colon(lines: List[str]) -> List[Character]:
    """Find CHARACTERS / CAST section in colon-cue format scripts."""
    return _extract_cast(lines)


def _extract_scenes_colon(
    lines: List[str], known_speakers: Set[str], noise: Set[str],
    first_page_only: Optional[Set[str]] = None,
) -> List[Scene]:
    scenes: List[Scene] = []
    scene_counter = 0
    scene_title = ""
    elements: List[Element] = []
    current_speaker: Optional[str] = None
    last_non_narrator_speaker: Optional[str] = None  # most recent non-NARRATOR speaker
    dialog_buf: List[str] = []

    def flush_dialog() -> None:
        nonlocal current_speaker, dialog_buf
        if current_speaker and dialog_buf:
            text = _normalize_text(" ".join(dialog_buf))
            if text:
                conf = 1.0 if current_speaker in known_speakers else 0.7
                if _EMBEDDED_PAREN_DIR_RE.search(text):
                    conf = min(conf, 0.7)
                elements.append(Element(kind="dialog", speaker=current_speaker, text=text, confidence=conf))
            current_speaker = None
        dialog_buf.clear()

    def commit_scene(is_final: bool = False) -> None:
        nonlocal scene_counter, scene_title, elements
        flush_dialog()
        if scene_counter > 0 or is_final:
            has_dialog = any(e.kind == "dialog" for e in elements)
            if has_dialog or is_final:
                num = len(scenes) + 1
                t = scene_title or f"Scene {num}"
                scenes.append(Scene(number=num, title=t, elements=elements[:]))
        elements.clear()

    _TITLE_ABBREVS = frozenset({"MR.", "MRS.", "MS.", "DR.", "SR.", "JR.", "REV.", "HON.", "MISS."})

    def _find_colon_cue(s: str) -> Optional[Tuple[str, str]]:
        """
        Return (speaker, remainder) if s contains a valid ALLCAPS: cue.

        Works backwards from the LAST colon in the line, collecting
        consecutive all-caps words. This correctly handles two-column PDFs
        where pdfplumber merges "...dialog text  SPEAKER:" into one line:
          "WHY YES, I certainly AM. KNIGHTLEY:" → KNIGHTLEY
          "A VISITOR AT HARTFIELD EMMA:"       → EMMA
        """
        last_colon = s.rfind(":")
        if last_colon < 0:
            return None

        before = s[:last_colon]
        remainder = s[last_colon + 1:].strip()

        # Walk words backwards from end of `before`, collecting all-caps runs.
        # Stop at any word that ends with sentence-ending punctuation (unless
        # it's a recognised title abbreviation like MR. or DR.).
        words = before.split()
        name_words: List[str] = []
        for word in reversed(words):
            if word.upper() in _TITLE_ABBREVS:
                name_words.insert(0, word.upper())
                break  # Title abbreviations are only the first word of a name
            if word.endswith((".", ",", ";", "!", "?")):
                break  # Sentence-ending punctuation stops the name
            if re.fullmatch(r"[A-Z][A-Z0-9\'\-]*", word):
                name_words.insert(0, word)
                if len(name_words) >= 3:
                    break
            else:
                break

        if not name_words:
            return None

        # Prose-context check: reject if the name is embedded in running text.
        # e.g. "a big noisy GASP:" — "noisy" precedes GASP with no sentence boundary.
        # Exception: if the preceding word ends with sentence-ending punctuation
        # (.!?,;) we may be in two-column merged format ("sure? EMMA:") → allow.
        words_before_name = words[: len(words) - len(name_words)]
        if words_before_name:
            preceding = words_before_name[-1]
            if re.search(r"[a-z]", preceding) and preceding[-1] not in ".!?,;":
                candidate_name = " ".join(name_words)
                if candidate_name not in known_speakers:
                    return None

        # Prefer the shortest suffix that matches a known speaker; fall back
        # to the single last word (handles cases with no known-speaker context).
        raw_name: str = ""
        for length in range(len(name_words), 0, -1):
            candidate = " ".join(name_words[-length:])
            if candidate in known_speakers:
                raw_name = candidate
                break
        if not raw_name:
            raw_name = name_words[-1]  # Just the rightmost word

        # Reject non-speaker patterns
        if _NON_CUE_RE.match(raw_name):
            return None
        if re.search(r"[a-z]", raw_name):
            return None
        if len(raw_name) < 1 or len(raw_name) > 40:
            return None
        if "@" in raw_name or "HTTP" in raw_name:
            return None
        if raw_name in ("NOTE", "NOTES", "ACT", "SCENE", "PART", "SETTING",
                        "SETTINGS", "WARNING", "IMPORTANT", "COPYRIGHT"):
            return None
        # Reject stutter/sound effects (3+ identical consecutive chars)
        if re.search(r"(.)\1{2,}", raw_name):
            return None
        # Short names (1–2 chars) must be in known_speakers (avoids "IS", "AM", etc.)
        if len(raw_name) <= 2 and raw_name not in known_speakers:
            return None
        # Reject if remainder is a pure number/code (ISBN, phone, etc.)
        if remainder and re.fullmatch(r"[\d\-\.\s/]+", remainder):
            return None

        speaker = CONTD_RE.sub("", raw_name).strip()
        return (speaker, remainder)

    for raw in lines:
        s = raw.strip()
        if not s:
            flush_dialog()
            current_speaker = None
            continue

        if s in noise:
            continue

        # Scene boundary: "SCENE N:" style
        # Try removing trailing colon for scene detection
        s_no_colon = re.sub(r":\s*$", "", s).strip()
        sm = _match_play_scene(s_no_colon) or _match_play_scene(s)
        if sm is not None:
            commit_scene()
            scene_counter += 1
            raw_title = sm[1]
            scene_title = raw_title or f"Scene {scene_counter}"
            current_speaker = None
            continue

        # Check for ALLCAPS: cue (possibly merged with left-column stage direction)
        cue = _find_colon_cue(s)
        if cue is not None:
            speaker, remainder = cue
            # Title-page guard: skip first-page-only cues before the first boundary
            if (
                scene_counter == 0
                and speaker not in known_speakers
                and first_page_only
                and s in first_page_only
            ):
                _append_stage_direction(elements, _normalize_text(s))
                continue
            flush_dialog()
            current_speaker = speaker
            if not _NARRATOR_NAME_RE.match(speaker):
                last_non_narrator_speaker = speaker

            # Handle inline parenthetical + dialog: "SPEAKER: (paren) text"
            if remainder.startswith("("):
                pm = _INLINE_PAREN_RE.match(remainder)
                if pm:
                    elements.append(
                        Element(kind="parenthetical", speaker=current_speaker,
                                text=pm.group(1).strip())
                    )
                    remainder = pm.group(2).strip()
            if remainder:
                dialog_buf.append(remainder)
            continue

        # Standalone parenthetical with pending speaker
        if (
            current_speaker
            and s.startswith("(")
            and s.endswith(")")
            and len(s) < 150
        ):
            paren_speaker = current_speaker
            flush_dialog()
            inner = s[1:-1].strip()
            elements.append(
                Element(kind="parenthetical", speaker=paren_speaker, text=inner)
            )
            # Restore speaker — flush_dialog() clears current_speaker when it
            # emits queued dialog; a mid-speech parenthetical must not break
            # the speaker's attribution for what follows.
            # NARRATOR parentheticals yield to the last non-narrator character.
            if _NARRATOR_NAME_RE.match(paren_speaker):
                current_speaker = last_non_narrator_speaker
            else:
                current_speaker = paren_speaker
            continue

        # Dialog continuation
        if current_speaker:
            # If this line is predominantly italic in the source PDF it is almost
            # certainly a stage direction that pdfplumber failed to separate from
            # the surrounding dialog.  Flush any accumulated dialog first, then
            # emit the line as a stage direction rather than attributing it to the
            # current speaker.
            if italic_lines and s.strip() in italic_lines:
                flush_dialog()
                _append_stage_direction(elements, _normalize_text(s))
                continue
            if _SD_IN_DIALOG_LINE_RE.search(s):
                # Line looks like stage direction absorbed into the dialog buffer.
                _dialog_buf_uncertain = True
            dialog_buf.append(s)
            continue

        # Stage direction
        _append_stage_direction(elements, _normalize_text(s))

    commit_scene(is_final=True)

    return scenes


# ---------------------------------------------------------------------------
# Speaker normalization (shared by all formats)
# ---------------------------------------------------------------------------


def _apply_speaker_normalization(script: Script, known_speakers: Set[str]) -> None:
    """Fuzzy-normalize speaker names against known cast, then cross-normalize."""
    # Pass 1: match against known cast
    if known_speakers:
        for sc in script.scenes:
            for el in sc.elements:
                if el.speaker and el.speaker not in known_speakers:
                    matched = _closest_known_speaker(el.speaker, known_speakers)
                    if matched != el.speaker:
                        el.speaker = matched

    # Pass 2: cross-normalize discovered speakers
    speaker_counts: Dict[str, int] = {}
    for sc in script.scenes:
        for el in sc.elements:
            if el.speaker:
                speaker_counts[el.speaker] = speaker_counts.get(el.speaker, 0) + 1

    all_speakers = set(speaker_counts) | known_speakers
    alias_map: Dict[str, str] = {}
    for name, count in sorted(speaker_counts.items(), key=lambda x: -x[1]):
        if name in alias_map:
            continue
        for other in all_speakers:
            if other == name or other in alias_map:
                continue
            if len(name) < 3 or len(other) < 3:
                continue
            if _levenshtein(name, other) <= 2:
                other_count = speaker_counts.get(other, 0)
                if other in known_speakers:
                    alias_map[name] = other
                elif name in known_speakers:
                    alias_map[other] = name
                elif len(other) > len(name):
                    alias_map[name] = other
                elif len(name) > len(other):
                    alias_map[other] = name
                elif other_count > count:
                    alias_map[name] = other
                else:
                    alias_map[other] = name
                break

    if alias_map:
        for sc in script.scenes:
            for el in sc.elements:
                if el.speaker and el.speaker in alias_map:
                    el.speaker = alias_map[el.speaker]


def _discover_new_characters(script: Script, known_speakers: Set[str]) -> None:
    """Add speakers found during parsing that aren't in the known cast."""
    dialog_counts: Dict[str, int] = {}
    for sc in script.scenes:
        for el in sc.elements:
            if el.speaker and el.kind == "dialog":
                dialog_counts[el.speaker] = dialog_counts.get(el.speaker, 0) + 1
    for d in sorted(dialog_counts):
        if d not in known_speakers and not _looks_like_chorus(d):
            # Require at least 2 dialog occurrences to avoid false positives
            # (one-off all-caps exclamations in dialog that land on their own line)
            if dialog_counts[d] >= 2:
                script.characters.append(Character(name=d))


# ---------------------------------------------------------------------------
# Script format detection (heist / scene_n / dash_dialog — layout-based)
# ---------------------------------------------------------------------------


def _detect_script_format(
    lines: List[str],
    skeleton: Optional["ScriptSkeleton"] = None,
) -> str:
    """Return 'dash_dialog', 'heist', or 'scene_n'.

    Uses pre-computed skeleton counts when available; falls back to inline
    scanning for backward compatibility.
    """
    if skeleton is not None:
        heist_count  = skeleton.heist_count
        scene_n_count = skeleton.scene_n_count
        int_ext_count = skeleton.int_ext_count
        dash_count   = skeleton.dash_count
        non_empty    = skeleton.non_empty_count
    else:
        heist_count  = sum(1 for l in lines if _is_heist_scene_header(l))
        scene_n_count = sum(1 for l in lines if SCENE_NUM_RE.match(l.strip()))
        int_ext_count = sum(1 for l in lines if INT_EXT_RE.match(l.strip()))
        dash_count   = sum(1 for l in lines if _is_dash_dialog_line(l))
        non_empty    = sum(1 for l in lines if l.strip())

    if dash_count >= 15 and non_empty > 0 and dash_count / non_empty > 0.20:
        if dash_count > heist_count * 3:
            return "dash_dialog"

    if heist_count >= 2:
        return "heist"
    if scene_n_count >= 1 or int_ext_count >= 2:
        return "scene_n"
    return "heist"


def _is_dash_dialog_line(raw: str) -> bool:
    s = raw.strip()
    m = _DASH_DIALOG_LINE_RE.match(s)
    if not m:
        return False
    token = m.group(1).strip()
    return not re.search(r"[a-z]", token) and len(token) <= 25


# ---------------------------------------------------------------------------
# Cast extraction
# ---------------------------------------------------------------------------


def _extract_cast(lines: List[str]) -> List[Character]:
    """Find CAST / CHARACTERS section and parse character rows."""
    cast: List[Character] = []
    cast_idx = None
    for i, raw in enumerate(lines):
        s = raw.strip().upper()
        if s in ("CAST", "CHARACTERS", "CAST OF CHARACTERS", "DRAMATIS PERSONAE",
                 "CHARACTER LIST", "CHARACTER DESCRIPTIONS", "CHARACTERS:"):
            cast_idx = i
            break
    if cast_idx is None:
        return cast

    blanks_in_a_row = 0
    for raw in lines[cast_idx + 1:]:
        s = raw.strip()
        if not s:
            blanks_in_a_row += 1
            if blanks_in_a_row >= 3:
                break
            continue
        blanks_in_a_row = 0

        if SCENE_HEADER_RE.match(raw) or SCENE_NUM_RE.match(s) or INT_EXT_RE.match(s):
            break
        su = s.upper()
        if su.startswith(("AUTHOR", "NOTES", "NOTE ON", "A NOTE", "SETTING", "TIME",
                           "LOCATION", "PLACE", "PRODUCTION", "SYNOPSIS")):
            break
        # A single-word all-caps section label (TIME, PLACE, etc.) also stops the cast
        if re.fullmatch(r"[A-Z]{2,}", s) and s in (
            "TIME", "PLACE", "LOCATION", "SETTING", "SYNOPSIS", "NOTES"
        ):
            break

        char = (_parse_cast_row(s) or _parse_cast_row_dotted(s)
                or _parse_cast_row_v2(s) or _parse_cast_row_comma(s)
                or _parse_cast_row_gender_first(s))
        if char:
            cast.append(char)

    return cast


def _parse_cast_row(s: str) -> Optional[Character]:
    """HEIST-style: 'MARVIN   The Boss   40   Male'"""
    # Normalize multiple spaces
    s = re.sub(r"\s{2,}", "  ", s)
    parts = [p for p in s.split("  ") if p.strip()]
    if not parts:
        return None
    name_raw = parts[0].strip()
    if re.search(r"[a-z]", name_raw):
        return None
    if not re.search(r"[A-Z]", name_raw) or len(name_raw) > 30:
        return None
    # Name must be purely letters/spaces/hyphens — reject things like "2F, 3M"
    if not re.fullmatch(r"[A-Z][A-Z0-9 \-/'\.]*", name_raw):
        return None
    # Require at least a role description (not a bare word with nothing else)
    if len(parts) < 2:
        return None

    role = parts[1].strip() if len(parts) > 1 else None
    age = None
    gender = None
    for tail in parts[2:]:
        tail = tail.strip()
        if re.fullmatch(r"\d{1,3}\+?", tail):
            age = tail
        elif tail.lower().startswith(("male", "female", "non-binary", "nonbinary", "nb")):
            t = tail.strip().lower()
            gender = "F" if t.startswith("female") else ("M" if t.startswith("male") else "X")
    return Character(name=name_raw, gender_hint=gender, role_hint=role, age_hint=age)


def _parse_cast_row_v2(s: str) -> Optional[Character]:
    """Standard-style: 'Eric:  19, A smart anxious kid...' or 'AVA:  30, any ethnicity...'"""
    # Normalize multiple spaces for matching
    s_norm = re.sub(r"\s{2,}", " ", s)
    m = re.match(
        r"^([A-Z][A-Za-z]+(?:\s+[A-Z][A-Za-z]+)?)\s*:\s*(\d{1,3})?\s*[,]?\s*(.*)",
        s_norm,
    )
    if not m:
        return None
    name = m.group(1).upper()
    if name in ("SETTING", "SETTINGS", "MAIN", "SUPPORTING", "PRODUCTION",
                "NOTE", "NOTES", "TIME", "PLACE"):
        return None
    age = m.group(2)
    description = (m.group(3) or "").strip()
    # Reject bare "Location:" headings with no description (Pakistan:, Nevada:, etc.)
    if not age and not description:
        return None

    desc_lower = description.lower()
    she = len(re.findall(r"\bshe\b|\bher\b|\bhers\b|\bherself\b", desc_lower))
    he = len(re.findall(r"\bhe\b|\bhis\b|\bhim\b|\bhimself\b", desc_lower))
    gender: Optional[str] = None
    if she > he:
        gender = "F"
    elif he > she:
        gender = "M"

    return Character(name=name, gender_hint=gender, age_hint=age)


def _parse_cast_row_dotted(s: str) -> Optional[Character]:
    """Dotted leader: 'REG……….British, 30s, Bass Player' or 'DIANA…U.S., mid-late 20s...'"""
    m = re.match(r"^([A-Z][A-Z0-9 ]*?)[…\.]{2,}\s*(.+)$", s)
    if not m:
        return None
    name_raw = m.group(1).strip()
    if re.search(r"[a-z]", name_raw) or len(name_raw) > 30:
        return None
    rest = m.group(2).strip()
    parts = [p.strip() for p in rest.split(",")]
    age = None
    gender = None
    for part in parts:
        part_clean = part.rstrip(".")
        if re.fullmatch(r"\d{1,3}s?", part_clean, re.I) or re.match(r"\d{1,3}[-–]\d{1,3}", part_clean):
            age = part_clean
        elif part_clean.lower().startswith(("male", "female", "non-binary", "nonbinary", "nb")):
            t = part_clean.strip().lower()
            gender = "F" if t.startswith("female") else ("M" if t.startswith("male") else "X")
    return Character(name=name_raw, gender_hint=gender, age_hint=age)


def _parse_cast_row_gender_first(s: str) -> Optional[Character]:
    """Inline gender word: 'CHARLIE Male, 40s-50s. Description.'
                           'DR. WOODLE Female. 40s-50s. Description.'
                           '**Voice Only** CREDIT CARD COMPANY AUTOMATED VOICE: Female.'

    The ALL-CAPS name (which may include title abbreviations like DR., slashes
    like SHELBY/TRINA, or hyphens) is followed immediately by 'Male' or 'Female'
    (optionally preceded by a colon).  An optional prefix like '**Voice Only**'
    is stripped first.
    """
    # Strip decorative prefixes like "**Voice Only**"
    cleaned = re.sub(r"^\*\*[^*]+\*\*\s*", "", s).strip()

    # Match: ALLCAPS_NAME (optional colon+spaces) gender_word
    # Name characters: uppercase letters, digits, spaces, periods (DR.), slashes, hyphens
    m = re.match(
        r"^([A-Z][A-Z0-9\./ -]{0,39}?)\s*:?\s+(Male|Female|Non-binary|Nonbinary|Mx)\b",
        cleaned,
        re.IGNORECASE,
    )
    if not m:
        return None

    name_raw = m.group(1).strip().rstrip(".")
    if not name_raw or len(name_raw) > 40:
        return None
    if re.search(r"[a-z]", name_raw):
        return None

    gender_word = m.group(2).lower()
    if "female" in gender_word:
        gender = "F"
    elif "male" in gender_word:
        gender = "M"
    else:
        gender = "X"

    rest = s[m.end():].strip()
    age_m = re.search(r"(\d{1,3}(?:s|[-–]\d{1,3}s?)?)\b", rest)
    age = age_m.group(1) if age_m else None

    return Character(name=name_raw, gender_hint=gender, age_hint=age)


def _parse_cast_row_comma(s: str) -> Optional[Character]:
    """Comma-delimited: 'ANDY, female, 30s, Caucasian.' or 'B, male, 15, ...'

    All-caps name is first token before the comma; gender/age follow in any order.
    """
    m = re.match(r"^([A-Z][A-Z0-9 ]*?),\s*(.+)$", s)
    if not m:
        return None
    name_raw = m.group(1).strip()
    # Reject non-names: must be all-caps, reasonable length, no digits-only
    if re.search(r"[a-z]", name_raw) or len(name_raw) > 30:
        return None
    if re.fullmatch(r"[\d\s]+", name_raw):
        return None

    parts = [p.strip() for p in m.group(2).split(",")]
    age = None
    gender = None
    for part in parts:
        part_clean = part.rstrip(".")
        if re.fullmatch(r"\d{1,3}s?", part_clean, re.I):
            age = part_clean
        elif part_clean.lower().startswith(("male", "female", "non-binary", "nonbinary", "nb")):
            t = part_clean.strip().lower()
            gender = "F" if t.startswith("female") else ("M" if t.startswith("male") else "X")

    return Character(name=name_raw, gender_hint=gender, age_hint=age)


# ---------------------------------------------------------------------------
# Scene extraction — format router (heist / scene_n / dash_dialog)
# ---------------------------------------------------------------------------


def _extract_scenes(
    lines: List[str],
    known_speakers: set,
    zones: Dict[str, int],
    fmt: str,
) -> List[Scene]:
    if fmt == "dash_dialog":
        return _extract_scenes_dash_dialog(lines)
    if fmt == "scene_n":
        return _extract_scenes_scene_n(lines, known_speakers, zones)
    return _extract_scenes_heist(lines, known_speakers, zones)


# ---------------------------------------------------------------------------
# HEIST-style scene extraction
# ---------------------------------------------------------------------------


def _extract_scenes_heist(
    lines: List[str],
    known_speakers: set,
    zones: Dict[str, int],
) -> List[Scene]:
    boundaries: List[Tuple[int, int, str]] = []
    seen_first = False
    for i, raw in enumerate(lines):
        if _is_heist_scene_header(raw):
            m = SCENE_HEADER_RE.match(raw)
            num = int(m.group("num"))
            title = _clean_title(m.group("title"))
            if not seen_first:
                seen_first = True
                boundaries.append((i, num, title))
            else:
                last_num = boundaries[-1][1]
                if num <= last_num - 5 or num > last_num + 20:
                    continue
                boundaries.append((i, num, title))

    if not boundaries:
        boundaries = [(0, 1, "Script")]

    boundaries.append((len(lines), -1, ""))

    scenes: List[Scene] = []
    for (start, num, title), (end, _, _) in zip(boundaries, boundaries[1:]):
        scene_lines = lines[start + 1: end]
        sc = Scene(number=num, title=title)
        sc.elements = _parse_scene_body(scene_lines, known_speakers, zones)
        scenes.append(sc)
    return scenes


# ---------------------------------------------------------------------------
# SCENE N / INT-EXT style scene extraction
# ---------------------------------------------------------------------------


def _extract_scenes_scene_n(
    lines: List[str],
    known_speakers: set,
    zones: Dict[str, int],
) -> List[Scene]:
    boundaries: List[Tuple[int, int, str]] = []
    scene_counter = 0
    last_was_scene_n = False

    for i, raw in enumerate(lines):
        s = raw.strip()

        if ACT_RE.match(s):
            continue

        m = SCENE_NUM_RE.match(s)
        if m:
            scene_counter += 1
            num_label = m.group("num")
            boundaries.append((i, scene_counter, f"Scene {num_label}"))
            last_was_scene_n = True
            continue

        m2 = INT_EXT_RE.match(s)
        if m2:
            loc = _clean_title(m2.group("loc"))
            if last_was_scene_n and boundaries:
                idx, num, _ = boundaries[-1]
                boundaries[-1] = (idx, num, loc)
            else:
                scene_counter += 1
                boundaries.append((i, scene_counter, loc))
            last_was_scene_n = False
            continue

        if s:
            last_was_scene_n = False

    if not boundaries:
        boundaries = [(0, 1, "Script")]

    boundaries.append((len(lines), -1, ""))

    scenes: List[Scene] = []
    for (start, num, title), (end, _, _) in zip(boundaries, boundaries[1:]):
        scene_lines = lines[start + 1: end]
        sc = Scene(number=num, title=title)
        sc.elements = _parse_scene_body(scene_lines, known_speakers, zones)
        scenes.append(sc)
    return scenes


# ---------------------------------------------------------------------------
# Dash-dialog format
# ---------------------------------------------------------------------------


def _extract_scenes_dash_dialog(lines: List[str]) -> List[Scene]:
    boundaries: List[Tuple[int, int, str]] = []
    last_num = 0
    for i, raw in enumerate(lines):
        s = raw.strip()
        m = _SCENE_NUM_DOT_RE.match(s)
        if m:
            indent = len(raw) - len(raw.lstrip())
            if indent < 30:
                num = int(m.group(1))
                if num <= last_num:
                    num = last_num + 1
                last_num = num
                boundaries.append((i, num, f"Scene {num}"))

    if not boundaries:
        boundaries = [(0, 1, "Script")]

    boundaries.append((len(lines), -1, ""))

    scenes: List[Scene] = []
    for (start, num, title), (end, _, _) in zip(boundaries, boundaries[1:]):
        scene_lines = lines[start + 1: end]
        sc = Scene(number=num, title=title)
        sc.elements = _parse_scene_body_dash_dialog(scene_lines)
        scenes.append(sc)
    return scenes


def _parse_scene_body_dash_dialog(lines: List[str]) -> List[Element]:
    elements: List[Element] = []
    indents = [len(r) - len(r.lstrip()) for r in lines if r.strip()]
    base_indent = Counter(indents).most_common(1)[0][0] if indents else 0
    prev_dialog: Optional[Element] = None

    for raw in lines:
        s = raw.strip()
        if not s:
            prev_dialog = None
            continue

        indent = len(raw) - len(raw.lstrip())

        if prev_dialog is not None and indent > base_indent + 2:
            prev_dialog.text = _normalize_text(prev_dialog.text + " " + s)
            continue
        prev_dialog = None

        m = _DASH_DIALOG_LINE_RE.match(s)
        if m:
            token = m.group(1).strip()
            if re.search(r"[a-z]", token):
                _append_stage_direction(elements, _normalize_text(s))
                continue

            speaker = _normalize_dash_speaker(token)
            rest = m.group(2).strip()

            pm = _INLINE_PAREN_RE.match(rest)
            if pm:
                paren_text = pm.group(1).strip()
                dialog_text = pm.group(2).strip()
                elements.append(
                    Element(kind="parenthetical", speaker=speaker, text=paren_text)
                )
                if dialog_text:
                    el = Element(kind="dialog", speaker=speaker,
                                 text=_normalize_text(dialog_text))
                    elements.append(el)
                    prev_dialog = el
            else:
                el = Element(kind="dialog", speaker=speaker,
                             text=_normalize_text(rest))
                elements.append(el)
                prev_dialog = el
            continue

        _append_stage_direction(elements, _normalize_text(s))

    return elements


def _append_stage_direction(elements: List[Element], text: str) -> None:
    if (
        elements
        and elements[-1].kind == "stage_direction"
        and elements[-1].text
        and elements[-1].text[-1] not in ".!?…\")"
    ):
        elements[-1].text = _normalize_text(elements[-1].text + " " + text)
    else:
        elements.append(Element(kind="stage_direction", text=text))


def _normalize_dash_speaker(raw: str) -> str:
    s = re.sub(r"\s*/\s*", "/", raw)
    s = re.sub(r"\s*&\s*", "&", s)
    return s.strip()


# ---------------------------------------------------------------------------
# Scene header helpers
# ---------------------------------------------------------------------------


def _is_heist_scene_header(raw: str) -> bool:
    indent = len(raw) - len(raw.lstrip(" "))
    if indent > SCENE_HEADER_MAX_INDENT:
        return False
    m = SCENE_HEADER_RE.match(raw)
    if not m:
        return False
    title = m.group("title")
    if len(title) < 3 or len(title) > 80:
        return False
    if re.search(r"[a-z]", title):
        return False
    if len(re.findall(r"[A-Z]", title)) < 3:
        return False
    # Reject screenplay page-continuation markers ("10 CONTINUED: 10")
    if re.match(r"CONT(INUED)?[:\s]", title):
        return False
    return True


def _clean_title(title: str) -> str:
    title = title.strip().rstrip(".")
    title = re.sub(r"\s+", " ", title)
    return title


# ---------------------------------------------------------------------------
# Scene body parser (heist / scene_n)
# ---------------------------------------------------------------------------


def _parse_scene_body(
    lines: List[str],
    known_speakers: set,
    zones: Dict[str, int],
) -> List[Element]:
    Z = zones
    d_min = Z["DIALOG_INDENT_MIN"]
    d_max = Z["DIALOG_INDENT_MAX"]
    cue_min = Z["CUE_INDENT_MIN"]
    p_min = Z["PARENTHETICAL_INDENT_MIN"]
    p_max = Z["PARENTHETICAL_INDENT_MAX"]
    pn_min = Z["PAGE_NUMBER_INDENT_MIN"]

    elements: List[Element] = []

    clean: List[str] = []
    for raw in lines:
        if "\x0c" in raw:
            raw = raw.replace("\x0c", "")
        if not raw.strip():
            clean.append("")
            continue
        s = raw.strip()
        if PAGE_FOOTER_RE.match(s):
            continue
        indent = len(raw) - len(raw.lstrip(" "))
        if indent >= pn_min and re.fullmatch(r"\s*\d+\.?\.?\s*", raw):
            continue
        if re.search(r'["""].+["""].*\d+\.?\s*$', s) and indent < 25:
            continue
        # Draft dates and revision marks that noise detection may have missed
        if _DRAFT_DATE_RE.match(s):
            continue
        clean.append(raw.rstrip())

    i = 0
    n = len(clean)
    pending_speaker: Optional[str] = None
    pending_confidence: float = 1.0
    pending_parenthetical: Optional[str] = None
    sd_buf: List[str] = []
    dialog_buf: List[str] = []

    def flush_stage_direction() -> None:
        nonlocal sd_buf
        if sd_buf:
            text = _normalize_text(" ".join(sd_buf))
            if text:
                elements.append(Element(kind="stage_direction", text=text))
            sd_buf.clear()

    def flush_dialog(force: bool = False) -> None:
        nonlocal dialog_buf, pending_speaker, pending_parenthetical, pending_confidence
        had_dialog = bool(dialog_buf)
        if pending_speaker and (had_dialog or pending_parenthetical):
            if pending_parenthetical:
                elements.append(
                    Element(kind="parenthetical", speaker=pending_speaker,
                            text=pending_parenthetical, confidence=pending_confidence)
                )
                pending_parenthetical = None
            if had_dialog:
                text = _normalize_text(" ".join(dialog_buf))
                if text:
                    conf = pending_confidence
                    if _EMBEDDED_PAREN_DIR_RE.search(text):
                        conf = min(conf, 0.7)
                    elements.append(
                        Element(kind="dialog", speaker=pending_speaker, text=text,
                                confidence=conf)
                    )
                dialog_buf.clear()
                pending_speaker = None
                pending_confidence = 1.0
        elif force:
            dialog_buf.clear()
            pending_speaker = None
            pending_confidence = 1.0
            pending_parenthetical = None

    while i < n:
        raw = clean[i]
        s = raw.strip()
        indent = len(raw) - len(raw.lstrip(" ")) if raw else 0

        if not s:
            flush_dialog()
            flush_stage_direction()
            i += 1
            continue

        if (
            pending_speaker
            and PARENTHETICAL_RE.match(s)
            and p_min <= indent <= p_max + 8
        ):
            inner = s.strip("()").strip()
            if dialog_buf:
                text = _normalize_text(" ".join(dialog_buf))
                if text:
                    elements.append(
                        Element(kind="dialog", speaker=pending_speaker, text=text,
                                confidence=pending_confidence)
                    )
                dialog_buf.clear()
                elements.append(
                    Element(kind="parenthetical", speaker=pending_speaker, text=inner,
                            confidence=pending_confidence)
                )
            else:
                pending_parenthetical = inner
            i += 1
            continue

        if (
            pending_speaker
            and s.startswith("(")
            and not s.endswith(")")
            and p_min <= indent <= p_max + 8
        ):
            paren_parts = [s.lstrip("(")]
            j = i + 1
            while j < n:
                nxt = clean[j].strip()
                if not nxt:
                    break
                paren_parts.append(nxt.rstrip(")"))
                if nxt.endswith(")"):
                    j += 1
                    break
                j += 1
            inner = " ".join(paren_parts).strip("() ").strip()
            if dialog_buf:
                text = _normalize_text(" ".join(dialog_buf))
                if text:
                    elements.append(
                        Element(kind="dialog", speaker=pending_speaker, text=text,
                                confidence=pending_confidence)
                    )
                dialog_buf.clear()
                elements.append(
                    Element(kind="parenthetical", speaker=pending_speaker, text=inner,
                            confidence=pending_confidence)
                )
            else:
                pending_parenthetical = inner
            i = j
            continue

        if pending_speaker and d_min <= indent <= d_max:
            if _SD_IN_DIALOG_LINE_RE.search(s):
                # Line looks like stage direction at dialog indent — classification uncertain.
                pending_confidence = min(pending_confidence, 0.7)
            dialog_buf.append(s)
            i += 1
            continue

        if pending_speaker:
            flush_dialog(force=True)

        if indent >= cue_min:
            if _looks_like_cue(s, known_speakers):
                speaker_text, paren_text, advance = _capture_cue(clean, i)
                j = i + advance
                while j < n and not clean[j].strip():
                    j += 1
                if j < n:
                    nxt = clean[j]
                    nxt_indent = len(nxt) - len(nxt.lstrip(" "))
                    nxt_strip = nxt.strip()
                    if (
                        d_min <= nxt_indent <= d_max
                        or _looks_like_cue(nxt_strip, known_speakers)
                        or (PARENTHETICAL_RE.match(nxt_strip) and p_min <= nxt_indent <= p_max + 8)
                    ):
                        flush_stage_direction()
                        pending_speaker = _normalize_speaker(speaker_text)
                        pending_confidence = 1.0 if pending_speaker in known_speakers else 0.7
                        if indent - cue_min <= 3:
                            # Cue barely above the indent threshold — classification is uncertain.
                            pending_confidence = min(pending_confidence, 0.7)
                        pending_parenthetical = paren_text
                        i += advance
                        continue
                sd_buf.append(s)
                i += 1
                continue
            else:
                sd_buf.append(s)
                i += 1
                continue

        if (
            d_min <= indent <= d_max
            and elements
            and elements[-1].kind == "dialog"
        ):
            prev = elements[-1]
            prev.text = _normalize_text(prev.text + " " + s)
            # Speakerless continuation is a heuristic fallback — flag as uncertain.
            prev.confidence = min(prev.confidence, 0.7)
            i += 1
            continue

        sd_buf.append(s)
        i += 1

    flush_dialog(force=True)
    flush_stage_direction()

    elements = _merge_wrapped_stage_directions(elements)
    return elements


# ---------------------------------------------------------------------------
# Cue helpers
# ---------------------------------------------------------------------------


_TERMINAL_PUNCT = ".!?…\"')"


def _merge_wrapped_stage_directions(elements: List[Element]) -> List[Element]:
    out: List[Element] = []
    for el in elements:
        if out and out[-1].kind == "stage_direction" and el.kind == "stage_direction":
            prev = out[-1].text.rstrip()
            curr = el.text.lstrip()
            ends_unfinished = prev[-1:] not in _TERMINAL_PUNCT if prev else False
            if ends_unfinished and curr[:1].islower():
                out[-1].text = (prev + " " + curr).strip()
                continue
            if prev.endswith((",", ";", ":")) and curr[:1].islower():
                out[-1].text = (prev + " " + curr).strip()
                continue
        out.append(el)
    return out


def _looks_like_cue(s: str, known_speakers: set) -> bool:
    if not s:
        return False
    base = re.sub(r"\s*\([^)]*\)\s*$", "", s).strip()
    if not base:
        return False
    if re.search(r"[a-z]", base):
        return False
    if not (1 <= len(base) <= 60):
        return False
    if base in known_speakers:
        return True
    if "/" in base and all(
        part.strip() in known_speakers for part in base.split("/") if part.strip()
    ):
        return True
    if base.endswith("."):
        return False
    if len(base) <= 25 and re.fullmatch(r"[A-Z][A-Z0-9 \-/'']*", base):
        return True
    return False


def _capture_cue(lines: List[str], i: int) -> Tuple[str, Optional[str], int]:
    cue = lines[i].strip()
    j = i + 1
    if j < len(lines) and lines[j].strip():
        nxt = lines[j]
        nxt_strip = nxt.strip()
        nxt_indent = len(nxt) - len(nxt.lstrip(" "))
        if (
            PARENTHETICAL_RE.match(nxt_strip)
            and PARENTHETICAL_INDENT_MIN <= nxt_indent <= PARENTHETICAL_INDENT_MAX + 12
        ):
            paren_inner = nxt_strip.strip("()").strip()
            return cue, paren_inner, 2
    return cue, None, 1


def _normalize_speaker(s: str) -> str:
    s = CONTD_RE.sub("", s)
    base = re.sub(r"\s*\([^)]*\)\s*", "", s).strip()
    base = re.sub(r"\s+", " ", base)
    return base


def _normalize_text(s: str) -> str:
    s = s.replace(" ", " ")
    s = re.sub(r"\s+", " ", s).strip()
    s = s.replace("‘", "'").replace("’", "'")
    s = s.replace("“", '"').replace("”", '"')
    return s


def _split_overlap_text(text: str, n_voices: int = 2) -> Optional[List[str]]:
    """Try to split concatenated two-column dialog text into per-voice portions.

    Two-column PDF overlaps merge two independent text columns into one string,
    e.g. "What do you mean? I'm sorry, I don't recognize that number."
    This function finds a sentence-boundary closest to the midpoint and splits
    there, returning [voice1_text, voice2_text].

    Returns a list of *n_voices* strings if a plausible split is found, or None
    when no good boundary exists (caller falls back to chorus mode — all voices
    read the full text).
    """
    if n_voices < 2 or not text.strip():
        return None

    length = len(text)
    midpoint = length / 2.0
    # Only split when the boundary lands between 15 % and 85 % of the text.
    lo, hi = length * 0.15, length * 0.85

    candidates: List[Tuple[float, int]] = []

    # Split just after sentence-ending punctuation, whitespace, then a new
    # sentence start (uppercase letter or opening paren/quote).  The lookahead
    # prevents splitting inside an ellipsis sequence like ". . ." — only the
    # final period (before "So why..." / "I'm sorry...") will match.
    for m in re.finditer(r'(?<=[.!?])\s+(?=[A-Z(\'\"])', text):
        pos = m.end()
        if lo <= pos <= hi:
            candidates.append((abs(pos - midpoint), pos))

    # Fallback: bare whitespace after a period even without the uppercase guard.
    # Only used if no uppercase-anchored candidates exist.
    if not candidates:
        for m in re.finditer(r'(?<=[.!?])\s+', text):
            pos = m.end()
            if lo <= pos <= hi:
                candidates.append((abs(pos - midpoint), pos))

    if not candidates:
        return None

    candidates.sort()
    split_pos = candidates[0][1]

    part1 = text[:split_pos].strip()
    part2 = text[split_pos:].strip()

    if not part1 or not part2:
        return None

    if n_voices == 2:
        return [part1, part2]

    # 3+ voices: first voice gets part1, remaining get part2 (rare in practice)
    return [part1] + [part2] * (n_voices - 1)


def _split_compound_cue(name: str, known_speakers: Set[str]) -> Optional[List[str]]:
    """Detect a two-column PDF artefact where two speaker names were concatenated
    with a space (e.g. "LEAH CREDIT CARD COMPANY" when both "LEAH" and
    "CREDIT CARD COMPANY" are known speakers).

    Tries every binary word-split left-to-right; returns [left, right] for the
    first split where left is a known speaker and right either:
      (a) is also an exact known speaker, or
      (b) is a leading prefix of a known speaker (handles abbreviations like
          "CREDIT CARD COMPANY" vs. "CREDIT CARD COMPANY AUTOMATED VOICE").

    Only called when the candidate contains at least one space.
    """
    words = name.split()
    for i in range(1, len(words)):
        left  = " ".join(words[:i])
        right = " ".join(words[i:])
        if left not in known_speakers:
            continue
        # Exact match
        if right in known_speakers:
            return [left, right]
        # Prefix match: right is a leading prefix of some known speaker name.
        # Use "right + ' '" to avoid partial-word matches (e.g. "CAR" should
        # not match "CAROL").
        right_prefix = right + " "
        for known in known_speakers:
            if known.startswith(right_prefix):
                return [left, right]
    return None


def _looks_like_chorus(name: str) -> bool:
    return "/" in name or " & " in name


def _levenshtein(a: str, b: str) -> int:
    if abs(len(a) - len(b)) > 3:
        return 99
    m, n = len(a), len(b)
    dp = list(range(n + 1))
    for i in range(1, m + 1):
        new_dp = [i] + [0] * n
        for j in range(1, n + 1):
            if a[i - 1] == b[j - 1]:
                new_dp[j] = dp[j - 1]
            else:
                new_dp[j] = 1 + min(dp[j], new_dp[j - 1], dp[j - 1])
        dp = new_dp
    return dp[n]


def _closest_known_speaker(name: str, known_speakers: set, max_dist: int = 2) -> str:
    if name in known_speakers:
        return name
    best, best_dist = name, max_dist + 1
    for k in known_speakers:
        d = _levenshtein(name, k)
        if d < best_dist:
            best, best_dist = k, d
    return best


def _derive_title(pdf_path: str) -> str:
    import os
    filename = os.path.splitext(os.path.basename(pdf_path))[0]
    try:
        with pdfplumber.open(pdf_path) as pdf:
            if not pdf.pages:
                return filename
            text = pdf.pages[0].extract_text() or ""
            for line in text.split("\n"):
                candidate = line.strip()
                if (
                    len(candidate) >= 3
                    and not re.search(r"https?://|@|\d{4}|draft|revision", candidate, re.I)
                    and not re.fullmatch(r"[\d\s\.]+", candidate)
                ):
                    return candidate[:80]
    except Exception:
        pass
    return filename


# ---------------------------------------------------------------------------
# Diagnostics
# ---------------------------------------------------------------------------


def summarise(script: Script) -> str:
    out = []
    out.append(f"Title: {script.title}")
    out.append(f"Characters ({len(script.characters)}):")
    for c in script.characters:
        bits = [c.name]
        if c.gender_hint:
            bits.append(f"[{c.gender_hint}]")
        if c.role_hint:
            bits.append(f"– {c.role_hint}")
        out.append("  " + " ".join(bits))
    out.append(f"Scenes ({len(script.scenes)}):")
    for sc in script.scenes:
        n_dialog = sum(1 for e in sc.elements if e.kind == "dialog")
        n_sd = sum(1 for e in sc.elements if e.kind == "stage_direction")
        out.append(
            f"  Scene {sc.number}: {sc.title}  ({n_dialog} lines, {n_sd} stage dirs)"
        )
    return "\n".join(out)


if __name__ == "__main__":
    import sys
    if len(sys.argv) < 2:
        print("Usage: python parser.py <pdf_path>")
        sys.exit(1)
    s = parse_pdf(sys.argv[1])
    print(summarise(s))
