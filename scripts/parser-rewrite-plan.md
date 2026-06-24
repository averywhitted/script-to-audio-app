# Parser Rewrite Plan — Block-Level Extraction with PyMuPDF

Branch: `parser-block-extraction`  
Base commit: `ca51a05` (v0.1.8 / build 10)

---

## Why we're doing this

The current parser (`backend/parser.py`) uses **pdfplumber** to extract individual words
with x/y coordinates, manually groups them into lines by y-position, then classifies each
line one at a time using a set of spatial rules (Rules 0–6).

This approach has a hard ceiling. The problems we kept hitting:

### 1. Post-parenthetical attribution bug
When a stage direction appears mid-speech:

```
JOSH
In Jesus name we pray.
(he bows his head)
And thanks for the food.
```

The parser sees the blank line after `(he bows his head)` and clears `pending_speaker`.
The next dialog line `"And thanks for the food."` gets attributed to nobody (null speaker)
or to the wrong character. Every attempt to fix this broke something else.

**Root cause:** classifying lines one at a time loses the surrounding context. We don't
"see" that Block A (dialog) → Block B (parenthetical) → Block C (same format as A) is a
single speech with an interruption.

### 2. Line merging mismatch
The parser merges consecutive dialog lines from the same speaker into one element.
The independent reference files (ground truth) have one element per PDF line.
These never match in count, making proper element-by-element testing impossible.

**Root cause:** we're working at line granularity. Multi-line speeches get merged after
the fact, and the merge logic is fragile.

### 3. Two-column layouts (e.g. Stereophonic)
pdfplumber reads words left-to-right across the whole page width. In a two-column
script, it interleaves columns: a word from column A, a word from column B, a word from
column A... producing garbage.

**Root cause:** pdfplumber has no concept of "this page has two distinct text columns."

### 4. Rules proliferation
Each new script format required adding more special-case rules. Rules interact with each
other in unexpected ways. The codebase had ~6 major rules plus multiple sub-rules,
correction passes, and frequency-analysis guards. Hard to reason about, hard to extend.

---

## The insight

The user observed: **text blocks are more semantically useful than individual words.**

A screenplay page has a natural block structure:
```
PAGE → TEXT BLOCK → TEXT FORMAT → TEXT
```

If we extract at the block level first, we can pattern-match on block relationships:

- SHORT block, ALL CAPS, right of center, followed by LONG mixed-case block below it
  → speaker cue + dialog (this pattern repeats 50 times → high confidence)
- Block that starts and ends with `(` `)`, sandwiched between two dialog blocks
  → parenthetical stage direction, both dialog blocks belong to the same speaker
- Two blocks with identical left-edge x, alternating left and right of center
  → two-column layout

This gives semantic meaning from structure, without needing to hardcode per-script rules.

---

## What we're replacing pdfplumber with

**PyMuPDF** (`fitz`) — a Python binding for the MuPDF library.

Key advantages:
- `page.get_text("dict")` returns the full hierarchy:
  `PAGE → BLOCK → LINE → SPAN → (text, font, bold, italic, size)`
- Blocks are rectangular regions of text that belong together. A multi-sentence speech
  is ONE block — not N separate lines. This eliminates the line-merging problem.
- Block detection handles multi-column layouts correctly (each column is separate blocks).
- 5–10× faster than pdfplumber on large PDFs.
- Still fully offline — no external API calls, no network required.

---

## New architecture

### Data structures (replacing `StructuredLine`)

```python
@dataclass
class TextSpan:
    text: str
    bold: bool
    italic: bool
    font: str
    size: float

@dataclass
class TextBlock:
    x0: float
    y0: float
    x1: float
    y1: float
    page: int
    lines: list[list[TextSpan]]   # block → lines → spans
    text: str                      # full concatenated text
    caps_ratio: float              # fraction of alpha chars that are uppercase
    center_x: float                # (x0 + x1) / 2
    width: float
    height: float
    line_count: int
    char_count: int
    starts_with_paren: bool
    ends_with_paren: bool
    is_italic: bool                # majority of chars are italic
    is_bold: bool
```

### Extraction (`_extract_blocks`)
Replaces `_extract_structured_lines`. Calls `page.get_text("dict")`, builds `TextBlock`
objects, skips image blocks, skips page-number-only blocks at page margins.

