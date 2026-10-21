//! Block classification: each block is scored against a library of weighted conventions (typographic, positional,
//! frequency, regex), then a sequence pass attributes speakers. Port of `_score_block(s)`, `_reorder_columns`,
//! `_classify_blocks` (minus the learned-style pass, which is `style.rs`) and `_silence_bare_names`.

use crate::blocks::PAGE_MARKER_RE;
use crate::model::{compute_doc_stats, normalize_speaker, DocStats, DocumentModel, LayoutProfile, X_TOLERANCE};
use crate::pystr::{is_alpha, is_upper, len, strip};
use crate::types::TextBlock;
use regex::Regex;
use serde::Serialize;
use std::sync::LazyLock;

const TWO_COLUMN_MIN_GAP: f64 = 200.0;

// Block types, in the order Python's `_BTYPES` lists them (ties go to the earliest).
const CC: usize = 0;
const DL: usize = 1;
const SD: usize = 2;
const PA: usize = 3;
const SH: usize = 4;
const NO: usize = 5;
const BTYPES: [&str; 6] = ["character_cue", "dialog", "stage_direction", "parenthetical", "scene_heading", "noise"];

static SCENE_HEADING_BLOCK_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"(?xi)^(?:
        (?:INT|EXT|INT\.\/EXT|EXT\.\/INT)[\.\s]   # INT./EXT. sluglines
        | SCENE\s+\w+                               # SCENE 3 / SCENE IV
        | ACT\s+\w+                                 # ACT I / ACT ONE
        | PART\s+\w+                                # PART ONE
        | PROLOGUE\b | EPILOGUE\b
        | (?:ONE|TWO|THREE|FOUR|FIVE|SIX|SEVEN|EIGHT|NINE|TEN|\d+)  # e.g. THREE DAYS TO DEPARTURE
          \s+DAYS?\s+(?:TO|UNTIL|BEFORE|AFTER)\b
    )",
    )
    .unwrap()
});
static SIG_INT_EXT_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)^(INT|EXT|INT\.\/EXT|EXT\.\/INT)[\.\s]").unwrap());
static SIG_ACT_SCENE_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)^(ACT\s+[IVX\d]+|SCENE\s+[IVX\d]+)").unwrap());
// The class is `[\:\.s]` in parser.py (an 's' slipped in); kept as is so behaviour matches.
static SIG_TRANSITION_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)^(CUT TO|FADE (?:TO|IN|OUT)|SMASH CUT|DISSOLVE TO|MATCH CUT)[\:\.s]?\s*$").unwrap()
});
static SIG_PAGENUM_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^\d+\.?$").unwrap());
static SIG_VO_OS_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)\(V\.O\.\)|\(O\.S\.\)|\(O\.C\.\)|\(PRE-LAP\)|\(NARR\.\)").unwrap());
static SIG_CONTD_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)\(CONT'D\)|\(MORE\)").unwrap());
static NAME_LINE_BRACKET_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\(([^)]*)\)").unwrap());

fn b2f(b: bool) -> f64 {
    if b { 1.0 } else { 0.0 }
}

#[derive(Clone, Copy)]
enum Sig {
    AllCaps, MixedCase, IsShort, IsLong, SingleLine, BalancedParens, IsItalic, IsBold, AtSpeakerX, AtDialogX,
    AtStageDirX, NearPageEdgeY, SpeakerZone, DialogZone, TextUniqueness, MatchesIntExt, MatchesActScene,
    MatchesTransition, IsPageNumber, VoOsSuffix, ContinuedSuffix, SimultaneousSlash,
}

