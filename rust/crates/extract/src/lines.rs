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

#[cfg(test)]
mod tests {
    use super::*;

    fn ch(c: char, l: f64, y: f64) -> Ch {
        Ch {
            c, l, r: l + 6.0, t: y - 9.0, b: y + 3.0, ox: l, oy: y, size: 12.0, font: "Embedded".into(),
            italic: false, bold: false, generated: false, ang: 0.0, asc: 0.9, desc: -0.3,
        }
    }

    fn word(text: &str, l: f64, y: f64) -> Vec<Ch> {
        text.chars().enumerate().map(|(i, c)| ch(c, l + 6.0 * i as f64, y)).collect()
    }

    fn texts(lines: &[Line]) -> Vec<String> {
        lines.iter().map(|l| l.spans.iter().map(|s| s.text.as_str()).collect()).collect()
    }

    #[test]
    fn same_baseline_is_one_line_and_a_gap_gets_a_space() {
        let mut cs = word("Hi", 72.0, 100.0);
        cs.extend(word("there", 72.0 + 12.0 + 3.0, 100.0)); // 3 pt gap: PDFium inserted no space glyph
        let lines = build_lines(&cs, &HashMap::new());
        assert_eq!(texts(&lines), vec!["Hi there"]);
    }

    #[test]
    fn hanging_indent_on_the_same_baseline_is_two_lines() {
        // "TESS:" at the margin, the speech hanging at x=162: MuPDF reports them as separate lines
        let mut cs = word("TESS:", 72.0, 100.0);
        cs.extend(word("Look", 162.0, 100.0));
        let lines = build_lines(&cs, &HashMap::new());
        assert_eq!(texts(&lines), vec!["TESS:", "Look"]);
    }

    #[test]
    fn a_new_baseline_is_a_new_line() {
        let mut cs = word("one", 72.0, 100.0);
        cs.extend(word("two", 72.0, 112.0));
        assert_eq!(texts(&build_lines(&cs, &HashMap::new())), vec!["one", "two"]);
    }

    #[test]
    fn pdfium_inserted_space_joins_the_span_and_never_breaks_the_line() {
        // PDFium reports its own spaces at the start of the previous glyph with size 1.0
        let mut cs = word("ab", 72.0, 100.0);
        let mut sp = ch(' ', 72.0 + 6.0, 100.0); // overlaps the previous glyph: a "backwards jump"
        sp.generated = true;
        sp.size = 1.0;
        cs.push(sp);
        cs.extend(word("cd", 72.0 + 15.0, 100.0));
        let lines = build_lines(&cs, &HashMap::new());
        assert_eq!(texts(&lines), vec!["ab cd"]);
        assert_eq!(lines[0].spans.len(), 1, "the inserted space must not start a size-1.0 span");
    }

    #[test]
    fn near_vertical_text_is_one_line_along_its_baseline_but_italic_shear_is_not_rotation() {
        let mut v: Vec<Ch> = Vec::new();
        for (i, c) in "Side".chars().enumerate() {
            let mut x = ch(c, 949.0, 840.0 - 10.0 * i as f64); // reads bottom to top
            x.ang = 4.712;
            v.push(x);
        }
        assert_eq!(texts(&build_lines(&v, &HashMap::new())), vec!["Side"]);
        let mut sheared = word("it", 72.0, 100.0);
        for c in &mut sheared {
            c.ang = 0.322; // PDFium reports italic shear as an angle; the baseline is still horizontal
        }
        sheared.extend(word("ic", 84.0, 100.0));
        assert_eq!(texts(&build_lines(&sheared, &HashMap::new())), vec!["itic"]);
    }

    #[test]
    fn standard_font_metrics_override_pdfiums() {
        let mut m = HashMap::new();
        m.insert("Courier".to_string(), (0.932, 0.317));
        let mut cs = word("a", 72.0, 100.0);
        cs[0].font = "Courier".into();
        let l = &build_lines(&cs, &m)[0];
        assert!((l.bbox[1] - (100.0 - 0.932 * 12.0)).abs() < 1e-9);
        assert!((l.bbox[3] - (100.0 + 0.317 * 12.0)).abs() < 1e-9);
    }

    #[test]
    fn base14_table_loads() {
        assert!(base14().contains_key("Times-Roman"));
    }
}
