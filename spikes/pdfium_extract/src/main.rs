mod blocks;
mod chars;
mod lines;

use pdfium_render::prelude::*;
use serde_json::json;

fn main() -> Result<(), PdfiumError> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 4 {
        eprintln!("usage: pdfium_extract <libpdfium.dylib> <pdf> chars|blocks");
        std::process::exit(2);
    }
    let mode = args[3].as_str();
    let pdfium = Pdfium::new(Pdfium::bind_to_library(&args[1])?);
    let doc = pdfium.load_pdf_from_file(&args[2], None)?;
    let metrics = lines::base14();
    let mut pages = Vec::new();
    for page in doc.pages().iter() {
        let pc = chars::page_chars(&page)?;
        if mode == "chars" {
            let cs: Vec<_> = pc.chars.iter().map(|c| json!({
                "c": c.c.to_string(), "l": c.l, "r": c.r, "t": c.t, "b": c.b, "ox": c.ox, "oy": c.oy,
                "size": c.size, "font": c.font, "italic": c.italic, "bold": c.bold, "gen": c.generated,
                "ang": c.ang, "asc": c.asc, "desc": c.desc,
            })).collect();
            pages.push(json!({"w": pc.w, "h": pc.h, "chars": cs}));
        } else {
            // The shape PyMuPDF's page.get_text("dict") gives backend/parser.py, so it can feed it unchanged.
            let blocks: Vec<_> = blocks::group_blocks(lines::build_lines(&pc.chars, &metrics))
                .into_iter()
                .map(|b| json!({
                    "type": 0, "bbox": b.bbox,
                    "lines": b.lines.iter().map(|l| json!({
                        "bbox": l.bbox,
                        "spans": l.spans.iter().map(|s| json!({
                            "text": s.text, "font": s.font, "size": s.size,
                            "flags": (if s.italic { 1 << 1 } else { 0 }) | (if s.bold { 1 << 4 } else { 0 }),
                            "bbox": l.bbox,
                        })).collect::<Vec<_>>(),
                    })).collect::<Vec<_>>(),
                }))
                .collect();
            pages.push(json!({"w": pc.w, "h": pc.h, "blocks": blocks}));
        }
    }
    println!("{}", json!({"pages": pages}));
    Ok(())
}
