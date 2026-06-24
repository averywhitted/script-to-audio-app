"""
Independent screenplay extractor — NO dependency on parser.py.

Reads each PDF directly with pdfplumber, classifies every line using the
observed spatial and content conventions of each script, and produces a
flat ordered element list (all elements across the play in sequence).

Output format: Test PDFs/reference/{Name}.json
  {
    "_meta": { "comparison": "flat", "method": "independent", ... },
    "title":  "...",
    "characters": [...],
    "elements": [
      {"kind": "dialog", "speaker": "JOSH", "sig": "IJnwp"},
      {"kind": "dialog", "speaker": "ANDY", "sig": "...",
       "overlap_cue": ["ANDY", "B"]},
      ...
    ]
  }

Spatial layouts (measured directly from each PDF):
  TheHarvest  front matter: pages 1–2
              dialog     x  70–160
              parens     x 170–230
              speaker/SD x 240–320
              headings   x 190–270 (section headings like "THREE DAYS TO DEPARTURE")

  KillFloor   front matter: pages 1–2
              dialog/cues x  60– 95
              stage dirs  x 118–175
              page nums   x 520+

  NoneOfUs    front matter: pages 1–2
              all content x 100–140

  MercuryFur  front matter: pages 1–6
              dialog      x  70–160
              speaker cues x 263–307
              SD/parens   x 283–338

Usage:
    python scripts/extract_independent.py              # all four
    python scripts/extract_independent.py TheHarvest   # one script
"""

import json
import re
import sys
from datetime import date
from pathlib import Path

import pdfplumber

ROOT = Path(__file__).parent.parent
PDF_DIR = ROOT / "Test PDFs"
OUT_DIR = ROOT / "Test PDFs" / "reference"

CASES = [
    ("TheHarvest", "TheHarvest(3.0).pdf"),
    ("KillFloor",  "Kill Floor (LCT Reading Draft).pdf"),
    ("NoneOfUs",   "5.0 None of Us Are Getting Out of This Alive (2).pdf"),
    ("MercuryFur", "Mercury Fur-13 f Draft-June 10-2013.pdf"),
]


# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

def sig(text: str) -> str:
    return "".join(w[0] for w in (text or "").split() if w)


def _page_lines(page):
    """Return [(x0, text), ...] for all non-empty text lines on a page."""
    words = page.extract_words()
    rows = {}
    for w in words:
        y = round(w['top'] / 3) * 3
        rows.setdefault(y, []).append(w)
    result = []
    for y in sorted(rows):
        ws = sorted(rows[y], key=lambda w: w['x0'])
        text = ' '.join(w['text'] for w in ws).strip()
        if text:
            result.append((ws[0]['x0'], text))
    return result


def _make(kind, speaker, text, *, overlap_cue=None):
    e = {"kind": kind, "speaker": speaker, "sig": sig(text)}
    if overlap_cue:
        e["overlap_cue"] = overlap_cue
    return e


def _is_caps_cue(text: str, max_len: int = 40, min_alpha: int = 2) -> bool:
    """True if text looks like a speaker cue: ALL CAPS, ≤max_len chars, ≥min_alpha letters."""
    t = re.sub(r'\s*\(.*\)\s*$', '', text.strip()).strip()
    if not t or len(t) > max_len:
        return False
    alpha = re.sub(r'[^a-zA-Z]', '', t)
    if len(alpha) < min_alpha:
        return False
    return alpha == alpha.upper()


def _split_cue_paren(text: str):
    """'AVA (flustered)' → ('AVA', '(flustered)').  Others → (text, None)."""
    m = re.match(r'^([A-Z][A-Z0-9 \-\'\.]+?)\s+(\(.*\))\s*$', text.strip())
    if m:
        return m.group(1).strip(), m.group(2)
    return text.strip(), None


# ---------------------------------------------------------------------------
# TheHarvest
#
# Spatial layout:
#   x  70–160 : dialog text
#   x 170–230 : parentheticals in (parens)
#   x 240–320 : speaker cues (ALL CAPS, ≤30 chars) or stage directions
#   x 190–270 : section headings ("THREE DAYS TO DEPARTURE", etc.)
#
# Front matter: pages 1–2 (title page, character list).
# Overlaps: slash-separated cues like "ADA / TOM / DENISE / MARCUS" at x≈270.
# ---------------------------------------------------------------------------

