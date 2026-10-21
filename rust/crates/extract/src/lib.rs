//! PDF text extraction for Table Read: PDFium characters -> lines -> blocks, in the page/block/line/span shape
//! that `backend/parser.py` reads from PyMuPDF (so the same parser can score it, and the Rust parser can follow).

pub mod blocks;
pub mod chars;
pub mod lines;

use serde_json::{json, Value};

/// One page as PyMuPDF's `page.get_text("dict")` would give it (text blocks only).
pub fn page_blocks_json(pc: &chars::PageChars, metrics: &std::collections::HashMap<String, (f64, f64)>) -> Value {
    let blocks: Vec<Value> = blocks::group_blocks(lines::build_lines(&pc.chars, metrics))
        .into_iter()
        .map(|b| {
            json!({
                "type": 0, "bbox": b.bbox,
                "lines": b.lines.iter().map(|l| json!({
                    "bbox": l.bbox, "titleText": l.title_text,
                    "spans": l.spans.iter().map(|s| json!({
                        "text": s.text, "font": s.font, "size": s.size,
                        "flags": (if s.italic { 1 << 1 } else { 0 }) | (if s.bold { 1 << 4 } else { 0 }),
                        "bbox": l.bbox,
                    })).collect::<Vec<_>>(),
                })).collect::<Vec<_>>(),
            })
        })
        .collect();
    json!({"w": pc.w, "h": pc.h, "blocks": blocks})
}

pub fn page_chars_json(pc: &chars::PageChars) -> Value {
    let cs: Vec<Value> = pc.chars.iter().map(|c| json!({
        "c": c.c.to_string(), "l": c.l, "r": c.r, "t": c.t, "b": c.b, "ox": c.ox, "oy": c.oy,
        "size": c.size, "font": c.font, "italic": c.italic, "bold": c.bold, "gen": c.generated,
        "ang": c.ang, "asc": c.asc, "desc": c.desc,
    })).collect();
    json!({"w": pc.w, "h": pc.h, "chars": cs})
}
