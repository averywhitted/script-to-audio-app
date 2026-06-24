#!/usr/bin/env python3
"""gen_test_script.py — generate a test PDF play script with all parser features.

Covers every feature the Table Read parser exercises:
  • Cast section (gender-first format)
  • Regular sequential dialog (multiple speakers)
  • Parentheticals (in-speech and standalone)
  • Stage directions
  • DR. prefix character (DR. CHEN)
  • Scene boundaries (SCENE N format)
  • Two-column simultaneous overlap (columns physically side-by-side in PDF)
  • Slash-cue chorus overlap (MARA/JOEL)
  • Ampersand-cue chorus (MARA & JOEL)

Output:  scripts/test_script.pdf

Run:
    python scripts/gen_test_script.py
"""
from __future__ import annotations

import sys
from pathlib import Path

# Ensure we can find the backend if needed
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "backend"))

from fpdf import FPDF, XPos, YPos

# ---------------------------------------------------------------------------
# Page geometry (US Letter)
# ---------------------------------------------------------------------------
PAGE_W = 216   # mm  (≈ 612 pt)
PAGE_H = 279   # mm  (≈ 792 pt)

LEFT_MARGIN  = 25   # mm  left text margin
RIGHT_MARGIN = 25   # mm
TOP_MARGIN   = 25   # mm
LINE_H       = 7    # mm  normal line height
PARA_GAP     = 4    # mm  extra gap between paragraphs / elements

# Two-column overlap layout
COL_L_X = LEFT_MARGIN          # left column starts here
COL_R_X = PAGE_W / 2 + 5       # right column starts here (well past centre)
COL_W   = PAGE_W / 2 - LEFT_MARGIN - 10  # each column is ~80 mm wide


def _clean(text: str) -> str:
    """Replace Unicode punctuation with ASCII equivalents safe for Courier."""
    return (text
            .replace("—", "--")   # em dash
            .replace("–", "-")    # en dash
            .replace("‘", "'").replace("’", "'")
            .replace("“", '"').replace("”", '"')
            .replace("…", "..."))


def make_pdf() -> FPDF:
    pdf = FPDF(orientation="P", unit="mm", format="Letter")
    pdf.set_margins(LEFT_MARGIN, TOP_MARGIN, RIGHT_MARGIN)
    pdf.set_auto_page_break(auto=True, margin=20)
    pdf.set_font("Courier", size=12)
    return pdf


def cue(pdf: FPDF, name: str) -> None:
    """All-caps speaker cue on its own line."""
    pdf.ln(PARA_GAP)
    pdf.set_font("Courier", "B", 12)
    pdf.set_x(LEFT_MARGIN)
    pdf.cell(0, LINE_H, _clean(name),
             new_x=XPos.LMARGIN, new_y=YPos.NEXT)
    pdf.set_font("Courier", size=12)


def dialog(pdf: FPDF, text: str) -> None:
    """Wrapped dialog text."""
    pdf.set_x(LEFT_MARGIN)
    pdf.multi_cell(PAGE_W - LEFT_MARGIN - RIGHT_MARGIN, LINE_H, _clean(text))


def paren(pdf: FPDF, text: str) -> None:
    """Parenthetical stage direction (indented)."""
    pdf.set_x(LEFT_MARGIN + 20)
    pdf.set_font("Courier", "I", 12)
    pdf.cell(0, LINE_H, _clean(f"({text})"),
             new_x=XPos.LMARGIN, new_y=YPos.NEXT)
    pdf.set_font("Courier", size=12)


def stage_dir(pdf: FPDF, text: str) -> None:
    """Full-width stage direction."""
    pdf.ln(PARA_GAP)
    pdf.set_x(LEFT_MARGIN)
    pdf.set_font("Courier", "I", 12)
    pdf.multi_cell(PAGE_W - LEFT_MARGIN - RIGHT_MARGIN, LINE_H, _clean(text))
    pdf.set_font("Courier", size=12)
    pdf.ln(PARA_GAP)