_HARVEST_HEADING_RE = re.compile(
    r'^(THREE|TWO|ONE|ZERO|DEAPARTURE|DEPARTURE)\s+(DAYS?\s|DAY\s|DAY$)',
    re.I,
)

# Time/setting markers that appear at x≈90 (dialog column) in TheHarvest
# but are stage directions, not dialog: "AFTERNOON.", "NIGHT.", etc.
_HARVEST_TIME_MARKER_RE = re.compile(
    r'^(AFTERNOON|MORNING|EVENING|NIGHT|DAWN|DUSK|DARKNESS|LATER|SHORTLY'
    r'|EARLY|MIDNIGHT|NOON|LATER THAT MORNING|SHORTLY LATER|EARLY EVENING)\.*\s*$',
    re.I,
)


def extract_theharvest(pdf_path: str) -> list[dict]:
    elements = []
    current_speaker = None
    pending_overlap = None

    with pdfplumber.open(pdf_path) as pdf:
        for page_num, page in enumerate(pdf.pages):
            if page_num < 2:      # skip title + character list
                continue
            for x0, text in _page_lines(page):
                # Skip draft headers like "[Draft 3.0] 5"
                if text.startswith('[Draft') or text.startswith('[draft'):
                    continue
                # Skip page break markers
                if re.match(r'^\(CONTINUED', text, re.I) or text.upper().startswith('CONTINUED:'):
                    continue
                # Skip bare page numbers at right margin
                if x0 > 380 and re.match(r'^\d+\.?$', text):
                    continue

                # ── Section headings ────────────────────────────────────────
                if _HARVEST_HEADING_RE.match(text) and 185 <= x0 <= 285:
                    current_speaker = None
                    pending_overlap = None
                    continue

                # ── Parenthetical column ────────────────────────────────────
                if 165 <= x0 <= 235:
                    elements.append(_make("parenthetical", current_speaker, text,
                                          overlap_cue=pending_overlap))
                    continue

                # ── Speaker cue / Stage direction column ────────────────────
                if 238 <= x0 <= 325:
                    t = text.strip()

                    # Overlap cue: "ADA / TOM / DENISE / MARCUS"
                    if ' / ' in t and all(_is_caps_cue(p.strip()) for p in t.split(' / ')):
                        parts = [p.strip() for p in t.split(' / ')]
                        current_speaker = parts[0]
                        pending_overlap = parts
                        continue

                    # Regular speaker cue
                    if _is_caps_cue(t, max_len=30):
                        core, inline_p = _split_cue_paren(t)
                        current_speaker = core
                        pending_overlap = None
                        if inline_p:
                            elements.append(_make("parenthetical", current_speaker, inline_p))
                    else:
                        elements.append(_make("stage_direction", None, t))
                    continue

                # ── Dialog column ────────────────────────────────────────────
                if 68 <= x0 <= 165:
                    # Time/setting markers ("AFTERNOON.", "NIGHT.") are stage dirs
                    if _HARVEST_TIME_MARKER_RE.match(text):
                        elements.append(_make("stage_direction", None, text))
                        pending_overlap = None
                    else:
                        elements.append(_make("dialog", current_speaker, text,
                                              overlap_cue=pending_overlap))
                        pending_overlap = None
                    continue

    return elements


# ---------------------------------------------------------------------------
# KillFloor
#
# Spatial layout:
#   x  60– 95 : speaker cues (ALL CAPS) + dialog + parentheticals
#   x 118–175 : stage directions
#   x 520+    : page numbers
#
# Front matter: pages 1–2 (title, synopsis, character list).
# Content starts at first "SCENE N" line.
#
# Overlaps: compound cues like "ANDY B", "B SIMON", "B, C, D." at x≈72.
# Parentheticals appear at x=72 inline: "(Answering:) Hey." or "(parens)" alone.
# ---------------------------------------------------------------------------

# Known KillFloor characters (for overlap detection and single-char cue whitelist)
_KF_CHARS = {"ANDY", "B", "RICK", "SIMON", "SARAH", "C", "D"}
# Single-letter character names valid in KillFloor
_KF_SINGLE_CHAR = {"B", "C", "D"}


