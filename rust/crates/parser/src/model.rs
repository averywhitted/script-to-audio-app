//! The script's own conventions, learned in a first pass: layout columns, cast lexicon, page furniture, and the
//! document statistics the scorer uses. Port of `_infer_layout_profile`, `_build_document_model`, `_learn_cue_labels`,
//! `_compute_doc_stats`, `_body_region`, `_normalize_speaker`.

use crate::blocks::is_speaker_cue_text;
use crate::pystr::strip;
use crate::types::TextBlock;
use regex::Regex;
use serde::Serialize;
use std::collections::{BTreeSet, HashMap, HashSet};
use std::sync::LazyLock;

pub const X_TOLERANCE: f64 = 15.0;
const FURNITURE_Y_PIN_TOL: f64 = 36.0;
const BODY_MARGIN: f64 = 6.0;
const LABEL_MIN_COUNT: usize = 5;
const LABEL_MIN_SHARE: f64 = 0.10;

static CONTD_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)\s*\([^)]*CONT[']?D[^)]*\)").unwrap());
static PAREN_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\s*\([^)]*\)\s*").unwrap());
static WS_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\s+").unwrap());
static CLEAN_CUE_NAME_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^[A-Z][A-Z0-9 .'\-]*$").unwrap());
static NAME_LINE_BRACKET_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\(([^)]*)\)").unwrap());

/// Universal non-name words that look like cues but are scene beats, production markers or front matter.
const NON_CAST_WORDS: &[&str] = &[
    "PAUSE", "BEAT", "SILENCE", "BLACKOUT", "INTERMISSION", "INTERVAL", "NIGHT", "DAY", "MORNING", "AFTERNOON",
    "EVENING", "DAWN", "DUSK", "NOON", "MIDNIGHT", "LATER", "CONTINUOUS", "MOMENTS", "SIMULTANEOUSLY", "END",
    "CURTAIN", "PROLOGUE", "EPILOGUE", "OK", "CONTINUED", "OMITTED", "INSERT", "INTERCUT", "INTERCUTTING",
    "MONTAGE", "FLASHBACK", "FLASHFORWARD", "BACK TO SCENE", "SERIES OF SHOTS", "TITLE", "SUPER", "CARD",
    "THE END", "FADE IN", "FADE OUT", "CHARACTERS", "CHARACTER", "CAST", "CAST OF CHARACTERS",
    "DRAMATIS PERSONAE", "SYNOPSIS",
];

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct LayoutProfile {
    pub speaker_x: f64,
    pub dialog_x: f64,
    pub stage_dir_x: Option<f64>,
    pub page_width: f64,
    pub is_split_layout: bool,
}

#[derive(Clone, Debug)]
pub struct DocumentModel {
    pub profile: LayoutProfile,
    /// normalized name -> cue-candidate occurrence count
    pub cast_lexicon: HashMap<String, usize>,
    /// names seen as a cue at least twice
    pub cast: HashSet<String>,
    pub cue_columns: Vec<f64>,
    pub dialog_columns: Vec<f64>,
    /// exact texts that repeat across many pages pinned to one vertical position
    pub furniture: HashSet<String>,
    pub cue_labels: HashSet<String>,
}

impl DocumentModel {
    pub fn is_cast(&self, name: Option<&str>) -> bool {
        name.map_or(false, |n| !n.is_empty() && self.cast.contains(n))
    }
    pub fn near_cue_column(&self, x: f64) -> bool {
        self.cue_columns.iter().any(|c| (x - c).abs() <= X_TOLERANCE)
    }
    pub fn near_dialog_column(&self, x: f64) -> bool {
        self.dialog_columns.iter().any(|c| (x - c).abs() <= X_TOLERANCE)
    }
    pub fn is_furniture(&self, block: &TextBlock) -> bool {
        self.furniture.contains(strip(&block.text))
    }
}

