"""features.py — the block → feature-vector contract.

Turns a ``TextBlock`` (see parser.py) into a fixed, ordered vector of numbers that
``ScriptElementClassifier`` consumes. This module is the boundary between "how we
read a PDF" and "how we classify what we read", and it exists so those two can be
replaced independently:

  * A future Swift/PDFKit extractor is *correct* iff it reproduces the vectors in
    ``ml/fixtures/{Name}_features.json`` for the same PDFs. That's the whole iOS
    portability story — no shared code required, just a shared contract.
  * The model can be retrained without touching extraction, and vice versa.

DESIGN RULE — every feature is document-relative or scale-free.
No raw coordinate ever reaches the model. A model weight learned against an
absolute x of 270 is a global constant in disguise, and global constants tuned on
one script are the documented cause of four failed parser rewrites (see CLAUDE.md's
parser protocol and memory `parser_audit_root_cause.md`). Positions are therefore
expressed as fractions of page width/height, or as signed offsets from the
document's own learned columns (``LayoutProfile.speaker_x`` / ``dialog_x`` /
``stage_dir_x``), which self-calibrate per document.

Two deliberate omissions:

  * No open-class vocabulary. The model never sees "which words", only structural
    properties of the text (length, caps, punctuation shape, closed-class pronoun
    person). Dialogue is not a vocabulary — "Hello" and "Wherefore art thou" are
    both dialogue — so a bag-of-words mostly learns character names and fails on
    the next script. It also keeps copyrighted script text out of a shipped model.
  * No predicted neighbour kind. Context features read only *observable*
    properties of adjacent blocks (caps ratio, cue-shaped text), never a
    neighbour's predicted label, which would force sequential decoding at
    inference time and let one bad call cascade down the page.

Bump FEATURE_SCHEMA_VERSION on ANY change to FEATURE_NAMES (order included) — the
golden fixtures and any trained model are only valid for the version they were
built against.
"""
from __future__ import annotations

import re
import statistics
from dataclasses import dataclass, asdict
from typing import Dict, List, Optional, Sequence

FEATURE_SCHEMA_VERSION = 1

# Closed-class pronoun sets. This is the one place semantics genuinely helps:
# "I can't believe you did that" (dialogue) and "She can't believe he did that"
# (stage direction) are structurally identical and differ only in grammatical
# person. Closed-class means the list is complete and generalises to any script,
# unlike an open vocabulary.
_FIRST_SECOND_PERSON = frozenset({
    "i", "me", "my", "mine", "myself", "im", "ive", "ill", "id",
    "we", "us", "our", "ours", "ourselves", "were", "weve",
    "you", "your", "yours", "yourself", "yourselves", "youre", "youve", "youll",
})
_THIRD_PERSON = frozenset({
    "he", "him", "his", "himself", "hes",
    "she", "her", "hers", "herself", "shes",
    "they", "them", "their", "theirs", "themselves", "theyre",
    "it", "its", "itself",
})

_WORD_RE = re.compile(r"[a-z']+")
_TERMINAL_PUNCT = (".", "!", "?", '."', '!"', '?"', ".'", "!'", "?'", "…")


@dataclass(frozen=True)
class DocumentContext:
    """Per-document normalisers, computed once so every block scales consistently."""
    page_width: float
    page_height: float
    median_font_size: float
    total_blocks: int

    @property
    def safe_width(self) -> float:
        return self.page_width if self.page_width > 1 else 612.0

    @property
    def safe_height(self) -> float:
        return self.page_height if self.page_height > 1 else 792.0

    @property
    def safe_font(self) -> float:
        return self.median_font_size if self.median_font_size > 0.1 else 12.0


def _block_font_size(block) -> float:
    """Character-weighted mean font size across a block's spans.

    Computed here rather than on TextBlock so this module can be added without
    modifying parser.py at all — Phase 1 then cannot regress the parser oracle.
    ``TextSpan.size`` is populated by the extractor but never otherwise consumed.
    """
    total_chars = 0
    weighted = 0.0
    for line in getattr(block, "lines", None) or []:
        for span in line:
            n = len(span.text)
            if n and span.size:
                weighted += span.size * n
                total_chars += n
    return weighted / total_chars if total_chars else 0.0