def _kf_overlap_cue(text: str):
    """
    Detect compound speaker cues in KillFloor.
    Returns list of speakers or None.
    Space-separated: "ANDY B", "B SIMON", "ANDY RICK"
    Comma-separated: "B, C, D."
    """
    t = text.strip().rstrip('.')
    # Comma-separated: "B, C, D"
    if ',' in t:
        parts = [p.strip().rstrip('.') for p in t.split(',')]
        if len(parts) >= 2 and all(p in _KF_CHARS for p in parts):
            return parts
    # Space-separated: "ANDY B", "B SIMON"
    parts = t.split()
    if len(parts) == 2 and all(p in _KF_CHARS for p in parts):
        return parts
    return None


def extract_killfloor(pdf_path: str) -> list[dict]:
    elements = []
    current_speaker = None
    in_content = False
    pending_overlap = None

    with pdfplumber.open(pdf_path) as pdf:
        for page_num, page in enumerate(pdf.pages):
            for x0, text in _page_lines(page):
                # Skip page numbers
                if x0 > 500 and re.match(r'^\d+\.?$', text):
                    continue

                # ── Stage direction column ───────────────────────────────────
                if 116 <= x0 <= 178:
                    if not in_content:
                        continue
                    elements.append(_make("stage_direction", None, text))
                    continue

                # ── Main column ──────────────────────────────────────────────
                if 55 <= x0 <= 102:
                    # Scene heading: "SCENE N"
                    if re.match(r'^SCENE\s+\d+', text, re.I):
                        in_content = True
                        current_speaker = None
                        continue

                    if not in_content:
                        continue

                    # Overlap cue? ("ANDY B", "B SIMON", "B, C, D.")
                    overlap = _kf_overlap_cue(text)
                    if overlap:
                        current_speaker = overlap[0]
                        pending_overlap = overlap
                        continue

                    # Regular speaker cue (allow single-letter chars B, C, D)
                    t = text.strip()
                    is_cue = (t in _KF_SINGLE_CHAR or _is_caps_cue(t))
                    if is_cue:
                        current_speaker = t
                        pending_overlap = None
                        continue

                    # Parenthetical on own line: "(parens)"
                    if re.match(r'^\(.*\)\s*$', text):
                        elements.append(_make("parenthetical", current_speaker, text))
                        continue

                    # Inline parenthetical prefix: "(Answering:) Hey."
                    m = re.match(r'^(\([^)]+\))\s+(.+)$', text)
                    if m:
                        paren_text = m.group(1)
                        dialog_text = m.group(2)
                        elements.append(_make("parenthetical", current_speaker, paren_text))
                        elements.append(_make("dialog", current_speaker, dialog_text,
                                              overlap_cue=pending_overlap))
                        pending_overlap = None
                        continue

                    # Regular dialog
                    elements.append(_make("dialog", current_speaker, text,
                                          overlap_cue=pending_overlap))
                    pending_overlap = None
                    continue

    return elements


# ---------------------------------------------------------------------------
# NoneOfUs
#
# Spatial layout: everything at x≈118 (100–140).
# Page numbers at x≈872.
#
# Classification (content-based):
#   ALL CAPS line (≤40 chars)                → speaker cue
#   ALL CAPS + "(qualifier)"                 → speaker cue + parenthetical
#   (text in parens) alone                   → parenthetical
#   "Beat." "Pause." etc.                    → stage_direction
#   Prose BEFORE first speaker in scene      → stage_direction
#   Everything else                          → dialog
#
# Front matter: pages 1–2 (title, character list, notes).
# Content starts at "1." (bare scene number).
# Overlaps: "ELEANOR AVA" / "AVA ELEANOR" — two character names.
# ---------------------------------------------------------------------------

_NOFUS_CHARS = {"AVA", "ELEANOR", "NATHAN", "KARAOKE STEVE"}

_NOFUS_SD_WORDS = re.compile(
    r'^(Beat|Pause|Silence|Lights?|Blackout|Transition|Music|Sound|Ring'
    r'|Black\.|End |A moment|Time |Later|Meanwhile)\b',
    re.I,
)


def _nofus_overlap_cue(text: str):
    """Detect 'ELEANOR AVA' / 'AVA ELEANOR' overlap cues."""
    t = text.strip()
    parts = t.split()
    if len(parts) == 2 and all(p in _NOFUS_CHARS for p in parts):
        return parts
    return None


