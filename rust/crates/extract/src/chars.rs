//! Per-character extraction from PDFium, in content-stream order (the Rust twin of scripts/proto_chars.py).

use pdfium_render::prelude::*;

#[derive(Clone, Debug)]
pub struct Ch {
    pub c: char,
    pub l: f64,
    pub r: f64,
    pub t: f64,
    pub b: f64,
    pub ox: f64,
    pub oy: f64,
    pub size: f64,
    pub font: String,
    pub italic: bool,
    pub bold: bool,
    pub generated: bool,
    pub ang: f64,
    pub asc: f64,
    pub desc: f64,
}

pub struct PageChars {
    pub w: f64,
    pub h: f64,
    pub chars: Vec<Ch>,
}

/// Device pixels per point: the integer-size page-to-device API keeps sub-point precision this way.
const SCALE: f64 = 100.0;

fn font_flags(name: &str, pdfium_italic: bool, pdfium_bold: bool) -> (bool, bool) {
    let n = name.to_lowercase();
    (
        pdfium_italic || n.contains("italic") || n.contains("oblique"),
        pdfium_bold || n.contains("bold"),
    )
}

pub fn page_chars(page: &PdfPage) -> Result<PageChars, PdfiumError> {
    let (w, h) = (page.width().value as f64, page.height().value as f64);
    let cfg = PdfRenderConfig::new().set_target_size((w * SCALE).round() as i32, (h * SCALE).round() as i32);
    let to_dev = |x: f64, y: f64| -> Result<(f64, f64), PdfiumError> {
        let (dx, dy) = page.points_to_pixels(PdfPoints::new(x as f32), PdfPoints::new(y as f32), &cfg)?;
        Ok((dx as f64 / SCALE, dy as f64 / SCALE))
    };
    let text = page.text()?;

    // Pass 1: text objects in content-stream order (MuPDF keeps stream order; PDFium's text page re-orders).
    struct Obj {
        asc: f64,
        desc: f64,
    }
    let mut objs: Vec<Obj> = Vec::new();
    let mut owner: std::collections::HashMap<usize, usize> = std::collections::HashMap::new();
    let mut keyed: Vec<(usize, Ch)> = Vec::new();
    for object in page.objects().iter() {
        let Some(obj) = object.as_text_object() else { continue };
        let k = objs.len();
        let m = obj.matrix()?;
        let det = (m.a() * m.d() - m.b() * m.c()).abs() as f64;
        let scale = if det > 0.0 { det.sqrt() } else { 1.0 };
        let font = obj.font();
        let asc = font.ascent(PdfPoints::new(1.0)).map(|p| p.value as f64).unwrap_or(0.8);
        let desc = font.descent(PdfPoints::new(1.0)).map(|p| p.value as f64).unwrap_or(-0.2);
        let chars = obj.chars(&text)?;
        if chars.len() == 0 {
            // A text object the text page dropped: typically a lone " " after a line (MuPDF's trailing
            // space) or a blank line. Keep it as a space at its origin.
            let size = obj.unscaled_font_size().value as f64 * scale;
            let name = font.name();
            let (italic, bold) = font_flags(&name, font.is_italic(), false);
            let (ox, oy) = to_dev(m.e() as f64, m.f() as f64)?;
            keyed.push((k, Ch {
                c: ' ', l: ox, r: ox + 0.25 * size, t: oy - asc * size, b: oy - desc * size,
                ox, oy, size, font: name, italic, bold, generated: false, ang: 0.0, asc, desc,
            }));
        } else {
            for ch in chars.iter() {
                owner.insert(ch.index(), k);
            }
        }
        objs.push(Obj { asc, desc });
    }

    // Pass 2: every text-page character in page order (this includes PDFium's inserted spaces, which belong
    // to no object and ride along with the previous character's object).
    let mut last = 0usize;
    let mut last_font = String::new();
    for ch in text.chars().iter() {
        let Some(c) = ch.unicode_char() else { continue };
        let generated = ch.is_generated().unwrap_or(false);
        if generated && c != ' ' {
            continue; // keep PDFium's inserted spaces, drop its inserted newlines and hyphens
        }
        let k = owner.get(&ch.index()).copied().unwrap_or(last);
        last = k;
        let info = objs.get(k);
        // text-matrix scale (uniform, also for rotated text); PDFium reports 1.0 for the bare font size
        let scale = ch
            .matrix()
            .map(|m| (m.a() * m.d() - m.b() * m.c()).abs() as f64)
            .ok()
            .filter(|det| *det > 0.0)
            .map_or(1.0, f64::sqrt);
        // Some PDFs encode their word spaces as TAB, and PDFium marks an end-of-line hyphen as U+0002; MuPDF reports
        // a space and a hyphen for these.
        let c = match c {
            '\t' => ' ',
            '\u{2}' => '-',
            other => other,
        };
        let tight = ch.tight_bounds()?;
        let loose = ch.loose_bounds()?; // advance-based extent, as MuPDF uses
        let (l, t) = to_dev(loose.left().value as f64, tight.top().value as f64)?;
        let (r, b) = to_dev(loose.right().value as f64, tight.bottom().value as f64)?;
        let (ox, oy) = ch.origin()?;
        let (ox, oy) = to_dev(ox.value as f64, oy.value as f64)?;
        let mut name = ch.font_name();
        if name.is_empty() {
            name = last_font.clone(); // PDFium's inserted spaces report no font: use the neighbour's
        } else {
            last_font = name.clone();
        }
        let heavy = matches!(
            ch.font_weight(),
            Some(PdfFontWeight::Weight600 | PdfFontWeight::Weight700Bold | PdfFontWeight::Weight800
                | PdfFontWeight::Weight900) | Some(PdfFontWeight::Custom(600..))
        );
        let (italic, bold) = font_flags(&name, ch.font_is_italic(), heavy || ch.font_is_bold_reenforced());
        keyed.push((k, Ch {
            c, l, r, t, b, ox, oy,
            size: ch.unscaled_font_size().value as f64 * scale,
            font: name, italic, bold, generated,
            ang: ch.angle_radians().unwrap_or(0.0) as f64,
            asc: info.map(|o| o.asc).unwrap_or(0.8),
            desc: info.map(|o| o.desc).unwrap_or(-0.2),
        }));
    }
    keyed.sort_by_key(|(k, _)| *k); // stable: keeps text-page order inside an object
    let out = merge_ligatures(keyed.into_iter().map(|(_, c)| c).collect());
    Ok(PageChars { w, h, chars: out })
}

