use pdfium_render::prelude::*;
use serde_json::json;
use table_read_extract::{chars, lines, page_blocks_json, page_chars_json};

fn main() -> Result<(), PdfiumError> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 4 {
        eprintln!("usage: pdfium_extract <libpdfium.dylib> <pdf> chars|blocks");
        std::process::exit(2);
    }
    let chars_only = args[3] == "chars";
    let pdfium = Pdfium::new(Pdfium::bind_to_library(&args[1])?);
    let doc = pdfium.load_pdf_from_file(&args[2], None)?;
    let metrics = lines::base14();
    let mut pages = Vec::new();
    for page in doc.pages().iter() {
        let pc = chars::page_chars(&page)?;
        pages.push(if chars_only { page_chars_json(&pc) } else { page_blocks_json(&pc, &metrics) });
    }
    println!("{}", json!({"pages": pages}));
    Ok(())
}