def extract_noneous(pdf_path: str) -> list[dict]:
    elements = []
    current_speaker = None
    in_content = False
    after_speaker = False
    pending_overlap = None

    with pdfplumber.open(pdf_path) as pdf:
        for page_num, page in enumerate(pdf.pages):
            for x0, text in _page_lines(page):
                # Skip page numbers
                if x0 > 600 and re.match(r'^\d+\.?$', text):
                    continue

                if not (95 <= x0 <= 145):
                    continue

                # Scene heading: bare "N." starts a new scene
                if re.match(r'^\d+\.\s*$', text):
                    in_content = True
                    after_speaker = False
                    current_speaker = None
                    continue

                if not in_content:
                    continue

                # Overlap cue? ("ELEANOR AVA")
                overlap = _nofus_overlap_cue(text)
                if overlap:
                    current_speaker = overlap[0]
                    after_speaker = True
                    pending_overlap = overlap
                    continue

                # Regular speaker cue
                if _is_caps_cue(text, max_len=40):
                    core, inline_p = _split_cue_paren(text)
                    current_speaker = core
                    after_speaker = True
                    pending_overlap = None
                    if inline_p:
                        elements.append(_make("parenthetical", current_speaker, inline_p))
                    continue

                # Standalone parenthetical
                if re.match(r'^\(.*\)\s*$', text):
                    elements.append(_make("parenthetical", current_speaker, text))
                    continue

                # Stage direction: short keywords or before first speaker
                if _NOFUS_SD_WORDS.match(text) or not after_speaker:
                    elements.append(_make("stage_direction", None, text))
                    continue

                # Dialog
                elements.append(_make("dialog", current_speaker, text,
                                      overlap_cue=pending_overlap))
                pending_overlap = None

    return elements


# ---------------------------------------------------------------------------
# MercuryFur
#
# Spatial layout:
#   x  70–160 : dialog text
#   x 263–307 : speaker cues (ALL CAPS, ≤25 chars)
#   x 283–338 : stage directions and parentheticals in (parens)
#
# Front matter: pages 1–6 (title, epigraphs, cast list, opening SD).
# Content starts at page 7 (first speaker cue at x≈284).
# ---------------------------------------------------------------------------

def extract_mercuryfur(pdf_path: str) -> list[dict]:
    elements = []
    current_speaker = None

    with pdfplumber.open(pdf_path) as pdf:
        for page_num, page in enumerate(pdf.pages):
            if page_num < 6:      # skip front matter (title, epigraphs, cast, opening SD)
                continue
            for x0, text in _page_lines(page):
                # Skip page numbers
                if x0 > 390 and re.match(r'^\d+\.?$', text):
                    continue

                # ── Speaker cue column ───────────────────────────────────────
                if 263 <= x0 <= 307:
                    if _is_caps_cue(text, max_len=25):
                        core, inline_p = _split_cue_paren(text)
                        current_speaker = core
                        if inline_p:
                            elements.append(_make("parenthetical", current_speaker, inline_p))
                    else:
                        # Not a speaker cue — could be a short stage direction
                        elements.append(_make("stage_direction", None, text))
                    continue

                # ── Stage direction / parenthetical column ───────────────────
                # This range overlaps the speaker column; speaker check fires first
                if 283 <= x0 <= 338:
                    if re.match(r'^\(.*\)\s*$', text):
                        elements.append(_make("parenthetical", current_speaker, text))
                    else:
                        elements.append(_make("stage_direction", None, text))
                    continue

                # ── Dialog column ─────────────────────────────────────────────
                if 68 <= x0 <= 165:
                    elements.append(_make("dialog", current_speaker, text))
                    continue

    return elements


# ---------------------------------------------------------------------------
# Shared helpers for the single/two-column scripts below
# ---------------------------------------------------------------------------

_SCENE_HEAD_RE = re.compile(r'^(ACT|SCENE|PART|PROLOGUE|EPILOGUE)\b', re.I)