fn signal(s: Sig, b: &TextBlock, p: &LayoutProfile, d: &DocStats) -> f64 {
    let zone = |b: &TextBlock| -> (f64, f64) {
        let xb = crate::model::x_bucket(b.x0);
        let freq = if d.max_x_count != 0 { *d.x_bin_count.get(&xb).unwrap_or(&0) as f64 / d.max_x_count as f64 } else { 0.0 };
        (freq, *d.x_bin_caps_avg.get(&xb).unwrap_or(&0.0))
    };
    match s {
        Sig::AllCaps => b.caps_ratio,
        Sig::MixedCase => 1.0 - b.caps_ratio,
        Sig::IsShort => f64::max(0.0, 1.0 - b.char_count as f64 / 50.0),
        Sig::IsLong => f64::min(1.0, b.char_count as f64 / 120.0),
        Sig::SingleLine => b2f(b.line_count == 1),
        Sig::BalancedParens => b2f(b.starts_with_paren && b.ends_with_paren),
        Sig::IsItalic => b2f(b.is_italic),
        Sig::IsBold => b2f(b.is_bold),
        Sig::AtSpeakerX => b2f((b.x0 - p.speaker_x).abs() <= X_TOLERANCE),
        Sig::AtDialogX => b2f((b.x0 - p.dialog_x).abs() <= X_TOLERANCE),
        Sig::AtStageDirX => match p.stage_dir_x {
            None => 0.0,
            Some(x) => b2f((b.x0 - x).abs() <= X_TOLERANCE),
        },
        Sig::NearPageEdgeY => b2f(b.y0 < d.body_top || b.y1 > d.body_bottom),
        Sig::SpeakerZone => {
            let (freq, caps_avg) = zone(b);
            freq * caps_avg
        }
        Sig::DialogZone => {
            let (freq, caps_avg) = zone(b);
            freq * (1.0 - caps_avg)
        }
        Sig::TextUniqueness => {
            let freq = *d.text_frequency.get(strip(&b.text)).unwrap_or(&1);
            f64::max(0.0, 1.0 - (freq as f64 - 1.0) / 5.0)
        }
        Sig::MatchesIntExt => b2f(SIG_INT_EXT_RE.is_match(&b.text)),
        Sig::MatchesActScene => b2f(SIG_ACT_SCENE_RE.is_match(&b.text)),
        Sig::MatchesTransition => b2f(SIG_TRANSITION_RE.is_match(strip(&b.text))),
        Sig::IsPageNumber => b2f(SIG_PAGENUM_RE.is_match(strip(&b.text))),
        Sig::VoOsSuffix => b2f(SIG_VO_OS_RE.is_match(&b.text)),
        Sig::ContinuedSuffix => b2f(SIG_CONTD_RE.is_match(&b.text)),
        Sig::SimultaneousSlash => b2f(b.text.contains(" / ")),
    }
}

struct Convention {
    signal: Sig,
    weights: &'static [(usize, f64)],
    strength: f64,
}