#[derive(Clone, Debug, Serialize)]
pub struct DocStats {
    pub x_bin_count: HashMap<i64, usize>,
    pub x_bin_caps_avg: HashMap<i64, f64>,
    pub text_frequency: HashMap<String, usize>,
    pub max_x_count: usize,
    pub total_blocks: usize,
    pub body_top: f64,
    pub body_bottom: f64,
}

/// Python `round(x / 5) * 5` (round half to even, on floats).
pub fn x_bucket(x: f64) -> i64 {
    (x / 5.0).round_ties_even() as i64 * 5
}

/// A counter that remembers first-seen order, so ties resolve like Python's `Counter.most_common(1)`.
struct Counter<K: std::hash::Hash + Eq + Clone> {
    order: Vec<K>,
    counts: HashMap<K, usize>,
}

impl<K: std::hash::Hash + Eq + Clone> Counter<K> {
    fn new() -> Self {
        Counter { order: Vec::new(), counts: HashMap::new() }
    }
    fn add(&mut self, k: K) {
        let n = self.counts.entry(k.clone()).or_insert(0);
        if *n == 0 {
            self.order.push(k);
        }
        *n += 1;
    }
    fn most_common_1(&self) -> Option<&K> {
        let mut best: Option<(&K, usize)> = None;
        for k in &self.order {
            let n = self.counts[k];
            if best.map_or(true, |(_, bn)| n > bn) {
                best = Some((k, n));
            }
        }
        best.map(|(k, _)| k)
    }
}

fn modal_x(xs: &[f64]) -> Option<f64> {
    let mut c = Counter::new();
    for x in xs {
        c.add(x_bucket(*x));
    }
    c.most_common_1().map(|b| *b as f64)
}

/// `_normalize_speaker`: parentheticals and "(CONT'D)" removed, whitespace collapsed.
pub fn normalize_speaker(s: &str) -> String {
    let s = CONTD_RE.replace_all(s, "");
    let base = strip(&PAREN_RE.replace_all(&s, "")).to_string();
    WS_RE.replace_all(&base, " ").into_owned()
}

fn trim_cue_punct(s: &str) -> &str {
    strip(s.trim_end_matches(['.', ':', ',']))
}

pub fn infer_layout_profile(blocks: &[TextBlock], page_width: f64, exclude_stage_dir_cols: &[f64]) -> LayoutProfile {
    let mut cue_xs = Vec::new();
    let mut dialog_xs = Vec::new();
    for (i, block) in blocks.iter().enumerate() {
        if !(block.line_count == 1 && is_speaker_cue_text(&block.text)) {
            continue;
        }
        cue_xs.push(block.x0);
        if let Some(nxt) = blocks.get(i + 1) {
            if nxt.caps_ratio < 0.5 && !(nxt.starts_with_paren && nxt.ends_with_paren) {
                dialog_xs.push(nxt.x0);
            }
        }
    }
    // Python: `_modal_x(...) or fallback`, so a modal bucket of exactly 0.0 falls back too.
    let speaker_x = modal_x(&cue_xs).filter(|v| *v != 0.0).unwrap_or(page_width / 2.0);
    let dialog_x = modal_x(&dialog_xs).filter(|v| *v != 0.0).unwrap_or(90.0);
    let excluded = |x: f64| exclude_stage_dir_cols.iter().any(|c| (x - c).abs() <= X_TOLERANCE);
    let stage_dir_xs: Vec<f64> = blocks
        .iter()
        .filter(|b| {
            b.caps_ratio < 0.5
                && b.char_count > 20
                && (b.x0 - dialog_x).abs() > 20.0
                && !excluded(b.x0)
                && !is_speaker_cue_text(&b.text)
                && !(b.starts_with_paren && b.ends_with_paren)
        })
        .map(|b| b.x0)
        .collect();
    LayoutProfile {
        speaker_x,
        dialog_x,
        stage_dir_x: modal_x(&stage_dir_xs),
        page_width,
        is_split_layout: (speaker_x - dialog_x).abs() > 30.0,
    }
}