def scene(pdf: FPDF, title: str) -> None:
    """Scene header."""
    pdf.ln(PARA_GAP * 2)
    pdf.set_font("Courier", "B", 12)
    pdf.set_x(LEFT_MARGIN)
    pdf.cell(0, LINE_H, _clean(title),
             new_x=XPos.LMARGIN, new_y=YPos.NEXT)
    pdf.set_font("Courier", size=12)
    pdf.ln(PARA_GAP)


def blank(pdf: FPDF, n: int = 1) -> None:
    pdf.ln(LINE_H * n)


# ---------------------------------------------------------------------------
# Two-column overlap helpers
# ---------------------------------------------------------------------------

def _ensure_space(pdf: FPDF, height_mm: float) -> None:
    """Force a manual page break if *height_mm* won't fit on the current page.

    This prevents fpdf2's auto-page-break from firing *inside* a two-column
    ``cell()`` call, which corrupts the shared ``y`` coordinate used for the
    matching column cell.
    """
    if pdf.get_y() + height_mm > pdf.h - pdf.b_margin:
        pdf.add_page()


def overlap_cue(pdf: FPDF, left_name: str, right_name: str) -> None:
    """Print both speaker cues side-by-side on the same line."""
    pdf.ln(PARA_GAP)
    # Guard against auto-page-break happening inside the first cell() call,
    # which would corrupt the y coordinate shared by both column cells.
    _ensure_space(pdf, LINE_H)
    pdf.set_font("Courier", "B", 12)
    y = pdf.get_y()
    pdf.set_xy(COL_L_X, y)
    pdf.cell(COL_W, LINE_H, _clean(left_name), new_x=XPos.RIGHT, new_y=YPos.TOP)
    pdf.set_xy(COL_R_X, y)
    pdf.cell(COL_W, LINE_H, _clean(right_name),
             new_x=XPos.LMARGIN, new_y=YPos.NEXT)
    pdf.set_font("Courier", size=12)


def overlap_dialog_line(pdf: FPDF, left_text: str, right_text: str) -> None:
    """Print one row of two-column dialog. Both cells at the same y."""
    # Same guard: force page break before capturing y so both columns share it.
    _ensure_space(pdf, LINE_H)
    y = pdf.get_y()
    pdf.set_xy(COL_L_X, y)
    pdf.cell(COL_W, LINE_H, _clean(left_text), new_x=XPos.RIGHT, new_y=YPos.TOP)
    pdf.set_xy(COL_R_X, y)
    pdf.cell(COL_W, LINE_H, _clean(right_text),
             new_x=XPos.LMARGIN, new_y=YPos.NEXT)


def overlap_block(pdf: FPDF, left_lines: list[str], right_lines: list[str]) -> None:
    """Print a block of two-column dialog rows, padding the shorter side."""
    n = max(len(left_lines), len(right_lines))
    for i in range(n):
        l = left_lines[i] if i < len(left_lines) else ""
        r = right_lines[i] if i < len(right_lines) else ""
        overlap_dialog_line(pdf, l, r)


# ---------------------------------------------------------------------------
# Build the script
# ---------------------------------------------------------------------------

