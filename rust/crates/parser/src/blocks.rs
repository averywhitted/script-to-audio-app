//! Raw extractor blocks -> `TextBlock`s: splitting at blank lines and speaker cues, open parentheticals merged.
//! Port of `_split_raw_block`, `_make_text_block`, `_merge_open_parentheticals` and the cue helpers.

use crate::pystr::{caps_ratio, is_alpha, is_upper, len, lstrip, rstrip, strip};
use crate::types::{RawBlock, RawDoc, TextBlock, TextSpan};
use regex::Regex;
use std::sync::LazyLock;

/// `_PAREN_MERGE_LOOKAHEAD`
const PAREN_MERGE_LOOKAHEAD: usize = 1;

pub(crate) static PAGE_MARKER_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^\[.{1,40}\]\s*\d{1,4}\.?\s*$|^\d{1,4}\.?\s*$").unwrap());
static CONTINUED_CUE_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)^(.+?)\s*\(\s*(?:cont(?:inued|['\u{2019}]?d|\.)?)\s*\)\s*:?\s*$").unwrap()
});
static CUE_WITH_INLINE_PAREN_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^([A-Z][A-Z'\s.]{0,30}?)\s*\([^)]+\)\s*$").unwrap());
static SCENE_WORD_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)^(?:INT|EXT|ACT|SCENE|PART|PROLOGUE|EPILOGUE)\b").unwrap());
static CONT_WORD_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)\(\s*cont").unwrap());

/// One line of a raw block as the parser handles it: geometry, stripped text, spans (`_RawLine`).
struct RawLn {
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,
    text: String,
    spans: Vec<TextSpan>,
}

/// `_extract_blocks` after the PDF has been read: every text block of the document, in order.
pub fn extract_blocks(doc: &RawDoc) -> Vec<TextBlock> {
    let mut out = Vec::new();
    for (page_num, page) in doc.pages.iter().enumerate() {
        for raw in &page.blocks {
            if raw.r#type != 0 {
                continue; // images and drawings
            }
            out.extend(split_raw_block(raw, page_num));
        }
    }
    out
}

/// The whole pre-classification pipeline: extract, then merge parentheticals split across blocks.
pub fn text_blocks(doc: &RawDoc) -> Vec<TextBlock> {
    merge_open_parentheticals(extract_blocks(doc))
}

pub fn split_raw_block(raw: &RawBlock, page_num: usize) -> Vec<TextBlock> {
    let raw_lines: Vec<RawLn> = raw
        .lines
        .iter()
        .map(|line| {
            let spans: Vec<TextSpan> = line
                .spans
                .iter()
                .map(|s| TextSpan {
                    text: s.text.clone(),
                    bold: s.flags & (1 << 4) != 0,
                    italic: s.flags & (1 << 1) != 0,
                    font: s.font.clone(),
                    size: s.size,
                })
                .collect();
            let joined: String = spans.iter().map(|s| s.text.as_str()).collect();
            RawLn { x0: line.bbox[0], y0: line.bbox[1], x1: line.bbox[2], y1: line.bbox[3], text: strip(&joined).to_string(), spans }
        })
        .collect();

    // Split at blank lines into sub-runs of consecutive non-empty lines.
    let mut sub_runs: Vec<Vec<&RawLn>> = Vec::new();
    let mut current: Vec<&RawLn> = Vec::new();
    for ln in &raw_lines {
        if ln.text.is_empty() {
            if !current.is_empty() {
                sub_runs.push(std::mem::take(&mut current));
            }
        } else {
            current.push(ln);
        }
    }
    if !current.is_empty() {
        sub_runs.push(current);
    }

    let mut result = Vec::new();
    for run in sub_runs {
        let first_text = run[0].text.as_str();
        let continued = continued_cue_name(first_text);
        if run.len() > 1 && continued.is_some() {
            // "ADA (cont.)" + speech: split the name line off and keep the marker silent.
            let mut cue = make_text_block(&run[..1], page_num);
            cue.text = continued.unwrap();
            result.push(cue);
            let mut tail = make_text_block(&run[1..], page_num);
            tail.is_split_continuation = true;
            result.push(tail);
        } else if run.len() > 1 && is_speaker_cue_text(first_text) {
            result.push(make_text_block(&run[..1], page_num));
            let mut tail = make_text_block(&run[1..], page_num);
            tail.is_split_continuation = true;
            result.push(tail);
        } else if run.len() > 1 && is_cue_with_inline_paren_line(first_text) {
            // "SPEAKER (stage direction)\nDialog": the paren drops the caps ratio, so tag the cue.
            let mut cue = make_text_block(&run[..1], page_num);
            cue.is_cue_with_inline_paren = true;
            result.push(cue);
            let mut tail = make_text_block(&run[1..], page_num);
            tail.is_split_continuation = true;
            result.push(tail);
        } else {
            result.push(make_text_block(&run, page_num));
        }
    }
    result
}

/// 'ADA (cont.)' / 'TOILET (cont’d)' / 'BEN (CONTINUED)' -> the name, if the part before the marker is itself
/// a name line.
pub fn continued_cue_name(text: &str) -> Option<String> {
    let t = strip(text);
    let m = CONTINUED_CUE_RE.captures(t)?;
    let name = m.get(1)?.as_str();
    if is_speaker_cue_text(name) {
        Some(strip(name).to_string())
    } else {
        None
    }
}

/// Whether text looks like a standalone speaker cue line: at most 50 chars, at least 90% of letters uppercase,
/// not a scene-heading keyword, not a page marker.
pub fn is_speaker_cue_text(text: &str) -> bool {
    let t = strip(text);
    if t.is_empty() || len(t) > 50 {
        return false;
    }
    if !is_upper(t.chars().next().unwrap()) {
        return false;
    }
    let alpha: Vec<char> = t.chars().filter(|c| is_alpha(*c)).collect();
    if alpha.is_empty() {
        return false;
    }
    if (alpha.iter().filter(|c| is_upper(**c)).count() as f64) / (alpha.len() as f64) < 0.9 {
        return false;
    }
    if SCENE_WORD_RE.is_match(t) {
        return false;
    }
    if PAGE_MARKER_RE.is_match(t) {
        return false;
    }
    true
}

/// 'SPEAKER (stage direction)' cue lines, excluding continuation markers like '(CONT'D)'.
pub fn is_cue_with_inline_paren_line(text: &str) -> bool {
    let t = strip(text);
    let Some(m) = CUE_WITH_INLINE_PAREN_RE.captures(t) else { return false };
    if CONT_WORD_RE.is_match(t) {
        return false;
    }
    let name = strip(m.get(1).unwrap().as_str());
    !name.is_empty() && is_speaker_cue_text(name)
}

fn make_text_block(lines: &[&RawLn], page_num: usize) -> TextBlock {
    let x0 = lines.iter().map(|l| l.x0).fold(f64::INFINITY, f64::min);
    let x1 = lines.iter().map(|l| l.x1).fold(f64::NEG_INFINITY, f64::max);
    let y0 = lines[0].y0;
    let y1 = lines[lines.len() - 1].y1;

    let line_texts: Vec<&str> = lines.iter().map(|l| l.text.as_str()).collect();
    let text = line_texts.join(" ");
    let all_chars: String = line_texts.concat();

    let (mut total, mut italic, mut bold) = (0usize, 0usize, 0usize);
    for sp in lines.iter().flat_map(|l| l.spans.iter()) {
        let n = len(&sp.text);
        total += n;
        if sp.italic {
            italic += n;
        }
        if sp.bold {
            bold += n;
        }
    }
    TextBlock {
        x0,
        y0,
        x1,
        y1,
        page: page_num,
        lines: lines.iter().map(|l| l.spans.clone()).collect(),
        caps_ratio: caps_ratio(&all_chars),
        center_x: (x0 + x1) / 2.0,
        width: x1 - x0,
        height: y1 - y0,
        line_count: lines.len(),
        char_count: len(&all_chars),
        starts_with_paren: lstrip(&text).starts_with('('),
        ends_with_paren: rstrip(&text).ends_with(')'),
        is_italic: total > 0 && 2 * italic > total,
        is_bold: total > 0 && 2 * bold > total,
        text,
        is_merged_parenthetical: false,
        is_split_continuation: false,
        is_cue_with_inline_paren: false,
    }
}

/// Merge blocks that form one multi-line parenthetical (the opener's ")" is in a later block).
pub fn merge_open_parentheticals(blocks: Vec<TextBlock>) -> Vec<TextBlock> {
    let mut result: Vec<TextBlock> = Vec::new();
    let mut i = 0;
    while i < blocks.len() {
        let block = &blocks[i];
        let text = block.text.as_str();
        if !text.starts_with('(') {
            result.push(block.clone());
            i += 1;
            continue;
        }
        let mut depth: i64 = 0;
        for c in text.chars() {
            match c {
                '(' => depth += 1,
                ')' => depth -= 1,
                _ => {}
            }
        }
        if depth <= 0 {
            result.push(block.clone());
            i += 1;
            continue;
        }
        // Only mid-sentence splits are merged: blocks ending in sentence punctuation are complete units.
        let last_char = rstrip(text).chars().last();
        if let Some(c) = last_char {
            if ".!?–—".contains(c) {
                result.push(block.clone());
                i += 1;
                continue;
            }
        }
        let mut merged_parts: Vec<String> = vec![text.to_string()];
        let mut all_line_spans: Vec<Vec<TextSpan>> = block.lines.clone();
        let mut j = i + 1;
        let mut trailing_text: Option<String> = None;
        let mut trailing_geo = (block.x0, block.y0, block.x1, block.y1, block.page);
        let mut found_close = false;
        let limit = i + PAREN_MERGE_LOOKAHEAD;

        while j < blocks.len() && j <= limit && depth > 0 {
            let nb = &blocks[j];
            let nt: Vec<char> = nb.text.chars().collect();
            let mut close_idx: Option<usize> = None;
            let mut nd = depth;
            for (k, c) in nt.iter().enumerate() {
                if *c == '(' {
                    nd += 1;
                } else if *c == ')' {
                    nd -= 1;
                    if nd <= 0 {
                        close_idx = Some(k);
                        break;
                    }
                }
            }
            if let Some(k) = close_idx {
                merged_parts.push(nt[..=k].iter().collect());
                let after: String = nt[k + 1..].iter().collect();
                let after = strip(&after);
                all_line_spans.extend(nb.lines.iter().cloned());
                trailing_geo = (nb.x0, nb.y0, nb.x1, nb.y1, nb.page);
                if !after.is_empty() {
                    trailing_text = Some(after.to_string());
                }
                depth = 0;
                found_close = true;
                j += 1;
            } else {
                merged_parts.push(nb.text.clone());
                all_line_spans.extend(nb.lines.iter().cloned());
                depth = nd;
                j += 1;
            }
        }

        if found_close {
            let last = &blocks[j - 1];
            let merged_text = merged_parts.join(" ");
            let merged_chars: String = merged_parts.concat();
            let mx1 = block.x1.max(last.x1);
            result.push(TextBlock {
                x0: block.x0,
                y0: block.y0,
                x1: mx1,
                y1: last.y1,
                page: block.page,
                line_count: all_line_spans.len(),
                lines: all_line_spans,
                caps_ratio: caps_ratio(&merged_chars),
                center_x: (block.x0 + mx1) / 2.0,
                width: mx1 - block.x0,
                height: last.y1 - block.y0,
                char_count: len(&merged_chars),
                starts_with_paren: true,
                ends_with_paren: rstrip(&merged_text).ends_with(')'),
                is_italic: block.is_italic,
                is_bold: block.is_bold,
                is_merged_parenthetical: true,
                is_split_continuation: false,
                is_cue_with_inline_paren: false,
                text: merged_text,
            });
            if let Some(tt) = trailing_text {
                let (tx0, ty0, tx1, ty1, tpage) = trailing_geo;
                result.push(TextBlock {
                    x0: tx0,
                    y0: ty0,
                    x1: tx1,
                    y1: ty1,
                    page: tpage,
                    lines: vec![],
                    caps_ratio: caps_ratio(&tt),
                    center_x: (tx0 + tx1) / 2.0,
                    width: tx1 - tx0,
                    height: ty1 - ty0,
                    line_count: 1,
                    char_count: len(&tt),
                    starts_with_paren: tt.starts_with('('),
                    ends_with_paren: rstrip(&tt).ends_with(')'),
                    is_italic: false,
                    is_bold: false,
                    is_merged_parenthetical: false,
                    is_split_continuation: false,
                    is_cue_with_inline_paren: false,
                    text: tt,
                });
            }
            i = j;
        } else {
            result.push(block.clone());
            i += 1;
        }
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{RawLine, RawSpan};

    // Expected values below were taken from backend/parser.py.

    #[test]
    fn speaker_cue_text() {
        for yes in ["ADA", "TESS:", "JEAN-LUC", "MOTHER (V.O.)", "A", "É", "ÉLISE"] {
            assert!(is_speaker_cue_text(yes), "{yes}");
        }
        for no in ["Ada", "INT. KITCHEN", "[DRAFT] 12", "12", "ADA (cont.)", ""] {
            assert!(!is_speaker_cue_text(no), "{no}");
        }
        assert!(!is_speaker_cue_text(&"A".repeat(51)));
    }

    #[test]
    fn continued_cue() {
        assert_eq!(continued_cue_name("ADA (cont.)").as_deref(), Some("ADA"));
        assert_eq!(continued_cue_name("ADA (CONT'D)").as_deref(), Some("ADA"));
        assert_eq!(continued_cue_name("TOILET (cont\u{2019}d)").as_deref(), Some("TOILET"));
        assert_eq!(continued_cue_name("BEN (CONTINUED)").as_deref(), Some("BEN"));
        assert_eq!(continued_cue_name("hello (cont.)"), None);
        assert_eq!(continued_cue_name("ADA"), None);
    }

    #[test]
    fn cue_with_inline_paren() {
        assert!(is_cue_with_inline_paren_line("TESS (quietly)"));
        assert!(!is_cue_with_inline_paren_line("TESS (CONT'D)"));
        assert!(!is_cue_with_inline_paren_line("tess (quietly)"));
        assert!(!is_cue_with_inline_paren_line("TESS (a)(b)"));
    }

    fn raw_line(text: &str, x0: f64, y0: f64, italic: bool) -> RawLine {
        RawLine {
            title_text: None,
            bbox: [x0, y0, x0 + 100.0, y0 + 12.0],
            spans: vec![RawSpan { text: text.into(), font: "F".into(), size: 12.0, flags: if italic { 2 } else { 0 } }],
        }
    }

    fn raw_block(lines: Vec<RawLine>) -> RawBlock {
        RawBlock { r#type: 0, lines }
    }

    #[test]
    fn a_cue_line_followed_by_speech_is_split_off() {
        let out = split_raw_block(&raw_block(vec![raw_line("TESS", 250.0, 100.0, false), raw_line("Look at me.", 180.0, 112.0, false)]), 3);
        assert_eq!(out.len(), 2);
        assert_eq!((out[0].text.as_str(), out[0].is_split_continuation), ("TESS", false));
        assert_eq!((out[1].text.as_str(), out[1].is_split_continuation, out[1].page), ("Look at me.", true, 3));
    }

    #[test]
    fn blank_lines_split_runs_and_a_continued_marker_is_silenced() {
        let out = split_raw_block(
            &raw_block(vec![raw_line("one", 90.0, 100.0, false), raw_line(" ", 90.0, 112.0, false), raw_line("ADA (cont.)", 250.0, 124.0, false), raw_line("two", 180.0, 136.0, false)]),
            0,
        );
        let texts: Vec<&str> = out.iter().map(|b| b.text.as_str()).collect();
        assert_eq!(texts, vec!["one", "ADA", "two"]);
    }

    #[test]
    fn style_is_the_majority_of_characters() {
        let b = &split_raw_block(&raw_block(vec![raw_line("abcd", 90.0, 100.0, true), raw_line("ef", 90.0, 112.0, false)]), 0)[0];
        assert!(b.is_italic && !b.is_bold);
        assert_eq!((b.line_count, b.char_count, b.text.as_str()), (2, 6, "abcd ef"));
    }

    fn tb(text: &str, y: f64) -> TextBlock {
        split_raw_block(&raw_block(vec![raw_line(text, 90.0, y, false)]), 0).remove(0)
    }

    #[test]
    fn an_open_parenthetical_is_merged_with_the_block_that_closes_it() {
        let out = merge_open_parentheticals(vec![tb("(Darren gets up and faces", 100.0), tb("Elliot.) Okay then.", 112.0), tb("Next", 124.0)]);
        assert_eq!(out.len(), 3);
        assert!(out[0].is_merged_parenthetical);
        assert_eq!(out[0].text, "(Darren gets up and faces Elliot.)");
        assert_eq!(out[1].text, "Okay then."); // dialogue after the close becomes its own block
        assert_eq!(out[2].text, "Next");
    }

    #[test]
    fn sentence_ending_openers_and_balanced_parens_are_left_alone() {
        let out = merge_open_parentheticals(vec![tb("(He leaves.", 100.0), tb("Then) more", 112.0), tb("(done)", 124.0)]);
        assert_eq!(out.len(), 3);
        assert!(out.iter().all(|b| !b.is_merged_parenthetical));
    }
}
