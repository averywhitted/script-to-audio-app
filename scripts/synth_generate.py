#!/usr/bin/env python3
"""synth_generate.py — typeset scripts whose correct parse is known exactly.

Every line is placed by this script, so its answer is known by construction:
what kind of element it is, who speaks it, and whether it should be read aloud
at all. That makes these PDFs an answer key with no hand-labelling and no
matching guesswork, in any quantity. `synth_score.py` runs the parser on them.

The layouts copy the families measured in the 13 real test PDFs (Oct 2026):

  screenplay       Courier, sluglines, centred names, (MORE)/(CONT'D)   INATH, Cracked Open
  stage_centered   names centred over full-width dialogue, directions   The Harvest, A Danger,
                   indented and/or in brackets                          Mercury Fur, Napoleon
  stage_left       name on its own line at the margin, dialogue below   Kill Floor, Hillside, None of Us
  inline_paren     "NAME (direction)" on the name line                  Stereophonic
  two_column       landscape page, two text columns, "NAME:" cues       EMMA
  inline_name      "NAME: dialogue" on one line, hanging indent         common format with no
                                                                        real example in the corpus

Each family is generated in several variants (page size, font, italics,
brackets) because those are exactly the things that differ between scripts and
that the parser must not assume. The 1000x1294 pages in the corpus are Letter
scaled by 1.634, so that scale is one of the variants.

The text is generated from templates, not taken from real plays: the parser
reads layout and typography, and generated text keeps the files license-free
while letting us control what matters (very short lines, names in capitals
inside directions, one-line minor characters).

Output, per script, in Test PDFs/synthetic/:
  <name>.pdf          the script
  <name>.truth.json   every unit in reading order: kind, speaker, text, page

Unit kinds: dialog, stage_direction, parenthetical (read aloud) and
character_cue, scene_heading, transition, page_furniture, front_matter (silent).

Usage:
  python scripts/synth_generate.py            # the standard set
  python scripts/synth_generate.py --seed 7   # a different but equally valid set
"""
from __future__ import annotations

import argparse
import json
import random
import sys
from dataclasses import dataclass, field
from pathlib import Path

import fitz  # PyMuPDF

ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = ROOT / "Test PDFs" / "synthetic"

LETTER = (612.0, 792.0)
A4 = (595.0, 842.0)
LANDSCAPE = (792.0, 612.0)

# Base-14 font codes for PyMuPDF: regular, italic, bold.
FONTS = {
    "courier": ("cour", "coit", "cobo"),
    "times": ("tiro", "tiit", "tibo"),
    "helvetica": ("helv", "heit", "hebo"),
}

SILENT_KINDS = {"character_cue", "scene_heading", "transition", "page_furniture", "front_matter"}


# ---------------------------------------------------------------------------
# Text
# ---------------------------------------------------------------------------

NAMES = [
    "MARA", "JOEL", "TESS", "OWEN", "RUTH", "SILAS", "NADIA", "FELIX", "IRIS", "MILO",
    "DR. CHEN", "MRS. HALE", "UNCLE BEN", "KARAOKE STEVE", "JUNE", "THEO", "VERA", "CAL",
]
GENERIC_ROLES = ["VOICE", "MAN", "WOMAN", "WAITER"]
PLACES = ["KITCHEN", "HOSPITAL CORRIDOR", "CAR", "ROOFTOP", "DINER", "MOTEL ROOM", "CHURCH HALL", "BEACH"]
TIMES_OF_DAY = ["DAY", "NIGHT", "MORNING", "LATER", "CONTINUOUS"]

SUBJECTS = ["I", "you", "we", "they", "she", "he", "nobody", "everyone", "your mother", "the landlord"]
VERBS = ["know", "think", "said", "wanted", "need", "remember", "forgot", "heard", "saw", "kept",
         "lost", "found", "promised", "never told", "always hated", "tried to fix", "left"]
OBJECTS = ["the car", "that letter", "the money", "it", "this place", "the truth", "my brother",
           "the keys", "what happened", "the whole thing", "your face", "a reason", "the house"]
TAILS = ["", "", "", " last night", " again", " for years", " before you came", " on purpose",
         " in the end", " the minute I walked in", " and you know it", " without asking"]
SHORT_LINES = ["Yes.", "No.", "What?", "Okay.", "I know.", "Sorry.", "Wait.", "Why?", "Fine.",
               "Really?", "Don't.", "Thank you.", "Hm.", "Go.", "Me?", "Never."]