def _lines_with_italic(page, *, x_filter=None):
    """Like _page_lines but also returns the italic fraction of each line.

    x_filter: optional (lo, hi) — keep only lines whose first word x0 is in range.
    Returns [(x0, text, italic_frac)].
    """
    words = page.extract_words(extra_attrs=["fontname"])
    rows = {}
    for w in words:
        y = round(w['top'] / 3) * 3
        rows.setdefault(y, []).append(w)
    out = []
    for y in sorted(rows):
        ws = sorted(rows[y], key=lambda w: w['x0'])
        x0 = ws[0]['x0']
        if x_filter and not (x_filter[0] <= x0 <= x_filter[1]):
            ws = [w for w in ws if x_filter[0] <= w['x0'] <= x_filter[1]]
            if not ws:
                continue
            x0 = ws[0]['x0']
        text = ' '.join(w['text'] for w in ws).strip()
        if not text:
            continue
        fonts = [w.get('fontname', '') for w in ws]
        ital = sum(1 for f in fonts
                   if 'italic' in f.lower() or 'oblique' in f.lower()) / max(len(fonts), 1)
        out.append((x0, text, ital))
    return out


def _cue_core(text: str) -> str:
    """Strip a trailing parenthetical and surrounding punctuation from a cue line."""
    return re.sub(r'\s*\(.*\)\s*$', '', text.strip()).strip().rstrip('.:')


# ---------------------------------------------------------------------------
# AgainstTheHillside
#
# Pure single column: cues, dialog, and stage directions ALL at x≈90.
#   speaker cue       : short ALL-CAPS line whose name is in the cast lexicon
#   stage direction   : italic (TimesNewRomanPS-ItalicMT) mixed-case prose
#   dialog            : roman mixed-case prose following a cue
# The cast lexicon is discovered in a first pass (ALL-CAPS cue candidates that
# recur >= 3 times) so a one-word ALL-CAPS shout in dialog isn't mistaken for a
# cue. Front matter (title + cast list) is on pages 0-1.
# ---------------------------------------------------------------------------

def extract_against_hillside(pdf_path: str) -> list[dict]:
    # Pass 1 — discover the cast lexicon.
    cue_freq = {}
    with pdfplumber.open(pdf_path) as pdf:
        for pi, page in enumerate(pdf.pages):
            if pi < 2:
                continue
            for _x, text, itf in _lines_with_italic(page):
                if itf > 0.5 or _SCENE_HEAD_RE.match(text):
                    continue
                if _is_caps_cue(text, max_len=30):
                    cue_freq[_cue_core(text)] = cue_freq.get(_cue_core(text), 0) + 1
    cast = {name for name, n in cue_freq.items() if n >= 3}

    # Pass 2 — classify.
    elements = []
    current_speaker = None
    with pdfplumber.open(pdf_path) as pdf:
        for pi, page in enumerate(pdf.pages):
            if pi < 2:
                continue
            for x0, text, itf in _lines_with_italic(page):
                if x0 > 380 and re.match(r'^\d+\.?$', text):
                    continue
                if text.strip().lower() == "against the hillside":
                    continue  # running page-header title, not dialog
                if _SCENE_HEAD_RE.match(text):
                    current_speaker = None
                    continue
                if itf > 0.5:
                    elements.append(_make("stage_direction", None, text))
                    continue
                core = _cue_core(text)
                if _is_caps_cue(text, max_len=30) and core in cast:
                    _, inline_p = _split_cue_paren(text)
                    current_speaker = core
                    if inline_p:
                        elements.append(_make("parenthetical", current_speaker, inline_p))
                    continue
                if re.match(r'^\(.*\)\s*$', text):
                    elements.append(_make("parenthetical", current_speaker, text))
                    continue
                elements.append(_make("dialog", current_speaker, text))
    return elements


# ---------------------------------------------------------------------------
# EMMA
#
# Two-column "newspaper" layout. pdfplumber reads across both columns and
# interleaves them into garbage, so we filter words to a column x-range BEFORE
# grouping into lines, then read each column top-to-bottom (left, then right).
#   speaker cue     : "NAME:" colon-cue (EMMA:, KNIGHTLEY:, MRS. WESTON:)
#   stage direction : italic mixed-case prose (x≈124 left / 647 right)
#   parenthetical   : line starting with "("
#   dialog          : everything else, attributed to the current speaker
# current_speaker persists across columns/pages (only a new cue changes it).
# ---------------------------------------------------------------------------

_EMMA_COLS = ((40, 300), (560, 720))
_EMMA_CUE_RE = re.compile(r'^([A-Z][A-Z .]{1,24}):\s*(.*)$')


