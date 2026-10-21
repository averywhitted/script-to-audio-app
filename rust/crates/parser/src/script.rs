//! Script assembly: classified blocks -> scenes and elements, then the finishing passes (timing beats dropped,
//! over-long scenes chunked, character list sanitized, one-off speakers flagged) and the corrections config.
//! Port of `_build_script_from_blocks`, `_finalise` and what they call.

use crate::classify::{ClassifiedBlock, Role};
use crate::model::normalize_speaker;
use crate::pystr::strip;
use crate::style::split_leading_paren;
use regex::Regex;
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::sync::LazyLock;

const CHUNK_TARGET_LINES: usize = 75;
const CHUNK_MIN_LINES: usize = 20;

#[derive(Clone, Debug, PartialEq)]
pub struct Element {
    pub kind: String, // "dialog" | "stage_direction" | "parenthetical"
    pub text: String,
    pub speaker: Option<String>,
    pub overlap_cue: Option<Vec<String>>,
    pub overlap_texts: Option<Vec<String>>,
    pub confidence: f64,
    pub reason: Option<String>,
}

impl Element {
    fn new(kind: &str, text: String, speaker: Option<String>) -> Element {
        Element { kind: kind.into(), text, speaker, overlap_cue: None, overlap_texts: None, confidence: 1.0, reason: None }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Character {
    pub name: String,
    pub gender_hint: Option<String>,
    pub role_hint: Option<String>,
    pub age_hint: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Scene {
    pub number: usize,
    pub title: String,
    pub elements: Vec<Element>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Script {
    pub title: String,
    pub characters: Vec<Character>,
    pub scenes: Vec<Scene>,
}

/// The worker's `_script_summary` shape (the app's `script.json` content), element order and all.
pub fn script_summary_json(script: &Script) -> Value {
    let line_count = script.scenes.iter().flat_map(|s| s.elements.iter()).filter(|e| e.kind == "dialog").count();
    json!({
        "title": script.title,
        "sceneCount": script.scenes.len(),
        "characterCount": script.characters.len(),
        "lineCount": line_count,
        "characters": script.characters.iter().map(|c| json!({
            "name": c.name, "genderHint": c.gender_hint, "roleHint": c.role_hint,
        })).collect::<Vec<_>>(),
        "scenes": script.scenes.iter().map(|sc| {
            let els: Vec<&Element> = sc.elements.iter().filter(|e| !strip(&e.text).is_empty()).collect();
            json!({
                "number": sc.number, "title": sc.title, "elementCount": els.len(),
                "elements": els.iter().map(|e| json!({
                    "kind": e.kind, "speaker": e.speaker, "text": e.text, "overlapCue": e.overlap_cue,
                    "overlapTexts": e.overlap_texts, "confidence": e.confidence, "reason": e.reason,
                })).collect::<Vec<_>>(),
            })
        }).collect::<Vec<_>>(),
    })
}

// ── corrections config (backend/corrections_config.json) ──────────────────────────────────────────────────────

#[derive(Default)]
pub struct Config {
    pub non_cue_words: Vec<String>,
    pub speaker_aliases: HashMap<String, String>,
    pub noise_line_patterns: Vec<Regex>,
}

impl Config {
    /// Same leniency as `_load_corrections_config`: bad entries are skipped, never fatal.
    pub fn from_json(raw: &Value) -> Config {
        let mut c = Config::default();
        if let Some(words) = raw.get("non_cue_words").and_then(Value::as_array) {
            c.non_cue_words = words
                .iter()
                .filter_map(Value::as_str)
                .filter(|w| !strip(w).is_empty())
                .map(|w| strip(w).to_uppercase())
                .collect();
        }
        if let Some(aliases) = raw.get("speaker_aliases").and_then(Value::as_object) {
            for (k, v) in aliases {
                if let Some(v) = v.as_str() {
                    if !strip(k).is_empty() {
                        c.speaker_aliases.insert(strip(k).to_uppercase(), strip(v).to_uppercase());
                    }
                }
            }
        }
        if let Some(patterns) = raw.get("noise_line_patterns").and_then(Value::as_array) {
            for p in patterns.iter().filter_map(Value::as_str) {
                if strip(p).is_empty() {
                    continue;
                }
                match Regex::new(&format!("(?i){p}")) {
                    Ok(re) => c.noise_line_patterns.push(re),
                    Err(e) => eprintln!("corrections_config: invalid pattern {p:?} - {e}"),
                }
            }
        }
        c
    }
}

// ── regexes and word lists ────────────────────────────────────────────────────────────────────────────────

static NON_CUE_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"(?xi)^(
        (?:THE\s+)?END(\s+OF\s+(ACT|PLAY|SCENE))?
       |FINIS|CURTAIN
       |BLACK\s*OUT|WHITE\s*OUT|FADE\s*(IN|OUT|TO\s+BLACK)
       |LIGHTS?\s*(UP|DOWN|OUT|FADE|RISE|FALL)
       |SILENCE|BLACKOUT|WHITEOUT
       |INTERMISSION|ENTR.?ACTE|INTERVAL
       |PRESET|PRESHOW
       |PROLOGUE|EPILOGUE|OVERTURE|PRELUDE|CODA
       |SCENE\b|ACT\b|PART\b|SECTION\b
       |CONTINUED|CONT.D|MORE
       |CHARACTERS?\b|CAST\b|SETTING\b|SYNOPSIS\b
       |NOTES?\b|TIME\b|PLACE\b|LOCATION\b
       |PRODUCTION\b|ADVISORY\b|ATTRIBUTION\b
       |COPYRIGHT\b|WARNING\b|DRAMATIS\b|PERSONAE\b
       |PAUSE\b|BEAT\b|WAIT\b|STOP\b  # common stage directions
       |ALL\b|BOTH\b|TOGETHER\b|EVERYONE\b|ENSEMBLE\b  # collective-speaker markers
       |.*\s+DAYS?\s*$    # time-section headers: DEPARTURE DAY, OPENING DAY
    )",
    )
    .unwrap()
});