def build_document_context(blocks: Sequence, page_width: float) -> DocumentContext:
    """Derive per-document normalisers from the extracted blocks.

    page_height is inferred the same way parser.py infers page_width (max observed
    extent) rather than read from the PDF, so the value stays consistent whether
    the caller is PyMuPDF, pdfplumber, or a future PDFKit extractor.
    """
    sizes = [s for s in (_block_font_size(b) for b in blocks) if s > 0]
    y_max = max((b.y1 for b in blocks), default=0.0)
    return DocumentContext(
        page_width=page_width,
        # +36pt of bottom margin, mirroring the +90 pad used for width inference.
        page_height=y_max + 36.0 if y_max > 1 else 792.0,
        median_font_size=statistics.median(sizes) if sizes else 0.0,
        total_blocks=len(blocks),
    )


# Ordered feature names. THE ORDER IS PART OF THE CONTRACT — a model trained on
# this order will silently mispredict if it changes. Bump the schema version.
FEATURE_NAMES: tuple[str, ...] = (
    # -- geometry, normalised to page --
    "x0_norm", "x1_norm", "width_norm", "center_x_norm",
    "y0_norm", "y1_norm", "height_norm",
    # -- geometry, relative to the document's own learned columns --
    "x0_delta_speaker", "x0_delta_dialog", "x0_delta_stage_dir",
    "has_stage_dir_column", "near_cue_column", "near_dialog_column",
    # -- typography --
    "caps_ratio", "is_bold", "is_italic", "font_size_ratio",
    # -- shape --
    "line_count", "word_count", "char_count",
    "starts_with_paren", "ends_with_paren", "balanced_parens",
    "ends_with_terminal_punct", "is_all_caps",
    # -- structural regex flags (reusing parser.py's own patterns) --
    "matches_int_ext", "matches_act_scene", "matches_transition",
    "is_page_number", "has_vo_os", "has_contd", "has_slash_separator",
    # -- closed-class grammatical person --
    "first_second_person_ratio", "third_person_ratio",
    # -- document context --
    "text_repeat_ratio", "is_furniture",
    "x_column_density", "x_column_caps_avg",
    # -- observable neighbour context (never a predicted label) --
    "prev_caps_ratio", "prev_is_cue_shaped", "prev_is_blank_gap",
    "next_caps_ratio", "next_is_cue_shaped",
    # -- extractor-provided structural hints --
    "is_split_continuation", "is_cue_with_inline_paren",
)


@dataclass
class BlockFeatures:
    """One block's features. Field order mirrors FEATURE_NAMES."""
    x0_norm: float = 0.0
    x1_norm: float = 0.0
    width_norm: float = 0.0
    center_x_norm: float = 0.0
    y0_norm: float = 0.0
    y1_norm: float = 0.0
    height_norm: float = 0.0

    x0_delta_speaker: float = 0.0
    x0_delta_dialog: float = 0.0
    x0_delta_stage_dir: float = 0.0
    has_stage_dir_column: float = 0.0
    near_cue_column: float = 0.0
    near_dialog_column: float = 0.0

    caps_ratio: float = 0.0
    is_bold: float = 0.0
    is_italic: float = 0.0
    font_size_ratio: float = 1.0

    line_count: float = 0.0
    word_count: float = 0.0
    char_count: float = 0.0
    starts_with_paren: float = 0.0
    ends_with_paren: float = 0.0
    balanced_parens: float = 0.0
    ends_with_terminal_punct: float = 0.0
    is_all_caps: float = 0.0

    matches_int_ext: float = 0.0
    matches_act_scene: float = 0.0
    matches_transition: float = 0.0
    is_page_number: float = 0.0
    has_vo_os: float = 0.0
    has_contd: float = 0.0
    has_slash_separator: float = 0.0

    first_second_person_ratio: float = 0.0
    third_person_ratio: float = 0.0

    text_repeat_ratio: float = 0.0
    is_furniture: float = 0.0
    x_column_density: float = 0.0
    x_column_caps_avg: float = 0.0

    prev_caps_ratio: float = 0.0
    prev_is_cue_shaped: float = 0.0
    prev_is_blank_gap: float = 0.0
    next_caps_ratio: float = 0.0
    next_is_cue_shaped: float = 0.0

    is_split_continuation: float = 0.0
    is_cue_with_inline_paren: float = 0.0

    def to_vector(self) -> List[float]:
        """Ordered feature vector. Order follows FEATURE_NAMES exactly."""
        d = asdict(self)
        return [float(d[name]) for name in FEATURE_NAMES]

    def to_dict(self) -> Dict[str, float]:
        d = asdict(self)
        return {name: float(d[name]) for name in FEATURE_NAMES}