/// If a block looks like a speaker cue, its normalized name.
pub fn cue_candidate_name(block: &TextBlock) -> Option<String> {
    if block.is_cue_with_inline_paren || (block.line_count == 1 && is_speaker_cue_text(&block.text)) {
        let normalized = normalize_speaker(&block.text);
        let name = strip(normalized.trim_end_matches(['.', ':', ','])).to_string();
        if !name.is_empty() && CLEAN_CUE_NAME_RE.is_match(&name) && !NON_CAST_WORDS.contains(&name.as_str()) {
            return Some(name);
        }
    }
    None
}

/// 5pt x-buckets holding at least max(5, 8% of `total`) entries, ascending.
fn dense_buckets(xs: &[f64], total: usize) -> Vec<f64> {
    if xs.is_empty() {
        return vec![];
    }
    let mut counts: HashMap<i64, usize> = HashMap::new();
    for x in xs {
        *counts.entry(x_bucket(*x)).or_insert(0) += 1;
    }
    let threshold = 5.max((0.08 * total as f64) as usize);
    let mut out: Vec<f64> = counts.into_iter().filter(|(_, n)| *n >= threshold).map(|(b, _)| b as f64).collect();
    out.sort_by(|a, b| a.partial_cmp(b).unwrap());
    out
}

pub fn build_document_model(blocks: &[TextBlock], page_width: f64) -> DocumentModel {
    let mut lexicon: Counter<String> = Counter::new();
    for block in blocks {
        let Some(name) = cue_candidate_name(block) else { continue };
        let parts: Vec<&str> = if name.contains(" / ") { name.split(" / ").map(strip).collect() } else { vec![name.as_str()] };
        for p in parts {
            if !p.is_empty() {
                lexicon.add(p.to_string());
            }
        }
    }
    let cast: HashSet<String> = lexicon.counts.iter().filter(|(_, n)| **n >= 2).map(|(k, _)| k.clone()).collect();

    let mut cue_xs = Vec::new();
    let mut dialog_xs = Vec::new();
    for (i, block) in blocks.iter().enumerate() {
        let name = cue_candidate_name(block);
        let primary: Option<String> = name.as_ref().map(|n| {
            if n.contains(" / ") { strip(n.split(" / ").next().unwrap()).to_string() } else { n.clone() }
        });
        match primary {
            Some(p) if !p.is_empty() && cast.contains(&p) => {}
            _ => continue,
        }
        cue_xs.push(block.x0);
        if let Some(nxt) = blocks.get(i + 1) {
            if nxt.caps_ratio < 0.5 && !(nxt.starts_with_paren && nxt.ends_with_paren) {
                dialog_xs.push(nxt.x0);
            }
        }
    }
    let total_cues = cue_xs.len();
    let cue_columns = dense_buckets(&cue_xs, total_cues);
    let dialog_columns = dense_buckets(&dialog_xs, total_cues);

    // Page furniture: repeated across many pages and pinned to one vertical position.
    let mut pages_by_text: HashMap<String, BTreeSet<usize>> = HashMap::new();
    let mut ys_by_text: HashMap<String, Vec<f64>> = HashMap::new();
    for block in blocks {
        let t = strip(&block.text);
        if !t.is_empty() {
            pages_by_text.entry(t.to_string()).or_default().insert(block.page);
            ys_by_text.entry(t.to_string()).or_default().push(block.y0);
        }
    }
    let n_pages = blocks.iter().map(|b| b.page).max().unwrap_or(0) + 1;
    let furniture_threshold = 5.max((0.05 * n_pages as f64) as usize);
    let mut furniture = HashSet::new();
    for (text, pages) in &pages_by_text {
        if pages.len() < furniture_threshold {
            continue;
        }
        let norm = trim_cue_punct(&normalize_speaker(text)).to_string();
        if cast.contains(&norm) {
            continue;
        }
        let ys = &ys_by_text[text];
        let (lo, hi) = ys.iter().fold((f64::INFINITY, f64::NEG_INFINITY), |(lo, hi), y| (lo.min(*y), hi.max(*y)));
        if hi - lo <= FURNITURE_Y_PIN_TOL {
            furniture.insert(text.clone());
        }
    }

    let profile = infer_layout_profile(blocks, page_width, &dialog_columns);
    DocumentModel {
        profile,
        cast_lexicon: lexicon.counts.clone(),
        cast,
        cue_columns,
        dialog_columns,
        furniture,
        cue_labels: learn_cue_labels(blocks),
    }
}