const BEAT_CORE: &str = r"\s*(?:a\s+)?(?:long\s+|short\s+|brief\s+|tiny\s+)?(?:beat|pause)s?\s*[.!]?\s*";
static TIMING_BEAT_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(&format!(r"(?i)^\(?{BEAT_CORE}\)?$")).unwrap());
static EMBEDDED_BEAT_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(&format!(r"(?i)\({BEAT_CORE}\)")).unwrap());
static MULTI_SPACE_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\s{2,}").unwrap());
static GROUP_CUE_SEP_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)\s*(?:&|,|\bAND\b)\s*").unwrap());
static SCENE_CHANGE_SD_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"(?i)\b(exit|exits|exiting|enter|enters|entering|lights?\s+(?:up|down|out|fade|change|shift)|blackout|fade\s+(?:to|out|in)|(?:the\s+)?(?:next|following)\s+(?:day|morning|night|afternoon|evening)|(?:an?|one|two|several|many)\s+(?:hour|day|week|month|year)s?\s+later|later\b|meanwhile\b|elsewhere\b)\b",
    )
    .unwrap()
});

/// Generic ensemble / bit-part roles: real speaking parts, flagged so the user confirms them.
const GENERIC_ROLES: &[&str] = &[
    "VOICE", "VOICES", "VOICE OF", "OFFSTAGE VOICE", "RECORDED VOICE", "OFFSTAGE", "MAN", "WOMAN", "BOY", "GIRL",
    "CHILD", "CHILDREN", "KID", "CROWD", "CHORUS", "ENSEMBLE", "COMPANY", "GROUP", "ALL", "BOTH", "UNISON",
    "SOLDIER", "SOLDIERS", "GUARD", "GUARDS", "OFFICER", "SERVANT", "SERVANTS", "ATTENDANT", "MESSENGER", "GHOST",
    "SPIRIT", "SHADOW", "ANNOUNCER", "STRANGER", "PASSERBY", "PERSON", "PEOPLE", "FIGURE", "NURSE", "DOCTOR",
    "WAITER", "WAITRESS", "BARTENDER", "DRIVER", "OPERATOR",
];