### Layout profiling (`_infer_layout_profile`)
Same concept as current frequency analysis but operating on blocks:
- Cluster blocks by (x_bucket, caps_ratio_bucket, width_bucket)
- Most frequent short+high-caps+right-x cluster → speaker cue cluster
- Most frequent long+low-caps+left-x cluster → dialog cluster
- Parenthetical blocks detected by content (starts+ends with parens), not position

### Classification (`_classify_blocks`)
Replaces `_classify_lines`. Classifies each block using:
1. Its own features (caps ratio, position, parens)
2. The features of the blocks immediately before and after it (context window)
3. The learned layout profile (cluster membership)

Context-aware rules:
- `(prev=speaker_cue, current=long+low-caps) → dialog attributed to prev speaker`
- `(prev=dialog[X], current=parenthetical, next=dialog-profile) → parenthetical mid-speech, next is still X`
- `(current=short+all-caps+right-x) → speaker_cue`
- `(current=starts+ends with paren) → parenthetical`
- `(current=all-caps+centered+bold) → scene_heading`

### Build script (`_build_script_from_blocks`)
Same as current `_build_script_from_classified` — groups classified blocks into scenes
and elements. Since blocks are already merged (multi-line speech = one block), the
merge step becomes trivial.

### Output
Identical: `Script → [Scene] → [Element(kind, speaker, text, overlap_cue)]`
No changes to anything downstream (audio_worker.py, Swift bridge, TTS pipeline).

---

## What this fixes

| Problem | Fix |
|---|---|
| Post-parenthetical attribution | Block context: `prev=dialog → paren → same-x-as-dialog` keeps speaker |
| Line merging mismatch | Blocks are already merged; ground truth and parser match naturally |
| Two-column layouts (Stereophonic) | PyMuPDF block detection separates columns |
| Rules proliferation | Replaced by profile-aware block classifier with context window |
| Page-break attribution | Still handled: look back for last speaker cue block |

---

## What this does NOT change

- `backend/audio_worker.py` — stdin/stdout JSON bridge, unchanged
- `backend/tts_engines.py` — TTS implementations, unchanged
- `backend/audio_pipeline.py` — scene orchestration, unchanged
- `backend/voice_assignment.py` — character→voice mapping, unchanged
- All Swift code — the JSON protocol is identical
- `requirements.txt` — add `pymupdf`, keep `pdfplumber` for now (parallel testing)

---

## Ground truth test infrastructure

We're also building **independent reference files** for 4 scripts that represent the
variety of screenplay formats we need to support:

| Script | Format characteristics |
|---|---|
| TheHarvest | Standard: dialog left, cues right, section headings, slash overlaps |
| KillFloor | Non-standard: cues and dialog share same x-column |
| NoneOfUs | Narrow column, two-character overlap cues |
| MercuryFur | Heavy stage directions, speaker cues at different x than usual |

These references are generated by `scripts/extract_independent.py` — a separate PDF
reader with NO dependency on parser.py — and stored in `Test PDFs/reference/{Name}_independent.json`.

The test in `backend/tests/test_reference.py` (`test_independent_attribution`) checks
that for every parser dialog element, the speaker matches what's independently verified
in the reference. This catches the original failure mode: "the parser produces output that
passes its own tests but is completely wrong."

As the block-level parser is built, the independent references become the primary
correctness check. The goal is full element-by-element comparison (kind + speaker + text)
once the block-level output and the independent reference share the same granularity.

---

## Implementation order

1. **Install PyMuPDF** and verify it extracts blocks correctly from each of the 4 test PDFs
2. **Write `_extract_blocks`** — replaces `_extract_structured_lines`
3. **Write `_infer_layout_profile`** — cluster blocks by position/caps/width
4. **Write `_classify_blocks`** — context-aware block classifier
5. **Write `_build_script_from_blocks`** — assemble final Script
6. **Wire into `parse_pdf()`** — keep old path behind a flag for parallel testing
7. **Run test suite** — all 7 reference tests must pass (or xfail for the same 3 as before)
8. **Update independent references** — with block-level output, update ground truth files
   to do full text comparison instead of sig-based approximation

---

## Known risks

- **PyMuPDF block detection on unusual PDFs** — some PDFs (especially scans or
  heavily-formatted ones) may produce blocks that don't align with our assumptions.
  Keep pdfplumber as a fallback initially.
- **Overlap cue detection** — the block model needs to handle slash-separated cues
  (`ADA / TOM / DENISE`) which appear as a single block at the speaker-cue x position.
- **Scene heading detection** — sluglines (`INT. KITCHEN - DAY`) need to be
  distinguished from regular stage directions; they're often centered or bold.
