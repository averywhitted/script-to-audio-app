//! Dump one parser stage as JSON for the Python-vs-Rust comparison (scripts/rust_parser_diff.py).
//! usage: parser_stage <stage> <extractor-blocks.json>      stages: text_blocks, doc_model

use serde_json::json;
use table_read_parser::{blocks, model, types::RawDoc};

fn sorted(s: &std::collections::HashSet<String>) -> Vec<String> {
    let mut v: Vec<String> = s.iter().cloned().collect();
    v.sort();
    v
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: parser_stage <stage> <extractor-blocks.json>");
        std::process::exit(2);
    }
    let doc: RawDoc = serde_json::from_str(&std::fs::read_to_string(&args[2]).expect("read input")).expect("parse input");
    match args[1].as_str() {
        "text_blocks" => println!("{}", serde_json::to_string(&blocks::text_blocks(&doc)).unwrap()),
        "doc_model" => {
            let tb = blocks::text_blocks(&doc);
            let m = model::build_document_model(&tb, model::page_width_of(&tb));
            println!(
                "{}",
                json!({
                    "profile": m.profile, "cast_lexicon": m.cast_lexicon, "cast": sorted(&m.cast),
                    "cue_columns": m.cue_columns, "dialog_columns": m.dialog_columns,
                    "furniture": sorted(&m.furniture), "cue_labels": sorted(&m.cue_labels),
                    "doc_stats": model::compute_doc_stats(&tb),
                })
            );
        }
        other => {
            eprintln!("unknown stage {other}");
            std::process::exit(2);
        }
    }
}