/// Confidence and review note for a dialog line, from how sure we are of its speaker.
pub fn dialog_confidence(speaker: &str, cast: &HashSet<String>) -> (f64, Option<String>) {
    if speaker.is_empty() {
        return (0.5, Some("No speaker detected — assigned by position.".into()));
    }
    let base = strip(speaker.split(" / ").next().unwrap());
    if GENERIC_ROLES.contains(&base) {
        return (0.6, Some(format!("“{base}” is a generic role — confirm the line and assign a voice.")));
    }
    if !cast.is_empty() && !cast.contains(base) {
        return (0.6, Some(format!("“{base}” speaks only once — check this is the right character.")));
    }
    (1.0, None)
}

/// Split a simultaneous/unison cue into its members, else None.
pub fn split_group_cue(speaker: &str, cast: &HashSet<String>) -> Option<Vec<String>> {
    if speaker.contains(" / ") {
        let parts: Vec<String> = speaker.split(" / ").map(strip).filter(|s| !s.is_empty()).map(String::from).collect();
        if parts.len() >= 2 {
            return Some(parts);
        }
    }
    let parts: Vec<String> = GROUP_CUE_SEP_RE.split(speaker).map(strip).filter(|s| !s.is_empty()).map(String::from).collect();
    if parts.len() >= 2 && !cast.is_empty() && parts.iter().all(|s| cast.contains(s)) {
        return Some(parts);
    }
    None
}

// ── assembly ──────────────────────────────────────────────────────────────────────────────────────────────

pub fn build_script_from_blocks(
    classified: &[ClassifiedBlock],
    title: &str,
    config: Option<&Config>,
    cast: &HashSet<String>,
) -> Script {
    let mut scenes: Vec<Scene> = Vec::new();
    let mut current: Vec<Element> = Vec::new();
    let mut scene_number: usize = 0;
    let mut scene_title = "Scene 1".to_string();

    // Drop front matter: start at the first scene heading, or (no headings) at the first recurring cast cue.
    let first_heading = classified.iter().position(|c| c.role == Role::SceneHeading);
    let classified: &[ClassifiedBlock] = if let Some(i) = first_heading {
        &classified[i..]
    } else {
        scene_number = 1;
        let first_cue = classified
            .iter()
            .position(|c| c.role == Role::SpeakerCue && c.speaker.as_ref().map_or(false, |s| cast.contains(s)))
            .or_else(|| classified.iter().position(|c| c.role == Role::SpeakerCue));
        match first_cue {
            Some(i) => &classified[i..],
            None => classified,
        }
    };

    macro_rules! flush_scene {
        () => {
            if !current.is_empty() {
                scenes.push(Scene { number: scene_number, title: scene_title.clone(), elements: std::mem::take(&mut current) });
            }
            current.clear();
        };
    }

    for cb in classified {
        match cb.role {
            Role::Noise => continue,
            Role::SceneHeading => {
                flush_scene!();
                scene_number += 1;
                scene_title = strip(&cb.block.text).to_string();
                continue;
            }
            Role::SpeakerCue => {
                // A direction written on the name line becomes an aside before the speech.
                if let Some(aside) = cb.aside.as_ref().filter(|a| !a.is_empty()) {
                    current.push(Element::new(
                        "parenthetical",
                        aside.clone(),
                        Some(normalize_speaker(cb.speaker.as_deref().unwrap_or(""))),
                    ));
                }
                continue;
            }
            _ => {}
        }
        let text = strip(&cb.block.text);
        if text.is_empty() {
            continue;
        }
        match cb.role {
            Role::Dialog => {
                let mut speaker = cb.speaker.clone().unwrap_or_default();
                let mut overlap_cue = None;
                if let Some(parts) = split_group_cue(&speaker, cast) {
                    speaker = parts[0].clone();
                    overlap_cue = Some(parts);
                }
                let norm_speaker = normalize_speaker(&speaker);
                // Peel off leading parentheticals like "(He sighs.) I think..."
                let mut remaining = text;
                while remaining.starts_with('(') {
                    let (paren, rest) = split_leading_paren(remaining);
                    let Some(paren) = paren else { break };
                    current.push(Element::new("parenthetical", paren.to_string(), Some(norm_speaker.clone())));
                    remaining = rest;
                }
                if !remaining.is_empty() {
                    let (conf, reason) = dialog_confidence(&norm_speaker, cast);
                    let mut el = Element::new("dialog", remaining.to_string(), Some(norm_speaker));
                    el.overlap_cue = overlap_cue;
                    el.confidence = conf;
                    el.reason = reason;
                    current.push(el);
                }
            }
            Role::Parenthetical => current.push(Element::new("parenthetical", text.to_string(), cb.speaker.clone())),
            Role::StageDirection => current.push(Element::new("stage_direction", text.to_string(), None)),
            _ => {}
        }
    }
    flush_scene!();

    if scenes.is_empty() {
        scenes.push(Scene { number: 1, title: "Scene 1".into(), elements: vec![] });
    }
    let characters = extract_characters(&scenes);
    let mut script = Script { title: title.to_string(), characters, scenes };
    if let Some(cfg) = config {
        apply_corrections_config(&mut script, cfg);
    }
    finalise(script)
}