def _pronoun_ratios(text: str) -> tuple[float, float]:
    words = _WORD_RE.findall(text.lower())
    if not words:
        return 0.0, 0.0
    stripped = [w.replace("'", "") for w in words]
    first = sum(1 for w in stripped if w in _FIRST_SECOND_PERSON)
    third = sum(1 for w in stripped if w in _THIRD_PERSON)
    n = len(stripped)
    return first / n, third / n


def extract_features(
    block,
    ctx: DocumentContext,
    profile,
    model=None,
    doc_stats=None,
    prev_block=None,
    next_block=None,
) -> BlockFeatures:
    """Build the feature vector for one block.

    ``model`` (DocumentModel) and ``doc_stats`` (_DocStats) are optional so this
    can be exercised in isolation; when absent the corresponding features stay at
    their neutral defaults rather than raising.
    """
    # Imported lazily: parser.py imports fitz at call time and is the heavier
    # module, so features.py stays importable (and unit-testable) without it.
    from parser import (
        _SIG_INT_EXT_RE, _SIG_ACT_SCENE_RE, _SIG_TRANSITION_RE,
        _SIG_PAGENUM_RE, _SIG_VO_OS_RE, _SIG_CONTD_RE,
        _is_speaker_cue_text, _X_TOLERANCE,
    )

    w = ctx.safe_width
    h = ctx.safe_height
    text = block.text or ""
    stripped = text.strip()

    f = BlockFeatures()

    # Geometry, page-relative
    f.x0_norm = block.x0 / w
    f.x1_norm = block.x1 / w
    f.width_norm = block.width / w
    f.center_x_norm = block.center_x / w
    f.y0_norm = block.y0 / h
    f.y1_norm = block.y1 / h
    f.height_norm = block.height / h

    # Geometry, relative to this document's learned columns. These are the
    # features that let one model serve scripts with wildly different margins.
    if profile is not None:
        f.x0_delta_speaker = (block.x0 - profile.speaker_x) / w
        f.x0_delta_dialog = (block.x0 - profile.dialog_x) / w
        if profile.stage_dir_x is not None:
            f.x0_delta_stage_dir = (block.x0 - profile.stage_dir_x) / w
            f.has_stage_dir_column = 1.0
    if model is not None:
        f.near_cue_column = float(model.near_cue_column(block.x0))
        f.near_dialog_column = float(model.near_dialog_column(block.x0))

    # Typography
    f.caps_ratio = block.caps_ratio
    f.is_bold = float(block.is_bold)
    f.is_italic = float(block.is_italic)
    size = _block_font_size(block)
    f.font_size_ratio = size / ctx.safe_font if size > 0 else 1.0

    # Shape
    words = stripped.split()
    f.line_count = float(block.line_count)
    f.word_count = float(len(words))
    f.char_count = float(block.char_count)
    f.starts_with_paren = float(block.starts_with_paren)
    f.ends_with_paren = float(block.ends_with_paren)
    f.balanced_parens = float(block.starts_with_paren and block.ends_with_paren)
    f.ends_with_terminal_punct = float(stripped.endswith(_TERMINAL_PUNCT))
    f.is_all_caps = float(block.caps_ratio >= 0.9)

    # Structural regex flags — parser.py's own patterns, not reimplementations,
    # so the model and the heuristic path can never disagree about what "looks
    # like a scene heading" means.
    f.matches_int_ext = float(bool(_SIG_INT_EXT_RE.match(stripped)))
    f.matches_act_scene = float(bool(_SIG_ACT_SCENE_RE.match(stripped)))
    f.matches_transition = float(bool(_SIG_TRANSITION_RE.match(stripped)))
    f.is_page_number = float(bool(_SIG_PAGENUM_RE.match(stripped)))
    f.has_vo_os = float(bool(_SIG_VO_OS_RE.search(stripped)))
    f.has_contd = float(bool(_SIG_CONTD_RE.search(stripped)))
    f.has_slash_separator = float(" / " in stripped)

    f.first_second_person_ratio, f.third_person_ratio = _pronoun_ratios(stripped)

    # Document context
    if doc_stats is not None:
        freq = doc_stats.text_frequency.get(stripped, 0)
        total = doc_stats.total_blocks or 1
        f.text_repeat_ratio = freq / total
        xb = round(block.x0 / 5) * 5
        f.x_column_density = doc_stats.x_bin_count.get(xb, 0) / (doc_stats.max_x_count or 1)
        f.x_column_caps_avg = doc_stats.x_bin_caps_avg.get(xb, 0.0)
    if model is not None:
        f.is_furniture = float(model.is_furniture(block))

    # Neighbour context — observable properties only, never a predicted label.
    if prev_block is not None:
        f.prev_caps_ratio = prev_block.caps_ratio
        f.prev_is_cue_shaped = float(
            prev_block.line_count == 1 and _is_speaker_cue_text(prev_block.text))
        # Vertical gap to the previous block, in units of this block's own height —
        # scale-free, and the main cue that a new paragraph/element has started.
        if block.height > 0.1:
            f.prev_is_blank_gap = float((block.y0 - prev_block.y1) > block.height * 0.6)
    if next_block is not None:
        f.next_caps_ratio = next_block.caps_ratio
        f.next_is_cue_shaped = float(
            next_block.line_count == 1 and _is_speaker_cue_text(next_block.text))

    f.is_split_continuation = float(getattr(block, "is_split_continuation", False))
    f.is_cue_with_inline_paren = float(getattr(block, "is_cue_with_inline_paren", False))

    return f