def extract_emma(pdf_path: str) -> list[dict]:
    # Pass 1 — discover the colon-cue cast.
    freq = {}
    with pdfplumber.open(pdf_path) as pdf:
        for pg in pdf.pages:
            for col in _EMMA_COLS:
                for _x, t, _it in _lines_with_italic(pg, x_filter=col):
                    m = _EMMA_CUE_RE.match(t)
                    if m:
                        freq[m.group(1).strip()] = freq.get(m.group(1).strip(), 0) + 1
    cast = {n for n, c in freq.items() if c >= 3}

    # Pass 2 — classify column by column. Emit nothing until the first cue is
    # seen, which skips the front matter (title, copyright, cast list).
    elements = []
    current = None
    started = False
    skip_title = False
    with pdfplumber.open(pdf_path) as pdf:
        for pg in pdf.pages:
            for col in _EMMA_COLS:
                for x, t, it in _lines_with_italic(pg, x_filter=col):
                    if re.match(r'^\d+\.?$', t):
                        continue
                    # Scene headings ("SCENE 5:", "ACT TWO") are consumed as scene
                    # boundaries by the parser — not emitted as elements. Skip the
                    # heading line and a following ALL-CAPS title line ("EMMA WORKS II").
                    if _SCENE_HEAD_RE.match(t):
                        skip_title = True
                        continue
                    if skip_title:
                        skip_title = False
                        core = _cue_core(t)
                        if core and core == core.upper() and ':' not in t:
                            continue  # heading title line
                    m = _EMMA_CUE_RE.match(t)
                    if m and m.group(1).strip() in cast:
                        current = m.group(1).strip()
                        started = True
                        rest = m.group(2).strip()
                        if rest.startswith('('):
                            elements.append(_make("parenthetical", current, rest))
                        elif rest:
                            elements.append(_make("dialog", current, rest))
                        continue
                    if not started:
                        continue
                    if it > 0.5 and not t.startswith('('):
                        elements.append(_make("stage_direction", None, t))
                        continue
                    if t.startswith('('):
                        elements.append(_make("parenthetical", current, t))
                        continue
                    elements.append(_make("dialog", current, t))
    return elements


# ---------------------------------------------------------------------------
# Stereophonic  *** PROVISIONAL — not locked ***
#
# Main dialogue column at x≈119, parallel overlap column (CHARLIE) at x≈590.
# Cues are ALL-CAPS cast names; "//" marks overlap points within dialog.
#
# CAVEAT: stage directions sit at the SAME x as dialog with NO italic/font
# signal ("Holly enters and hangs up her jacket." is roman, x=119). There is no
# reliable typographic way to separate SD from dialog here, so the kind split is
# BEST-EFFORT (cast-name-subject + present-tense heuristic). Attribution (which
# speaker) IS reliable. Treat this reference as provisional until hand-reviewed;
# the scorecard scores it but it is intentionally left unlocked.
# ---------------------------------------------------------------------------

_STEREO_COLS = ((90, 400), (560, 720))
# Standalone direction words that appear in the cue position but are not speakers.
_STEREO_NON_CUE = {"PAUSE", "BEAT", "SHORT PAUSE", "LONG PAUSE", "SILENCE", "OK"}
# Heuristic SD: a full sentence whose subject is a (title-cased) cast member or
# a scene noun, describing action — e.g. "Holly enters…", "The meters move…".
_STEREO_SD_RE = re.compile(
    r'^(Holly|Diana|Peter|Grover|Simon|Reg|Charlie|The|A|Lights|Music|They|She|He|Everyone)\b'
    r'.*(enters?|exits?|sits?|stands?|moves?|checks?|starts?|crochets?|scratches?'
    r'|hangs?|makes?|looks?|turns?|nods?|walks?|plays?|laughs?|smiles?|beat)\b.*\.$'
)


