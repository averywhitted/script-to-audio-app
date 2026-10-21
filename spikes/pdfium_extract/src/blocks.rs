//! Group lines into blocks the way MuPDF does (reproduces 19349 of 19357 PyMuPDF block boundaries).

use crate::lines::Line;

const GAP: f64 = 1.45; // a drop of more than this many em starts a new block
const INDENT: f64 = 0.25; // a line indented more than this many em beyond the previous one starts a new block

pub struct Block {
    pub bbox: [f64; 4],
    pub lines: Vec<Line>,
}

pub fn group_blocks(lines: Vec<Line>) -> Vec<Block> {
    let mut blocks: Vec<Vec<Line>> = Vec::new();
    let mut cur: Vec<Line> = Vec::new();
    for ln in lines {
        if let Some(prev) = cur.last() {
            let size = ln.spans.iter().map(|s| s.size).fold(0.0, f64::max);
            let dy = ln.bbox[1] - prev.bbox[1];
            let dx = ln.bbox[0] - prev.bbox[0];
            if dy < -0.5 * size || dy > GAP * size || (dy > 0.3 * size && dx > INDENT * size) {
                blocks.push(std::mem::take(&mut cur));
            }
        }
        cur.push(ln);
    }
    if !cur.is_empty() {
        blocks.push(cur);
    }
    blocks
        .into_iter()
        .map(|lines| {
            let bbox = [
                lines.iter().map(|l| l.bbox[0]).fold(f64::MAX, f64::min),
                lines.iter().map(|l| l.bbox[1]).fold(f64::MAX, f64::min),
                lines.iter().map(|l| l.bbox[2]).fold(f64::MIN, f64::max),
                lines.iter().map(|l| l.bbox[3]).fold(f64::MIN, f64::max),
            ];
            Block { bbox, lines }
        })
        .collect()
}