/// Name-line brackets this script repeats heavily, so they are labels rather than directions.
pub fn learn_cue_labels(blocks: &[TextBlock]) -> HashSet<String> {
    let mut counts: HashMap<String, usize> = HashMap::new();
    for b in blocks {
        if b.is_cue_with_inline_paren {
            if let Some(m) = NAME_LINE_BRACKET_RE.captures(&b.text) {
                *counts.entry(strip(&m[1]).to_lowercase()).or_insert(0) += 1;
            }
        }
    }
    let total: usize = counts.values().sum();
    counts
        .into_iter()
        .filter(|(_, n)| *n >= LABEL_MIN_COUNT && (*n as f64) >= LABEL_MIN_SHARE * total as f64)
        .map(|(c, _)| c)
        .collect()
}

/// Where this script's body text sits on the page, learned from the text right after character names.
pub fn body_region(blocks: &[TextBlock]) -> (f64, f64) {
    let (mut ys0, mut ys1): (Vec<f64>, Vec<f64>) = (vec![], vec![]);
    if blocks.len() > 1 {
        for (i, b) in blocks[..blocks.len() - 1].iter().enumerate() {
            if b.line_count == 1 && is_speaker_cue_text(&b.text) {
                let nxt = &blocks[i + 1];
                if nxt.page == b.page && !is_speaker_cue_text(&nxt.text) {
                    ys0.push(b.y0);
                    ys1.push(nxt.y1);
                }
            }
        }
    }
    if ys1.len() < 20 {
        return (60.0, 732.0);
    }
    ys0.sort_by(|a, b| a.partial_cmp(b).unwrap());
    ys1.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let top = ys0[(0.01 * ys0.len() as f64) as usize];
    let bottom = ys1[(ys1.len() - 1).min((0.99 * ys1.len() as f64) as usize)];
    (top - BODY_MARGIN, bottom + BODY_MARGIN)
}

pub fn compute_doc_stats(blocks: &[TextBlock]) -> DocStats {
    let mut x_count: HashMap<i64, usize> = HashMap::new();
    let mut x_caps_sum: HashMap<i64, f64> = HashMap::new();
    let mut text_freq: HashMap<String, usize> = HashMap::new();
    for b in blocks {
        let xb = x_bucket(b.x0);
        *x_count.entry(xb).or_insert(0) += 1;
        *x_caps_sum.entry(xb).or_insert(0.0) += b.caps_ratio;
        *text_freq.entry(strip(&b.text).to_string()).or_insert(0) += 1;
    }
    let x_caps_avg = x_count.iter().map(|(xb, n)| (*xb, x_caps_sum[xb] / *n as f64)).collect();
    let max_x = x_count.values().copied().max().unwrap_or(1);
    let (top, bottom) = body_region(blocks);
    DocStats {
        x_bin_count: x_count,
        x_bin_caps_avg: x_caps_avg,
        text_frequency: text_freq,
        max_x_count: max_x,
        total_blocks: blocks.len(),
        body_top: top,
        body_bottom: bottom,
    }
}

/// Page width as `_block_parse` derives it from the blocks.
pub fn page_width_of(blocks: &[TextBlock]) -> f64 {
    blocks.iter().map(|b| b.x1).filter(|x| *x > 200.0).fold(None, |m: Option<f64>, x| Some(m.map_or(x, |m| m.max(x))))
        .map_or(612.0, |m| m + 90.0)
}