// The convention library, in parser.py's order (float sums accumulate in this order).
static CONVENTIONS: &[Convention] = &[
    // Typographic
    Convention { signal: Sig::AllCaps, weights: &[(CC, 0.80), (DL, -0.40), (SD, -0.10), (PA, -0.20), (SH, 0.30)], strength: 0.90 },
    Convention { signal: Sig::MixedCase, weights: &[(CC, -0.30), (DL, 0.35), (SD, 0.35), (PA, 0.25), (SH, -0.20)], strength: 0.70 },
    Convention { signal: Sig::IsShort, weights: &[(CC, 0.50), (DL, -0.20), (SD, -0.10), (PA, 0.30), (SH, 0.20), (NO, 0.40)], strength: 0.70 },
    Convention { signal: Sig::IsLong, weights: &[(CC, -0.80), (DL, 0.30), (SD, 0.30), (PA, -0.60), (SH, -0.50), (NO, -0.70)], strength: 0.85 },
    Convention { signal: Sig::SingleLine, weights: &[(CC, 0.40), (DL, -0.10), (SD, -0.10), (PA, 0.25), (SH, 0.35), (NO, 0.50)], strength: 0.75 },
    Convention { signal: Sig::BalancedParens, weights: &[(CC, -0.30), (DL, -0.20), (SD, 0.30), (PA, 0.90), (SH, -0.40)], strength: 0.90 },
    Convention { signal: Sig::IsItalic, weights: &[(CC, 0.15), (DL, -0.10), (SD, 0.55), (PA, 0.35), (SH, -0.10)], strength: 0.65 },
    Convention { signal: Sig::IsBold, weights: &[(CC, 0.30), (DL, -0.10), (SD, -0.10), (PA, -0.10), (SH, 0.25)], strength: 0.55 },
    // Positional
    Convention { signal: Sig::AtSpeakerX, weights: &[(CC, 0.70), (DL, -0.20), (SD, 0.10), (PA, -0.10), (SH, 0.10)], strength: 0.85 },
    Convention { signal: Sig::AtDialogX, weights: &[(CC, -0.10), (DL, 0.65), (SD, -0.10), (PA, 0.55), (SH, -0.10)], strength: 0.80 },
    Convention { signal: Sig::AtStageDirX, weights: &[(CC, -0.20), (DL, -0.20), (SD, 0.65), (PA, -0.30), (SH, -0.10)], strength: 0.75 },
    Convention { signal: Sig::NearPageEdgeY, weights: &[(CC, -0.30), (DL, -0.30), (SD, -0.10), (PA, -0.20), (SH, -0.20), (NO, 0.65)], strength: 0.75 },
    // Document-frequency
    Convention { signal: Sig::SpeakerZone, weights: &[(CC, 0.90), (DL, -0.20), (SD, 0.10), (PA, 0.10), (SH, 0.20)], strength: 0.95 },
    Convention { signal: Sig::DialogZone, weights: &[(CC, -0.40), (DL, 0.65), (SD, 0.20), (PA, 0.40), (SH, -0.10)], strength: 0.90 },
    Convention { signal: Sig::TextUniqueness, weights: &[(CC, -0.50), (DL, 0.30), (SD, 0.35), (PA, 0.20), (SH, 0.20)], strength: 0.70 },
    // Pattern / regex
    Convention { signal: Sig::MatchesIntExt, weights: &[(CC, -0.80), (DL, -0.80), (SD, 0.10), (PA, -0.80), (SH, 0.95), (NO, -0.50)], strength: 0.99 },
    Convention { signal: Sig::MatchesActScene, weights: &[(CC, -0.20), (DL, -0.50), (SD, -0.10), (PA, -0.30), (SH, 0.85)], strength: 0.90 },
    Convention { signal: Sig::MatchesTransition, weights: &[(CC, -0.50), (DL, -0.50), (SD, 0.20), (PA, -0.30), (SH, 0.70)], strength: 0.92 },
    Convention { signal: Sig::IsPageNumber, weights: &[(CC, -0.90), (DL, -0.90), (SD, -0.70), (PA, -0.80), (SH, -0.80), (NO, 0.90)], strength: 0.95 },
    Convention { signal: Sig::VoOsSuffix, weights: &[(CC, 0.85), (DL, -0.40), (SD, -0.20), (PA, 0.10), (SH, -0.30)], strength: 0.92 },
    Convention { signal: Sig::ContinuedSuffix, weights: &[(CC, 0.75), (DL, -0.60), (SD, -0.40), (PA, -0.20), (SH, -0.40)], strength: 0.90 },
    Convention { signal: Sig::SimultaneousSlash, weights: &[(CC, -0.10), (DL, 0.60), (SD, -0.10), (PA, -0.10), (SH, -0.30)], strength: 0.70 },
];

#[derive(Clone, Debug)]
pub struct ScoredBlock {
    pub scores: [f64; 6],
    pub best_type: usize,
    pub confidence: f64,
}

/// Score one block against all conventions and return the winner.
pub fn score_block(block: &TextBlock, profile: &LayoutProfile, stats: &DocStats) -> ScoredBlock {
    let mut raw = [0.0f64; 6];
    for conv in CONVENTIONS {
        let sig = signal(conv.signal, block, profile, stats);
        if sig == 0.0 {
            continue;
        }
        for (bt, w) in conv.weights {
            raw[*bt] += sig * w * conv.strength;
        }
    }
    let mut best = 0;
    for t in 1..6 {
        if raw[t] > raw[best] {
            best = t;
        }
    }
    let mn = raw.iter().cloned().fold(f64::INFINITY, f64::min);
    let shifted: Vec<f64> = raw.iter().map(|v| v - mn).collect();
    let total = shifted.iter().fold(0.0, |a, v| a + v);
    let total = if total == 0.0 { 1.0 } else { total };
    ScoredBlock { scores: raw, best_type: best, confidence: shifted[best] / total }
}

