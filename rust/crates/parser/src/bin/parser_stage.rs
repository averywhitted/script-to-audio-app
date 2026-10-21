//! Dump one parser stage as JSON for the Python-vs-Rust comparison (scripts/rust_parser_diff.py).
//! usage: parser_stage <stage> <extractor-blocks.json>      stages: text_blocks

use table_read_parser::{blocks, types::RawDoc};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: parser_stage <stage> <extractor-blocks.json>");
        std::process::exit(2);
    }
    let doc: RawDoc = serde_json::from_str(&std::fs::read_to_string(&args[2]).expect("read input")).expect("parse input");
    match args[1].as_str() {
        "text_blocks" => println!("{}", serde_json::to_string(&blocks::text_blocks(&doc)).unwrap()),
        other => {
            eprintln!("unknown stage {other}");
            std::process::exit(2);
        }
    }
}
