"""
audio_drama.py
==============

Tkinter desktop app: convert a script PDF into per-scene audio files.

Visual design: dark theme (#141414 background, #e8824a accent) with a
four-step wizard flow — Import → Review → Cast Voices → Generate.
"""

from __future__ import annotations

import os
import platform
import queue
import sys
import threading
import time
import tkinter as tk
import traceback
from datetime import datetime
from pathlib import Path
from tkinter import filedialog, messagebox, ttk
from typing import Dict, List, Optional


def _dbg(msg: str) -> None:
    print(f"[ui] {msg}", file=sys.stderr, flush=True)


_dbg("starting imports")
import parser as script_parser
import tts_engines
from audio_pipeline import generate_script, GenerationProgress
from voice_assignment import auto_assign, Assignment, NARRATOR_KEY
_dbg("imports done")


APP_TITLE = "Script to Audiodrama"

# ── Color palette (matches design handoff) ──────────────────────────────────
BG0     = "#141414"   # main window background
BG1     = "#1c1c1e"   # sidebar / card background
BG2     = "#242426"   # elevated cards / input fields
BG3     = "#2e2e30"   # hover state
BG4     = "#3a3a3c"   # subtle borders
BORDER  = "#333333"   # card border
ACCENT  = "#e8824a"   # orange
GREEN   = "#4caf7d"   # success
TEXT0   = "#f0ede8"   # primary text
TEXT1   = "#b8b5b0"   # secondary text
TEXT2   = "#7a7775"   # muted text
TEXT3   = "#4a4846"   # very muted

# ── Fonts ────────────────────────────────────────────────────────────────────
FONT_SANS   = "Helvetica Neue"
FONT_MONO   = "Menlo"
FONT_SANS_F = (FONT_SANS, 13)
FONT_MONO_F = (FONT_MONO, 11)

# Per-character colors for script preview (cycles through these)
CHAR_PALETTE = [
    "#e8824a", "#6b9fd4", "#78c98a", "#b478c9",
    "#c9a378", "#78b4c9", "#c97878", "#a3c978",
]


def _char_color(index: int) -> str:
    return CHAR_PALETTE[index % len(CHAR_PALETTE)]


# ── Base styled widgets ──────────────────────────────────────────────────────

class DarkFrame(tk.Frame):
    def __init__(self, parent, bg=BG0, **kw):
        super().__init__(parent, bg=bg, **kw)


class Label(tk.Label):
    def __init__(self, parent, text="", font=None, fg=TEXT0, bg=BG0, **kw):
        super().__init__(parent, text=text, font=font or FONT_SANS_F,
                         fg=fg, bg=bg, **kw)


class _LabelButton(tk.Label):
    """Label-based button — custom bg/fg work reliably on macOS (Aqua ignores tk.Button bg)."""

    _BASE_BG  = BG2
    _HOVER_BG = BG3
    _BASE_FG  = TEXT0
    _FONT     = FONT_SANS_F
    _PADX, _PADY = 14, 7

    def __init__(self, parent, text="", command=None, **kw):
        self._cmd      = command
        self._enabled  = True
        self._base_bg  = kw.pop("bg",  self._BASE_BG)
        self._hover_bg = kw.pop("hover_bg", self._HOVER_BG)
        self._base_fg  = kw.pop("fg",  self._BASE_FG)
        super().__init__(
            parent, text=text,
            bg=self._base_bg, fg=self._base_fg,
            font=kw.pop("font", self._FONT),
            padx=kw.pop("padx", self._PADX),
            pady=kw.pop("pady", self._PADY),
            cursor="hand2",
            **kw,
        )
        self.bind("<Enter>",    self._on_enter)
        self.bind("<Leave>",    self._on_leave)
        self.bind("<Button-1>", self._on_click)

    def _on_enter(self, _e):
        if self._enabled:
            tk.Label.configure(self, bg=self._hover_bg)

    def _on_leave(self, _e):
        if self._enabled:
            tk.Label.configure(self, bg=self._base_bg)

    def _on_click(self, _e):
        if self._enabled and self._cmd:
            self._cmd()

    def configure(self, **kw):
        if "command" in kw:
            self._cmd = kw.pop("command")
        if "state" in kw:
            state = kw.pop("state")
            if state == "disabled":
                self._enabled = False
                tk.Label.configure(self, bg=BG3, fg=TEXT3, cursor="")
            else:
                self._enabled = True
                tk.Label.configure(self, bg=self._base_bg, fg=self._base_fg,
                                   cursor="hand2")
        if kw:
            tk.Label.configure(self, **kw)

    def cget(self, key):
        if key == "state":
            return "normal" if self._enabled else "disabled"
        return tk.Label.cget(self, key)


class AccentButton(_LabelButton):
    """Orange primary action button."""
    _BASE_BG  = ACCENT
    _HOVER_BG = "#d4723e"
    _BASE_FG  = "#ffffff"
    _FONT     = (FONT_SANS, 13, "bold")
    _PADX, _PADY = 18, 8


class GhostButton(_LabelButton):
    """Subtle secondary button."""
    _BASE_BG  = BG2
    _HOVER_BG = BG3
    _BASE_FG  = TEXT1
    _FONT     = FONT_SANS_F
    _PADX, _PADY = 14, 7


def _link_btn(parent, text, command, fg=ACCENT, bg=BG0, font=None):
    """Inline text link — for Back navigation etc."""
    lbl = tk.Label(parent, text=text, fg=fg, bg=bg,
                   font=font or (FONT_SANS, 12),
                   cursor="hand2")
    lbl.bind("<Button-1>", lambda e: command())
    lbl.bind("<Enter>", lambda e: lbl.configure(fg=TEXT0))
    lbl.bind("<Leave>", lambda e: lbl.configure(fg=fg))
    return lbl


# ── Step navigation bar ──────────────────────────────────────────────────────

class StepNav(tk.Frame):
    STEPS = ["Import", "Review", "Cast Voices", "Generate"]

    def __init__(self, parent, current_step: int, go_to_step, **kw):
        super().__init__(parent, bg=BG1,
                         highlightbackground=BORDER, highlightthickness=1,
                         **kw)
        self._go = go_to_step
        self._current = current_step
        self._build()

    def _build(self):
        for w in self.winfo_children():
            w.destroy()

        inner = tk.Frame(self, bg=BG1)
        inner.pack(fill="x", padx=8)

        for i, label in enumerate(self.STEPS):
            num = i + 1
            done = num < self._current
            active = num == self._current

            if i > 0:
                tk.Label(inner, text="›", fg=TEXT3, bg=BG1,
                         font=(FONT_SANS, 11)).pack(side="left", padx=2)

            frame = tk.Frame(inner, bg=BG1)
            frame.pack(side="left")

            # Number badge
            if done:
                badge_bg, badge_fg = GREEN, "#fff"
                badge_text = "✓"
            elif active:
                badge_bg, badge_fg = ACCENT, "#fff"
                badge_text = str(num)
            else:
                badge_bg, badge_fg = BG3, TEXT3
                badge_text = str(num)

            badge = tk.Label(frame, text=badge_text,
                             bg=badge_bg, fg=badge_fg,
                             font=(FONT_MONO, 9, "bold"),
                             width=2, anchor="center")
            badge.pack(side="left", padx=(8, 4))

            # Label
            if active:
                col, weight = ACCENT, "bold"
            elif done:
                col, weight = TEXT1, "normal"
            else:
                col, weight = TEXT3, "normal"

            lbl = tk.Label(frame, text=label, fg=col, bg=BG1,
                           font=(FONT_SANS, 12, weight))
            lbl.pack(side="left", padx=(0, 8))

            if done:
                for w in [frame, badge, lbl]:
                    w.configure(cursor="hand2")
                for w in [frame, badge, lbl]:
                    w.bind("<Button-1>", lambda e, n=num: self._go(n))

    def update_step(self, step: int):
        self._current = step
        self._build()


