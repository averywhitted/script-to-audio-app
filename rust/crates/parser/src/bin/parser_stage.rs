//! Dump one parser stage as JSON for the Python-vs-Rust comparison (scripts/rust_parser_diff.py).
//! usage: parser_stage <stage> <extractor-blocks.json>      stages: text_blocks, doc_model, classified_nostyle, style, classified

use serde_json::json;
use table_read_parser::{blocks, classify, model, types::RawDoc};

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
        "classified_nostyle" => {
            // roles and speakers before the learned-style pass (stage 4)
            let tb = blocks::text_blocks(&doc);
            let m = model::build_document_model(&tb, model::page_width_of(&tb));
            let mut r = classify::classify_core(tb, &m);
            classify::silence_bare_names(&mut r, &m);
            let out: Vec<_> = r
                .iter()
                .map(|c| json!({"page": c.block.page, "x0": c.block.x0, "y0": c.block.y0, "text": c.block.text,
                                "role": c.role, "speaker": c.speaker, "aside": c.aside}))
                .collect();
            println!("{}", serde_json::to_string(&out).unwrap());
        }
        "classified" => {
            let tb = blocks::text_blocks(&doc);
            let m = model::build_document_model(&tb, model::page_width_of(&tb));
            let r = classify::classify_blocks(tb, &m);
            let out: Vec<_> = r
                .iter()
                .map(|c| json!({"page": c.block.page, "x0": c.block.x0, "y0": c.block.y0, "text": c.block.text,
                                "role": c.role, "speaker": c.speaker, "aside": c.aside}))
                .collect();
            println!("{}", serde_json::to_string(&out).unwrap());
        }
        "style" => {
            // the learned-style model itself, fitted on the classifier's output before the style pass
            let tb = blocks::text_blocks(&doc);
            let m = model::build_document_model(&tb, model::page_width_of(&tb));
            let r = classify::classify_core(tb, &m);
            let out = match table_read_parser::style::learn_style(&r, &m) {
                None => json!(null),
                Some(l) => json!({"prior": l.prior, "evidence": l.evidence, "pool_size": l.pool.len(),
                                  "dialog": l.dialog, "direction": l.direction}),
            };
            println!("{}", out);
        }
        other => {
            eprintln!("unknown stage {other}");
            std::process::exit(2);
        }
    }
}