OPENERS = ["Look,", "Listen.", "Honestly,", "Well,", "I mean,", "Okay, so", "No, no,", "Fine.",
           "You know what?", "Wait,"]

SD_VERBS = ["crosses to the window", "sits", "stands", "picks up the letter", "turns away",
            "looks at the door", "laughs", "pours a drink", "exits", "enters", "freezes",
            "puts down the keys", "stares at the phone", "starts to speak, then stops"]
SD_LONE = ["Pause.", "Beat.", "Silence.", "Lights shift.", "A phone rings offstage.",
           "Blackout.", "A long pause.", "The kettle whistles.", "Rain against the glass."]
SD_SCENE = ["A small kitchen. Morning light. Dishes piled in the sink.",
            "The diner is nearly empty. A radio plays somewhere behind the counter.",
            "Night. The rooftop is lit only by the city below.",
            "A motel room with two unmade beds and a television that does not work."]
PARENS = ["(beat)", "(quietly)", "(laughing)", "(a beat, then)", "(re: the letter)", "(beat; softer)",
          "(not looking up)", "(sarcastic)"]


class TextGen:
    def __init__(self, rng: random.Random):
        self.rng = rng

    def sentence(self) -> str:
        r = self.rng
        s = f"{r.choice(SUBJECTS)} {r.choice(VERBS)} {r.choice(OBJECTS)}{r.choice(TAILS)}"
        s = s[0].upper() + s[1:]
        return s + r.choice([".", ".", ".", "?", "!", "..."])

    def dialog(self, others: list[str]) -> str:
        r = self.rng
        if r.random() < 0.28:
            return r.choice(SHORT_LINES)
        parts = []
        if r.random() < 0.3:
            parts.append(r.choice(OPENERS))
        n = r.choice([1, 1, 2, 2, 3, 4, 6])
        for _ in range(n):
            parts.append(self.sentence())
        if others and r.random() < 0.15:
            parts.append(f"{others[0].split()[-1].title()}?")
        return " ".join(parts)

    def stage_direction(self, cast: list[str]) -> str:
        r = self.rng
        roll = r.random()
        if roll < 0.3:
            return r.choice(SD_LONE)
        a = r.choice(cast)
        if roll < 0.75:
            return f"{a} {r.choice(SD_VERBS)}."
        b = r.choice([c for c in cast if c != a] or [a])
        return f"{a} {r.choice(SD_VERBS)}. {b} {r.choice(SD_VERBS)}, then {r.choice(SD_VERBS)}."

    def paren(self, cast: list[str]) -> str:
        if self.rng.random() < 0.25:
            return f"(to {self.rng.choice(cast)})"
        return self.rng.choice(PARENS)


# ---------------------------------------------------------------------------
# Script content: a list of scenes, each a list of beats
# ---------------------------------------------------------------------------

@dataclass
class Beat:
    kind: str                       # "speech" | "direction"
    speaker: str | None = None
    text: str = ""
    paren: str | None = None        # parenthetical before the speech
    mid_paren: str | None = None    # parenthetical splitting the speech in two
    text2: str = ""                 # speech after mid_paren
    extension: str = ""             # "(V.O.)", "(O.S.)" on the name line


@dataclass
class Content:
    title: str
    cast: list[str]
    scenes: list[tuple[str, list[Beat]]]   # (heading, beats)


def make_content(rng: random.Random, family: str, n_scenes: int) -> Content:
    gen = TextGen(rng)
    cast = rng.sample(NAMES, rng.randint(4, 7))
    minor = rng.choice(GENERIC_ROLES)           # speaks once or twice only
    title = rng.choice(["The Long Way Down", "Small Hours", "Saltwater", "The Lending Library",
                        "Everything Is Fine", "North of Here"])
    scenes = []
    for s in range(n_scenes):
        if family == "screenplay":
            heading = f"{rng.choice(['INT.', 'EXT.'])} {rng.choice(PLACES)} - {rng.choice(TIMES_OF_DAY)}"
        else:
            heading = rng.choice([f"SCENE {s + 1}", f"Scene {s + 1}", f"ACT ONE, SCENE {s + 1}"])
        beats: list[Beat] = []
        if family != "screenplay" or rng.random() < 0.8:
            beats.append(Beat("direction", text=rng.choice(SD_SCENE)))
        on_stage = rng.sample(cast, min(len(cast), rng.randint(2, 4)))
        last = None
        for _ in range(rng.randint(28, 48)):
            if rng.random() < 0.22:
                beats.append(Beat("direction", text=gen.stage_direction(on_stage)))
                last = None
                continue
            # Speakers rarely follow themselves without a direction in between.
            speaker = rng.choice([c for c in on_stage if c != last] or on_stage)
            last = speaker
            if s == 1 and rng.random() < 0.05:
                speaker = minor
            others = [c for c in on_stage if c != speaker]
            b = Beat("speech", speaker=speaker, text=gen.dialog(others))
            if rng.random() < 0.18:
                b.paren = gen.paren(others or cast)
            if rng.random() < 0.08 and len(b.text) > 20:
                b.mid_paren = gen.paren(others or cast)
                b.text2 = gen.dialog(others)
            if family == "screenplay" and rng.random() < 0.08:
                b.extension = rng.choice(["(V.O.)", "(O.S.)"])
            beats.append(b)
        scenes.append((heading, beats))
    return Content(title=title, cast=cast + [minor], scenes=scenes)