# ── SCREEN 1: Import ─────────────────────────────────────────────────────────

class ImportScreen(tk.Frame):
    def __init__(self, parent, on_choose_pdf, recent_files: List[str], **kw):
        super().__init__(parent, bg=BG0, **kw)
        self._on_choose = on_choose_pdf
        self._recent = recent_files
        self._build()

    def _build(self):
        # Center everything vertically
        self.rowconfigure(0, weight=1)
        self.columnconfigure(0, weight=1)

        inner = tk.Frame(self, bg=BG0)
        inner.grid(row=0, column=0)

        # Hero heading
        tk.Label(inner, text=APP_TITLE,
                 font=(FONT_SANS, 28, "bold"),
                 fg=TEXT0, bg=BG0).pack(pady=(0, 8))
        tk.Label(inner,
                 text="Load a PDF screenplay or stage play to begin.",
                 font=(FONT_SANS, 13), fg=TEXT2, bg=BG0).pack(pady=(0, 40))

        # Drop zone card
        dz = tk.Frame(inner, bg=BG1,
                      highlightbackground=BORDER, highlightthickness=1)
        dz.pack(ipadx=60, ipady=40, pady=(0, 24))
        dz.configure(cursor="hand2")

        tk.Label(dz, text="📜", font=(FONT_SANS, 36), bg=BG1).pack()
        tk.Label(dz, text="Drop your script here",
                 font=(FONT_SANS, 15, "bold"), fg=TEXT0, bg=BG1).pack(pady=(12, 4))
        tk.Label(dz, text="PDF, or click to browse…",
                 font=(FONT_SANS, 12), fg=TEXT2, bg=BG1).pack()

        for w in [dz] + dz.winfo_children():
            w.bind("<Button-1>", lambda e: self._on_choose())

        # Drag-and-drop support
        try:
            self.drop_target_register("*")  # type: ignore
            self.dnd_bind("<<Drop>>", lambda e: self._on_choose())
        except Exception:
            pass

        # Divider
        div = tk.Frame(inner, bg=BG0)
        div.pack(fill="x", padx=40, pady=8)
        tk.Frame(div, bg=BORDER, height=1).pack(
            side="left", fill="x", expand=True, pady=7)
        tk.Label(div, text=" or open recent ", fg=TEXT3, bg=BG0,
                 font=(FONT_SANS, 11)).pack(side="left")
        tk.Frame(div, bg=BORDER, height=1).pack(
            side="left", fill="x", expand=True, pady=7)

        # Recent files
        if self._recent:
            tk.Label(inner, text="RECENT SCRIPTS",
                     font=(FONT_MONO, 10), fg=TEXT3, bg=BG0).pack(
                anchor="w", padx=4, pady=(4, 6))
            for path in self._recent[-5:]:
                self._recent_row(inner, path)
        else:
            tk.Label(inner, text="No recent scripts.",
                     font=(FONT_SANS, 12), fg=TEXT3, bg=BG0).pack(pady=8)

    def _recent_row(self, parent, path: str):
        row = tk.Frame(parent, bg=BG1,
                       highlightbackground=BORDER, highlightthickness=1,
                       cursor="hand2")
        row.pack(fill="x", pady=3, ipady=8, ipadx=12)

        tk.Label(row, text="📄", font=(FONT_SANS, 16), bg=BG1).pack(
            side="left", padx=(8, 6))
        info = tk.Frame(row, bg=BG1)
        info.pack(side="left", fill="x", expand=True)
        tk.Label(info, text=Path(path).name,
                 font=(FONT_SANS, 12, "bold"), fg=TEXT0, bg=BG1,
                 anchor="w").pack(fill="x")
        tk.Label(info, text=str(Path(path).parent),
                 font=(FONT_SANS, 10), fg=TEXT2, bg=BG1,
                 anchor="w").pack(fill="x")
        tk.Label(row, text="›", fg=TEXT3, bg=BG1,
                 font=(FONT_SANS, 14)).pack(side="right", padx=8)

        for w in [row] + row.winfo_children() + info.winfo_children():
            w.bind("<Button-1>", lambda e, p=path: self._on_choose(p))


# ── SCREEN 2: Review (script preview + sidebar) ──────────────────────────────

