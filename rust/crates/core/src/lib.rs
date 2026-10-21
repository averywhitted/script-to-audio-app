//! The shared core's top-level entry point: a PDF path in, the parsed script out. Parser version is part of the
//! output so devices can tell which parser produced a `script.json` (docs/adr/0003-sync-model.md).

use pdfium_render::prelude::*;
use serde_json::{json, Value};
use table_read_extract::{chars, lines, page_blocks_json};
use table_read_parser::{
    blocks, classify, model,
    script::{self, Config},
    types::RawDoc,
};

/// Bumped whenever the parser's output could change for the same PDF.
pub const PARSER_VERSION: &str = "rust-0.1.0";

#[derive(Debug)]
pub enum ParseError {
    Pdf(PdfiumError),
    Bad(String),
}

impl From<PdfiumError> for ParseError {
    fn from(e: PdfiumError) -> Self {
        ParseError::Pdf(e)
    }
}

/// Read a PDF with PDFium into the page/block/line/span structure the parser consumes.
pub fn extract_document(pdfium: &Pdfium, pdf_path: &str) -> Result<RawDoc, ParseError> {
    let doc = pdfium.load_pdf_from_file(pdf_path, None)?;
    let metrics = lines::base14();
    let mut pages = Vec::new();
    for page in doc.pages().iter() {
        let pc = chars::page_chars(&page)?;
        pages.push(page_blocks_json(&pc, &metrics));
    }
    serde_json::from_value(json!({ "pages": pages })).map_err(|e| ParseError::Bad(e.to_string()))
}

/// The text lines of the first page, top to bottom, for title derivation.
fn first_page_lines(doc: &RawDoc) -> Vec<String> {
    doc.pages
        .first()
        .map(|p| {
            p.blocks
                .iter()
                .flat_map(|b| b.lines.iter())
                .map(|l| l.spans.iter().map(|s| s.text.as_str()).collect::<String>())
                .collect()
        })
        .unwrap_or_default()
}

/// Parse extracted blocks into a script. `title` overrides the derived title when given.
pub fn parse_document(doc: &RawDoc, file_stem: &str, title: Option<&str>, config: Option<&Config>) -> script::Script {
    let tb = blocks::text_blocks(doc);
    let m = model::build_document_model(&tb, model::page_width_of(&tb));
    let classified = classify::classify_blocks(tb, &m);
    let title = title.map(String::from).unwrap_or_else(|| script::derive_title(&first_page_lines(doc), file_stem));
    script::build_script_from_blocks(&classified, &title, config, &m.cast)
}

/// A PDF in, `script.json` content out (the worker's script summary plus the parser version).
pub fn parse_pdf(pdfium: &Pdfium, pdf_path: &str, config: Option<&Config>) -> Result<Value, ParseError> {
    let doc = extract_document(pdfium, pdf_path)?;
    let stem = std::path::Path::new(pdf_path).file_stem().and_then(|s| s.to_str()).unwrap_or("script");
    let parsed = parse_document(&doc, stem, None, config);
    let mut out = script::script_summary_json(&parsed);
    out["parserVersion"] = json!(PARSER_VERSION);
    Ok(out)
}