fn extract_characters(scenes: &[Scene]) -> Vec<Character> {
    let mut seen: HashSet<&str> = HashSet::new();
    let mut chars = Vec::new();
    for sc in scenes {
        for el in &sc.elements {
            if el.kind == "dialog" {
                if let Some(sp) = el.speaker.as_deref().filter(|s| !s.is_empty()) {
                    if seen.insert(sp) {
                        chars.push(Character { name: sp.to_string(), gender_hint: None, role_hint: None, age_hint: None });
                    }
                }
            }
        }
    }
    chars
}

/// Data-driven corrections from corrections_config.json: speaker aliases, noise-line patterns, extra non-cue words.
pub fn apply_corrections_config(script: &mut Script, config: &Config) {
    for sc in &mut script.scenes {
        for el in &mut sc.elements {
            if let Some(sp) = el.speaker.as_ref() {
                if let Some(to) = config.speaker_aliases.get(sp) {
                    el.speaker = Some(to.clone());
                }
            }
            if !config.noise_line_patterns.is_empty() && el.kind == "dialog" && config.noise_line_patterns.iter().any(|p| p.is_match(&el.text)) {
                el.kind = "stage_direction".into();
                el.speaker = None;
            }
        }
    }
    if !config.non_cue_words.is_empty() {
        let pat = format!("(?i)^(?:{})", config.non_cue_words.iter().map(|w| format!("{}\\b", regex::escape(w))).collect::<Vec<_>>().join("|"));
        let re = Regex::new(&pat).unwrap();
        let removed: HashSet<String> = script.characters.iter().filter(|c| re.is_match(&c.name)).map(|c| c.name.clone()).collect();
        script.characters.retain(|c| !removed.contains(&c.name));
        for sc in &mut script.scenes {
            for el in &mut sc.elements {
                if el.speaker.as_ref().map_or(false, |s| removed.contains(s)) {
                    el.kind = "stage_direction".into();
                    el.speaker = None;
                }
            }
        }
    }
}

// ── finishing passes ──────────────────────────────────────────────────────────────────────────────────────

fn strip_embedded_beats(text: &str) -> String {
    strip(&MULTI_SPACE_RE.replace_all(&EMBEDDED_BEAT_RE.replace_all(text, " "), " ")).to_string()
}

/// Bare timing beats ("Beat.", "PAUSE", "(beat)") are never read aloud.
fn drop_timing_beats(scenes: &mut [Scene]) {
    for scene in scenes {
        let mut kept = Vec::new();
        for mut el in std::mem::take(&mut scene.elements) {
            if (el.kind == "stage_direction" || el.kind == "parenthetical") && TIMING_BEAT_RE.is_match(strip(&el.text)) {
                continue;
            }
            if el.kind == "dialog" && el.text.contains('(') {
                el.text = strip_embedded_beats(&el.text);
                if let Some(ts) = &el.overlap_texts {
                    if !ts.is_empty() {
                        el.overlap_texts = Some(ts.iter().map(|t| strip_embedded_beats(t)).collect());
                    }
                }
                if el.text.is_empty() {
                    continue;
                }
            }
            kept.push(el);
        }
        scene.elements = kept;
    }
}