class ReviewScreen(tk.Frame):
    def __init__(self, parent, script: script_parser.Script,
                 pdf_path: str, on_next, on_back=None, **kw):
        super().__init__(parent, bg=BG0, **kw)
        self._script = script
        self._pdf_path = pdf_path
        self._on_next = on_next
        self._on_back = on_back or (lambda: None)
        self._char_colors: Dict[str, str] = {}
        for i, ch in enumerate(script.characters):
            self._char_colors[ch.name] = _char_color(i)
        self._build()

    def _build(self):
        self.columnconfigure(0, weight=1)
        self.columnconfigure(1, weight=0)
        self.rowconfigure(0, weight=1)

        # ── Left: script pane ───────────────────────────────────────────────
        left = tk.Frame(self, bg=BG0)
        left.grid(row=0, column=0, sticky="nsew")
        left.rowconfigure(1, weight=1)
        left.columnconfigure(0, weight=1)

        # Header row
        hdr = tk.Frame(left, bg=BG0)
        hdr.grid(row=0, column=0, sticky="ew", padx=24, pady=(16, 8))
        tk.Label(hdr, text="Script Preview",
                 font=(FONT_SANS, 13, "bold"), fg=TEXT0, bg=BG0).pack(side="left")
        tk.Label(hdr, text=Path(self._pdf_path).name,
                 font=(FONT_MONO, 11), fg=TEXT2, bg=BG0).pack(side="right")

        # Scrollable text area
        txt_frame = tk.Frame(left, bg=BG0)
        txt_frame.grid(row=1, column=0, sticky="nsew", padx=(20, 0))
        txt_frame.rowconfigure(0, weight=1)
        txt_frame.columnconfigure(0, weight=1)

        self.txt = tk.Text(
            txt_frame, bg=BG0, fg=TEXT1,
            relief="flat", bd=0, padx=20, pady=4,
            font=(FONT_SANS, 13), wrap="word",
            state="disabled",
            insertbackground=ACCENT,
            selectbackground=BG3,
        )
        sb = ttk.Scrollbar(txt_frame, command=self.txt.yview)
        self.txt.configure(yscrollcommand=sb.set)
        self.txt.grid(row=0, column=0, sticky="nsew")
        sb.grid(row=0, column=1, sticky="ns")

        # Define text tags
        self.txt.tag_configure("scene_heading",
            font=(FONT_MONO, 11, "bold"), foreground=TEXT2,
            spacing1=18, spacing3=8)
        self.txt.tag_configure("stage_dir",
            font=(FONT_SANS, 12, "italic"), foreground=TEXT2,
            lmargin1=12, lmargin2=12, spacing1=2, spacing3=2)
        self.txt.tag_configure("char_name",
            font=(FONT_MONO, 11, "bold"),
            spacing1=10, spacing3=2)
        self.txt.tag_configure("paren",
            font=(FONT_SANS, 12, "italic"), foreground=TEXT2)
        self.txt.tag_configure("dialog",
            font=(FONT_SANS, 13), foreground=TEXT0,
            lmargin1=24, lmargin2=24, spacing3=6)

        # Per-character color tags
        for name, color in self._char_colors.items():
            self.txt.tag_configure(f"char_{name}", foreground=color)

        self._populate_text()

        # ── Right: sidebar ───────────────────────────────────────────────────
        right = tk.Frame(self, bg=BG1, width=280,
                         highlightbackground=BORDER, highlightthickness=1)
        right.grid(row=0, column=1, sticky="nsew")
        right.pack_propagate(False)
        right.rowconfigure(1, weight=1)
        right.columnconfigure(0, weight=1)

        # Sidebar header
        shdr = tk.Frame(right, bg=BG1)
        shdr.grid(row=0, column=0, sticky="ew",
                  padx=16, pady=(14, 10))
        tk.Label(shdr, text="Parsed Script",
                 font=(FONT_SANS, 13, "bold"), fg=TEXT0, bg=BG1).pack(
            anchor="w")
        tk.Label(shdr, text=f"from {Path(self._pdf_path).name}",
                 font=(FONT_SANS, 11), fg=TEXT2, bg=BG1).pack(anchor="w")

        # Scrollable sidebar body
        sb2_frame = tk.Frame(right, bg=BG1)
        sb2_frame.grid(row=1, column=0, sticky="nsew")
        sb2_frame.rowconfigure(0, weight=1)
        sb2_frame.columnconfigure(0, weight=1)

        canvas = tk.Canvas(sb2_frame, bg=BG1, highlightthickness=0, bd=0)
        vsb = ttk.Scrollbar(sb2_frame, orient="vertical", command=canvas.yview)
        canvas.configure(yscrollcommand=vsb.set)
        canvas.grid(row=0, column=0, sticky="nsew")
        vsb.grid(row=0, column=1, sticky="ns")

        body = tk.Frame(canvas, bg=BG1)
        win_id = canvas.create_window((0, 0), window=body, anchor="nw")

        def _resize(e):
            canvas.configure(scrollregion=canvas.bbox("all"))
        body.bind("<Configure>", _resize)

        def _canvas_resize(e):
            canvas.itemconfigure(win_id, width=e.width)
        canvas.bind("<Configure>", _canvas_resize)

        self._build_sidebar(body)

        # Sidebar footer
        foot = tk.Frame(right, bg=BG1,
                        highlightbackground=BORDER, highlightthickness=1)
        foot.grid(row=2, column=0, sticky="ew")
        tk.Label(foot,
                 text="Review the parsed script,\nthen cast voices.",
                 font=(FONT_SANS, 11), fg=TEXT2, bg=BG1,
                 justify="left").pack(anchor="w", padx=14, pady=(10, 6))
        btn_row = tk.Frame(foot, bg=BG1)
        btn_row.pack(fill="x", padx=14, pady=(0, 12))
        AccentButton(btn_row, text="Cast Voices →",
                     command=self._on_next).pack(side="right")
        _link_btn(btn_row, "← Back", self._on_back, bg=BG1).pack(
            side="left", pady=4)

    def _build_sidebar(self, body: tk.Frame):
        s = self._script

        # Stats grid
        stats = [
            (len(s.scenes), "Scenes"),
            (len(s.characters), "Characters"),
            (sum(sum(1 for e in sc.elements if e.kind == "dialog")
                 for sc in s.scenes), "Lines"),
        ]
        grid = tk.Frame(body, bg=BG1)
        grid.pack(fill="x", padx=10, pady=(4, 8))
        for val, lbl in stats:
            box = tk.Frame(grid, bg=BG2,
                           highlightbackground=BORDER, highlightthickness=1)
            box.pack(side="left", expand=True, fill="x", padx=4, pady=4,
                     ipadx=8, ipady=6)
            tk.Label(box, text=str(val),
                     font=(FONT_SANS, 18, "bold"), fg=TEXT0, bg=BG2).pack()
            tk.Label(box, text=lbl,
                     font=(FONT_SANS, 10), fg=TEXT2, bg=BG2).pack()

        # Characters section
        tk.Label(body, text="CHARACTERS",
                 font=(FONT_MONO, 9), fg=TEXT3, bg=BG1).pack(
            anchor="w", padx=14, pady=(6, 4))

        for i, ch in enumerate(s.characters[:20]):
            color = self._char_colors.get(ch.name, TEXT2)
            row = tk.Frame(body, bg=BG1)
            row.pack(fill="x", padx=10, pady=2)

            # Color dot
            dot = tk.Canvas(row, width=8, height=8,
                            bg=BG1, highlightthickness=0)
            dot.pack(side="left", padx=(4, 8))
            dot.create_oval(1, 1, 7, 7, fill=color, outline="")

            tk.Label(row, text=ch.name,
                     font=(FONT_MONO, 11), fg=TEXT0, bg=BG1).pack(side="left")
            if ch.role_hint:
                tk.Label(row, text=ch.role_hint,
                         font=(FONT_SANS, 10), fg=TEXT2, bg=BG1).pack(
                    side="left", padx=(6, 0))

        if len(s.characters) > 20:
            tk.Label(body, text=f"  …and {len(s.characters)-20} more",
                     font=(FONT_SANS, 11), fg=TEXT3, bg=BG1).pack(
                anchor="w", padx=14)

        # Scenes section
        tk.Label(body, text="SCENES",
                 font=(FONT_MONO, 9), fg=TEXT3, bg=BG1).pack(
            anchor="w", padx=14, pady=(14, 4))

        for sc in s.scenes:
            row = tk.Frame(body, bg=BG1)
            row.pack(fill="x", padx=10, pady=2)
            tk.Label(row, text=str(sc.number),
                     font=(FONT_MONO, 9), fg=ACCENT, bg=BG1,
                     width=3, anchor="e").pack(side="left")
            tk.Label(row, text=sc.title,
                     font=(FONT_SANS, 11), fg=TEXT1, bg=BG1,
                     anchor="w", justify="left").pack(
                side="left", padx=(6, 0), fill="x", expand=True)

    def _populate_text(self):
        self.txt.configure(state="normal")
        self.txt.delete("1.0", "end")
        for sc in self._script.scenes:
            # Scene heading
            heading = f"  {sc.number}  {sc.title.upper()}\n"
            self.txt.insert("end", heading, "scene_heading")

            for el in sc.elements:
                if el.kind == "stage_direction":
                    self.txt.insert("end", el.text + "\n", "stage_dir")
                elif el.kind == "parenthetical":
                    color_tag = f"char_{el.speaker}" if el.speaker and el.speaker in self._char_colors else ""
                    self.txt.insert("end", "\n")
                    self.txt.insert("end", (el.speaker or "") + "\n",
                                    ("char_name", color_tag))
                    self.txt.insert("end", f"({el.text})\n", "paren")
                elif el.kind == "dialog":
                    color_tag = f"char_{el.speaker}" if el.speaker and el.speaker in self._char_colors else ""
                    self.txt.insert("end", "\n")
                    self.txt.insert("end", (el.speaker or "") + "\n",
                                    ("char_name", color_tag))
                    self.txt.insert("end", el.text + "\n", "dialog")

            self.txt.insert("end", "\n")

        self.txt.configure(state="disabled")
        self.txt.see("1.0")


