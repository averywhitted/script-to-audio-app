//! Lines and spans from characters (the Rust twin of scripts/proto_lines.py).

use crate::chars::Ch;
use std::collections::HashMap;

pub struct Span {
    pub text: String,
    pub font: String,
    pub size: f64,
    pub italic: bool,
    pub bold: bool,
}

pub struct Line {
    pub bbox: [f64; 4],
    pub spans: Vec<Span>,
}

/// Tuned against PyMuPDF's lines on the corpus (see README).
const BACK: f64 = 0.5; // how far a character may sit behind the previous one's right edge, in em
const DRIFT: f64 = 0.3; // baseline wobble allowed within a line, in em
const JUMP: f64 = 2.0; // a forward gap over this many em starts a new line (hanging indents, columns)
const SPACE_GAP: f64 = 0.1; // a gap over this many em with no space glyph gets a space, as MuPDF does

/// MuPDF's own line-box metrics for the 14 standard (non-embedded) PDF fonts: (above, below) the baseline in em.
pub fn base14() -> HashMap<String, (f64, f64)> {
    serde_json::from_str(include_str!("../base14_metrics.json")).expect("base14_metrics.json")
}

/// Near-vertical text. PDFium also reports italic shear as an "angle" (0.32 rad on Kill Floor) while the
/// baseline stays horizontal, so only a large angle counts as rotated.
fn rotated(c: &Ch) -> bool {
    c.ang.sin().abs() > 0.7
}

pub fn build_lines(chars: &[Ch], metrics: &HashMap<String, (f64, f64)>) -> Vec<Line> {
    let mut groups: Vec<Vec<Ch>> = Vec::new();
    let mut cur: Vec<Ch> = Vec::new();
    for c in chars {
        let mut c = c.clone();
        if let Some(&(a, d)) = metrics.get(&c.font) {
            c.asc = a;
            c.desc = -d;
        }
        if c.generated {
            // PDFium-inserted space: joins the current line, never decides a break
            if !cur.is_empty() {
                cur.push(c);
            }
            continue;
        }
        if let Some(p) = cur.iter().rev().find(|x| !x.generated).cloned() {
            let sz = c.size.max(p.size).max(1.0); // PDFium's inserted spaces report size 1.0
            let same = if rotated(&c) || rotated(&p) {
                let a = p.ang;
                let (ux, uy) = (a.cos(), a.sin()); // baseline direction, y-down device space
                let (dx, dy) = (c.ox - p.ox, c.oy - p.oy);
                let along = dx * ux + dy * uy;
                let across = -dx * uy + dy * ux;
                (c.ang - a).abs() < 0.05 && across.abs() <= DRIFT * sz && -BACK * sz <= along && along <= (1.0 + JUMP) * sz
            } else {
                (c.oy - p.oy).abs() <= DRIFT * sz && c.l >= p.r - BACK * sz && (c.l - p.r) <= JUMP * sz
            };
            if !same {
                groups.push(std::mem::take(&mut cur));
            } else if !rotated(&c) && c.c != ' ' && p.c != ' ' && cur.last().map_or(false, |x| x.c != ' ') && (c.l - p.r) > SPACE_GAP * sz {
                let mut sp = p.clone();
                sp.c = ' ';
                sp.generated = true;
                sp.l = p.r;
                sp.r = c.l;
                cur.push(sp); // MuPDF spaces by gap too
            }
        }
        cur.push(c);
    }
    if !cur.is_empty() {
        groups.push(cur);
    }
    groups.iter().filter_map(|g| make_line(g)).collect()
}

fn make_line(ln: &[Ch]) -> Option<Line> {
    let text: String = ln.iter().map(|c| c.c).collect();
    if text.is_empty() {
        return None;
    }
    let base = ln[0].oy;
    let a = ln.iter().map(|c| c.asc * c.size).fold(f64::MIN, f64::max);
    let d = ln.iter().map(|c| -c.desc * c.size).fold(f64::MIN, f64::max);
    let bbox = if rotated(&ln[0]) {
        [
            ln.iter().map(|c| c.l.min(c.r)).fold(f64::MAX, f64::min),
            ln.iter().map(|c| c.t.min(c.b)).fold(f64::MAX, f64::min),
            ln.iter().map(|c| c.l.max(c.r)).fold(f64::MIN, f64::max),
            ln.iter().map(|c| c.t.max(c.b)).fold(f64::MIN, f64::max),
        ]
    } else {
        [
            ln.iter().map(|c| c.l).fold(f64::MAX, f64::min),
            base - a,
            ln.iter().map(|c| c.r).fold(f64::MIN, f64::max),
            base + d,
        ]
    };
    let mut spans: Vec<Span> = Vec::new();
    for c in ln {
        let same_span = spans.last().map_or(false, |s| {
            s.font == c.font && (s.size - c.size).abs() < 0.005 && s.italic == c.italic && s.bold == c.bold
        });
        if same_span {
            spans.last_mut().unwrap().text.push(c.c);
        } else if c.generated && !spans.is_empty() {
            // an inserted space belongs to the span it follows (its own size is meaningless)
            spans.last_mut().unwrap().text.push(c.c);
        } else {
            spans.push(Span { text: c.c.to_string(), font: c.font.clone(), size: c.size, italic: c.italic, bold: c.bold });
        }
    }
    Some(Line { bbox, spans })
}