/// Split over-long scenes at logical break points (a stage direction, or a speaker change when far over target).
fn split_elements(elements: &[Element], target: usize, min_lines: usize) -> Vec<Vec<Element>> {
    let mut chunks: Vec<Vec<Element>> = Vec::new();
    let mut current: Vec<Element> = Vec::new();
    let mut dialog_count = 0usize;
    let n = elements.len();
    for (i, el) in elements.iter().enumerate() {
        current.push(el.clone());
        if el.kind == "dialog" {
            dialog_count += 1;
        }
        if dialog_count < target {
            continue;
        }
        if el.kind == "stage_direction" && SCENE_CHANGE_SD_RE.is_match(&el.text) {
            chunks.push(std::mem::take(&mut current));
            dialog_count = 0;
            continue;
        }
        if el.kind == "stage_direction" && dialog_count >= target {
            chunks.push(std::mem::take(&mut current));
            dialog_count = 0;
            continue;
        }
        if dialog_count >= target * 2 && el.kind == "dialog" {
            let next = if i + 1 < n { Some(&elements[i + 1]) } else { None };
            if next.map_or(true, |nx| nx.kind == "stage_direction" || (nx.kind == "dialog" && nx.speaker != el.speaker)) {
                chunks.push(std::mem::take(&mut current));
                dialog_count = 0;
            }
        }
    }
    if !current.is_empty() {
        if !chunks.is_empty() && dialog_count < min_lines {
            chunks.last_mut().unwrap().extend(current);
        } else {
            chunks.push(current);
        }
    }
    if chunks.is_empty() {
        vec![elements.to_vec()]
    } else {
        chunks
    }
}

fn auto_chunk_scenes(scenes: Vec<Scene>) -> Vec<Scene> {
    let mut result: Vec<Scene> = Vec::new();
    for scene in scenes {
        let dialog_count = scene.elements.iter().filter(|e| e.kind == "dialog").count();
        if dialog_count as f64 <= CHUNK_TARGET_LINES as f64 * 1.5 {
            result.push(scene);
            continue;
        }
        let chunks = split_elements(&scene.elements, CHUNK_TARGET_LINES, CHUNK_MIN_LINES);
        for (idx, els) in chunks.into_iter().enumerate() {
            let number = result.len() + 1;
            let title = if idx == 0 { scene.title.clone() } else { format!("{} (part {})", scene.title, idx + 1) };
            result.push(Scene { number, title, elements: els });
        }
    }
    for (i, sc) in result.iter_mut().enumerate() {
        sc.number = i + 1;
    }
    result
}

/// Remove high-confidence false positives from the character list.
fn sanitize_characters(script: &mut Script) {
    let dialog_speakers: HashSet<&str> = script
        .scenes
        .iter()
        .flat_map(|s| s.elements.iter())
        .filter(|e| e.kind == "dialog")
        .filter_map(|e| e.speaker.as_deref().filter(|s| !s.is_empty()))
        .collect();
    let title_upper = strip(&script.title).to_uppercase();
    let keep: Vec<Character> = script
        .characters
        .iter()
        .filter(|c| {
            let name = strip(&c.name);
            !(NON_CUE_RE.is_match(name) || name == title_upper || !dialog_speakers.contains(name))
        })
        .cloned()
        .collect();
    script.characters = keep;
}

fn mark_single_occurrence_confidence(script: &mut Script) {
    let known: HashSet<String> = script.characters.iter().map(|c| c.name.clone()).collect();
    let mut counts: HashMap<String, usize> = HashMap::new();
    for sc in &script.scenes {
        for el in &sc.elements {
            if el.kind == "dialog" || el.kind == "parenthetical" {
                if let Some(sp) = el.speaker.as_deref().filter(|s| !s.is_empty()) {
                    *counts.entry(sp.to_string()).or_insert(0) += 1;
                }
            }
        }
    }
    for sc in &mut script.scenes {
        for el in &mut sc.elements {
            if el.kind == "dialog" || el.kind == "parenthetical" {
                if let Some(sp) = el.speaker.clone().filter(|s| !s.is_empty()) {
                    if counts.get(&sp).copied().unwrap_or(0) == 1 && !known.contains(&sp) {
                        el.confidence = el.confidence.min(0.7);
                        if el.reason.is_none() {
                            el.reason = Some(format!("“{sp}” speaks only once — check this is the right character."));
                        }
                    }
                }
            }
        }
    }
}

