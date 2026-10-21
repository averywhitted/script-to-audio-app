//! usage: table_read_parse <libpdfium.dylib> <pdf> [corrections_config.json]   (prints script.json content)

use pdfium_render::prelude::*;
use table_read_parser::script::Config;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: table_read_parse <libpdfium.dylib> <pdf> [corrections_config.json]");
        std::process::exit(2);
    }
    let pdfium = Pdfium::new(Pdfium::bind_to_library(&args[1]).expect("bind PDFium"));
    let config = args.get(3).map(|p| {
        Config::from_json(&serde_json::from_str(&std::fs::read_to_string(p).expect("read config")).expect("parse config"))
    });
    match table_read_core::parse_pdf(&pdfium, &args[2], config.as_ref()) {
        Ok(v) => println!("{v}"),
        Err(e) => {
            eprintln!("{e:?}");
            std::process::exit(1);
        }
    }
}
