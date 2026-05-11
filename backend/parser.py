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

import re
from collections import Counter
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Set, Tuple

import pdfplumber


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
PARENTHETICAL_RE = re.compile(r"^\s*\(.*\)\s*$")
CONTD_RE = re.compile(r"\s*\([^)]*CONT['']?D[^)]*\)", re.I)

# Dash-dialog format ("SPEAKER – text" inline on one line)
_DASH_DIALOG_LINE_RE = re.compile(
    r"^([A-Z0-9][A-Z0-9 /&]*?)\s*[–\-]\s*(.+)$"
)
_SCENE_NUM_DOT_RE = re.compile(r"^\s*(\d+)\.\s*$")
_INLINE_PAREN_RE = re.compile(r"^\(([^)]+)\)\s*(.*)$")

# ---------------------------------------------------------------------------
# Play-format regex constants
# ---------------------------------------------------------------------------

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
       |.*\s+DAYS?\s*$    # time-section headers: "DEPARTURE DAY", "OPENING DAY"
    )""",
    re.VERBOSE | re.IGNORECASE,
)

# Scene boundary in play format
_PLAY_SCENE_RE = re.compile(
    r"""^
    (?:
        (?:SCENE|Scene|SCENE)\s+(\d+)          # SCENE 1 / Scene 1
      | ACT\s+([IVXivx]+|\d+)                  # ACT I / ACT 1
      | -{1,3}\s*(\d+)\s*-{1,3}               # - 1 - / -- 2 --
      | ([1-9]\d?)\.\s*$                       # 1. or 12.  (scene number+dot, NOT page numbers)
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
            text = "".join(line_chars)
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

    out: List[str] = []
    with pdfplumber.open(pdf_path) as pdf:
        for page in pdf.pages:
            text = page.extract_text(layout=True, x_tolerance=2) or ""
            for line in text.split("\n"):
                out.append(_undouble(line))
    return out


def _extract_plain_lines(pdf_path: str) -> List[str]:
    """Return plain (non-layout) lines. Best for standard play format."""
    lines, _ = _extract_plain_lines_with_pages(pdf_path)
    return lines


def _extract_plain_lines_with_pages(pdf_path: str) -> Tuple[List[str], List[Set[str]]]:
    """Return (all_lines, per_page_content_sets) for play parsing + noise detection."""
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
                    normalized = _undouble(line)
                    plain_lines.append(normalized)
                    s = normalized.strip()
                    if s:
                        pg_set.add(s)
                pypdf_page_sets.append(pg_set)
            return plain_lines, pypdf_page_sets
        except Exception:
            pass  # fall through to pdfplumber

    all_lines: List[str] = []
    page_sets: List[Set[str]] = []
    with pdfplumber.open(pdf_path) as pdf:
        for page in pdf.pages:
            text = page.extract_text() or ""
            page_content: Set[str] = set()
            for line in text.split("\n"):
                normalized = _undouble(line)
                all_lines.append(normalized)
                s = normalized.strip()
                if s:
                    page_content.add(s)
            page_sets.append(page_content)
    return all_lines, page_sets


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
# Public API
# ---------------------------------------------------------------------------


def parse_pdf(pdf_path: str) -> Script:
    """Parse a PDF script into a Script object.

    Detection priority:
      1. heist (numbered scene headers, very distinctive) → layout-based
      2. colon_play / play (pattern-based, plain text)
      3. scene_n / dash_dialog (indent-based, layout text)
    """
    title = _derive_title(pdf_path)
    plain_lines, page_sets = _extract_plain_lines_with_pages(pdf_path)

    # Check for heist format first — numbered "N  SCENE TITLE" headers are
    # unambiguous and must win over the play detector (which also fires on
    # screenplays with all-caps character cues).
    heist_count = sum(1 for l in plain_lines if _is_heist_scene_header(l))
    if heist_count >= 2:
        layout_lines = extract_layout_lines(pdf_path)
        return parse_lines(layout_lines, title=title)

    # Play formats (pattern-based on plain text)
    play_fmt = _detect_play_format(plain_lines)
    if play_fmt == "play":
        return _parse_play(plain_lines, page_sets, title)
    if play_fmt == "colon_play":
        return _parse_colon_play(plain_lines, page_sets, title)

    # Fall back to indent-based parsing (scene_n, dash_dialog, heist fallback)
    layout_lines = extract_layout_lines(pdf_path)
    return parse_lines(layout_lines, title=title)


def parse_lines(lines: List[str], title: str = "Script") -> Script:
    """Parse pre-extracted layout lines (heist / scene_n / dash_dialog formats)."""
    script = Script(title=title)

    overrides = _detect_indent_zones(lines)
    zones = _make_zones(overrides)

    fmt = _detect_script_format(lines)

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

    return script


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
    # Sentence punctuation or header markers → not a speaker name
    if re.search(r"[.!?]", base):
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


def _detect_play_format(plain_lines: List[str]) -> Optional[str]:
    """Return 'play', 'colon_play', or None."""
    content_lines = [l.strip() for l in plain_lines if l.strip()]
    total = len(content_lines)
    if total < 40:
        return None

    # If 65%+ of content lines have no lowercase, this is probably a notes/
    # all-caps document, not a script (scripts need mixed-case dialog).
    all_caps_count = sum(1 for s in content_lines if not re.search(r"[a-z]", s))
    if all_caps_count / total > 0.65:
        return None

    # Score: standalone all-caps lines immediately followed by mixed-case text
    cue_score = 0
    colon_score = 0
    for i, s in enumerate(content_lines):
        # Colon-cue detection: line ends with ALLCAPS: or starts with ALLCAPS:
        if re.search(r"(?:^|(?<=\s))([A-Z][A-Z\s\.\']{1,30}):\s*$", s):
            colon_score += 1
        elif re.match(r"^([A-Z][A-Z\s\.\']{1,30}):\s+\S", s):
            colon_score += 1

        # Play cue detection: standalone all-caps line → mixed-case next line
        if _is_caps_cue_candidate(s):
            for j in range(i + 1, min(i + 4, total)):
                nxt = content_lines[j]
                if nxt:
                    if re.search(r"[a-z]", nxt) and len(nxt) >= 3:
                        cue_score += 1
                    break

    cue_ratio = cue_score / total
    colon_ratio = colon_score / total

    # colon_play needs a clear colon-cue signal AND play cues must be weak
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

    # Always noise: bare numbers (page numbers), dates, single chars, revision marks
    for s in stripped:
        if re.fullmatch(r"\d+", s):
            noise.add(s)
        elif re.fullmatch(r"\d{2,}\.", s):  # "186." style page numbers
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
        groups = m.groups()  # (scene_N, act_N, dash_N, dot_N, part_N, title_text)
        for g in groups[:5]:
            if g is not None:
                try:
                    return (int(g), (groups[5] or "").strip())
                except ValueError:
                    roman = {"I": 1, "II": 2, "III": 3, "IV": 4, "V": 5,
                             "VI": 6, "VII": 7, "VIII": 8, "IX": 9, "X": 10}
                    return (roman.get(g.upper(), 1), (groups[5] or "").strip())

    # "The First Act" / "Second Act" ordinal format
    m2 = _ORDINAL_ACT_RE.match(s)
    if m2:
        n = _ORDINAL_TO_INT.get(m2.group(1).upper(), 1)
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
) -> Script:
    """Parse a standard play (speaker name on own line, dialog below)."""
    script = Script(title=title)
    noise = _collect_page_noise(plain_lines, page_sets)

    script.characters = _extract_cast(plain_lines)
    known_speakers = {c.name for c in script.characters}

    script.scenes = _extract_scenes_play(plain_lines, known_speakers, noise)

    _apply_speaker_normalization(script, known_speakers)
    _discover_new_characters(script, known_speakers)
    return script