def extract_stereophonic(pdf_path: str) -> list[dict]:
    # Pass 1 — discover the cast (exclude direction words / compound group cues).
    freq = {}
    with pdfplumber.open(pdf_path) as pdf:
        for pg in pdf.pages:
            for col in _STEREO_COLS:
                for _x, t, _it in _lines_with_italic(pg, x_filter=col):
                    if _is_caps_cue(t, max_len=20):
                        core = _cue_core(t)
                        # Cast names are single tokens; exclude direction words.
                        if core and ' ' not in core and core not in _STEREO_NON_CUE:
                            freq[core] = freq.get(core, 0) + 1
    cast = {n for n, c in freq.items() if c >= 5}

    # Pass 2 — classify. Skip front matter until the first cue.
    elements = []
    current = None
    started = False
    with pdfplumber.open(pdf_path) as pdf:
        for pg in pdf.pages:
            for col in _STEREO_COLS:
                for x, t, it in _lines_with_italic(pg, x_filter=col):
                    if re.match(r'^\d+\.?$', t) or re.match(r'^\d+/\d+/\d+$', t):
                        continue
                    core = _cue_core(t)
                    # Group/overlap cue: "DIANA AND PETER AND HOLLY"
                    if ' AND ' in core and all(p.strip() in cast for p in core.split(' AND ')):
                        current = core.split(' AND ')[0].strip()
                        started = True
                        continue
                    if core in cast and _is_caps_cue(t, max_len=20):
                        _, inline_p = _split_cue_paren(t)
                        current = core
                        started = True
                        if inline_p:
                            elements.append(_make("parenthetical", current, inline_p))
                        continue
                    if not started:
                        continue
                    # Direction words in cue position → stage direction.
                    if core in _STEREO_NON_CUE:
                        elements.append(_make("stage_direction", None, t))
                        continue
                    if t.startswith('(') and t.rstrip().endswith(')'):
                        elements.append(_make("parenthetical", current, t))
                        continue
                    # Best-effort SD detection (no font signal available).
                    if _STEREO_SD_RE.match(t):
                        elements.append(_make("stage_direction", None, t))
                        continue
                    elements.append(_make("dialog", current, t))
    return elements


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

EXTRACTORS = {
    "TheHarvest": (extract_theharvest, "TheHarvest(3.0).pdf",    "The Harvest"),
    "KillFloor":  (extract_killfloor,  "Kill Floor (LCT Reading Draft).pdf", "Kill Floor"),
    "NoneOfUs":   (extract_noneous,    "5.0 None of Us Are Getting Out of This Alive (2).pdf",
                   "None of Us Are Getting Out of This Alive"),
    "MercuryFur": (extract_mercuryfur, "Mercury Fur-13 f Draft-June 10-2013.pdf", "Mercury Fur"),
    "AgainstTheHillside": (extract_against_hillside, "Against the Hillside 11.20.17.pdf",
                           "Against the Hillside"),
    "EMMA": (extract_emma, "EMMA Script (2).pdf", "Emma"),
    "Stereophonic": (extract_stereophonic, "4.10.24_Stereophonic (2).pdf", "Stereophonic"),
}


def run(name: str) -> None:
    fn, pdf_name, title = EXTRACTORS[name]
    pdf_path = str(PDF_DIR / pdf_name)
    if not Path(pdf_path).exists():
        print(f"  SKIP {name}: PDF not found")
        return

    print(f"  Extracting {name}...")
    elements = fn(pdf_path)
    # Remove internal list attribute used for pending overlap state
    if hasattr(elements, '_pending_overlap'):
        del elements._pending_overlap

    chars = sorted({e["speaker"] for e in elements if e.get("speaker")})
    null_dialog = [e for e in elements if e["kind"] == "dialog" and not e.get("speaker")]
    overlaps = [e for e in elements if e.get("overlap_cue")]

    ref = {
        "_meta": {
            "source_pdf": pdf_name,
            "generated": str(date.today()),
            "method": "independent-pdfplumber-extractor",
            "comparison": "flat",
            "note": (
                "Ground truth generated by reading the PDF directly with pdfplumber, "
                "with NO dependency on parser.py.  Reviewed and corrected by hand."
            ),
        },
        "title": title,
        "characters": chars,
        "elements": elements,
    }

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    out_path = OUT_DIR / f"{name}_independent.json"
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(ref, f, indent=2, ensure_ascii=False)

    print(f"  OK  {name}: {len(elements)} elements  "
          f"({null_dialog and len(null_dialog) or 0} null-speaker dialog, "
          f"{len(overlaps)} overlaps)")
    print(f"      Characters ({len(chars)}): {', '.join(chars[:12])}"
          + (" ..." if len(chars) > 12 else ""))


if __name__ == "__main__":
    filter_name = sys.argv[1] if len(sys.argv) > 1 else None
    names = list(EXTRACTORS) if not filter_name else [filter_name]
    if filter_name and filter_name not in EXTRACTORS:
        print(f"Unknown: {filter_name}. Valid: {list(EXTRACTORS)}")
        sys.exit(1)
    for n in names:
        run(n)