def extract_all(
    blocks: Sequence,
    ctx: DocumentContext,
    profile,
    model=None,
    doc_stats=None,
) -> List[BlockFeatures]:
    """Feature vectors for a whole document, with neighbour context wired up."""
    n = len(blocks)
    return [
        extract_features(
            blocks[i], ctx, profile, model, doc_stats,
            prev_block=blocks[i - 1] if i > 0 else None,
            next_block=blocks[i + 1] if i + 1 < n else None,
        )
        for i in range(n)
    ]


@dataclass
class DocumentFeatures:
    """Everything one PDF yields: the blocks, their features, and the learned model."""
    blocks: List
    features: List[BlockFeatures]
    context: DocumentContext
    profile: object
    model: object
    doc_stats: object

    def __len__(self) -> int:
        return len(self.blocks)


def features_for_pdf(pdf_path: str) -> DocumentFeatures:
    """PDF → blocks + feature vectors, mirroring _block_parse's setup exactly.

    THE single entry point for producing features — used by the worker command,
    the dataset builder, the golden fixtures and the reporting tools alike, so
    they can never drift apart in how a document is prepared. The block
    preparation sequence here must stay in lockstep with ``parser._block_parse``.
    """
    from parser import (
        _extract_blocks, _merge_open_parentheticals,
        _build_document_model, _compute_doc_stats, _reorder_columns,
    )

    blocks = _extract_blocks(pdf_path)
    if not blocks:
        raise RuntimeError(
            f"No text blocks extracted from {pdf_path} — PyMuPDF missing, or the "
            "PDF is a scanned image with no text layer.")

    blocks = _merge_open_parentheticals(blocks)

    page_widths = [b.x1 for b in blocks if b.x1 > 200]
    page_width = max(page_widths) + 90.0 if page_widths else 612.0

    model = _build_document_model(blocks, page_width=page_width)

    # Reading-order normalisation, exactly as _classify_blocks does before it
    # scores. Two-column scripts (EMMA, Stereophonic) interleave otherwise, and
    # the prev_*/next_* features would then describe different neighbours at
    # training time than at inference time — a silent train/serve skew in
    # precisely the two hardest scripts in the corpus.
    blocks = _reorder_columns(blocks, model)

    doc_stats = _compute_doc_stats(blocks)
    ctx = build_document_context(blocks, page_width)

    return DocumentFeatures(
        blocks=blocks,
        features=extract_all(blocks, ctx, model.profile, model, doc_stats),
        context=ctx,
        profile=model.profile,
        model=model,
        doc_stats=doc_stats,
    )
