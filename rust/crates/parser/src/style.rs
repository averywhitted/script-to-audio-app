//! Learned style: what THIS script's dialogue and directions look like. Every script marks its stage directions its
//! own way, so each block is described by general features, the script supplies its own examples of dialogue (the
//! text right after a character's name), and a two-part mixture model learns what everything else looks like.
//! Port of `_style_features`, `_learn_style`, `_apply_learned_style`, `_split_leading_paren`.

use crate::classify::{ClassifiedBlock, Role};
use crate::model::DocumentModel;
use crate::pystr::{is_alpha, is_space, is_upper, len, py_sum, strip};
use crate::types::TextBlock;
use regex::Regex;
use std::collections::{HashMap, HashSet};
use std::sync::LazyLock;

const STYLE_MIN_ANCHORS: usize = 20;
const STYLE_EM_ROUNDS: usize = 30;
const STYLE_SMOOTHING: f64 = 1.0;
const STYLE_OVERRIDE_LR: f64 = 19.0;
const UNKNOWN: &str = "?";

static FAMILY_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)[-,]?(?:Bold|Italic|Oblique|BoldItalic|BoldOblique|Regular|Roman|MT|PS)+$").unwrap()
});

/// Split a leading parenthetical from the rest: `(Some("(...)"), rest)` or `(None, text)`.
pub fn split_leading_paren(text: &str) -> (Option<&str>, &str) {
    if !text.starts_with('(') {
        return (None, text);
    }
    let mut depth = 0i64;
    for (i, c) in text.char_indices() {
        if c == '(' {
            depth += 1;
        } else if c == ')' {
            depth -= 1;
            if depth == 0 {
                let paren = &text[..i + 1];
                let rest = strip(&text[i + 1..]);
                if !rest.is_empty() {
                    return (Some(paren), rest);
                }
                break;
            }
        }
    }
    (None, text)
}

/// Insertion-ordered counter (Python `Counter.most_common(1)` keeps the first-seen maximum).
struct Counter<K: std::hash::Hash + Eq + Clone> {
    order: Vec<K>,
    counts: HashMap<K, usize>,
}

