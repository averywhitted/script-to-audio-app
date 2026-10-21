use serde::{Deserialize, Serialize};

/// One styled run of text within a line (`TextSpan` in parser.py).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct TextSpan {
    pub text: String,
    pub bold: bool,
    pub italic: bool,
    pub font: String,
    pub size: f64,
}

/// An atomic semantic unit: a stage direction paragraph, a speaker cue, a dialog run or a parenthetical
/// (`TextBlock` in parser.py).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct TextBlock {
    pub x0: f64,
    pub y0: f64,
    pub x1: f64,
    pub y1: f64,
    pub page: usize,
    pub lines: Vec<Vec<TextSpan>>,
    pub text: String,
    pub caps_ratio: f64,
    pub center_x: f64,
    pub width: f64,
    pub height: f64,
    pub line_count: usize,
    pub char_count: usize,
    pub starts_with_paren: bool,
    pub ends_with_paren: bool,
    pub is_italic: bool,
    pub is_bold: bool,
    pub is_merged_parenthetical: bool,
    pub is_split_continuation: bool,
    pub is_cue_with_inline_paren: bool,
}

/// The extractor's output (PyMuPDF `get_text("dict")` shape): pages > blocks > lines > spans.
#[derive(Clone, Debug, Deserialize)]
pub struct RawSpan {
    pub text: String,
    pub font: String,
    pub size: f64,
    pub flags: i64,
}

#[derive(Clone, Debug, Deserialize)]
pub struct RawLine {
    pub bbox: [f64; 4],
    pub spans: Vec<RawSpan>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct RawBlock {
    #[serde(default)]
    pub r#type: i64,
    pub lines: Vec<RawLine>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct RawPage {
    pub blocks: Vec<RawBlock>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct RawDoc {
    pub pages: Vec<RawPage>,
}
