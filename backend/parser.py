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

Supports two common script formats:

  HEIST-style  — Scene headers are numbered: "1  SCENE NAME" at low indent.
                 Character cues at wide indent (~col 35). Dialog at ~col 12.

  Standard-style — "SCENE N" lines at high/centered indent, followed by
                   "INT./EXT. LOCATION" lines at low indent. Character cues
                   centered (~col 30). Dialog at ~col 17.

Both formats are auto-detected. Indent zones (dialog / cue / stage-direction)
are calibrated from the document itself so that scripts with different margins
or typefaces parse correctly without manual tuning.

PDF font artifacts (some exporters double every character, e.g. "VVIINNNNYY")
are transparently normalized before parsing.
"""

from __future__ import annotations

import re
from collections import Counter
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple

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


# Regex helpers
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
# Doubled-character normalization
# ---------------------------------------------------------------------------


def _undouble(line: str) -> str:
    """Remove doubled-character artifacts from PDF font rendering.

    Some PDF exporters render each glyph twice, producing text like
    "VVIINNNNYY ((CCOONNTT''DD))" instead of "VINNY (CONT'D)".

    IMPORTANT: Leading whitespace (indentation) is preserved unchanged —
    only the visible content is normalized. This keeps indent values
    meaningful for zone calibration even when content is doubled.
    """
    stripped = line.lstrip(" ")
    if not stripped:
        return line
    leading = line[: len(line) - len(stripped)]
    return leading + _undouble_content(stripped)


def _undouble_content(s: str) -> str:
    """Normalize doubled characters in a string that contains no leading spaces."""
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
    # De-duplicate
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
# Indent-zone auto-calibration
# ---------------------------------------------------------------------------


def _detect_indent_zones(lines: List[str]) -> Dict[str, int]:
    """Analyse a script's indentation distribution to calibrate zone thresholds.

    Returns a dict of override values, or {} if calibration is inconclusive.
    The caller merges these over the module-level defaults.
    """
    cue_indents: List[int] = []
    lower_indents: List[int] = []

    for raw in lines:
        s = raw.strip()
        if not s or len(s) < 3:
            continue
        indent = len(raw) - len(raw.lstrip(" "))
        # Skip lines that are just whitespace padding (pdfplumber fills blank
        # lines to page width with spaces)
        if indent > 70:
            continue
        # Skip lines that are purely numeric (page numbers)
        if re.fullmatch(r"[\d\.\s]+", s):
            continue

        # Strip trailing parenthetical voice markers for cue detection
        base = re.sub(r"\s*\([^)]*\)\s*$", "", s).strip()
        # All-caps token of name-ish length, no terminal period → likely a cue
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

    dialog_mode = Counter(below_cue).most_common(1)[0][0]

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
    """Merge calibration overrides with module-level defaults."""
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


def extract_layout_lines(pdf_path: str) -> List[str]:
    """Return the script as a list of layout-preserving lines, with doubled-
    character artifacts normalized."""
    out: List[str] = []
    with pdfplumber.open(pdf_path) as pdf:
        for page in pdf.pages:
            text = page.extract_text(layout=True, x_tolerance=2) or ""
            for line in text.split("\n"):
                out.append(_undouble(line))
    return out


def parse_pdf(pdf_path: str) -> Script:
    """Parse a PDF script into a Script object."""
    lines = extract_layout_lines(pdf_path)
    return parse_lines(lines, title=_derive_title(pdf_path))


def parse_lines(lines: List[str], title: str = "Script") -> Script:
    script = Script(title=title)

    # Auto-calibrate indent zones for this document
    overrides = _detect_indent_zones(lines)
    zones = _make_zones(overrides)

    # Detect which scene-boundary format the script uses
    fmt = _detect_script_format(lines)

    # Extract cast list
    script.characters = _extract_cast(lines)
    known_speaker_set = {c.name for c in script.characters}

    # Extract scenes
    script.scenes = _extract_scenes(lines, known_speaker_set, zones, fmt)

    # Pass 1: Fuzzy-normalize against known cast members (edit dist ≤ 2).
    # Handles partial undoubling of names that have consecutive repeated
    # letters (VINY→VINNY, JES→JESS, etc.) when those names ARE in the cast.
    if known_speaker_set:
        for sc in script.scenes:
            for el in sc.elements:
                if el.speaker and el.speaker not in known_speaker_set:
                    matched = _closest_known_speaker(el.speaker, known_speaker_set)
                    if matched != el.speaker:
                        el.speaker = matched

    # Pass 2: Cross-normalize among all discovered speakers.
    # Handles supporting characters not listed in the cast (SCOT→SCOTT, etc.)
    # by preferring whichever variant has more dialog lines.
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
            # Don't fuzzy-merge very short names — "1" and "2" are distinct speakers
            if len(name) < 3 or len(other) < 3:
                continue
            if _levenshtein(name, other) <= 2:
                other_count = speaker_counts.get(other, 0)
                # Resolution order:
                # 1. Prefer known cast names
                # 2. Prefer the longer name (truncated renderings are shorter)
                # 3. Prefer the one with more dialog
                if other in known_speaker_set:
                    alias_map[name] = other
                elif name in known_speaker_set:
                    alias_map[other] = name
                elif len(other) > len(name):
                    alias_map[name] = other  # other is longer → keep other
                elif len(name) > len(other):
                    alias_map[other] = name  # name is longer → keep name
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

    # Append any character names discovered during scene parsing that are
    # genuinely new (not resolved by either normalization pass).
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
# Script format detection
# ---------------------------------------------------------------------------


def _detect_script_format(lines: List[str]) -> str:
    """Return 'dash_dialog', 'heist', or 'scene_n'."""
    heist_count = sum(1 for l in lines if _is_heist_scene_header(l))
    scene_n_count = sum(1 for l in lines if SCENE_NUM_RE.match(l.strip()))
    int_ext_count = sum(1 for l in lines if INT_EXT_RE.match(l.strip()))
    dash_count = sum(1 for l in lines if _is_dash_dialog_line(l))
    non_empty = sum(1 for l in lines if l.strip())

    # Dash-dialog: many inline SPEAKER – text lines, outnumbering any indent cues
    if dash_count >= 15 and non_empty > 0 and dash_count / non_empty > 0.20:
        if dash_count > heist_count * 3:  # confident it's not just decoration
            return "dash_dialog"

    if heist_count >= 2:
        return "heist"
    if scene_n_count >= 1 or int_ext_count >= 2:
        return "scene_n"
    return "heist"  # Default fallback


def _is_dash_dialog_line(raw: str) -> bool:
    """True for lines in 'SPEAKER – dialog' format (uppercase/digit speaker only)."""
    s = raw.strip()
    m = _DASH_DIALOG_LINE_RE.match(s)
    if not m:
        return False
    token = m.group(1).strip()
    # Speaker token must be purely uppercase/digits — lowercase = stage direction
    return not re.search(r"[a-z]", token) and len(token) <= 25


# ---------------------------------------------------------------------------
# Cast extraction
# ---------------------------------------------------------------------------


def _extract_cast(lines: List[str]) -> List[Character]:
    """Find the CAST section and parse each character row.

    Supports two formats:

      HEIST-style:
        CAST
        MARVIN       The Boss       40   Male

      Standard-style:
        CAST OF CHARACTERS
        Eric:  19, A smart, anxious kid...
        Jess:  18, Magnetic, volatile...
    """
    cast: List[Character] = []
    cast_idx = None
    for i, raw in enumerate(lines):
        s = raw.strip().upper()
        if s in ("CAST", "CHARACTERS", "CAST OF CHARACTERS", "DRAMATIS PERSONAE"):
            cast_idx = i
            break
    if cast_idx is None:
        return cast

    blanks_in_a_row = 0
    for raw in lines[cast_idx + 1 :]:
        s = raw.strip()
        if not s:
            blanks_in_a_row += 1
            if blanks_in_a_row >= 2:
                break
            continue
        blanks_in_a_row = 0

        if SCENE_HEADER_RE.match(raw) or SCENE_NUM_RE.match(s) or INT_EXT_RE.match(s):
            break
        su = s.upper()
        if su.startswith("AUTHOR") or su.startswith("NOTES") or su.startswith("SETTING"):
            break

        # Try both cast row formats
        char = _parse_cast_row(s) or _parse_cast_row_v2(s)
        if char:
            cast.append(char)
        # Don't break on unrecognized rows — cast lists often have section
        # headings like "Supporting-" interspersed; just skip them.

    return cast


def _parse_cast_row(s: str) -> Optional[Character]:
    """HEIST-style: 'MARVIN   The Boss   40   Male' (all-caps name first)."""
    parts = [p for p in re.split(r"\s{2,}", s) if p]
    if not parts:
        return None
    name_raw = parts[0]
    if re.search(r"[a-z]", name_raw):
        return None
    if not re.search(r"[A-Z]", name_raw) or len(name_raw) > 30:
        return None

    role = parts[1] if len(parts) > 1 else None
    age = None
    gender = None
    for tail in parts[2:]:
        if re.fullmatch(r"\d{1,3}\+?", tail):
            age = tail
        elif tail.lower().startswith(("male", "female", "non-binary", "nonbinary", "nb")):
            t = tail.strip().lower()
            gender = "F" if t.startswith("female") else ("M" if t.startswith("male") else "X")
    return Character(name=name_raw, gender_hint=gender, role_hint=role, age_hint=age)


def _parse_cast_row_v2(s: str) -> Optional[Character]:
    """Standard-style: 'Eric:  19, A smart, anxious kid who...'

    Name is mixed-case followed by colon. We up-case it to match script cues.
    Gender is inferred from pronouns in the description.
    """
    m = re.match(
        r"^([A-Z][A-Za-z]+(?:\s+[A-Z][A-Za-z]+)?)\s*:\s*(\d{1,3})?\s*[,]?\s*(.*)",
        s,
    )
    if not m:
        return None
    name = m.group(1).upper()
    # Reject obvious non-names (section headings, etc.)
    if name in ("SETTING", "SETTINGS", "MAIN", "SUPPORTING", "PRODUCTION", "NOTE"):
        return None
    age = m.group(2)
    description = m.group(3) or ""

    desc_lower = description.lower()
    she = len(re.findall(r"\bshe\b|\bher\b|\bhers\b|\bherself\b", desc_lower))
    he = len(re.findall(r"\bhe\b|\bhis\b|\bhim\b|\bhimself\b", desc_lower))
    gender: Optional[str] = None
    if she > he:
        gender = "F"
    elif he > she:
        gender = "M"

    return Character(name=name, gender_hint=gender, age_hint=age)


# ---------------------------------------------------------------------------
# Scene extraction — format router
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
# HEIST-style scene extraction (numbered headers: "1  SCENE NAME")
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
        scene_lines = lines[start + 1 : end]
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
    """Handle scripts that use 'SCENE N' headers (optionally preceded by
    'ACT N') and 'INT./EXT. LOCATION' lines for titles."""
    boundaries: List[Tuple[int, int, str]] = []
    scene_counter = 0          # Global counter for uniqueness across acts
    last_was_scene_n = False    # True immediately after a SCENE N line

    for i, raw in enumerate(lines):
        s = raw.strip()

        # Skip ACT / END OF ACT markers (cosmetic only)
        if ACT_RE.match(s):
            continue

        # SCENE N header
        m = SCENE_NUM_RE.match(s)
        if m:
            scene_counter += 1
            num_label = m.group("num")
            boundaries.append((i, scene_counter, f"Scene {num_label}"))
            last_was_scene_n = True
            continue

        # INT./EXT. location line
        m2 = INT_EXT_RE.match(s)
        if m2:
            loc = _clean_title(m2.group("loc"))
            if last_was_scene_n and boundaries:
                # Update the pending SCENE N boundary's title with this location
                idx, num, _ = boundaries[-1]
                boundaries[-1] = (idx, num, loc)
            else:
                # Standalone location change mid-scene — start a new sub-scene
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
        scene_lines = lines[start + 1 : end]
        sc = Scene(number=num, title=title)
        sc.elements = _parse_scene_body(scene_lines, known_speakers, zones)
        scenes.append(sc)
    return scenes


# ---------------------------------------------------------------------------
# Dash-dialog format (e.g. Cyrano: "SPEAKER – text" inline, "N." scene markers)
# ---------------------------------------------------------------------------


def _extract_scenes_dash_dialog(lines: List[str]) -> List[Scene]:
    """Scene boundaries are bare 'N.' lines (e.g. '2.' alone at low indent).

    Everything between two boundaries is parsed as dash-dialog body.
    Falls back to a single scene if no markers are found.
    """
    boundaries: List[Tuple[int, int, str]] = []
    last_num = 0
    for i, raw in enumerate(lines):
        s = raw.strip()
        m = _SCENE_NUM_DOT_RE.match(s)
        if m:
            indent = len(raw) - len(raw.lstrip())
            if indent < 30:  # not a right-margin page number
                num = int(m.group(1))
                # If numbering resets (e.g. Act 2 restarts at 1), continue from where we left off
                if num <= last_num:
                    num = last_num + 1
                last_num = num
                boundaries.append((i, num, f"Scene {num}"))

    if not boundaries:
        boundaries = [(0, 1, "Script")]

    boundaries.append((len(lines), -1, ""))

    scenes: List[Scene] = []
    for (start, num, title), (end, _, _) in zip(boundaries, boundaries[1:]):
        scene_lines = lines[start + 1 : end]
        sc = Scene(number=num, title=title)
        sc.elements = _parse_scene_body_dash_dialog(scene_lines)
        scenes.append(sc)
    return scenes


def _parse_scene_body_dash_dialog(lines: List[str]) -> List[Element]:
    """Parse one scene's lines in dash-dialog format.

    Recognised patterns:
      SPEAKER – text                     → dialog
      SPEAKER – (direction) text         → parenthetical + dialog
      SPEAKER – (direction)              → parenthetical only
      anything else                      → stage direction
      indented continuation of previous  → appended to prior dialog
    """
    elements: List[Element] = []

    # Determine the modal (base) indent so we can spot continuation lines
    indents = [
        len(r) - len(r.lstrip())
        for r in lines if r.strip()
    ]
    base_indent = Counter(indents).most_common(1)[0][0] if indents else 0

    prev_dialog: Optional[Element] = None

    for raw in lines:
        s = raw.strip()
        if not s:
            prev_dialog = None
            continue

        indent = len(raw) - len(raw.lstrip())

        # Continuation: deeper indent than the base, and there's an open dialog
        if prev_dialog is not None and indent > base_indent + 2:
            prev_dialog.text = _normalize_text(prev_dialog.text + " " + s)
            continue
        prev_dialog = None

        # Try dash-dialog match
        m = _DASH_DIALOG_LINE_RE.match(s)
        if m:
            token = m.group(1).strip()
            # Reject if token contains lowercase — it's a stage direction
            # e.g. "a silence – they look at each other"
            if re.search(r"[a-z]", token):
                _append_stage_direction(elements, _normalize_text(s))
                continue

            speaker = _normalize_dash_speaker(token)
            rest = m.group(2).strip()

            # Split off a leading parenthetical: "(direction) remaining text"
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

        # Everything else is a stage direction
        _append_stage_direction(elements, _normalize_text(s))

    return elements


def _append_stage_direction(elements: List[Element], text: str) -> None:
    """Append a stage direction, merging with the previous one if it was mid-sentence."""
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
    """Normalise speaker token: collapse whitespace around / and &."""
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
    return True


def _clean_title(title: str) -> str:
    title = title.strip().rstrip(".")
    title = re.sub(r"\s+", " ", title)
    return title


# ---------------------------------------------------------------------------
# Scene body parser
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

    # Pre-clean: drop page footers, page-break markers, and page headers
    clean: List[str] = []
    for raw in lines:
        if "\x0c" in raw:
            raw = raw.replace("\x0c", "")
        if not raw.strip():
            clean.append("")
            continue
        s = raw.strip()
        # Standard page footer: "44." or "44.."
        if PAGE_FOOTER_RE.match(s):
            continue
        indent = len(raw) - len(raw.lstrip(" "))
        # Right-aligned page number (deep indent + just digits)
        if indent >= pn_min and re.fullmatch(r"\s*\d+\.?\.?\s*", raw):
            continue
        # Page header with script title and page number: e.g. "Fluorescent"   3.
        # Appears after de-doubling as quoted-text + number at low indent
        if re.search(r'["“”].+["“”].*\d+\.?\s*$', s) and indent < 25:
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

        # --- Parenthetical ---
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

        # --- Multi-line parenthetical (opening paren, no closing) ---
        # e.g. "(Meets his gaze, a quiet challenge in his" ... "voice)"
        if (
            pending_speaker
            and s.startswith("(")
            and not s.endswith(")")
            and p_min <= indent <= p_max + 8
        ):
            # Collect until we see the closing paren
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

        # --- Dialog continuation ---
        if pending_speaker and d_min <= indent <= d_max:
            dialog_buf.append(s)
            i += 1
            continue

        # --- Flush if something else arrived while speaker is pending ---
        if pending_speaker:
            flush_dialog(force=True)

        # --- Character cue OR stage direction at cue indent ---
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

        # --- Page-break dialog continuation ---
        # A dialog-indented line with no pending speaker, right after a dialog
        # element — this happens when a character's speech spans a page break.
        if (
            d_min <= indent <= d_max
            and elements
            and elements[-1].kind == "dialog"
        ):
            prev = elements[-1]
            prev.text = _normalize_text(prev.text + " " + s)
            i += 1
            continue

        # --- Anything else → stage direction ---
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
    """Strip voice markers (V.O., O.S.) and CONT'D from a character cue."""
    # Remove CONT'D / CONTD markers first
    s = CONTD_RE.sub("", s)
    # Remove other parenthetical markers like (V.O.) (O.S.)
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
    """Simple Levenshtein distance. Returns 99 if strings differ by more than 3."""
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
    """Return the closest known speaker, or the original name if no match within max_dist."""
    if name in known_speakers:
        return name
    best, best_dist = name, max_dist + 1
    for k in known_speakers:
        d = _levenshtein(name, k)
        if d < best_dist:
            best, best_dist = k, d
    return best


def _derive_title(pdf_path: str) -> str:
    """Try to extract a human-readable title from the first page; fall back to filename."""
    import os
    filename = os.path.splitext(os.path.basename(pdf_path))[0]
    try:
        with pdfplumber.open(pdf_path) as pdf:
            if not pdf.pages:
                return filename
            text = pdf.pages[0].extract_text() or ""
            # First non-empty line of the first page is usually the title
            for line in text.split("\n"):
                candidate = line.strip()
                # Must be at least 3 chars, not a URL, not a date-ish string
                if (
                    len(candidate) >= 3
                    and not re.search(r"https?://|@|\d{4}|draft|revision", candidate, re.I)
                    and not re.fullmatch(r"[\d\s\.]+", candidate)
                ):
                    # Truncate very long first lines (they're probably not titles)
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