pub fn finalise(mut script: Script) -> Script {
    drop_timing_beats(&mut script.scenes);
    script.scenes = auto_chunk_scenes(std::mem::take(&mut script.scenes));
    sanitize_characters(&mut script);
    mark_single_occurrence_confidence(&mut script);
    script
}

/// First line of the first page that looks like a title (`_derive_title`), else the file name.
pub fn derive_title(first_page_lines: &[String], filename_stem: &str) -> String {
    static BAD: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)https?://|@|\d{4}|draft|revision").unwrap());
    static ONLY_DIGITS: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^[\d\s\.]+$").unwrap());
    static WS: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\s+").unwrap());
    for line in first_page_lines {
        // pdfplumber returns single-spaced lines; PDFium leaves runs of spaces and tabs where text was positioned
        let collapsed = WS.replace_all(line, " ");
        let candidate = strip(&collapsed);
        if candidate.chars().count() >= 3 && !BAD.is_match(candidate) && !ONLY_DIGITS.is_match(candidate) {
            return candidate.chars().take(80).collect();
        }
    }
    filename_stem.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cast(names: &[&str]) -> HashSet<String> {
        names.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn group_cues_split_only_for_known_cast_or_slashes() {
        let c = cast(&["SALLY", "EVELYN", "TONY"]);
        assert_eq!(split_group_cue("ADA / TOM", &c), Some(vec!["ADA".into(), "TOM".into()]));
        assert_eq!(split_group_cue("SALLY & EVELYN", &c), Some(vec!["SALLY".into(), "EVELYN".into()]));
        assert_eq!(split_group_cue("SALLY AND TONY", &c), Some(vec!["SALLY".into(), "TONY".into()]));
        assert_eq!(split_group_cue("SALLY & NOBODY", &c), None);
        assert_eq!(split_group_cue("SALLY", &c), None);
    }

    #[test]
    fn dialog_confidence_flags_generic_and_one_off_speakers() {
        let c = cast(&["ADA"]);
        assert_eq!(dialog_confidence("ADA", &c), (1.0, None));
        assert_eq!(dialog_confidence("", &c).0, 0.5);
        assert_eq!(dialog_confidence("CROWD", &c).0, 0.6);
        assert_eq!(dialog_confidence("BOB", &c).0, 0.6);
        assert_eq!(dialog_confidence("BOB", &HashSet::new()), (1.0, None));
    }

    #[test]
    fn timing_beats() {
        for yes in ["Beat.", "PAUSE", "A long pause.", "(beat)", "(a short pause)"] {
            assert!(TIMING_BEAT_RE.is_match(yes), "{yes}");
        }
        for no in ["(beat; softer)", "Silence falls.", "Beating heart"] {
            assert!(!TIMING_BEAT_RE.is_match(no), "{no}");
        }
        assert_eq!(strip_embedded_beats("Well (beat) maybe."), "Well maybe.");
    }

    #[test]
    fn non_cue_words() {
        for yes in ["END OF ACT", "CURTAIN", "OPENING DAY", "ENTRACTE", "SCENE 4", "BOTH"] {
            assert!(NON_CUE_RE.is_match(yes), "{yes}");
        }
        assert!(!NON_CUE_RE.is_match("ADA"));
    }

    #[test]
    fn title_skips_urls_years_and_numbers() {
        // expectations checked against parser._derive_title's filters
        let lines = vec!["12".to_string(), "© 2015 Someone".to_string(), "http://x.org".to_string(), "THE HARVEST".to_string()];
        assert_eq!(derive_title(&lines, "file"), "THE HARVEST");
        assert_eq!(derive_title(&["Hi".to_string(), "www.example.com".to_string()], "file"), "www.example.com");
        assert_eq!(derive_title(&[], "file"), "file");
    }
}