def build(out_path: str) -> None:
    pdf = make_pdf()
    pdf.add_page()

    # ── Title ────────────────────────────────────────────────────────────────
    pdf.set_font("Courier", "B", 14)
    pdf.cell(0, 10, "HOLD MUSIC", align="C",
             new_x=XPos.LMARGIN, new_y=YPos.NEXT)
    pdf.set_font("Courier", size=12)
    pdf.cell(0, LINE_H, "A Play in One Act", align="C",
             new_x=XPos.LMARGIN, new_y=YPos.NEXT)
    pdf.ln(LINE_H * 2)

    # ── Cast of Characters ───────────────────────────────────────────────────
    pdf.set_font("Courier", "B", 12)
    pdf.cell(0, LINE_H, "CAST OF CHARACTERS",
             new_x=XPos.LMARGIN, new_y=YPos.NEXT)
    pdf.set_font("Courier", size=12)
    pdf.ln(LINE_H)

    cast = [
        "MARA  Female. 30s. Persistent.",
        "JOEL  Male. 30s. Mara's partner.",
        "DR. CHEN  Female. 50s. A therapist.",
        "AUTOMATED VOICE  Non-binary. A phone system.",
    ]
    for line in cast:
        pdf.set_x(LEFT_MARGIN + 5)
        pdf.cell(0, LINE_H, _clean(line),
                 new_x=XPos.LMARGIN, new_y=YPos.NEXT)
    pdf.ln(LINE_H)

    # ── SCENE ONE: Regular sequential dialog ─────────────────────────────────
    scene(pdf, "SCENE ONE")

    stage_dir(pdf, "A small apartment. MARA sits at a kitchen table, phone in hand. JOEL leans against the counter.")

    cue(pdf, "MARA")
    dialog(pdf, "I've been on hold for forty minutes. Forty.")

    blank(pdf)

    cue(pdf, "JOEL")
    dialog(pdf, "You should just hang up and call back.")

    blank(pdf)

    cue(pdf, "MARA")
    paren(pdf, "not looking up")
    dialog(pdf, "That resets the queue. I lose my place. I've done this before, Joel.")

    blank(pdf)

    cue(pdf, "JOEL")
    dialog(pdf, "Right. Sorry.")
    paren(pdf, "He pours himself a glass of water.")
    dialog(pdf, "Do you want anything while you wait?")

    blank(pdf)

    cue(pdf, "MARA")
    dialog(pdf, "I want them to answer.")

    blank(pdf)

    stage_dir(pdf, "A beat. The hold music plays tinnily from the phone speaker.")

    # ── SCENE TWO: DR. CHEN and parentheticals ───────────────────────────────
    scene(pdf, "SCENE TWO")

    stage_dir(pdf, "DR. CHEN's office. Sparse, calm. MARA sits across from her.")

    cue(pdf, "DR. CHEN")
    dialog(pdf, "And how long has this been going on?")

    blank(pdf)

    cue(pdf, "MARA")
    dialog(pdf, "The hold music? Or the general feeling that I'm talking into a void and no one will ever pick up?")

    blank(pdf)

    cue(pdf, "DR. CHEN")
    paren(pdf, "making a note")
    dialog(pdf, "Both, if you'd like.")

    blank(pdf)

    cue(pdf, "MARA")
    dialog(pdf, "Six months. Maybe longer. It started with the insurance claim. Then the bank. Then the — I don't know. Everything became a phone call.")

    blank(pdf)

    stage_dir(pdf, "DR. CHEN sets down her pen.")

    cue(pdf, "DR. CHEN")
    dialog(pdf, "Mara. I want you to notice something. You came here today. You made an appointment. A person answered.")

    blank(pdf)

    cue(pdf, "MARA")
    paren(pdf, "quietly")
    dialog(pdf, "Your receptionist took three tries.")

    blank(pdf)

    cue(pdf, "DR. CHEN")
    paren(pdf, "a small smile")
    dialog(pdf, "Fair.")

    blank(pdf)

    # ── SCENE THREE: Slash and ampersand chorus overlaps ─────────────────────
    scene(pdf, "SCENE THREE")

    stage_dir(pdf, "The apartment again. MARA and JOEL, together.")

    cue(pdf, "JOEL")
    dialog(pdf, "Okay. New plan. I call. You stay on hold. We cover twice the ground.")

    blank(pdf)

    cue(pdf, "MARA")
    dialog(pdf, "What if they answer mine while you're mid-sentence on yours?")

    blank(pdf)

    cue(pdf, "JOEL")
    dialog(pdf, "Then we hang up whichever one didn't work.")

    blank(pdf)

    stage_dir(pdf, "They look at each other. They both start dialing at the same time.")

    # Slash chorus cue
    cue(pdf, "MARA/JOEL")
    dialog(pdf, "Hello, yes, I'm calling about —")

    blank(pdf)

    stage_dir(pdf, "They stop. Look at each other. Try again.")

    # Ampersand chorus cue
    cue(pdf, "MARA & JOEL")
    dialog(pdf, "Sorry. Go ahead.")

    blank(pdf)

    stage_dir(pdf, "Another beat.")

    cue(pdf, "MARA")
    paren(pdf, "to Joel")
    dialog(pdf, "This isn't going to work.")

    blank(pdf)

    cue(pdf, "JOEL")
    dialog(pdf, "Probably not.")

    blank(pdf)

    # ── SCENE FOUR: Two-column simultaneous overlap ───────────────────────────
    scene(pdf, "SCENE FOUR")

    stage_dir(pdf, "MARA is finally connected. The AUTOMATED VOICE comes through the phone. They speak at the same time — the columns below indicate simultaneous speech.")

    # Two-column overlap block 1
    overlap_cue(pdf, "MARA", "AUTOMATED VOICE")
    overlap_block(pdf,
        left_lines=[
            "Yes, hi. I'm calling about",
            "claim number 4471-B. I",
            "submitted it six months ago.",
        ],
        right_lines=[
            "Thank you for calling. Your",
            "call is very important to us.",
            "Please hold.",
        ],
    )

    blank(pdf)

    stage_dir(pdf, "The hold music resumes. MARA doesn't hang up.")

    blank(pdf)

    # Second two-column overlap block — shorter, one side longer
    overlap_cue(pdf, "MARA", "AUTOMATED VOICE")
    overlap_block(pdf,
        left_lines=[
            "I'm still here. I just need",
            "someone to — hello?",
        ],
        right_lines=[
            "We're sorry. All representatives",
            "are currently assisting other",
            "customers. Your wait time is",
            "approximately forty minutes.",
        ],
    )

    blank(pdf)

    cue(pdf, "MARA")
    paren(pdf, "to herself")
    dialog(pdf, "Forty minutes.")

    blank(pdf)

    stage_dir(pdf, "She sits down. The hold music plays.")

    blank(pdf)

    # One more overlap — with a parenthetical in the middle of the overlap section
    stage_dir(pdf, "JOEL enters. MARA holds up a hand — don't say anything.")

    overlap_cue(pdf, "MARA", "AUTOMATED VOICE")
    overlap_block(pdf,
        left_lines=[
            "Did you just — was that a",
            "person? Hello?",
        ],
        right_lines=[
            "To repeat these options,",
            "press nine.",
        ],
    )

    blank(pdf)

    cue(pdf, "JOEL")
    dialog(pdf, "Should I —")

    blank(pdf)

    cue(pdf, "MARA")
    dialog(pdf, "Shh.")

    blank(pdf)

    # ── SCENE FIVE: Resolution ────────────────────────────────────────────────
    scene(pdf, "SCENE FIVE")

    cue(pdf, "AUTOMATED VOICE")
    dialog(pdf, "Thank you for your patience. A representative will be with you shortly.")

    blank(pdf)

    stage_dir(pdf, "A long pause. Then a click. A real human voice.")

    cue(pdf, "MARA")
    dialog(pdf, "Hello? Oh my god. Hi. Yes. Claim number 4471-B.")
    paren(pdf, "she stands up")
    dialog(pdf, "No — no, please don't put me on hold. I'm begging you.")

    blank(pdf)

    cue(pdf, "DR. CHEN")
    paren(pdf, "voice only, as if remembered")
    dialog(pdf, "You came here today. A person answered.")

    blank(pdf)

    cue(pdf, "MARA")
    paren(pdf, "into the phone, quietly")
    dialog(pdf, "Thank you. I'll wait.")

    blank(pdf)

    stage_dir(pdf, "The hold music returns. MARA sits back down. This time she almost smiles.")
    blank(pdf)
    stage_dir(pdf, "END OF PLAY")

    # ── Save ──────────────────────────────────────────────────────────────────
    pdf.output(out_path)
    print(f"Written: {out_path}")


if __name__ == "__main__":
    out = Path(__file__).resolve().parent / "test_script.pdf"
    build(str(out))