# ---------------------------------------------------------------------------
# Typesetting
# ---------------------------------------------------------------------------

@dataclass
class Style:
    family: str
    font: str = "times"
    size: float = 12.0
    page: tuple[float, float] = LETTER
    scale: float = 1.0
    italic_sd: bool = False
    paren_sd: bool = False       # stage directions wrapped in brackets
    # Conventions no part of the parser mentions, for testing whether it learns
    # a script's own style rather than following rules: "bold", "small"
    # (smaller type) or "sans" (a different typeface from the dialogue).
    sd_style: str = ""
    sd_x: float = 0.0            # set per family below
    columns: int = 1


@dataclass
class Layout:
    """Column geometry in unscaled points, relative to the column's left edge."""
    margin_left: float
    width: float
    cue_x: float
    dialog_x: float
    dialog_w: float
    paren_x: float
    sd_x: float
    sd_w: float


class Typesetter:
    def __init__(self, style: Style, content: Content):
        self.st = style
        self.content = content
        self.doc = fitz.open()
        self.units: list[dict] = []
        # Every piece of text in drawing order, which is reading order: the
        # scorer aligns the parser's output against this stream token by token.
        self.stream: list[tuple[int, str]] = []
        self.page = None
        self.page_no = 0
        self.col = 0
        self.y = 0.0
        reg, ita, bold = FONTS[style.font]
        self.f_reg, self.f_ita, self.f_bold = reg, ita, bold
        self.lh = style.size * (1.0 if style.font == "courier" else 1.2)
        self.size_now = style.size   # type size being set (directions may differ)
        pw, ph = style.page
        self.top, self.bottom = 72.0, ph - 72.0
        if style.columns == 2:
            gap = 36.0
            colw = (pw - 2 * 40.0 - gap) / 2
            self.col_lefts = [40.0, 40.0 + colw + gap]
            self.colw = colw
        else:
            self.col_lefts = [0.0]
            self.colw = pw
        self.lay = self._layout()

    # -- geometry -------------------------------------------------------------
    def _layout(self) -> Layout:
        st = self.st
        pw = self.colw if st.columns == 2 else st.page[0]
        m = 0.0 if st.columns == 2 else 72.0
        if st.family == "screenplay":
            return Layout(108, pw - 180, cue_x=252, dialog_x=180, dialog_w=252, paren_x=223,
                          sd_x=108, sd_w=pw - 180)
        if st.family == "stage_centered":
            return Layout(m, pw - 2 * m, cue_x=-1, dialog_x=m, dialog_w=pw - 2 * m,
                          paren_x=m + 108, sd_x=st.sd_x or m + 180, sd_w=pw - (st.sd_x or m + 180) - m)
        if st.family in ("stage_left", "inline_paren"):
            return Layout(m, pw - 2 * m, cue_x=m, dialog_x=m, dialog_w=pw - 2 * m,
                          paren_x=m + 36, sd_x=st.sd_x or m + 72, sd_w=pw - (st.sd_x or m + 72) - m)
        if st.family == "two_column":
            return Layout(0, pw, cue_x=0, dialog_x=15, dialog_w=pw - 15, paren_x=15,
                          sd_x=st.sd_x or 60, sd_w=pw - (st.sd_x or 60))
        if st.family == "inline_name":
            return Layout(m, pw - 2 * m, cue_x=m, dialog_x=m + 90, dialog_w=pw - 2 * m - 90,
                          paren_x=m + 90, sd_x=st.sd_x or m + 90, sd_w=pw - (st.sd_x or m + 90) - m)
        raise ValueError(st.family)

    def _w(self, text: str, font: str) -> float:
        return fitz.get_text_length(text, fontname=font, fontsize=self.size_now)

    def _wrap(self, text: str, width: float, font: str) -> list[str]:
        lines, cur = [], ""
        for word in text.split():
            trial = f"{cur} {word}".strip()
            if cur and self._w(trial, font) > width:
                lines.append(cur)
                cur = word
            else:
                cur = trial
        if cur:
            lines.append(cur)
        return lines

    # -- pages ----------------------------------------------------------------
    def _new_page(self) -> None:
        s = self.st.scale
        pw, ph = self.st.page
        self.page = self.doc.new_page(width=pw * s, height=ph * s)
        self.page_no += 1
        self.col = 0
        self.y = self.top
        if self.page_no > 2:                          # body pages carry furniture
            n = str(self.page_no - 2)
            if self.st.family == "screenplay":
                self._draw(pw - 108, 40, f"{n}.", self.f_reg, "page_furniture")
            else:
                self._draw(pw / 2 - 6, ph - 40, n, self.f_reg, "page_furniture")
                if self.st.family in ("stage_centered", "inline_paren"):
                    self._draw(72 if self.st.columns == 1 else 40, 40,
                               f"{self.content.title.upper()} - Draft 4", self.f_reg, "page_furniture")

    def _advance(self, lines: int = 1) -> bool:
        """Move down; returns True if a new column/page was started."""
        if self.y + self.lh * lines > self.bottom:
            if self.col + 1 < len(self.col_lefts):
                self.col += 1
                self.y = self.top
            else:
                self._new_page()
            return True
        return False

    def _draw(self, x: float, y: float, text: str, font: str, kind: str,
              speaker: str | None = None) -> None:
        """Draw text at unscaled (x, y) and record it as its own unit."""
        s = self.st.scale
        self.page.insert_text((x * s, y * s), text, fontname=font, fontsize=self.st.size * s)
        self._record(self._unit(kind, speaker), text)

    def _record(self, unit: dict, text: str) -> None:
        unit["text"] = f"{unit['text']} {text}".strip()
        unit["pages"].add(self.page_no)
        self.stream.append((unit["id"], text))

    def _line(self, x: float, text: str, font: str, unit: dict) -> None:
        self._advance()          # a unit that crosses a page simply flows on
        s = self.st.scale
        cx = self.col_lefts[self.col] + x
        self.page.insert_text((cx * s, self.y * s), text, fontname=font, fontsize=self.size_now * s)
        self._record(unit, text)
        self.y += self.lh

    def _unit(self, kind: str, speaker: str | None = None) -> dict:
        u = {"id": len(self.units), "kind": kind, "speaker": speaker, "text": "", "pages": set()}
        self.units.append(u)
        return u

    def _block(self, x: float, width: float, text: str, font: str, kind: str,
               speaker: str | None = None) -> None:
        u = self._unit(kind, speaker)
        for ln in self._wrap(text, width, font):
            self._line(x, ln, font, u)

    def _gap(self) -> None:
        self.y += self.lh

    # -- front matter -----------------------------------------------------------
    def front_matter(self) -> None:
        pw, ph = self.st.page
        self._new_page()
        t = self.content.title.upper()
        self._draw(pw / 2 - self._w(t, self.f_bold) / 2, ph / 3, t, self.f_bold, "front_matter")
        by = "by Sam Avery Lund"
        self._draw(pw / 2 - self._w(by, self.f_reg) / 2, ph / 3 + 30, by, self.f_reg, "front_matter")
        self._draw(72, ph - 100, "Draft 4 - October 2026", self.f_reg, "front_matter")
        self._new_page()
        self._draw(72, 100, "CHARACTERS", self.f_bold, "front_matter")
        y = 130
        for name in self.content.cast:
            line = f"{name}, {random.Random(name).choice(['forties', 'a nurse', 'her brother', 'a stranger', 'sixty'])}"
            self._draw(90, y, line, self.f_reg, "front_matter")
            y += self.lh * 1.5

    # -- elements ---------------------------------------------------------------
    def heading(self, text: str) -> None:
        self._advance(3)
        self._gap()
        L = self.lay
        if self.st.family in ("stage_centered", "two_column") and self.st.columns == 1:
            x = self.st.page[0] / 2 - self._w(text, self.f_bold) / 2
        else:
            x = L.sd_x if self.st.family == "screenplay" else L.margin_left
        self._block(x, self.colw, text, self.f_bold if self.st.family != "screenplay" else self.f_reg,
                    "scene_heading")
        self._gap()

    def direction(self, text: str) -> None:
        L = self.lay
        if self.st.paren_sd:
            text = f"({text})"
        font = self.f_ita if self.st.italic_sd else self.f_reg
        if self.st.sd_style == "bold":
            font = self.f_bold
        elif self.st.sd_style == "sans":
            font = FONTS["helvetica" if self.st.font != "helvetica" else "times"][0]
        elif self.st.sd_style == "small":
            self.size_now = round(self.st.size * 0.83, 1)
        self._block(L.sd_x, L.sd_w, text, font, "stage_direction")
        self.size_now = self.st.size
        self._gap()

    def cue_line(self, b: Beat) -> None:
        L = self.lay
        name = f"{b.speaker} {b.extension}".strip()
        if self.st.family == "stage_centered":
            x = L.dialog_x + L.dialog_w / 2 - self._w(name, self.f_reg) / 2
        else:
            x = L.cue_x
        self._advance(2)
        if self.st.family == "inline_paren" and b.paren:
            u = self._unit("character_cue")
            self._line(x, name, self.f_reg, u)
            self.y -= self.lh
            p = self._unit("parenthetical", b.speaker)
            px = x + self._w(name + " ", self.f_reg)
            self._line(px, b.paren, self.f_reg, p)
            b.paren = None
            return
        cue_text = f"{name}:" if self.st.family == "two_column" else name
        u = self._unit("character_cue")
        self._line(x, cue_text, self.f_bold if self.st.family == "two_column" else self.f_reg, u)

    def speech_text(self, b: Beat, text: str) -> None:
        L = self.lay
        self._block(L.dialog_x, L.dialog_w, text, self.f_reg, "dialog", b.speaker)

    def paren_line(self, b: Beat, text: str) -> None:
        L = self.lay
        self._block(L.paren_x, L.dialog_w, text, self.f_reg, "parenthetical", b.speaker)

    def speech(self, b: Beat) -> None:
        if self.st.family == "inline_name":
            self.inline_speech(b)
            return
        self.cue_line(b)
        if b.paren:
            self.paren_line(b, b.paren)
        if self.st.family == "screenplay":
            self.screenplay_dialog(b)
        else:
            self.speech_text(b, b.text)
            if b.mid_paren:
                self.paren_line(b, b.mid_paren)
                self.speech_text(b, b.text2)
        self._gap()

    def screenplay_dialog(self, b: Beat) -> None:
        """Dialogue that breaks across a page gets (MORE) and a (CONT'D) name."""
        L = self.lay
        for part, text in ((0, b.text), (1, b.text2 if b.mid_paren else "")):
            if part == 1:
                if not text:
                    break
                self.paren_line(b, b.mid_paren)
            u = self._unit("dialog", b.speaker)
            for ln in self._wrap(text, L.dialog_w, self.f_reg):
                if self.y + self.lh > self.bottom:
                    self._draw(L.cue_x, self.y, "(MORE)", self.f_reg, "page_furniture")
                    self._new_page()
                    self._draw(L.cue_x, self.y, f"{b.speaker} (CONT'D)", self.f_reg, "character_cue")
                    self.y += self.lh
                    u = self._unit("dialog", b.speaker)
                self._line(L.dialog_x, ln, self.f_reg, u)

    def inline_speech(self, b: Beat) -> None:
        """'NAME: dialogue' on one line; continuation lines hang at dialog_x."""
        L = self.lay
        self._advance(1)
        s = self.st.scale
        name = f"{b.speaker}:"
        cx = self.col_lefts[self.col] + L.cue_x
        self.page.insert_text((cx * s, self.y * s), name, fontname=self.f_bold, fontsize=self.st.size * s)
        self._record(self._unit("character_cue"), name)
        text = f"{b.paren} {b.text}" if b.paren else b.text
        if b.mid_paren:
            text = f"{text} {b.mid_paren} {b.text2}"
        for ln in self._wrap(text, L.dialog_w, self.f_reg):
            self._advance()
            self.page.insert_text(((self.col_lefts[self.col] + L.dialog_x) * s, self.y * s), ln,
                                  fontname=self.f_reg, fontsize=self.st.size * s)
            self.y += self.lh
        # Lines here mix dialogue and brackets, so the truth is recorded per
        # piece rather than per physical line; the token order is the same.
        for kind, piece in _split_parens(text):
            self._record(self._unit(kind, b.speaker), piece)
        self._gap()

    def build(self) -> fitz.Document:
        self.front_matter()
        self._new_page()
        for heading, beats in self.content.scenes:
            self.heading(heading)
            for b in beats:
                if b.kind == "direction":
                    self.direction(b.text)
                else:
                    self.speech(b)
        return self.doc