/// PDFium reports a ligature glyph ("ﬁ") as its letters ('f','i') sharing one box; MuPDF reports the ligature
/// character itself. Put them back so the text matches what the Python worker has always stored (corrections are
/// keyed on it).
pub fn merge_ligatures(chars: Vec<Ch>) -> Vec<Ch> {
    fn same_box(a: &Ch, b: &Ch) -> bool {
        !a.generated && !b.generated && (a.l - b.l).abs() < 0.011 && (a.r - b.r).abs() < 0.011 && (a.oy - b.oy).abs() < 0.011 && a.r > a.l
    }
    let mut out: Vec<Ch> = Vec::with_capacity(chars.len());
    let mut i = 0;
    while i < chars.len() {
        let c = &chars[i];
        let lig = |n: usize| -> Option<char> {
            if i + n > chars.len() || !(1..n).all(|k| same_box(&chars[i], &chars[i + k])) {
                return None;
            }
            let s: String = chars[i..i + n].iter().map(|x| x.c).collect();
            match s.as_str() {
                "ffi" => Some('\u{FB03}'),
                "ffl" => Some('\u{FB04}'),
                "ff" => Some('\u{FB00}'),
                "fi" => Some('\u{FB01}'),
                "fl" => Some('\u{FB02}'),
                _ => None,
            }
        };
        if c.c == 'f' {
            if let Some(l) = lig(3).map(|l| (l, 3)).or_else(|| lig(2).map(|l| (l, 2))) {
                let mut m = c.clone();
                m.c = l.0;
                out.push(m);
                i += l.1;
                continue;
            }
        }
        out.push(c.clone());
        i += 1;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ch(c: char, l: f64, r: f64) -> Ch {
        Ch { c, l, r, t: 90.0, b: 103.0, ox: l, oy: 100.0, size: 12.0, font: "F".into(), italic: false, bold: false, generated: false, ang: 0.0, asc: 0.9, desc: -0.3 }
    }

    fn text(cs: &[Ch]) -> String {
        cs.iter().map(|c| c.c).collect()
    }

    #[test]
    fn letters_sharing_one_box_become_the_ligature() {
        let cs = vec![ch('a', 0.0, 6.0), ch('f', 6.0, 14.4), ch('i', 6.0, 14.4), ch('n', 14.4, 20.0), ch('e', 20.0, 26.0)];
        assert_eq!(text(&merge_ligatures(cs)), "a\u{FB01}ne");
        let cs = vec![ch('f', 0.0, 9.0), ch('f', 0.0, 9.0), ch('i', 0.0, 9.0), ch('x', 9.0, 15.0)];
        assert_eq!(text(&merge_ligatures(cs)), "\u{FB03}x");
    }

    #[test]
    fn ordinary_neighbours_are_left_alone() {
        let cs = vec![ch('o', 0.0, 6.0), ch('f', 6.0, 10.0), ch('i', 10.0, 14.0), ch('f', 14.0, 18.0), ch('f', 18.0, 22.0)];
        assert_eq!(text(&merge_ligatures(cs)), "ofiff");
    }
}