/// Reorder blocks into reading order for multi-column layouts (left column of a page fully, then right).
pub fn reorder_columns(blocks: Vec<TextBlock>, model: &DocumentModel) -> Vec<TextBlock> {
    let mut cols = model.cue_columns.clone();
    cols.sort_by(|a, b| a.partial_cmp(b).unwrap());
    if cols.len() < 2 {
        return blocks;
    }
    if cols[cols.len() - 1] - cols[0] < TWO_COLUMN_MIN_GAP {
        return blocks;
    }
    let split = (cols[0] + cols[cols.len() - 1]) / 2.0;
    let mut pages: Vec<usize> = blocks.iter().map(|b| b.page).collect();
    pages.sort();
    pages.dedup();
    let mut ordered = Vec::with_capacity(blocks.len());
    for page in pages {
        let mut left: Vec<&TextBlock> = blocks.iter().filter(|b| b.page == page && b.x0 < split).collect();
        let mut right: Vec<&TextBlock> = blocks.iter().filter(|b| b.page == page && b.x0 >= split).collect();
        left.sort_by(|a, b| a.y0.partial_cmp(&b.y0).unwrap());
        right.sort_by(|a, b| a.y0.partial_cmp(&b.y0).unwrap());
        ordered.extend(left.into_iter().cloned());
        ordered.extend(right.into_iter().cloned());
    }
    ordered
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Role {
    SpeakerCue,
    Dialog,
    StageDirection,
    Parenthetical,
    SceneHeading,
    Noise,
}

#[derive(Clone, Debug, Serialize)]
pub struct ClassifiedBlock {
    pub block: TextBlock,
    pub role: Role,
    pub speaker: Option<String>,
    pub aside: Option<String>,
}

fn cb(block: &TextBlock, role: Role, speaker: Option<String>) -> ClassifiedBlock {
    ClassifiedBlock { block: block.clone(), role, speaker, aside: None }
}

/// The direction on a name line ("NADIA (laughing)" -> "(laughing)"), or None when the bracket is a label.
pub fn name_line_aside(text: &str, labels: &std::collections::HashSet<String>) -> Option<String> {
    let m = NAME_LINE_BRACKET_RE.captures(text)?;
    let content = strip(&m[1]);
    let letters: Vec<char> = content.chars().filter(|c| is_alpha(*c)).collect();
    if letters.is_empty() || letters.iter().all(|c| is_upper(*c)) || labels.contains(&content.to_lowercase()) {
        return None;
    }
    Some(format!("({content})"))
}

pub const NON_CAST_WORDS: &[&str] = &[
    "PAUSE", "BEAT", "SILENCE", "BLACKOUT", "INTERMISSION", "INTERVAL", "NIGHT", "DAY", "MORNING", "AFTERNOON",
    "EVENING", "DAWN", "DUSK", "NOON", "MIDNIGHT", "LATER", "CONTINUOUS", "MOMENTS", "SIMULTANEOUSLY", "END",
    "CURTAIN", "PROLOGUE", "EPILOGUE", "OK", "CONTINUED", "OMITTED", "INSERT", "INTERCUT", "INTERCUTTING",
    "MONTAGE", "FLASHBACK", "FLASHFORWARD", "BACK TO SCENE", "SERIES OF SHOTS", "TITLE", "SUPER", "CARD",
    "THE END", "FADE IN", "FADE OUT", "CHARACTERS", "CHARACTER", "CAST", "CAST OF CHARACTERS",
    "DRAMATIS PERSONAE", "SYNOPSIS",
];

fn rstrip_cue(s: &str) -> &str {
    s.trim_end_matches(['.', ':', ','])
}

/// Phases 1 and 2 of `_classify_blocks` (scoring, then the speaker-attribution sequence pass). The learned-style
/// pass and `_silence_bare_names` are applied by the caller.
pub fn classify_core(blocks: Vec<TextBlock>, model: &DocumentModel) -> Vec<ClassifiedBlock> {
    let profile = &model.profile;
    let blocks = reorder_columns(blocks, model);
    let stats = compute_doc_stats(&blocks);
    let mut result: Vec<ClassifiedBlock> = Vec::with_capacity(blocks.len());
    let mut pending: Option<String> = None;

    for block in &blocks {
        let sb = score_block(block, profile, &stats);
        let text = strip(&block.text);
        if text.is_empty() {
            result.push(cb(block, Role::Noise, None));
            continue;
        }
        if model.is_furniture(block) {
            result.push(cb(block, Role::Noise, None));
            continue;
        }
        if block.is_cue_with_inline_paren {
            let speaker = rstrip_cue(&normalize_speaker(text)).to_string();
            if !speaker.is_empty() {
                pending = Some(speaker.clone());
                let mut c = cb(block, Role::SpeakerCue, Some(speaker));
                c.aside = name_line_aside(text, &model.cue_labels);
                result.push(c);
            } else {
                result.push(cb(block, Role::Noise, None));
            }
            continue;
        }
        if PAGE_MARKER_RE.is_match(text) {
            result.push(cb(block, Role::Noise, None));
            continue;
        }
        if SCENE_HEADING_BLOCK_RE.is_match(text) {
            // Reject TOC entries: "SCENE N: long description..."
            let after_colon = text.find(':').map(|i| strip(&text[i + 1..])).unwrap_or("");
            if !text.contains(':') || len(after_colon) <= 30 {
                result.push(cb(block, Role::SceneHeading, None));
                continue;
            }
        }
        let role = BTYPES[sb.best_type];
        match role {
            "noise" => result.push(cb(block, Role::Noise, None)),
            "scene_heading" => result.push(cb(block, Role::StageDirection, None)),
            "parenthetical" => {
                let at_dlg = (block.x0 - profile.dialog_x).abs() <= X_TOLERANCE;
                let balanced = block.starts_with_paren && block.ends_with_paren;
                if balanced && block.char_count <= 120 && at_dlg {
                    result.push(cb(block, Role::Parenthetical, pending.clone()));
                } else if at_dlg && pending.is_some() && !balanced {
                    result.push(cb(block, Role::Dialog, pending.clone()));
                } else {
                    result.push(cb(block, Role::StageDirection, None));
                }
            }
            "character_cue" => {
                if block.is_split_continuation && pending.is_some() {
                    result.push(cb(block, Role::Dialog, pending.clone()));
                } else if block.caps_ratio >= 0.80 {
                    let off_column = (block.x0 - profile.speaker_x).abs() > X_TOLERANCE * 5.0;
                    if off_column && !model.near_cue_column(block.x0) {
                        result.push(cb(block, Role::StageDirection, None));
                    } else {
                        let speaker = rstrip_cue(&normalize_speaker(text)).to_string();
                        if speaker.is_empty() || NON_CAST_WORDS.contains(&speaker.as_str()) {
                            result.push(cb(block, Role::Noise, None));
                        } else {
                            pending = Some(speaker.clone());
                            result.push(cb(block, Role::SpeakerCue, Some(speaker)));
                        }
                    }
                } else {
                    let at_dlg = (block.x0 - profile.dialog_x).abs() <= X_TOLERANCE;
                    if at_dlg && pending.is_some() {
                        result.push(cb(block, Role::Dialog, pending.clone()));
                    } else {
                        result.push(cb(block, Role::StageDirection, None));
                    }
                }
            }
            "dialog" => {
                if pending.is_some() {
                    result.push(cb(block, Role::Dialog, pending.clone()));
                } else {
                    result.push(cb(block, Role::StageDirection, None));
                }
            }
            _ => result.push(cb(block, Role::StageDirection, None)),
        }
    }
    result
}

/// A line that is nothing but one of this script's character names is a name label, never narration.
pub fn silence_bare_names(result: &mut [ClassifiedBlock], model: &DocumentModel) {
    for c in result.iter_mut() {
        if c.role == Role::StageDirection {
            let norm = normalize_speaker(strip(&c.block.text));
            let name = strip(rstrip_cue(&norm));
            if !name.is_empty() && model.cast.contains(name) {
                c.role = Role::Noise;
                c.speaker = None;
            }
        }
    }
}