def _split_parens(text: str) -> list[tuple[str, str]]:
    """'(beat) Fine. (to MARA) Go.' -> [(parenthetical,'(beat)'), (dialog,'Fine.'), ...]"""
    out, buf, depth = [], "", 0
    for ch in text:
        if ch == "(" and depth == 0:
            if buf.strip():
                out.append(("dialog", buf.strip()))
            buf, depth = "(", 1
        elif ch == ")" and depth == 1:
            out.append(("parenthetical", buf + ")"))
            buf, depth = "", 0
        else:
            buf += ch
    if buf.strip():
        out.append(("dialog", buf.strip()))
    return out


# ---------------------------------------------------------------------------
# The standard set
# ---------------------------------------------------------------------------

def standard_styles() -> list[tuple[str, Style]]:
    big = 1000 / 612        # the corpus's 1000x1294 pages are Letter at this scale
    return [
        ("screenplay_letter", Style("screenplay", font="courier")),
        ("screenplay_scaled", Style("screenplay", font="courier", scale=big)),
        ("screenplay_a4", Style("screenplay", font="courier", page=A4)),
        ("centered_parens", Style("stage_centered", paren_sd=True, sd_x=250)),
        ("centered_italic", Style("stage_centered", italic_sd=True, sd_x=270)),
        ("centered_courier_a4", Style("stage_centered", font="courier", page=A4, paren_sd=True)),
        ("left_indented", Style("stage_left", sd_x=144)),
        ("left_italic_margin", Style("stage_left", italic_sd=True, sd_x=72, size=11)),
        ("left_scaled", Style("stage_left", scale=big, italic_sd=True, sd_x=108)),
        ("inline_paren_scaled", Style("inline_paren", scale=big, font="times", italic_sd=True, sd_x=108)),
        ("inline_paren_helv", Style("inline_paren", font="helvetica", italic_sd=True, sd_x=108)),
        ("two_column_wide", Style("two_column", page=LANDSCAPE, italic_sd=True, columns=2,
                                  scale=1000 / 792, size=11)),
        ("inline_name_times", Style("inline_name", italic_sd=True, paren_sd=True)),
        # Unseen conventions: directions sit exactly where dialogue does and are
        # marked only by a style the parser has never been told about.
        ("unseen_bold", Style("stage_left", sd_style="bold", sd_x=72)),
        ("unseen_small", Style("stage_left", sd_style="small", sd_x=72)),
        ("unseen_sans", Style("stage_left", sd_style="sans", sd_x=72)),
        ("unseen_bold_centered", Style("stage_centered", sd_style="bold", sd_x=72)),
        ("inline_name_courier", Style("inline_name", font="courier", sd_x=72)),
    ]


def write(name: str, style: Style, seed: int) -> dict:
    rng = random.Random(f"{seed}:{name}")
    content = make_content(rng, style.family, n_scenes=rng.randint(4, 6))
    ts = Typesetter(style, content)
    doc = ts.build()
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    doc.save(OUT_DIR / f"{name}.pdf")
    units = ts.units
    for u in units:
        u["pages"] = sorted(u["pages"])
    truth = {
        "_meta": {"generator": "synth_generate.py", "seed": seed, "family": style.family,
                  "style": {k: v for k, v in style.__dict__.items()}},
        "title": content.title,
        "cast": content.cast,
        "scenes": [h for h, _ in content.scenes],
        "units": units,
        "stream": ts.stream,
    }
    (OUT_DIR / f"{name}.truth.json").write_text(json.dumps(truth, indent=1))
    return {"name": name, "pages": doc.page_count, "units": len(units)}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--seed", type=int, default=1)
    args = ap.parse_args()
    for name, style in standard_styles():
        info = write(name, style, args.seed)
        print(f"{info['name']:24} {info['pages']:4} pages {info['units']:6} units")
    print(f"\nWritten to {OUT_DIR.relative_to(ROOT)}/")
    return 0


if __name__ == "__main__":
    sys.exit(main())