# ── SCREEN 3: Cast Voices ────────────────────────────────────────────────────

class CastScreen(tk.Frame):
    def __init__(self, parent, script: script_parser.Script,
                 engine_voices: List[tts_engines.VoiceInfo],
                 assignment: Assignment,
                 on_engine_change, on_next, on_back=None, **kw):
        super().__init__(parent, bg=BG0, **kw)
        self._script = script
        self._on_back = on_back or (lambda: None)
        self._engine_voices = engine_voices
        self._assignment = assignment
        self._on_engine_change = on_engine_change
        self._on_next = on_next
        self.voice_pickers: Dict[str, tk.StringVar] = {}  # key → StringVar (survives widget destruction)
        self._char_colors: Dict[str, str] = {}
        for i, ch in enumerate(script.characters):
            self._char_colors[ch.name] = _char_color(i)
        self._build()

    def _build(self):
        self.rowconfigure(0, weight=1)
        self.columnconfigure(0, weight=1)

        # ── Main area ──────────────────────────────────────────────────────
        main = tk.Frame(self, bg=BG0)
        main.grid(row=0, column=0, sticky="nsew")
        main.rowconfigure(1, weight=1)
        main.columnconfigure(0, weight=1)

        # Header
        hdr = tk.Frame(main, bg=BG0)
        hdr.grid(row=0, column=0, sticky="ew", padx=28, pady=(20, 0))
        tk.Label(hdr, text="Cast Voices",
                 font=(FONT_SANS, 18, "bold"), fg=TEXT0, bg=BG0).pack(
            side="left", anchor="w")

        # Scrollable cast table
        table_wrap = tk.Frame(main, bg=BG0)
        table_wrap.grid(row=1, column=0, sticky="nsew", padx=(20, 0), pady=10)
        table_wrap.rowconfigure(0, weight=1)
        table_wrap.columnconfigure(0, weight=1)

        canvas = tk.Canvas(table_wrap, bg=BG0, highlightthickness=0)
        vsb = ttk.Scrollbar(table_wrap, orient="vertical", command=canvas.yview)
        canvas.configure(yscrollcommand=vsb.set)
        canvas.grid(row=0, column=0, sticky="nsew")
        vsb.grid(row=0, column=1, sticky="ns")

        inner = tk.Frame(canvas, bg=BG0)
        win_id = canvas.create_window((0, 0), window=inner, anchor="nw")

        def _resize(e):
            canvas.configure(scrollregion=canvas.bbox("all"))
        inner.bind("<Configure>", _resize)

        def _canvas_resize(e):
            canvas.itemconfigure(win_id, width=e.width)
        canvas.bind("<Configure>", _canvas_resize)

        self._render_cast_table(inner)

        # Bottom bar
        foot = tk.Frame(main, bg=BG0,
                        highlightbackground=BORDER, highlightthickness=1)
        foot.grid(row=2, column=0, sticky="ew")
        btn_row = tk.Frame(foot, bg=BG0)
        btn_row.pack(fill="x", padx=20, pady=10)
        AccentButton(btn_row, text="Generate Audio →",
                     command=self._on_next).pack(side="right")
        _link_btn(btn_row, "← Back", self._on_back).pack(side="left", pady=4)

        # ── Right sidebar (engine picker) ─────────────────────────────────
        right = tk.Frame(self, bg=BG1, width=260,
                         highlightbackground=BORDER, highlightthickness=1)
        right.grid(row=0, column=1, sticky="nsew")
        right.pack_propagate(False)

        tk.Label(right, text="Voice Engine",
                 font=(FONT_SANS, 13, "bold"), fg=TEXT0, bg=BG1).pack(
            anchor="w", padx=16, pady=(16, 4))
        tk.Label(right, text="Pick the TTS engine for all voices.",
                 font=(FONT_SANS, 11), fg=TEXT2, bg=BG1,
                 wraplength=220, justify="left").pack(
            anchor="w", padx=16, pady=(0, 12))

        # Engine radio buttons
        self.engine_var = tk.StringVar(value="mac")
        self.engine_var.trace_add("write", lambda *_: self._on_engine_change(
            self.engine_var.get(), self.openai_key_var.get()))

        for txt, val in [
            ("macOS built-in\n(offline · free)", "mac"),
            ("OpenAI TTS\n(cloud · requires API key)", "openai"),
        ]:
            rb_frame = tk.Frame(right, bg=BG2,
                                highlightbackground=BORDER, highlightthickness=1)
            rb_frame.pack(fill="x", padx=12, pady=4, ipadx=8, ipady=6)
            rb = tk.Radiobutton(
                rb_frame, text=txt, variable=self.engine_var, value=val,
                bg=BG2, fg=TEXT1, selectcolor=BG2,
                activebackground=BG2, activeforeground=TEXT0,
                font=(FONT_SANS, 11), anchor="w",
                highlightthickness=0, relief="flat",
            )
            rb.pack(fill="x")

        # OpenAI key field
        key_card = tk.Frame(right, bg=BG2,
                            highlightbackground=BORDER, highlightthickness=1)
        key_card.pack(fill="x", padx=12, pady=(8, 0), ipadx=10, ipady=8)
        tk.Label(key_card, text="API KEY",
                 font=(FONT_MONO, 9), fg=TEXT3, bg=BG2).pack(anchor="w")
        self.openai_key_var = tk.StringVar(
            value=os.environ.get("OPENAI_API_KEY", ""))
        self.openai_key_entry = tk.Entry(
            key_card, textvariable=self.openai_key_var,
            show="•", bg=BG3, fg=TEXT1, insertbackground=ACCENT,
            relief="flat", bd=0, font=(FONT_MONO, 11))
        self.openai_key_entry.pack(fill="x", pady=(4, 0), ipady=4)

    def _render_cast_table(self, parent: tk.Frame):
        # voice_pickers now stores StringVar — safe to read after widget destruction
        self.voice_pickers.clear()
        for w in parent.winfo_children():
            w.destroy()

        voice_displays = [v.display for v in self._engine_voices]
        voices_by_id = {v.id: v for v in self._engine_voices}

        if not voice_displays:
            tk.Label(parent, text="No voices found for this engine.",
                     font=FONT_SANS_F, fg=TEXT2, bg=BG0).pack(pady=20)
            return

        # Column headers
        hdr = tk.Frame(parent, bg=BG0)
        hdr.pack(fill="x", padx=8, pady=(4, 4))
        tk.Label(hdr, text="CHARACTER", font=(FONT_MONO, 9), fg=TEXT3, bg=BG0,
                 width=24, anchor="w").pack(side="left")
        tk.Label(hdr, text="VOICE", font=(FONT_MONO, 9), fg=TEXT3, bg=BG0,
                 anchor="w").pack(side="left")

        tk.Frame(parent, bg=BORDER, height=1).pack(fill="x", padx=8, pady=(0, 6))

        def add_row(label_text: str, key: str,
                    hint: Optional[str] = None,
                    color: Optional[str] = None):
            row = tk.Frame(parent, bg=BG0)
            row.pack(fill="x", padx=8, pady=3)

            # Left: color dot + character name + hint
            name_frame = tk.Frame(row, bg=BG0, width=200)
            name_frame.pack(side="left")
            name_frame.pack_propagate(False)

            if color:
                dot = tk.Canvas(name_frame, width=8, height=8,
                                bg=BG0, highlightthickness=0)
                dot.pack(side="left", padx=(0, 6), pady=4)
                dot.create_oval(1, 1, 7, 7, fill=color, outline="")

            tk.Label(name_frame, text=label_text,
                     font=(FONT_MONO, 11), fg=TEXT0, bg=BG0,
                     anchor="w").pack(side="left")
            if hint:
                tk.Label(name_frame, text=hint,
                         font=(FONT_SANS, 10), fg=TEXT2, bg=BG0).pack(
                    side="left", padx=(6, 0))

            # Right: OptionMenu — uses tk (not ttk) so bg/fg work on macOS
            current_vid = self._assignment.mapping.get(key)
            default_disp = (voices_by_id[current_vid].display
                            if current_vid and current_vid in voices_by_id
                            else voice_displays[0])
            var = tk.StringVar(value=default_disp)
            om = tk.OptionMenu(row, var, *voice_displays)
            om.configure(
                bg=BG2, fg=TEXT0,
                activebackground=ACCENT, activeforeground="#fff",
                highlightthickness=0, relief="flat", bd=0,
                font=FONT_SANS_F, anchor="w", width=34,
                indicatoron=True,
            )
            om["menu"].configure(
                bg=BG2, fg=TEXT0,
                activebackground=ACCENT, activeforeground="#fff",
                font=FONT_SANS_F, bd=0, tearoff=False,
            )
            om.pack(side="left", padx=(8, 0))
            self.voice_pickers[key] = var   # store StringVar, not the widget

        # Narrator row (always first)
        add_row("Narrator", NARRATOR_KEY, hint="(stage directions)")
        tk.Frame(parent, bg=BORDER, height=1).pack(
            fill="x", padx=8, pady=(4, 8))

        for i, ch in enumerate(self._script.characters):
            color = _char_color(i)
            hint_bits = []
            if ch.role_hint:
                hint_bits.append(ch.role_hint)
            if ch.gender_hint:
                hint_bits.append(ch.gender_hint)
            hint = " · ".join(hint_bits) if hint_bits else None
            add_row(ch.name, ch.name, hint=hint, color=color)

    def refresh_voices(self, new_voices: List[tts_engines.VoiceInfo],
                       new_assignment: Assignment):
        """Called when engine changes while on this screen."""
        self._engine_voices = new_voices
        self._assignment = new_assignment
        # Find the inner scrollable frame and rebuild
        for w in self.winfo_children():
            if isinstance(w, tk.Frame):
                for c in w.winfo_children():
                    if isinstance(c, tk.Frame):
                        self._render_cast_table(c)
                        return

    def resolved_assignment(self) -> Assignment:
        """Build an Assignment from the current StringVar selections."""
        voice_id_by_display = {v.display: v.id for v in self._engine_voices}
        voices_by_id = {v.id: v for v in self._engine_voices}
        mapping: Dict[str, str] = {}
        for key, var in self.voice_pickers.items():
            disp = var.get()  # StringVar.get() works even after widget is gone
            vid = voice_id_by_display.get(disp)
            if vid:
                mapping[key] = vid
        # Fill any gaps from the auto-assignment
        for k, v in self._assignment.mapping.items():
            mapping.setdefault(k, v)
        return Assignment(mapping=mapping, voices_by_id=voices_by_id)