def _extract_scenes_play(
    lines: List[str], known_speakers: Set[str], noise: Set[str]
) -> List[Scene]:
    scenes: List[Scene] = []
    scene_counter = 0
    scene_title = ""
    elements: List[Element] = []
    current_speaker: Optional[str] = None
    dialog_buf: List[str] = []

    def flush_dialog() -> None:
        nonlocal current_speaker, dialog_buf
        if current_speaker and dialog_buf:
            text = _normalize_text(" ".join(dialog_buf))
            if text:
                elements.append(Element(kind="dialog", speaker=current_speaker, text=text))
            current_speaker = None  # Clear after emitting so flush_orphan_speaker doesn't double-emit
        dialog_buf.clear()

    def flush_orphan_speaker() -> None:
        """Speaker set but no dialog arrived — emit as stage direction."""
        nonlocal current_speaker
        if current_speaker and not dialog_buf:
            elements.append(Element(kind="stage_direction", text=current_speaker))
        current_speaker = None

    def commit_scene(is_final: bool = False) -> None:
        nonlocal scene_counter, scene_title, elements
        flush_dialog()
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

    for raw in lines:
        s = raw.strip()
        if not s:
            flush_dialog()
            current_speaker = None
            continue

        if s in noise:
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

            flush_dialog()
            flush_orphan_speaker()
            current_speaker = normalized
            prev_nonempty = s
            continue

        # Standalone parenthetical with pending speaker
        if (
            current_speaker
            and s.startswith("(")
            and s.endswith(")")
            and len(s) < 150
        ):
            flush_dialog()
            inner = s[1:-1].strip()
            elements.append(
                Element(kind="parenthetical", speaker=current_speaker, text=inner)
            )
            prev_nonempty = s
            continue

        # Dialog content
        if current_speaker:
            dialog_buf.append(s)
            prev_nonempty = s
            continue

        # Stage direction (no speaker set)
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
) -> Script:
    """Parse a colon-cue format script (SPEAKER: dialog text)."""
    script = Script(title=title)
    noise = _collect_page_noise(plain_lines, page_sets)

    script.characters = _extract_cast_colon(plain_lines)
    known_speakers = {c.name for c in script.characters}

    script.scenes = _extract_scenes_colon(plain_lines, known_speakers, noise)

    _apply_speaker_normalization(script, known_speakers)
    _discover_new_characters(script, known_speakers)
    return script


