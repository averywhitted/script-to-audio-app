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

Architecture — block-level extraction (PyMuPDF / fitz):

  1. _extract_blocks      PyMuPDF `get_text("dict")` → atomic TextBlock units,
                          splitting mixed blocks at blank lines + speaker cues.
  2. _infer_layout_profile  learns this document's columns (speaker_x, dialog_x,
                          stage_dir_x) from the block positions.
  3. _classify_blocks     two-phase: a weighted convention scorer (_score_blocks)
                          assigns each block a kind, then a sequence pass attributes
                          speakers (pending_speaker state machine).
  4. _build_script_from_blocks  groups classified blocks into scenes/elements,
                          applies corrections config, and finalises.

`parse_pdf()` is the single entry point. The output schema and the JSON bridge to
Swift are unchanged. Title extraction (`_derive_title`) uses pdfplumber for first-
page text; everything else uses PyMuPDF.

Correctness is measured by scripts/scorecard.py against locked independent ground
truth in Test PDFs/reference/*_independent.json — run it (or the parser-regression-
guard agent) before changing this file.
"""

from __future__ import annotations

import json
import logging
import os
import re
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from typing import Any, Callable, Dict, List, Optional, Set, Tuple

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


# ---------------------------------------------------------------------------
# Block-level data classes (PyMuPDF extraction path)
# ---------------------------------------------------------------------------


@dataclass
class TextSpan:
    """A single styled run of text within a line."""
    text: str
    bold: bool
    italic: bool
    font: str
    size: float


@dataclass
class TextBlock:
    """A rectangular region of text extracted by PyMuPDF block detection.

    Each block is an atomic semantic unit: a stage direction paragraph,
    a speaker cue, a dialog run, or a parenthetical.  The block extractor
    splits mixed PyMuPDF blocks (stage-dir + speaker + dialog in one region)
    into separate TextBlock objects so the classifier sees clean units.
    """
    x0: float
    y0: float
    x1: float
    y1: float
    page: int
    lines: List[List["TextSpan"]]  # outer = lines, inner = spans per line
    text: str                       # full whitespace-normalised concatenated text
    caps_ratio: float               # fraction of alpha chars that are uppercase
    center_x: float                 # (x0 + x1) / 2
    width: float                    # x1 - x0
    height: float                   # y1 - y0
    line_count: int
    char_count: int
    starts_with_paren: bool
    ends_with_paren: bool
    is_italic: bool                 # majority of chars are italic
    is_bold: bool
    is_merged_parenthetical: bool = False  # produced by _merge_open_parentheticals
    is_split_continuation: bool = False   # tail block produced by _split_raw_block cue split
    is_cue_with_inline_paren: bool = False  # "SPEAKER (stage direction)" — cue line with embedded direction


# ---------------------------------------------------------------------------
# Default indent zones (calibrated for HEIST-style; overridden by auto-detect)
# ---------------------------------------------------------------------------


# Regex helpers — heist / scene_n / dash_dialog formats
CONTD_RE = re.compile(r"\s*\([^)]*CONT['']?D[^)]*\)", re.I)

# Heuristics for detecting a stage-direction line that has leaked into a dialog buffer.
# Checked per-line (at buffer time) and on the combined text (at flush time).

# Matches stage directions of the form "CHARACTER NAME verb..." where the subject
# is one or more ALL-CAPS words (≥2 chars each) followed by a lowercase word.
# Examples: "JOSH opens his eyes.", "MARCUS smiles at DENISE.", "TOM AND ALICE exit."
# Does NOT match: plain dialog, short exclamations ("WHAT?"), lines with no
# lowercase follow-on.  Case-sensitive by design — character-name subjects in
# stage directions are always printed in ALL CAPS in play format.

# Embedded parenthetical direction in the combined dialog text (≥8 chars inside parens).

# Page-marker / draft-watermark lines that appear on every page of a script draft.
# These should be silently dropped rather than attributed to a character as dialog.
# Matches patterns like:
#   "[Draft 3.0] 4"   "[DRAFT] 12"   "[v2.1] 100"   "[Final] 3"
# Also matches bare page numbers (1–4 digits) that appear alone on a line.
_PAGE_MARKER_RE = re.compile(
    r"^\[.{1,40}\]\s*\d{1,4}\.?\s*$"  # bracket-enclosed metadata + page number
    r"|^\d{1,4}\.?\s*$",               # bare page number, with or without trailing dot
)


# Dash-dialog format ("SPEAKER – text" inline on one line)

# ---------------------------------------------------------------------------
# Play-format regex constants
# ---------------------------------------------------------------------------

# Narrator speaker names — used to detect when the "narrator" turn should yield
# back to the last character speaker after a parenthetical.  Matches "NARRATOR",
# "NARRATOR 1", "NARRATOR (V.O.)", etc.

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

# "The First Act" / "The Second Act" ordinal format (e.g. Mr. Burns)
# ACT must be at end of line to avoid matching mid-sentence "the third act finale..."

# "SCENE ONE" / "SCENE TWO" etc. — cardinal word-form scene numbers.
# Many plays use this instead of "SCENE 1". Matched before _NON_CUE_RE's bare
# "SCENE\b" guard so the boundary is recognised rather than filtered.
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

# Speaker cue in colon-play format: "SPEAKER:" or "SPEAKER: inline dialog"


# ---------------------------------------------------------------------------
# Doubled-character normalization
# ---------------------------------------------------------------------------


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


# Sentinel character used to separate left- and right-column text on two-column rows.
# Must be a character that never appears in normal script text.


# ---------------------------------------------------------------------------
# Block-level extraction (PyMuPDF path — replaces _extract_structured_lines)
# ---------------------------------------------------------------------------

# Internal: fully-typed raw line tuple produced during block extraction.
# Fields: (x0, y0, x1, y1, text, spans)
_RawLine = Tuple[float, float, float, float, str, List[TextSpan]]


def _merge_open_parentheticals(blocks: List[TextBlock]) -> List[TextBlock]:
    """Pre-pass: merge PyMuPDF blocks that form a single multi-line parenthetical.

    When a block opens with '(' but the matching ')' is in a subsequent block,
    PyMuPDF has split the stage-direction paragraph at a line boundary.  This
    pass merges the continuation blocks into the opener so _classify_blocks
    sees a single balanced parenthetical.

    If the closing block has trailing text after ')' (e.g. dialog that begins
    on the same line as the stage-direction close), a synthetic TextBlock is
    inserted for that remainder so it can be classified independently.
    """
    result: List[TextBlock] = []
    i = 0
    while i < len(blocks):
        block = blocks[i]
        text = block.text

        if not text.startswith("("):
            result.append(block)
            i += 1
            continue

        depth = 0
        for c in text:
            if c == "(":
                depth += 1
            elif c == ")":
                depth -= 1

        if depth <= 0:
            result.append(block)
            i += 1
            continue

        # Only merge mid-sentence splits: opener must end without sentence-ending
        # punctuation.  Blocks ending in ".!?–—" are complete semantic units whose
        # closing ")" happens to be in a later block — merging them would collapse
        # multiple separate stage-direction elements into one.
        last_char = text.rstrip()[-1] if text.rstrip() else ""
        if last_char in ".!?–—":
            result.append(block)
            i += 1
            continue

        # Unbalanced opener — merge subsequent blocks until parens balance.
        # Hard cap: only look ahead _PAREN_MERGE_LOOKAHEAD blocks so a block
        # that starts with '(' but never closes (dialog, etc.) doesn't eat
        # the rest of the document.
        merged_parts = [text]
        all_line_spans: List[List[TextSpan]] = list(block.lines)
        j = i + 1
        trailing_text: Optional[str] = None
        trailing_geo = (block.x0, block.y0, block.x1, block.y1, block.page)
        found_close = False
        limit = i + _PAREN_MERGE_LOOKAHEAD

        while j < len(blocks) and j <= limit and depth > 0:
            nb = blocks[j]
            nt = nb.text
            close_idx: Optional[int] = None
            nd = depth
            for k, c in enumerate(nt):
                if c == "(":
                    nd += 1
                elif c == ")":
                    nd -= 1
                    if nd <= 0:
                        close_idx = k
                        break

            if close_idx is not None:
                merged_parts.append(nt[: close_idx + 1])
                after = nt[close_idx + 1 :].strip()
                all_line_spans.extend(nb.lines)
                trailing_geo = (nb.x0, nb.y0, nb.x1, nb.y1, nb.page)
                if after:
                    trailing_text = after
                depth = 0
                found_close = True
                j += 1
            else:
                merged_parts.append(nt)
                all_line_spans.extend(nb.lines)
                depth = nd
                j += 1

        if found_close:
            last = blocks[j - 1]
            merged_text = " ".join(merged_parts)
            merged_chars = "".join(merged_parts)
            alpha = [c for c in merged_chars if c.isalpha()]
            caps_r = sum(1 for c in alpha if c.isupper()) / max(len(alpha), 1)
            mx1 = max(block.x1, last.x1)
            merged = TextBlock(
                x0=block.x0, y0=block.y0, x1=mx1, y1=last.y1,
                page=block.page, lines=all_line_spans,
                text=merged_text, caps_ratio=caps_r,
                center_x=(block.x0 + mx1) / 2,
                width=mx1 - block.x0, height=last.y1 - block.y0,
                line_count=len(all_line_spans),
                char_count=len(merged_chars),
                starts_with_paren=True,
                ends_with_paren=merged_text.rstrip().endswith(")"),
                is_italic=block.is_italic, is_bold=block.is_bold,
                is_merged_parenthetical=True,
            )
            result.append(merged)

            if trailing_text:
                tx0, ty0, tx1, ty1, tpage = trailing_geo
                ta = [c for c in trailing_text if c.isalpha()]
                tc_ratio = sum(1 for c in ta if c.isupper()) / max(len(ta), 1)
                synthetic = TextBlock(
                    x0=tx0, y0=ty0, x1=tx1, y1=ty1,
                    page=tpage, lines=[],
                    text=trailing_text, caps_ratio=tc_ratio,
                    center_x=(tx0 + tx1) / 2,
                    width=tx1 - tx0, height=ty1 - ty0,
                    line_count=1, char_count=len(trailing_text),
                    starts_with_paren=trailing_text.startswith("("),
                    ends_with_paren=trailing_text.rstrip().endswith(")"),
                    is_italic=False, is_bold=False,
                )
                result.append(synthetic)
            i = j
        else:
            # Paren never closed within the lookahead — emit original block unchanged.
            result.append(block)
            i += 1

    return result


def _extract_blocks(pdf_path: str) -> List[TextBlock]:
    """Extract semantic TextBlock objects from a PDF using PyMuPDF.

    Returns an empty list if PyMuPDF is not installed so the caller can fall
    back to the pdfplumber path without crashing.

    Each returned TextBlock is an atomic unit (stage direction, speaker cue,
    dialog paragraph, or parenthetical).  PyMuPDF blocks that contain mixed
    content — e.g. a stage direction immediately followed by a speaker cue
    and dialog, all within the same rectangular region — are split at:

      1. Blank lines within the raw PyMuPDF block.
      2. Speaker-cue transitions: if the first non-blank line of a sub-run is
         an ALL-CAPS name (≤ 50 chars) and more content follows, the speaker
         cue becomes its own TextBlock so the classifier sees
         [speaker_cue] → [dialog] rather than one compound block.
    """
    try:
        import fitz  # PyMuPDF
    except ImportError:
        logger.warning("PyMuPDF not installed; block extraction unavailable")
        return []

    result: List[TextBlock] = []
    with fitz.open(pdf_path) as doc:
        for page_num, page in enumerate(doc):
            raw_blocks = page.get_text("dict")["blocks"]
            for raw_block in raw_blocks:
                if raw_block["type"] != 0:
                    continue  # skip image/drawing blocks
                result.extend(_split_raw_block(raw_block, page_num))
    return result


def _split_raw_block(raw_block: dict, page_num: int) -> List[TextBlock]:
    """Convert one PyMuPDF block dict into one or more TextBlock objects."""
    # Build typed line tuples from PyMuPDF's nested dict structure.
    raw_lines: List[_RawLine] = []
    for line in raw_block["lines"]:
        x0, y0, x1, y1 = line["bbox"]
        spans = [
            TextSpan(
                text=s["text"],
                bold=bool(s["flags"] & (1 << 4)),
                italic=bool(s["flags"] & (1 << 1)),
                font=s["font"],
                size=s["size"],
            )
            for s in line["spans"]
        ]
        text = "".join(s.text for s in spans).strip()
        raw_lines.append((x0, y0, x1, y1, text, spans))

    # Split at blank lines → sub-runs of consecutive non-empty lines.
    sub_runs: List[List[_RawLine]] = []
    current: List[_RawLine] = []
    for raw_line in raw_lines:
        if not raw_line[4]:  # empty text
            if current:
                sub_runs.append(current)
                current = []
        else:
            current.append(raw_line)
    if current:
        sub_runs.append(current)

    result: List[TextBlock] = []
    for run in sub_runs:
        first_text = run[0][4]
        if len(run) > 1 and _is_speaker_cue_text(first_text):
            # Split speaker cue from following content.
            result.append(_make_text_block([run[0]], page_num))
            tail = _make_text_block(run[1:], page_num)
            tail.is_split_continuation = True
            result.append(tail)
        elif len(run) > 1 and _is_cue_with_inline_paren_line(first_text):
            # "SPEAKER (stage direction)\nDialog" — the paren on the cue line
            # drops the caps ratio below the normal threshold, so it can't be
            # detected by _is_speaker_cue_text.  Split and tag the cue block so
            # Phase 2 can force-classify it as a speaker cue.
            cue = _make_text_block([run[0]], page_num)
            cue.is_cue_with_inline_paren = True
            result.append(cue)
            tail = _make_text_block(run[1:], page_num)
            tail.is_split_continuation = True
            result.append(tail)
        else:
            result.append(_make_text_block(run, page_num))
    return result


def _is_speaker_cue_text(text: str) -> bool:
    """Return True if text looks like a standalone speaker cue line.

    Criteria:
    - ≤ 50 chars
    - ≥ 90 % of alphabetic chars are uppercase
    - At least 2 alphabetic chars
    - Not a scene-heading keyword (INT, EXT, ACT, SCENE, …)
    - Not a page-marker / draft-watermark line
    """
    t = text.strip()
    if not t or len(t) > 50:
        return False
    if not t[0].isupper():
        return False
    alpha = [c for c in t if c.isalpha()]
    if len(alpha) < 1:
        return False
    if sum(1 for c in alpha if c.isupper()) / len(alpha) < 0.9:
        return False
    if re.match(r"^(?:INT|EXT|ACT|SCENE|PART|PROLOGUE|EPILOGUE)\b", t, re.IGNORECASE):
        return False
    if _PAGE_MARKER_RE.match(t):
        return False
    return True


# Matches "NAME (stage direction)" — all-caps name followed by a parenthetical
# that fills the rest of the line (nothing after the closing paren).
_CUE_WITH_INLINE_PAREN_RE = re.compile(r'^([A-Z][A-Z\'\s.]{0,30}?)\s*\([^)]+\)\s*$')


def _is_cue_with_inline_paren_line(text: str) -> bool:
    """Return True for 'SPEAKER (stage direction)' cue lines where the paren
    content prevents _is_speaker_cue_text from recognising the speaker name.

    Excludes standard screenplay continuation markers like '(CONT'D)' and
    '(cont.)' — those are handled elsewhere and don't need the extra split.
    """
    t = text.strip()
    m = _CUE_WITH_INLINE_PAREN_RE.match(t)
    if not m:
        return False
    if re.search(r'\(\s*cont', t, re.IGNORECASE):
        return False
    name = m.group(1).strip()
    return bool(name) and _is_speaker_cue_text(name)


def _make_text_block(lines: List[_RawLine], page_num: int) -> TextBlock:
    """Build a TextBlock from a list of (x0, y0, x1, y1, text, spans) tuples."""
    x0 = min(l[0] for l in lines)
    x1 = max(l[2] for l in lines)
    y0 = lines[0][1]
    y1 = lines[-1][3]

    line_texts = [l[4] for l in lines]
    all_spans: List[List[TextSpan]] = [l[5] for l in lines]

    text = " ".join(line_texts)
    all_chars = "".join(line_texts)
    alpha = [c for c in all_chars if c.isalpha()]
    caps_r = sum(1 for c in alpha if c.isupper()) / max(len(alpha), 1)

    total_chars = sum(len(s.text) for spans in all_spans for s in spans)
    italic_chars = sum(len(s.text) for spans in all_spans for s in spans if s.italic)
    bold_chars = sum(len(s.text) for spans in all_spans for s in spans if s.bold)

    width = x1 - x0
    return TextBlock(
        x0=x0,
        y0=y0,
        x1=x1,
        y1=y1,
        page=page_num,
        lines=all_spans,
        text=text,
        caps_ratio=caps_r,
        center_x=(x0 + x1) / 2,
        width=width,
        height=y1 - y0,
        line_count=len(lines),
        char_count=len(all_chars),
        starts_with_paren=text.lstrip().startswith("("),
        ends_with_paren=text.rstrip().endswith(")"),
        is_italic=total_chars > 0 and italic_chars > total_chars / 2,
        is_bold=total_chars > 0 and bold_chars > total_chars / 2,
    )


# ---------------------------------------------------------------------------
# Layout profile inference (block-level)
# ---------------------------------------------------------------------------


@dataclass
class LayoutProfile:
    """Learned spatial layout of a script inferred from block positions.

    Used by _classify_blocks to distinguish dialog from stage directions
    when the two share similar content features but appear at different x
    positions on the page.
    """
    speaker_x: float           # modal x0 of speaker cue blocks
    dialog_x: float            # modal x0 of dialog blocks
    stage_dir_x: Optional[float]  # modal x0 of stage-direction blocks (may be None or == dialog_x)
    page_width: float
    is_split_layout: bool      # True when speaker_x and dialog_x differ by > 30 pt


def _infer_layout_profile(blocks: List[TextBlock], page_width: float = 612.0) -> LayoutProfile:
    """Infer the script's spatial layout from a flat list of TextBlocks.

    Algorithm:
    1. Find all candidate speaker-cue blocks using _is_speaker_cue_text.
    2. The x0 of these blocks clusters around the speaker cue column.
    3. The x0 of blocks immediately following each speaker cue clusters
       around the dialog column.
    4. Any remaining low-caps-ratio blocks at a third x cluster are
       stage directions.
    """
    def _modal_x(xs: List[float]) -> Optional[float]:
        if not xs:
            return None
        # Bucket to nearest 5 pt to suppress sub-pixel variation.
        counts: Counter = Counter(round(x / 5) * 5 for x in xs)
        return float(counts.most_common(1)[0][0])

    cue_xs: List[float] = []
    dialog_xs: List[float] = []

    for i, block in enumerate(blocks):
        if not (block.line_count == 1 and _is_speaker_cue_text(block.text)):
            continue
        cue_xs.append(block.x0)
        # The immediately following block is usually dialog.
        if i + 1 < len(blocks):
            nxt = blocks[i + 1]
            if nxt.caps_ratio < 0.5 and not (nxt.starts_with_paren and nxt.ends_with_paren):
                dialog_xs.append(nxt.x0)

    speaker_x = _modal_x(cue_xs) or page_width / 2
    dialog_x = _modal_x(dialog_xs) or 90.0

    # Stage direction x: low-caps blocks that are NOT at dialog_x and are
    # not speaker cues themselves (e.g. TheHarvest stage dirs live at x=270).
    stage_dir_xs = [
        b.x0 for b in blocks
        if b.caps_ratio < 0.5
        and b.char_count > 20
        and abs(b.x0 - dialog_x) > 20
        and not _is_speaker_cue_text(b.text)
        and not (b.starts_with_paren and b.ends_with_paren)
    ]
    stage_dir_x = _modal_x(stage_dir_xs)

    return LayoutProfile(
        speaker_x=speaker_x,
        dialog_x=dialog_x,
        stage_dir_x=stage_dir_x,
        page_width=page_width,
        is_split_layout=abs(speaker_x - dialog_x) > 30,
    )


# ---------------------------------------------------------------------------
# Block classifier
# ---------------------------------------------------------------------------


@dataclass
class ClassifiedBlock:
    """A TextBlock with a predicted structural role and optional speaker."""
    block: TextBlock
    role: str                    # 'speaker_cue' | 'dialog' | 'stage_direction' |
                                 # 'parenthetical' | 'scene_heading' | 'noise'
    speaker: Optional[str] = None  # populated for 'speaker_cue' blocks only


_SCENE_HEADING_BLOCK_RE = re.compile(
    r"""^(?:
        (?:INT|EXT|INT\.\/EXT|EXT\.\/INT)[\.\s]   # INT./EXT. sluglines
        | SCENE\s+\w+                               # SCENE 3 / SCENE IV
        | ACT\s+\w+                                 # ACT I / ACT ONE
        | PART\s+\w+                                # PART ONE
        | PROLOGUE\b | EPILOGUE\b
        | (?:ONE|TWO|THREE|FOUR|FIVE|SIX|SEVEN|EIGHT|NINE|TEN|\d+)  # e.g. "THREE DAYS TO DEPARTURE"
          \s+DAYS?\s+(?:TO|UNTIL|BEFORE|AFTER)\b
    )""",
    re.IGNORECASE | re.VERBOSE,
)

_X_TOLERANCE = 15.0           # pt — two x-values are "the same column" if within this
# Only merge a parenthetical that continues into the immediately following block
# (dist = 1) AND whose opener ends mid-word (no sentence-ending punctuation).
# Larger spans mean the blocks are already semantically separate elements.
_PAREN_MERGE_LOOKAHEAD = 1


# ---------------------------------------------------------------------------
# Phase 1 — Confidence-based block scorer
# ---------------------------------------------------------------------------
#
# Each block is scored against a library of weighted signals.  Signals capture
# typographic properties (caps ratio, length, styling), positional context
# (x-zone membership from the layout profile), document-frequency statistics
# (how often similar blocks appear at the same column), and regex patterns
# (hard format markers).  Each signal contributes independently; the type
# with the highest weighted sum wins.  Negative weights penalise a type.
#
# This is deliberately separate from Phase 2 (speaker attribution).  The
# scorer answers "what KIND of block is this?" purely from evidence on the
# page.  Phase 2 answers "whose line is it?" from sequence context.

# ---------------------------------------------------------------------------
# Document statistics (computed once per document, used by frequency signals)

@dataclass
class _DocStats:
    x_bin_count: Dict[int, int]       # {x_bin_5pt: total_block_count}
    x_bin_caps_avg: Dict[int, float]  # {x_bin_5pt: mean_caps_ratio}
    text_frequency: Dict[str, int]    # {normalised_text: occurrence_count}
    max_x_count: int                  # max value in x_bin_count (for normalisation)
    total_blocks: int


def _compute_doc_stats(blocks: List["TextBlock"]) -> _DocStats:
    x_count: Dict[int, int] = defaultdict(int)
    x_caps_sum: Dict[int, float] = defaultdict(float)
    text_freq: Dict[str, int] = defaultdict(int)

    for b in blocks:
        xb = round(b.x0 / 5) * 5
        x_count[xb] += 1
        x_caps_sum[xb] += b.caps_ratio
        text_freq[b.text.strip()] += 1

    x_caps_avg = {xb: x_caps_sum[xb] / x_count[xb] for xb in x_count}
    max_x = max(x_count.values()) if x_count else 1

    return _DocStats(
        x_bin_count=dict(x_count),
        x_bin_caps_avg=x_caps_avg,
        text_frequency=dict(text_freq),
        max_x_count=max_x,
        total_blocks=len(blocks),
    )


# ---------------------------------------------------------------------------
# Convention library
#
# Each Convention names a signal and the weight it contributes to each block
# type's score.  Positive = supports that type; negative = penalises it.
# strength (0–1) scales all weights — higher means the convention is more
# reliable across different script formats.
#
# Adding a new convention: append a _Convention entry here.  The signal id
# must match a key in _SIGNAL_FNS below.

_BTYPES = ("character_cue", "dialog", "stage_direction", "parenthetical", "scene_heading", "noise")
_CC, _DL, _SD, _PA, _SH, _NO = _BTYPES  # shorthand aliases for weight dicts


@dataclass
class _Convention:
    id: str                     # must match a key in _SIGNAL_FNS
    weights: Dict[str, float]   # btype -> weight; negative penalises that type
    strength: float             # 0-1: reliability across script formats
    source: str                 # "universal"|"screenplay"|"stage_play"|"observed"


# Regex patterns referenced by signal functions
_SIG_INT_EXT_RE    = re.compile(r'^(INT|EXT|INT\.\/EXT|EXT\.\/INT)[\.\s]', re.I)
_SIG_ACT_SCENE_RE  = re.compile(r'^(ACT\s+[IVX\d]+|SCENE\s+[IVX\d]+)', re.I)
_SIG_TRANSITION_RE = re.compile(r'^(CUT TO|FADE (?:TO|IN|OUT)|SMASH CUT|DISSOLVE TO|MATCH CUT)[\:\.s]?\s*$', re.I)
_SIG_PAGENUM_RE    = re.compile(r'^\d+\.?$')
_SIG_VO_OS_RE      = re.compile(r'\(V\.O\.\)|\(O\.S\.\)|\(O\.C\.\)|\(PRE-LAP\)|\(NARR\.\)', re.I)
_SIG_CONTD_RE      = re.compile(r"\(CONT'D\)|\(MORE\)", re.I)


# Signal functions — each returns a float in [0, 1].
# Signature: (block, profile, doc_stats) — unused args are accepted but ignored.
# fmt: off
def _sig_all_caps(b, p, d):       return b.caps_ratio
def _sig_mixed_case(b, p, d):     return 1.0 - b.caps_ratio
def _sig_is_short(b, p, d):       return max(0.0, 1.0 - b.char_count / 50.0)
def _sig_is_long(b, p, d):        return min(1.0, b.char_count / 120.0)
def _sig_single_line(b, p, d):    return 1.0 if b.line_count == 1 else 0.0
def _sig_balanced_parens(b, p, d): return 1.0 if (b.starts_with_paren and b.ends_with_paren) else 0.0
def _sig_is_italic(b, p, d):      return 1.0 if b.is_italic else 0.0
def _sig_is_bold(b, p, d):        return 1.0 if b.is_bold else 0.0

def _sig_at_speaker_x(b, p, d):   return 1.0 if abs(b.x0 - p.speaker_x) <= _X_TOLERANCE else 0.0
def _sig_at_dialog_x(b, p, d):    return 1.0 if abs(b.x0 - p.dialog_x) <= _X_TOLERANCE else 0.0
def _sig_at_stage_dir_x(b, p, d):
    return 0.0 if p.stage_dir_x is None else (1.0 if abs(b.x0 - p.stage_dir_x) <= _X_TOLERANCE else 0.0)
def _sig_near_page_edge_y(b, p, d): return 1.0 if (b.y0 < 60 or b.y1 > 732) else 0.0

def _sig_speaker_zone(b, p, d):
    # High when block is in a zone that is both high-frequency AND predominantly
    # ALL CAPS — i.e. a character-cue column.  Product of the two factors avoids
    # boosting dialog columns that are also high-frequency but low-caps.
    xb = round(b.x0 / 5) * 5
    freq = d.x_bin_count.get(xb, 0) / d.max_x_count if d.max_x_count else 0.0
    caps_avg = d.x_bin_caps_avg.get(xb, 0.0)
    return freq * caps_avg
def _sig_dialog_zone(b, p, d):
    # Complement of speaker_zone: high-frequency zone with predominantly mixed-case
    # text — i.e. a dialog column.
    xb = round(b.x0 / 5) * 5
    freq = d.x_bin_count.get(xb, 0) / d.max_x_count if d.max_x_count else 0.0
    caps_avg = d.x_bin_caps_avg.get(xb, 0.0)
    return freq * (1.0 - caps_avg)
def _sig_text_uniqueness(b, p, d):
    freq = d.text_frequency.get(b.text.strip(), 1)
    return max(0.0, 1.0 - (freq - 1) / 5.0)   # freq≥6 → 0.0; unique → 1.0

def _sig_matches_int_ext(b, p, d):    return 1.0 if _SIG_INT_EXT_RE.match(b.text) else 0.0
def _sig_matches_act_scene(b, p, d):  return 1.0 if _SIG_ACT_SCENE_RE.match(b.text) else 0.0
def _sig_matches_transition(b, p, d): return 1.0 if _SIG_TRANSITION_RE.match(b.text.strip()) else 0.0
def _sig_is_page_number(b, p, d):     return 1.0 if _SIG_PAGENUM_RE.match(b.text.strip()) else 0.0
def _sig_vo_os_suffix(b, p, d):       return 1.0 if _SIG_VO_OS_RE.search(b.text) else 0.0
def _sig_continued_suffix(b, p, d):   return 1.0 if _SIG_CONTD_RE.search(b.text) else 0.0
def _sig_simultaneous_slash(b, p, d): return 1.0 if ' / ' in b.text else 0.0
# fmt: on

_SIGNAL_FNS: Dict[str, Callable] = {
    "all_caps":           _sig_all_caps,
    "mixed_case":         _sig_mixed_case,
    "is_short":           _sig_is_short,
    "is_long":            _sig_is_long,
    "single_line":        _sig_single_line,
    "balanced_parens":    _sig_balanced_parens,
    "is_italic":          _sig_is_italic,
    "is_bold":            _sig_is_bold,
    "at_speaker_x":       _sig_at_speaker_x,
    "at_dialog_x":        _sig_at_dialog_x,
    "at_stage_dir_x":     _sig_at_stage_dir_x,
    "near_page_edge_y":   _sig_near_page_edge_y,
    "speaker_zone":       _sig_speaker_zone,
    "dialog_zone":        _sig_dialog_zone,
    "text_uniqueness":    _sig_text_uniqueness,
    "matches_int_ext":    _sig_matches_int_ext,
    "matches_act_scene":  _sig_matches_act_scene,
    "matches_transition": _sig_matches_transition,
    "is_page_number":     _sig_is_page_number,
    "vo_os_suffix":       _sig_vo_os_suffix,
    "continued_suffix":   _sig_continued_suffix,
    "simultaneous_slash": _sig_simultaneous_slash,
}

CONVENTIONS: List[_Convention] = [
    # ── Typographic ───────────────────────────────────────────────────────────
    _Convention("all_caps",
        weights={_CC: 0.80, _DL: -0.40, _SD: -0.10, _PA: -0.20, _SH: 0.30},
        strength=0.90, source="universal"),
    _Convention("mixed_case",
        weights={_CC: -0.30, _DL: 0.35, _SD: 0.35, _PA: 0.25, _SH: -0.20},
        strength=0.70, source="universal"),
    _Convention("is_short",
        weights={_CC: 0.50, _DL: -0.20, _SD: -0.10, _PA: 0.30, _SH: 0.20, _NO: 0.40},
        strength=0.70, source="universal"),
    _Convention("is_long",
        weights={_CC: -0.80, _DL: 0.30, _SD: 0.30, _PA: -0.60, _SH: -0.50, _NO: -0.70},
        strength=0.85, source="universal"),
    _Convention("single_line",
        weights={_CC: 0.40, _DL: -0.10, _SD: -0.10, _PA: 0.25, _SH: 0.35, _NO: 0.50},
        strength=0.75, source="universal"),
    _Convention("balanced_parens",
        weights={_CC: -0.30, _DL: -0.20, _SD: 0.30, _PA: 0.90, _SH: -0.40},
        strength=0.90, source="universal"),
    _Convention("is_italic",
        weights={_CC: 0.15, _DL: -0.10, _SD: 0.55, _PA: 0.35, _SH: -0.10},
        strength=0.65, source="stage_play"),
    _Convention("is_bold",
        weights={_CC: 0.30, _DL: -0.10, _SD: -0.10, _PA: -0.10, _SH: 0.25},
        strength=0.55, source="stage_play"),
    # ── Positional ────────────────────────────────────────────────────────────
    _Convention("at_speaker_x",
        weights={_CC: 0.70, _DL: -0.20, _SD: 0.10, _PA: -0.10, _SH: 0.10},
        strength=0.85, source="universal"),
    _Convention("at_dialog_x",
        weights={_CC: -0.10, _DL: 0.65, _SD: -0.10, _PA: 0.55, _SH: -0.10},
        strength=0.80, source="universal"),
    _Convention("at_stage_dir_x",
        # Blocks in a third column are almost always stage directions.
        # Balanced-paren blocks there are embedded stage directions, NOT
        # character parentheticals — so PA is penalised.
        weights={_CC: -0.20, _DL: -0.20, _SD: 0.65, _PA: -0.30, _SH: -0.10},
        strength=0.75, source="universal"),
    _Convention("near_page_edge_y",
        weights={_CC: -0.30, _DL: -0.30, _SD: -0.10, _PA: -0.20, _SH: -0.20, _NO: 0.65},
        strength=0.75, source="universal"),
    # ── Document-frequency ────────────────────────────────────────────────────
    _Convention("speaker_zone",
        # Product of x-bin frequency and zone caps average.  High only when a
        # column is BOTH heavily used AND predominantly ALL CAPS — i.e. a real
        # speaker-cue column.  Avoids falsely boosting CC for dialog columns
        # (which are also high-frequency but mixed-case).
        weights={_CC: 0.90, _DL: -0.20, _SD: 0.10, _PA: 0.10, _SH: 0.20},
        strength=0.95, source="universal"),
    _Convention("dialog_zone",
        # Complement: high-frequency, low-caps zone → dialog column.
        weights={_CC: -0.40, _DL: 0.65, _SD: 0.20, _PA: 0.40, _SH: -0.10},
        strength=0.90, source="universal"),
    _Convention("text_uniqueness",
        weights={_CC: -0.50, _DL: 0.30, _SD: 0.35, _PA: 0.20, _SH: 0.20},
        strength=0.70, source="universal"),
    # ── Pattern / regex ───────────────────────────────────────────────────────
    _Convention("matches_int_ext",
        weights={_CC: -0.80, _DL: -0.80, _SD: 0.10, _PA: -0.80, _SH: 0.95, _NO: -0.50},
        strength=0.99, source="screenplay"),
    _Convention("matches_act_scene",
        weights={_CC: -0.20, _DL: -0.50, _SD: -0.10, _PA: -0.30, _SH: 0.85},
        strength=0.90, source="stage_play"),
    _Convention("matches_transition",
        weights={_CC: -0.50, _DL: -0.50, _SD: 0.20, _PA: -0.30, _SH: 0.70},
        strength=0.92, source="screenplay"),
    _Convention("is_page_number",
        weights={_CC: -0.90, _DL: -0.90, _SD: -0.70, _PA: -0.80, _SH: -0.80, _NO: 0.90},
        strength=0.95, source="universal"),
    _Convention("vo_os_suffix",
        weights={_CC: 0.85, _DL: -0.40, _SD: -0.20, _PA: 0.10, _SH: -0.30},
        strength=0.92, source="screenplay"),
    _Convention("continued_suffix",
        weights={_CC: 0.75, _DL: -0.60, _SD: -0.40, _PA: -0.20, _SH: -0.40},
        strength=0.90, source="universal"),
    _Convention("simultaneous_slash",
        weights={_CC: -0.10, _DL: 0.60, _SD: -0.10, _PA: -0.10, _SH: -0.30},
        strength=0.70, source="observed"),
]


@dataclass
class ScoredBlock:
    """A TextBlock with per-type confidence scores from Phase 1 of classification."""
    block: "TextBlock"
    scores: Dict[str, float]  # btype -> raw weighted sum (can be negative)
    best_type: str            # type with highest score
    confidence: float         # winner's lead over runner-up, normalised to [0, 1]


def _score_block(
    block: "TextBlock",
    profile: "LayoutProfile",
    doc_stats: _DocStats,
) -> ScoredBlock:
    """Score one block against all conventions and return the winner."""
    raw: Dict[str, float] = {t: 0.0 for t in _BTYPES}

    for conv in CONVENTIONS:
        fn = _SIGNAL_FNS.get(conv.id)
        if fn is None:
            continue
        sig_val = fn(block, profile, doc_stats)
        if sig_val == 0.0:
            continue
        for btype, weight in conv.weights.items():
            raw[btype] = raw.get(btype, 0.0) + sig_val * weight * conv.strength

    best = max(raw, key=lambda t: raw[t])

    # Normalise confidence: shift so min=0, then winner fraction of total.
    mn = min(raw.values())
    shifted = {t: raw[t] - mn for t in raw}
    total = sum(shifted.values()) or 1.0
    confidence = shifted[best] / total

    return ScoredBlock(block=block, scores=raw, best_type=best, confidence=confidence)


def _score_blocks(
    blocks: List["TextBlock"],
    profile: "LayoutProfile",
) -> List[ScoredBlock]:
    """Phase 1: classify all blocks by typographic, positional, and frequency signals."""
    doc_stats = _compute_doc_stats(blocks)
    return [_score_block(b, profile, doc_stats) for b in blocks]


def _classify_blocks(
    blocks: List[TextBlock],
    profile: LayoutProfile,
) -> List[ClassifiedBlock]:
    """Two-phase block classification.

    Phase 1 — scoring (_score_blocks): each block is scored against the
    convention library to determine its most likely structural type purely
    from typographic, positional, and document-frequency signals.

    Phase 2 — semantic pass (below): reads the sequence of scored blocks and
    applies speaker-attribution state.  The only sequence-level overrides are:
      • dialog with no pending speaker → reclassified stage_direction (scripts
        where stage dirs share the dialog column, e.g. NoneOfUs)
      • merged parenthetical stage_direction → pending_speaker preserved so
        the character continues after the embedded aside (EDDIE pattern)
    """
    scored = _score_blocks(blocks, profile)
    result: List[ClassifiedBlock] = []
    pending_speaker: Optional[str] = None

    for sb in scored:
        block = sb.block
        text = block.text.strip()

        # Empty blocks are always noise regardless of score.
        if not text:
            result.append(ClassifiedBlock(block=block, role="noise"))
            continue

        # "SPEAKER (stage direction)" cue blocks — bypass Phase 1 scoring entirely.
        # _split_raw_block already separated the cue from the dialog tail; here we
        # just need to extract the speaker name and promote the block to speaker_cue.
        if block.is_cue_with_inline_paren:
            speaker = _normalize_speaker(text).rstrip(".:,")
            if speaker:
                pending_speaker = speaker
                result.append(ClassifiedBlock(block=block, role="speaker_cue",
                                              speaker=speaker))
            else:
                result.append(ClassifiedBlock(block=block, role="noise"))
            continue

        # Hard overrides for definitive format markers.  These regex patterns
        # are high-confidence enough to bypass the scorer — typographic signals
        # like is_long/mixed_case would otherwise outweigh them.
        if _PAGE_MARKER_RE.match(text):
            result.append(ClassifiedBlock(block=block, role="noise"))
            continue

        if _SCENE_HEADING_BLOCK_RE.match(text):
            # Reject TOC entries: "SCENE N: long description…"
            colon_pos = text.find(":")
            after_colon = text[colon_pos + 1:].strip() if colon_pos != -1 else ""
            if colon_pos == -1 or len(after_colon) <= 30:
                result.append(ClassifiedBlock(block=block, role="scene_heading"))
                continue
            # Long colon suffix → likely a TOC entry; fall through to scorer.

        role = sb.best_type

        if role == "noise":
            result.append(ClassifiedBlock(block=block, role="noise"))

        elif role == "scene_heading":
            # Reached here only for TOC-rejected blocks whose scorer still
            # voted scene_heading — treat as stage_direction.
            result.append(ClassifiedBlock(block=block, role="stage_direction"))

        elif role == "parenthetical":
            at_dlg = abs(block.x0 - profile.dialog_x) <= _X_TOLERANCE
            if (block.starts_with_paren and block.ends_with_paren
                    and block.char_count <= 120 and at_dlg):
                # True character parenthetical: short balanced-paren block at the
                # dialog column — e.g. "(quietly)", "(beat)", "(to DIANA)".
                # Preserve pending_speaker so dialog that follows stays attributed.
                result.append(ClassifiedBlock(block=block, role="parenthetical",
                                              speaker=pending_speaker))
            else:
                # Misfire: either no enclosing parens (short dialog/SD block that
                # scored as PA via single_line+at_dialog_x), or a long/off-column
                # paren block (multi-sentence stage direction in parens, cast note, etc).
                if at_dlg and pending_speaker is not None and not (
                    block.starts_with_paren and block.ends_with_paren
                ):
                    # Non-paren block at dialog_x — treat as dialog continuation.
                    result.append(ClassifiedBlock(block=block, role="dialog",
                                                  speaker=pending_speaker))
                else:
                    result.append(ClassifiedBlock(block=block, role="stage_direction"))

        elif role == "character_cue":
            if block.is_split_continuation and pending_speaker is not None:
                # This block is the dialog tail produced when _split_raw_block separated
                # a speaker cue from its following text.  Even if it scores as CC (e.g.
                # "B." after "ANDY"), the pending speaker is already correct — treat it
                # as dialog rather than promoting it to a new speaker cue.
                result.append(ClassifiedBlock(block=block, role="dialog",
                                              speaker=pending_speaker))
            elif block.caps_ratio >= 0.80:
                # Confirmed character cue — predominantly ALL CAPS.
                # Reject blocks that are far from the speaker column — these are
                # typically right-column labels in parallel-speech layouts where
                # two characters' lines appear side-by-side on the same y.
                if abs(block.x0 - profile.speaker_x) > _X_TOLERANCE * 5:
                    result.append(ClassifiedBlock(block=block, role="stage_direction"))
                else:
                    speaker = _normalize_speaker(text).rstrip(".:,")
                    if not speaker:
                        # Normalization stripped everything (e.g. "(CONTINUED:)" or
                        # "(MORE)" page-continuation markers).  Treat as noise and
                        # preserve pending_speaker so the speech continues correctly.
                        result.append(ClassifiedBlock(block=block, role="noise"))
                    else:
                        pending_speaker = speaker
                        result.append(ClassifiedBlock(block=block, role="speaker_cue",
                                                      speaker=speaker))
            else:
                # Scorer misfired: short mixed-case block (stage direction, one-word
                # response) at a high-frequency x-zone scored as CC via zone signals.
                # Reclassify by positional context instead.
                at_dlg = abs(block.x0 - profile.dialog_x) <= _X_TOLERANCE
                if at_dlg and pending_speaker is not None:
                    result.append(ClassifiedBlock(block=block, role="dialog",
                                                  speaker=pending_speaker))
                else:
                    result.append(ClassifiedBlock(block=block, role="stage_direction"))

        elif role == "dialog":
            if pending_speaker is not None:
                result.append(ClassifiedBlock(block=block, role="dialog",
                                              speaker=pending_speaker))
            else:
                # No active speaker — block is at dialog_x but between speeches.
                # Common in scripts where stage directions share the dialog column
                # (NoneOfUs, AgainstTheHillside, etc.).
                result.append(ClassifiedBlock(block=block, role="stage_direction"))

        else:  # stage_direction
            result.append(ClassifiedBlock(block=block, role="stage_direction"))

    return result


# ---------------------------------------------------------------------------
# Script assembly from classified blocks
# ---------------------------------------------------------------------------


def _split_leading_paren(text: str) -> Tuple[Optional[str], str]:
    """Split a leading parenthetical from the rest of a text.

    Returns (paren_text, remainder) where paren_text is the leading "(…)"
    and remainder is everything after it (stripped).  Returns (None, text)
    if there is no leading parenthetical followed by more content.
    """
    if not text.startswith("("):
        return None, text
    depth = 0
    for i, c in enumerate(text):
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                paren = text[: i + 1]
                rest = text[i + 1 :].strip()
                if rest:
                    return paren, rest
                break
    return None, text


def _build_script_from_blocks(
    classified: List[ClassifiedBlock],
    title: str,
    config: Optional[dict] = None,
) -> Script:
    """Assemble a Script from classified blocks.

    Groups classified blocks into scenes (split on 'scene_heading' blocks)
    and converts each block into an Element.  Since blocks are already
    paragraph-level units, no line-merging is required.
    """
    scenes: List[Scene] = []
    current_elements: List[Element] = []
    scene_number = 0
    scene_title = "Scene 1"

    def _flush_scene() -> None:
        nonlocal scene_number, scene_title
        if current_elements:
            scenes.append(Scene(number=scene_number, title=scene_title,
                                elements=list(current_elements)))
        current_elements.clear()

    # If scene headings exist, drop all content before the first heading to
    # remove front-matter contamination (title pages, cast lists, etc.).
    has_headings = any(cb.role == "scene_heading" for cb in classified)
    if has_headings:
        first_idx = next(i for i, cb in enumerate(classified) if cb.role == "scene_heading")
        classified = classified[first_idx:]
    else:
        scene_number = 1  # no headings → everything goes into one scene

    for cb in classified:
        role = cb.role

        if role == "noise":
            continue

        if role == "scene_heading":
            _flush_scene()
            scene_number += 1
            scene_title = cb.block.text.strip()
            continue

        if role == "speaker_cue":
            # Speaker cues do not become elements; they set context for dialog.
            continue

        text = cb.block.text.strip()
        if not text:
            continue

        if role == "dialog":
            # Handle overlap cues (e.g. "ADA / TOM / DENISE")
            speaker = cb.speaker or ""
            overlap_cue: Optional[List[str]] = None
            if " / " in speaker:
                parts = [p.strip() for p in speaker.split(" / ") if p.strip()]
                if len(parts) >= 2:
                    overlap_cue = parts
                    speaker = parts[0]
            norm_speaker = _normalize_speaker(speaker)
            # Peel off any leading parentheticals like "(He sighs.) I think..."
            # before emitting the dialog proper.
            remaining = text
            while remaining.startswith("("):
                paren, rest = _split_leading_paren(remaining)
                if paren is None:
                    break
                current_elements.append(Element(kind="parenthetical",
                                                 text=paren, speaker=norm_speaker))
                remaining = rest
            if remaining:
                current_elements.append(Element(
                    kind="dialog",
                    text=remaining,
                    speaker=norm_speaker,
                    overlap_cue=overlap_cue,
                ))

        elif role == "parenthetical":
            current_elements.append(Element(
                kind="parenthetical",
                text=text,
                speaker=cb.speaker,
            ))

        elif role == "stage_direction":
            current_elements.append(Element(
                kind="stage_direction",
                text=text,
            ))

    _flush_scene()

    # Ensure at least one scene.
    if not scenes:
        scenes.append(Scene(number=1, title="Scene 1", elements=[]))

    characters = _extract_characters_from_elements(scenes)
    script = Script(title=title, characters=characters, scenes=scenes)

    if config:
        script = _apply_corrections_config(script, config)

    return _finalise(script)


def _extract_characters_from_elements(scenes: List[Scene]) -> List[Character]:
    """Collect unique speaker names from all dialog elements."""
    seen: Set[str] = set()
    chars: List[Character] = []
    for scene in scenes:
        for el in scene.elements:
            if el.kind == "dialog" and el.speaker and el.speaker not in seen:
                seen.add(el.speaker)
                chars.append(Character(name=el.speaker))
    return chars


# ---------------------------------------------------------------------------
# Top-level block-based parse (wires together all three steps)
# ---------------------------------------------------------------------------


def _block_parse(pdf_path: str, title: str, config: Optional[dict]) -> Script:
    """Parse a PDF using the block-level PyMuPDF extractor.

    This is now the primary parse path on the parser-block-extraction branch.
    Falls back to the pdfplumber path only if PyMuPDF is not installed
    (i.e. _extract_blocks returns an empty list).
    """
    blocks = _extract_blocks(pdf_path)
    if not blocks:
        return None  # PyMuPDF unavailable — caller will use pdfplumber

    blocks = _merge_open_parentheticals(blocks)

    page_widths = [b.x1 for b in blocks if b.x1 > 200]
    page_width = max(page_widths) + 90.0 if page_widths else 612.0

    profile = _infer_layout_profile(blocks, page_width=page_width)
    logger.debug(
        "Block profile: speaker_x=%.0f dialog_x=%.0f stage_dir_x=%s split=%s",
        profile.speaker_x, profile.dialog_x,
        f"{profile.stage_dir_x:.0f}" if profile.stage_dir_x else "None",
        profile.is_split_layout,
    )

    classified = _classify_blocks(blocks, profile)
    result = _build_script_from_blocks(classified, title=title, config=config)
    scene_count = len(result.scenes) if result else 0
    print(f"[parser] BLOCK PARSE OK — {len(blocks)} blocks, {scene_count} scenes, "
          f"speaker_x={profile.speaker_x:.0f} dialog_x={profile.dialog_x:.0f}",
          file=__import__("sys").stderr, flush=True)
    return result


# ---------------------------------------------------------------------------
# Scene-heading patterns used by _classify_lines
# ---------------------------------------------------------------------------


# A line is a speaker-cue candidate if it:
#   • Is not empty
#   • Is predominantly uppercase (≥ 85 % alpha chars are upper)
#   • Is short (≤ 60 chars)
#   • Does not look like a stage direction or scene heading


# ---------------------------------------------------------------------------
# Indent-zone auto-calibration (heist / scene_n formats)
# ---------------------------------------------------------------------------


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

    # Load data-driven corrections once.
    config = _load_corrections_config()

    # Block-level (PyMuPDF) parse — the only parse path. PyMuPDF is bundled with
    # the app; if it is somehow unavailable we fail loudly rather than silently
    # producing a worse parse. (_block_parse applies corrections + _finalise.)
    script = _block_parse(pdf_path, title, config)
    if script is None:
        raise RuntimeError(
            "PyMuPDF (fitz) is required to parse PDFs but is not installed. "
            "Install it with `pip install pymupdf`."
        )
    return script


# ---------------------------------------------------------------------------
# Play-format detection
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# Play-format page noise
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# Standard play format parser
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# Colon-cue play format parser (e.g. EMMA / TRW Plays)
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# Speaker normalization (shared by all formats)
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# Script format detection (heist / scene_n / dash_dialog — layout-based)
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# Cast extraction
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# Scene extraction — format router (heist / scene_n / dash_dialog)
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# HEIST-style scene extraction
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# SCENE N / INT-EXT style scene extraction
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# Dash-dialog format
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# Scene header helpers
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# Scene body parser (heist / scene_n)
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# Cue helpers
# ---------------------------------------------------------------------------


def _normalize_speaker(s: str) -> str:
    s = CONTD_RE.sub("", s)
    base = re.sub(r"\s*\([^)]*\)\s*", "", s).strip()
    base = re.sub(r"\s+", " ", base)
    return base


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