impl<K: std::hash::Hash + Eq + Clone> Counter<K> {
    fn new() -> Self {
        Counter { order: vec![], counts: HashMap::new() }
    }
    fn add(&mut self, k: K) {
        let n = self.counts.entry(k.clone()).or_insert(0);
        if *n == 0 {
            self.order.push(k);
        }
        *n += 1;
    }
    fn top(&self) -> Option<&K> {
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

/// Python `repr(float)` for the half-point sizes used here ("12.0", "9.5").
fn py_float(x: f64) -> String {
    format!("{:?}", x)
}

pub fn style_features(block: &TextBlock, page_width: f64) -> Vec<String> {
    let full = strip(&block.text);
    let mut rest = full;
    // Peel leading asides exactly as script assembly does.
    while rest.starts_with('(') {
        let (lead, after) = split_leading_paren(rest);
        if lead.is_none() || strip(after).is_empty() {
            break;
        }
        rest = strip(after);
    }
    if strip(rest).is_empty() {
        rest = full;
    }
    let skip = len(full) - len(rest); // characters of leading asides to leave out

    let (mut total, mut ital, mut bold) = (0usize, 0usize, 0usize);
    let mut fonts: Counter<String> = Counter::new();
    let mut sizes: Counter<i64> = Counter::new(); // keyed by 2*size, so half-points are exact
    let mut seen = 0usize;
    for spans in &block.lines {
        for sp in spans {
            for ch in sp.text.chars() {
                seen += 1;
                if seen <= skip || is_space(ch) {
                    continue;
                }
                total += 1;
                ital += sp.italic as usize;
                bold += sp.bold as usize;
                fonts.add(FAMILY_RE.replace(&sp.font, "").into_owned());
                sizes.add((sp.size * 2.0).round_ties_even() as i64);
            }
        }
    }
    let text = strip(rest);
    let starts_paren = text.starts_with('(');
    let ends_paren = text.ends_with(')');
    let alpha = text.chars().filter(|c| is_alpha(*c)).count();
    let upper = text.chars().filter(|c| is_alpha(*c) && is_upper(*c)).count();
    let caps_ratio = upper as f64 / alpha.max(1) as f64;

    let share = |k: usize| -> String {
        if total == 0 {
            return UNKNOWN.to_string();
        }
        let r = k as f64 / total as f64;
        (if r >= 0.95 { "all" } else if r > 0.05 { "some" } else { "none" }).to_string()
    };
    let last = text.chars().last();
    let mut end: String = match last {
        None => String::new(),
        Some(c) if "?!.,".contains(c) => c.to_string(),
        Some(_) => "other".to_string(),
    };
    if text.ends_with("?\u{201d}") || text.ends_with("?\"") {
        end = "?".into();
    } else if text.ends_with("!\u{201d}") || text.ends_with("!\"") {
        end = "!".into();
    }
    let paren = if starts_paren && ends_paren { "both" } else if starts_paren { "open" } else { "none" };
    let caps = if caps_ratio >= 0.8 { "high" } else if caps_ratio >= 0.3 { "mid" } else { "low" };
    let quoted = text.starts_with('\u{201c}') || text.starts_with('"');
    let unknown = || UNKNOWN.to_string();
    vec![
        format!("x{}", (block.x0 / page_width.max(1.0) * 50.0).round_ties_even() as i64),
        if total > 0 { format!("it:{}", share(ital)) } else { unknown() },
        if total > 0 { format!("bd:{}", share(bold)) } else { unknown() },
        fonts.top().map_or_else(unknown, |f| format!("font:{f}")),
        sizes.top().map_or_else(unknown, |s| format!("size:{}", py_float(*s as f64 / 2.0))),
        format!("paren:{paren}"),
        format!("end:{end}"),
        format!("quote:{}", if quoted { "True" } else { "False" }),
        format!("caps:{caps}"),
    ]
}

type Table = Vec<HashMap<String, f64>>;

pub struct Learned {
    /// indices into `result` of the non-anchor blocks (the "pool")
    pub pool: Vec<usize>,
    pub evidence: Vec<f64>,
    pub speaker: Vec<Option<String>>,
    pub prior: f64,
    pub dialog: Table,
    pub direction: Table,
}

fn make_table(weighted: &[(&Vec<String>, f64)], n_feat: usize, values: &[HashSet<String>]) -> Table {
    let mut out = Vec::with_capacity(n_feat);
    for k in 0..n_feat {
        let mut counts: HashMap<&str, f64> = HashMap::new();
        let mut known = 0.0;
        for (f, w) in weighted {
            if f[k] != UNKNOWN {
                *counts.entry(f[k].as_str()).or_insert(0.0) += *w;
                known += *w;
            }
        }
        let vals: Vec<&String> = values[k].iter().filter(|v| v.as_str() != UNKNOWN).collect();
        let denom = known + STYLE_SMOOTHING * vals.len().max(1) as f64;
        out.push(vals.iter().map(|v| ((*v).clone(), (counts.get(v.as_str()).copied().unwrap_or(0.0) + STYLE_SMOOTHING) / denom)).collect());
    }
    out
}

fn loglik(t: &Table, f: &[String]) -> f64 {
    py_sum(f.iter().enumerate().filter(|(_, v)| v.as_str() != UNKNOWN).map(|(k, v)| t[k][v].ln()))
}

/// Fit this script's style model. None when the script has too few named speeches to learn from.
pub fn learn_style(result: &[ClassifiedBlock], model: &DocumentModel) -> Option<Learned> {
    let page_width = model.profile.page_width;
    let (mut anchors, mut pool, mut pool_speaker): (Vec<usize>, Vec<usize>, Vec<Option<String>>) = (vec![], vec![], vec![]);
    let mut prev: Option<usize> = None;
    let mut speaking: Option<String> = None;
    for (i, cb) in result.iter().enumerate() {
        if cb.role == Role::Noise {
            continue;
        }
        match cb.role {
            Role::SceneHeading => speaking = None,
            Role::SpeakerCue => speaking = cb.speaker.clone(),
            Role::Dialog | Role::StageDirection | Role::Parenthetical => {
                if cb.role == Role::Dialog && prev.map_or(false, |p| result[p].role == Role::SpeakerCue) {
                    anchors.push(i);
                } else {
                    pool.push(i);
                    pool_speaker.push(speaking.clone());
                }
            }
            Role::Noise => {}
        }
        prev = Some(i);
    }
    if anchors.len() < STYLE_MIN_ANCHORS || pool.is_empty() {
        return None;
    }

    let anchor_f: Vec<Vec<String>> = anchors.iter().map(|i| style_features(&result[*i].block, page_width)).collect();
    let pool_f: Vec<Vec<String>> = pool.iter().map(|i| style_features(&result[*i].block, page_width)).collect();
    let n_feat = anchor_f.first().unwrap_or(&pool_f[0]).len();
    let mut values: Vec<HashSet<String>> = vec![HashSet::new(); n_feat];
    for f in anchor_f.iter().chain(pool_f.iter()) {
        for (k, v) in f.iter().enumerate() {
            values[k].insert(v.clone());
        }
    }

    let dialog_t = make_table(&anchor_f.iter().map(|f| (f, 1.0)).collect::<Vec<_>>(), n_feat, &values);
    let mut resp = vec![0.5f64; pool_f.len()];
    let mut prior = 0.5f64;
    let mut dir_t: Table = vec![];
    for _ in 0..STYLE_EM_ROUNDS {
        dir_t = make_table(&pool_f.iter().zip(resp.iter()).map(|(f, r)| (f, *r)).collect::<Vec<_>>(), n_feat, &values);
        let mut new = Vec::with_capacity(pool_f.len());
        for f in &pool_f {
            let a = prior.ln() + loglik(&dir_t, f);
            let b = (1.0 - prior).ln() + loglik(&dialog_t, f);
            let m = a.max(b);
            new.push((a - m).exp() / ((a - m).exp() + (b - m).exp()));
        }
        resp = new;
        prior = (py_sum(resp.iter().cloned()) / resp.len() as f64).max(0.01).min(0.99);
    }
    let evidence = pool_f.iter().map(|f| loglik(&dir_t, f) - loglik(&dialog_t, f)).collect();
    Some(Learned { pool, evidence, speaker: pool_speaker, prior, dialog: dialog_t, direction: dir_t })
}

/// Hand a line to the narrator only when its own look is much more typical of this script's directions than of its
/// dialogue (odds 19:1), and the reverse for lines the classifier gave to the narrator inside a speaking scene.
pub fn apply_learned_style(result: &mut [ClassifiedBlock], model: &DocumentModel) {
    let Some(learned) = learn_style(result, model) else { return };
    let sure = STYLE_OVERRIDE_LR.ln();
    for ((idx, lr), speaker) in learned.pool.iter().zip(learned.evidence.iter()).zip(learned.speaker.iter()) {
        let cb = &mut result[*idx];
        if cb.role == Role::Dialog && *lr >= sure {
            cb.role = Role::StageDirection;
            cb.speaker = None;
        } else if cb.role == Role::StageDirection && *lr <= -sure && speaker.as_ref().map_or(false, |s| !s.is_empty()) {
            cb.role = Role::Dialog;
            cb.speaker = speaker.clone();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn split_leading_paren_matches_python() {
        assert_eq!(split_leading_paren("(quietly) Hello there"), (Some("(quietly)"), "Hello there"));
        assert_eq!(split_leading_paren("(only this)"), (None, "(only this)"));
        assert_eq!(split_leading_paren("(a (nested) one) rest"), (Some("(a (nested) one)"), "rest"));
        assert_eq!(split_leading_paren("no paren"), (None, "no paren"));
        assert_eq!(split_leading_paren("(unclosed rest"), (None, "(unclosed rest"));
    }

    #[test]
    fn family_regex_strips_style_suffixes() {
        assert_eq!(FAMILY_RE.replace("TimesNewRomanPS-BoldMT", ""), "TimesNewRoman");
        assert_eq!(FAMILY_RE.replace("Courier-Oblique", ""), "Courier");
        assert_eq!(FAMILY_RE.replace("Sylfaen", ""), "Sylfaen");
    }

    #[test]
    fn floats_print_like_python() {
        assert_eq!(py_float(12.0), "12.0");
        assert_eq!(py_float(9.5), "9.5");
    }
}