# ── SCREEN 4: Generate ────────────────────────────────────────────────────────

class GenerateScreen(tk.Frame):
    def __init__(self, parent, script: script_parser.Script,
                 output_dir: str, on_change_output, on_back=None, **kw):
        super().__init__(parent, bg=BG0, **kw)
        self._script = script
        self._on_back = on_back or (lambda: None)
        self._output_dir = output_dir
        self._on_change_output = on_change_output
        self._cancel_flag = False
        self._worker: Optional[threading.Thread] = None
        self._progress_queue: queue.Queue = queue.Queue()
        self._scene_progress: Dict[int, float] = {}
        self._build()

    def _build(self):
        self.rowconfigure(0, weight=1)
        self.columnconfigure(0, weight=1)
        self.columnconfigure(1, weight=0)

        # ── Main: controls + log ─────────────────────────────────────────
        main = tk.Frame(self, bg=BG0)
        main.grid(row=0, column=0, sticky="nsew")
        main.rowconfigure(1, weight=1)
        main.columnconfigure(0, weight=1)

        # Controls bar
        ctrl = tk.Frame(main, bg=BG1,
                        highlightbackground=BORDER, highlightthickness=1)
        ctrl.grid(row=0, column=0, sticky="ew")

        ctrl_inner = tk.Frame(ctrl, bg=BG1)
        ctrl_inner.pack(fill="x", padx=20, pady=10)

        # ── Pack action buttons FIRST so expand=True on the folder row
        #    doesn't steal the whole cavity (Tkinter pack bug on macOS).
        self.gen_btn = AccentButton(
            ctrl_inner, text="▶  Generate Audio",
            command=self._start_generation)
        self.gen_btn.pack(side="right", padx=(12, 0))

        self.cancel_btn = GhostButton(
            ctrl_inner, text="Cancel",
            command=self._cancel)
        self.cancel_btn.pack(side="right", padx=(0, 4))
        self.cancel_btn.configure(state="disabled")

        _link_btn(ctrl_inner, "← Back", self._on_back,
                  bg=BG1, fg=TEXT2).pack(side="right", padx=(0, 8))

        # Output folder — packed AFTER buttons so it fills remaining space
        out_grp = tk.Frame(ctrl_inner, bg=BG1)
        out_grp.pack(side="left", fill="x", expand=True)
        tk.Label(out_grp, text="OUTPUT FOLDER",
                 font=(FONT_MONO, 9), fg=TEXT3, bg=BG1).pack(anchor="w")
        out_row = tk.Frame(out_grp, bg=BG2,
                           highlightbackground=BORDER, highlightthickness=1)
        out_row.pack(fill="x", pady=(4, 0), ipadx=8, ipady=5)
        self.out_label = tk.Label(
            out_row, text=self._output_dir or "Not set",
            font=(FONT_MONO, 10), fg=TEXT1, bg=BG2, anchor="w")
        self.out_label.pack(side="left", fill="x", expand=True)
        _link_btn(out_row, "Change", self._on_change_output,
                  bg=BG2, fg=ACCENT,
                  font=(FONT_SANS, 11)).pack(side="right", padx=(4, 0))

        # Log area
        log_frame = tk.Frame(main, bg=BG0)
        log_frame.grid(row=1, column=0, sticky="nsew")
        log_frame.rowconfigure(0, weight=1)
        log_frame.columnconfigure(0, weight=1)

        self.log = tk.Text(
            log_frame, bg=BG0, fg=TEXT1,
            relief="flat", bd=0, padx=24, pady=12,
            font=(FONT_MONO, 11), wrap="word",
            state="disabled",
            selectbackground=BG3,
        )
        log_sb = ttk.Scrollbar(log_frame, command=self.log.yview)
        self.log.configure(yscrollcommand=log_sb.set)
        self.log.grid(row=0, column=0, sticky="nsew")
        log_sb.grid(row=0, column=1, sticky="ns")

        # Log tags
        self.log.tag_configure("time", foreground=TEXT3)
        self.log.tag_configure("info", foreground=TEXT2)
        self.log.tag_configure("success", foreground=GREEN)
        self.log.tag_configure("warn", foreground=ACCENT)
        self.log.tag_configure("active", foreground=TEXT0)
        self.log.tag_configure("error", foreground="#e05555")

        # ── Right: scene sidebar ──────────────────────────────────────────
        right = tk.Frame(self, bg=BG1, width=300,
                         highlightbackground=BORDER, highlightthickness=1)
        right.grid(row=0, column=1, sticky="nsew")
        right.pack_propagate(False)
        right.rowconfigure(1, weight=1)
        right.columnconfigure(0, weight=1)

        tk.Label(right, text="Scenes",
                 font=(FONT_SANS, 13, "bold"), fg=TEXT0, bg=BG1).grid(
            row=0, column=0, sticky="w", padx=16, pady=(14, 4))

        scene_scroll = tk.Frame(right, bg=BG1)
        scene_scroll.grid(row=1, column=0, sticky="nsew")
        scene_scroll.rowconfigure(0, weight=1)
        scene_scroll.columnconfigure(0, weight=1)

        sc_canvas = tk.Canvas(scene_scroll, bg=BG1, highlightthickness=0)
        sc_vsb = ttk.Scrollbar(scene_scroll, orient="vertical",
                               command=sc_canvas.yview)
        sc_canvas.configure(yscrollcommand=sc_vsb.set)
        sc_canvas.grid(row=0, column=0, sticky="nsew")
        sc_vsb.grid(row=0, column=1, sticky="ns")

        self.scene_body = tk.Frame(sc_canvas, bg=BG1)
        sc_win = sc_canvas.create_window((0, 0), window=self.scene_body, anchor="nw")

        def _sc_resize(e):
            sc_canvas.configure(scrollregion=sc_canvas.bbox("all"))
        self.scene_body.bind("<Configure>", _sc_resize)

        def _sc_canvas_resize(e):
            sc_canvas.itemconfigure(sc_win, width=e.width)
        sc_canvas.bind("<Configure>", _sc_canvas_resize)

        self._build_scene_list()
        self._log_line("Ready. Click Generate Audio to begin.", "info")

    def _build_scene_list(self):
        for w in self.scene_body.winfo_children():
            w.destroy()
        self._scene_frames: Dict[int, Dict] = {}

        for sc in self._script.scenes:
            pct = self._scene_progress.get(sc.number, 0.0)
            done = pct >= 1.0
            active = 0 < pct < 1.0

            card = tk.Frame(self.scene_body, bg=BG2,
                            highlightbackground=BORDER, highlightthickness=1)
            card.pack(fill="x", padx=8, pady=4, ipadx=8, ipady=6)

            # Status icon
            if done:
                icon_bg, icon_char = GREEN, "✓"
            elif active:
                icon_bg, icon_char = ACCENT, "●"
            else:
                icon_bg, icon_char = BG3, "○"

            icon = tk.Label(card, text=icon_char,
                            font=(FONT_SANS, 11), fg="#fff" if done or active else TEXT3,
                            bg=icon_bg, width=2, anchor="center")
            icon.pack(side="left", padx=(0, 8))

            info = tk.Frame(card, bg=BG2)
            info.pack(side="left", fill="x", expand=True)

            tk.Label(info, text=sc.title,
                     font=(FONT_SANS, 11, "bold" if active else "normal"),
                     fg=TEXT0, bg=BG2, anchor="w").pack(fill="x")

            status_text = ("Done" if done
                           else f"{int(pct*100)}%" if active
                           else "Queued")
            status_lbl = tk.Label(info, text=status_text,
                                  font=(FONT_SANS, 10), fg=TEXT2, bg=BG2,
                                  anchor="w")
            status_lbl.pack(fill="x")

            # Progress bar
            if active:
                prog_bg = tk.Frame(card, bg=BG4, height=3)
                prog_bg.pack(fill="x", pady=(4, 0), side="bottom")
                fill_w = int(pct * 260)
                tk.Frame(prog_bg, bg=ACCENT, height=3,
                         width=fill_w).pack(side="left")

            self._scene_frames[sc.number] = {
                "card": card,
                "icon": icon,
                "status_lbl": status_lbl,
            }

    def _log_line(self, text: str, tag: str = ""):
        self.log.configure(state="normal")
        now = datetime.now().strftime("%M:%S")
        self.log.insert("end", f"{now}  ", "time")
        if tag == "success":
            icon = "✓  "
        elif tag == "active":
            icon = "●  "
        elif tag == "warn":
            icon = "!  "
        elif tag == "error":
            icon = "✗  "
        else:
            icon = "   "
        self.log.insert("end", icon + text + "\n", tag or "info")
        self.log.configure(state="disabled")
        self.log.see("end")

    def _start_generation(self):
        self._log_line("Starting generation…", "active")

    def _cancel(self):
        self._cancel_flag = True

    def update_output_dir(self, path: str):
        self._output_dir = path
        if hasattr(self, "out_label"):
            self.out_label.configure(text=path or "Not set")

    def run_generation(self, engine, assignment: Assignment,
                       cancel_check, progress_cb):
        """Called by App when ready to start."""
        if not self._output_dir:
            messagebox.showinfo("Need a folder", "Choose an output folder first.")
            return
        self._cancel_flag = False
        self.gen_btn.configure(state="disabled")
        self.cancel_btn.configure(state="normal")
        self._scene_progress.clear()
        self._build_scene_list()

        def worker():
            t0 = time.time()
            try:
                res = generate_script(
                    script=self._script,
                    engine=engine,
                    assignment=assignment,
                    output_dir=self._output_dir,
                    progress_cb=progress_cb,
                    cancel_check=cancel_check,
                )
                self._progress_queue.put(("done", (res, time.time() - t0)))
            except Exception as e:
                self._progress_queue.put(("error", (str(e), traceback.format_exc())))

        self._worker = threading.Thread(target=worker, daemon=True)
        self._worker.start()

    def handle_progress(self, p: GenerationProgress):
        if p.element_index >= 0:
            frac = (p.element_index + 1) / max(p.total_elements_in_scene, 1)
            self._scene_progress[self._script.scenes[p.scene_index].number] = frac
            self._build_scene_list()
        if p.message:
            tag = ("success" if "✓" in p.message
                   else "warn" if "warn" in p.message.lower()
                   else "info")
            self._log_line(p.message, tag)

    def handle_done(self, result, seconds: float):
        self.gen_btn.configure(state="normal", text="✓  Open Output Folder",
                               command=self._open_output)
        self.cancel_btn.configure(state="disabled")
        for sc in self._script.scenes:
            self._scene_progress[sc.number] = 1.0
        self._build_scene_list()
        n = len(result.files)
        self._log_line(
            f"Done — {n} scene file{'s' if n != 1 else ''} in "
            f"{_fmt_duration(seconds)}.", "success")
        if result.errors:
            for err in result.errors:
                self._log_line("ERROR: " + err, "error")

    def handle_error(self, msg: str, tb: str):
        self.gen_btn.configure(state="normal")
        self.cancel_btn.configure(state="disabled")
        self._log_line("ERROR: " + msg, "error")
        self._log_line(tb, "error")

    def _open_output(self):
        if self._output_dir and platform.system() == "Darwin":
            import subprocess
            subprocess.Popen(["open", self._output_dir])