def _extract_cast_colon(lines: List[str]) -> List[Character]:
    """Find CHARACTERS / CAST section in colon-cue format scripts."""
    return _extract_cast(lines)


def _extract_scenes_colon(
    lines: List[str], known_speakers: Set[str], noise: Set[str]
) -> List[Scene]:
    scenes: List[Scene] = []
    scene_counter = 0
    scene_title = ""
    elements: List[Element] = []
    current_speaker: Optional[str] = None
    dialog_buf: List[str] = []

    def flush_dialog() -> None:
        nonlocal current_speaker, dialog_buf
        if current_speaker and dialog_buf:
            text = _normalize_text(" ".join(dialog_buf))
            if text:
                elements.append(Element(kind="dialog", speaker=current_speaker, text=text))
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
            flush_dialog()
            current_speaker = speaker

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
            flush_dialog()
            inner = s[1:-1].strip()
            elements.append(
                Element(kind="parenthetical", speaker=current_speaker, text=inner)
            )
            continue

        # Dialog continuation
        if current_speaker:
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


def _detect_script_format(lines: List[str]) -> str:
    """Return 'dash_dialog', 'heist', or 'scene_n'."""
    heist_count = sum(1 for l in lines if _is_heist_scene_header(l))
    scene_n_count = sum(1 for l in lines if SCENE_NUM_RE.match(l.strip()))
    int_ext_count = sum(1 for l in lines if INT_EXT_RE.match(l.strip()))
    dash_count = sum(1 for l in lines if _is_dash_dialog_line(l))
    non_empty = sum(1 for l in lines if l.strip())

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
                or _parse_cast_row_v2(s) or _parse_cast_row_comma(s))
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
        and elements[-1].text[-1] not in ".!?…\""
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
        clean.append(raw.rstrip())

    i = 0
    n = len(clean)
    pending_speaker: Optional[str] = None
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
        nonlocal dialog_buf, pending_speaker, pending_parenthetical
        had_dialog = bool(dialog_buf)
        if pending_speaker and (had_dialog or pending_parenthetical):
            if pending_parenthetical:
                elements.append(
                    Element(kind="parenthetical", speaker=pending_speaker,
                            text=pending_parenthetical)
                )
                pending_parenthetical = None
            if had_dialog:
                text = _normalize_text(" ".join(dialog_buf))
                if text:
                    elements.append(
                        Element(kind="dialog", speaker=pending_speaker, text=text)
                    )
                dialog_buf.clear()
                pending_speaker = None
        elif force:
            dialog_buf.clear()
            pending_speaker = None
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
                        Element(kind="dialog", speaker=pending_speaker, text=text)
                    )
                dialog_buf.clear()
                elements.append(
                    Element(kind="parenthetical", speaker=pending_speaker, text=inner)
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
                        Element(kind="dialog", speaker=pending_speaker, text=text)
                    )
                dialog_buf.clear()
                elements.append(
                    Element(kind="parenthetical", speaker=pending_speaker, text=inner)
                )
            else:
                pending_parenthetical = inner
            i = j
            continue

        if pending_speaker and d_min <= indent <= d_max:
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


def _looks_like_chorus(name: str) -> bool:
    return "/" in name


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
