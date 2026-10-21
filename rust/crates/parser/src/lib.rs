//! Port of `backend/parser.py`. Each stage can be dumped as JSON (`parser_stage`) and compared field for field with
//! the Python parser's own state by `scripts/rust_parser_diff.py`; the Python parser is the reference until the
//! cutover (docs/adr/0002-shared-rust-core.md).

pub mod blocks;
pub mod classify;
pub mod model;
pub mod pystr;
pub mod style;
pub mod types;