# ── Utilities ──────────────────────────────────────────────────────────────

def _fmt_duration(seconds: float) -> str:
    seconds = int(seconds)
    if seconds < 60:
        return f"{seconds}s"
    m, s = divmod(seconds, 60)
    return f"{m}m {s}s" if m < 60 else f"{m//60}h {m%60}m"


# ── Root App ──────────────────────────────────────────────────────────────────

class App(tk.Tk):
    def __init__(self):
        _dbg("Tk init")
        super().__init__()
        _dbg(f"Tk {self.tk.call('info','patchlevel')} / Python {sys.version.split()[0]}")

        self.title(APP_TITLE)
        self.geometry("960x720")
        self.minsize(800, 580)
        self.configure(bg=BG0)

        # State
        self.script: Optional[script_parser.Script] = None
        self.pdf_path: Optional[str] = None
        self.output_dir: Optional[str] = None
        self.engine_voices: List[tts_engines.VoiceInfo] = []
        self.assignment: Optional[Assignment] = None
        self._step = 1
        self._cancel_flag = False
        self._progress_queue: queue.Queue = queue.Queue()
        self._recent_files: List[str] = self._load_recent()

        # ttk dark-ish style for comboboxes + scrollbars
        style = ttk.Style(self)
        try:
            style.theme_use("clam")
        except Exception:
            pass
        # Voice pickers now use tk.OptionMenu (not ttk.Combobox) — no Combobox
        # style needed.  Just darken the scrollbars.
        style.configure("TScrollbar",
                        background=BG3, troughcolor=BG1,
                        arrowcolor=TEXT2, borderwidth=0)
        style.map("TScrollbar",
                  background=[("active", BG4)])

        try:
            self._build_ui()
        except Exception:
            _dbg("FATAL during _build_ui:\n" + traceback.format_exc())
            raise

        self._load_engine_voices()
        _dbg("startup complete")

    # ── Layout ────────────────────────────────────────────────────────────

    def _build_ui(self):
        # Title bar
        tbar = tk.Frame(self, bg=BG1,
                        highlightbackground=BORDER, highlightthickness=1)
        tbar.pack(fill="x")
        # Traffic lights (cosmetic)
        tl_frame = tk.Frame(tbar, bg=BG1)
        tl_frame.pack(side="left", padx=12, pady=10)
        for color in ("#ff5f57", "#febc2e", "#28c840"):
            tk.Canvas(tl_frame, width=12, height=12, bg=BG1,
                      highlightthickness=0).pack(side="left", padx=3)
            # Draw filled circles
            c = tl_frame.winfo_children()[-1]
            c.create_oval(1, 1, 11, 11, fill=color, outline="")
        # Title label
        self.title_label = tk.Label(
            tbar, text=APP_TITLE,
            font=(FONT_SANS, 13), fg=TEXT1, bg=BG1)
        self.title_label.pack(side="left", expand=True)

        # Step nav (hidden on import screen)
        self.step_nav = StepNav(self, current_step=1,
                                go_to_step=self._go_to_step)
        # (packed dynamically)

        # Content area
        self.content = tk.Frame(self, bg=BG0)
        self.content.pack(fill="both", expand=True)
        self.content.rowconfigure(0, weight=1)
        self.content.columnconfigure(0, weight=1)

        self._show_step(1)

    def _show_step(self, step: int):
        self._step = step

        # Update step nav visibility and state
        if step > 1:
            self.step_nav.update_step(step)
            if not self.step_nav.winfo_ismapped():
                self.step_nav.pack(fill="x", after=self.title_label.master)
        else:
            if self.step_nav.winfo_ismapped():
                self.step_nav.pack_forget()

        # Update title
        if self.script and step > 1:
            self.title_label.configure(text=self.script.title)
        else:
            self.title_label.configure(text=APP_TITLE)

        # Snapshot cast-screen assignment before destroying it so step 4 can
        # read it without touching destroyed Tcl widget commands.
        if hasattr(self, "_cast_screen") and step != 3:
            try:
                self.assignment = self._cast_screen.resolved_assignment()
            except Exception:
                pass

        # Destroy old screen
        for w in self.content.winfo_children():
            w.destroy()

        if step == 1:
            ImportScreen(
                self.content,
                on_choose_pdf=self._on_choose_pdf,
                recent_files=self._recent_files,
            ).grid(row=0, column=0, sticky="nsew")

        elif step == 2:
            ReviewScreen(
                self.content,
                script=self.script,
                pdf_path=self.pdf_path,
                on_next=lambda: self._show_step(3),
                on_back=lambda: self._show_step(1),
            ).grid(row=0, column=0, sticky="nsew")

        elif step == 3:
            self._cast_screen = CastScreen(
                self.content,
                script=self.script,
                engine_voices=self.engine_voices,
                assignment=self.assignment,
                on_engine_change=self._on_engine_change,
                on_next=lambda: self._show_step(4),
                on_back=lambda: self._show_step(2),
            )
            self._cast_screen.grid(row=0, column=0, sticky="nsew")

        elif step == 4:
            if not self.output_dir and self.pdf_path:
                self.output_dir = str(
                    Path(self.pdf_path).parent
                    / (Path(self.pdf_path).stem + " - audio drama"))
            self._gen_screen = GenerateScreen(
                self.content,
                script=self.script,
                output_dir=self.output_dir or "",
                on_change_output=self._on_choose_output,
                on_back=lambda: self._show_step(3),
            )
            self._gen_screen.grid(row=0, column=0, sticky="nsew")
            # Wire gen/cancel directly into app-level callbacks
            self._gen_screen.gen_btn.configure(command=self._on_generate)
            self._gen_screen.cancel_btn.configure(command=self._on_cancel)

    def _go_to_step(self, step: int):
        if step <= self._step:
            self._show_step(step)

    # ── File pickers ──────────────────────────────────────────────────────

    def _on_choose_pdf(self, path: Optional[str] = None):
        if path is None:
            path = filedialog.askopenfilename(
                title="Choose a script PDF",
                filetypes=[("PDF files", "*.pdf"), ("All files", "*.*")])
        if not path:
            return
        self.pdf_path = path
        self._add_recent(path)
        self._set_parsing_status()
        self.update_idletasks()
        try:
            self.script = script_parser.parse_pdf(path)
        except Exception as e:
            _dbg("parse error:\n" + traceback.format_exc())
            messagebox.showerror("Could not parse PDF", str(e))
            return
        _dbg(f"parsed {len(self.script.scenes)} scenes, "
             f"{len(self.script.characters)} characters")
        self._reassign_voices()
        self._show_step(2)

    def _on_choose_output(self):
        initial = str(Path(self.pdf_path).parent) if self.pdf_path else str(Path.home())
        path = filedialog.askdirectory(
            title="Choose output folder", initialdir=initial)
        if not path:
            return
        self.output_dir = path
        if hasattr(self, "_gen_screen"):
            self._gen_screen.update_output_dir(path)

    # ── Engine / voice management ─────────────────────────────────────────

    def _on_engine_change(self, engine_id: str, api_key: str):
        self._load_engine_voices(engine_id, api_key)
        if self.script:
            self._reassign_voices()

    def _load_engine_voices(self, engine_id: str = "mac", api_key: str = ""):
        if engine_id == "openai":
            self.engine_voices = tts_engines.OpenAIEngine().list_voices()
        else:
            v = tts_engines.MacSayEngine().list_voices()
            if not v:
                v = [
                    tts_engines.VoiceInfo("Ava (Premium)", "Ava", "F", "en_US"),
                    tts_engines.VoiceInfo("Tom (Premium)", "Tom", "M", "en_US"),
                    tts_engines.VoiceInfo("Samantha", "Samantha", "F", "en_US"),
                    tts_engines.VoiceInfo("Daniel", "Daniel", "M", "en_GB"),
                ]
            self.engine_voices = v
        _dbg(f"loaded {len(self.engine_voices)} voices for {engine_id}")

    def _reassign_voices(self):
        if self.script:
            self.assignment = auto_assign(self.script.characters, self.engine_voices)

    def _build_engine_for_run(self) -> tts_engines.TTSEngine:
        if hasattr(self, "_cast_screen"):
            engine_id = self._cast_screen.engine_var.get()
            api_key = self._cast_screen.openai_key_var.get().strip()
        else:
            engine_id = "mac"
            api_key = ""
        if engine_id == "openai":
            if not api_key:
                raise RuntimeError(
                    "OpenAI API key required. Paste your key in the Cast Voices screen.")
            q = getattr(self._cast_screen, "openai_quality_var", None)
            model = "tts-1-hd" if q and "hd" in q.get() else "tts-1"
            return tts_engines.OpenAIEngine(api_key=api_key, model=model)
        return tts_engines.MacSayEngine()

    # ── Generation ────────────────────────────────────────────────────────

    def _on_generate(self):
        if not self.script:
            messagebox.showinfo("Need a PDF", "Load a script first.")
            return
        if not self.output_dir:
            self._on_choose_output()
            if not self.output_dir:
                return
        try:
            engine = self._build_engine_for_run()
        except Exception as e:
            messagebox.showerror("Engine setup failed", str(e))
            return
        if not engine.is_available():
            messagebox.showerror(
                "Engine unavailable",
                f"The '{engine.name}' engine isn't available.\n\n"
                "If you chose OpenAI, check your API key.")
            return

        # self.assignment was snapshotted in _show_step before CastScreen was
        # destroyed — safe to use even though the Combobox Tcl commands are gone.
        assignment = self.assignment
        os.makedirs(self.output_dir, exist_ok=True)

        self._cancel_flag = False

        def cb(p: GenerationProgress):
            self._progress_queue.put(("progress", p))

        def cancel_check():
            return self._cancel_flag

        self._gen_screen.run_generation(engine, assignment, cancel_check, cb)
        self._poll_progress()

    def _on_cancel(self):
        self._cancel_flag = True

    def _poll_progress(self):
        try:
            while True:
                kind, payload = self._progress_queue.get_nowait()
                if kind == "progress":
                    self._gen_screen.handle_progress(payload)
                elif kind == "done":
                    res, secs = payload
                    self._gen_screen.handle_done(res, secs)
                    return
                elif kind == "error":
                    msg, tb = payload
                    self._gen_screen.handle_error(msg, tb)
                    return
        except queue.Empty:
            pass
        if hasattr(self, "_gen_screen"):
            self.after(120, self._poll_progress)

    # ── Status helpers ────────────────────────────────────────────────────

    def _set_parsing_status(self):
        # Show a temporary parsing message in place of the import screen
        for w in self.content.winfo_children():
            w.destroy()
        frame = tk.Frame(self.content, bg=BG0)
        frame.grid(row=0, column=0)
        tk.Label(frame, text="Parsing script…",
                 font=(FONT_SANS, 16), fg=TEXT2, bg=BG0).pack(pady=40)

    # ── Recent files ──────────────────────────────────────────────────────

    def _recent_path(self) -> str:
        return str(Path.home() / ".script_to_audio_recent.txt")

    def _load_recent(self) -> List[str]:
        try:
            with open(self._recent_path()) as f:
                return [l.strip() for l in f if l.strip()]
        except Exception:
            return []

    def _add_recent(self, path: str):
        paths = self._recent_files
        if path in paths:
            paths.remove(path)
        paths.append(path)
        self._recent_files = paths[-10:]
        try:
            with open(self._recent_path(), "w") as f:
                f.write("\n".join(self._recent_files))
        except Exception:
            pass


BUILD_TAG = "dark-wizard-v1"


def main():
    os.environ.setdefault("TK_SILENCE_DEPRECATION", "1")
    print(f"[ui] build tag: {BUILD_TAG}", file=sys.stderr, flush=True)
    try:
        app = App()
        app.mainloop()
    except Exception:
        traceback.print_exc(file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
