//! Group lines into blocks the way MuPDF does (reproduces 19349 of 19357 PyMuPDF block boundaries, 135 false splits).

use crate::lines::Line;

const GAP: f64 = 1.5; // a drop of more than this many em starts a new block (Kill Floor's double spacing is exactly 1.5)
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::lines::Span;

    fn line(x: f64, y: f64) -> Line {
        Line {
            bbox: [x, y, x + 100.0, y + 15.0],
            title_text: String::new(),
            spans: vec![Span { text: "x".into(), font: "F".into(), size: 12.0, italic: false, bold: false }],
        }
    }

    fn sizes(lines: Vec<Line>) -> Vec<usize> {
        group_blocks(lines).iter().map(|b| b.lines.len()).collect()
    }

    #[test]
    fn same_indent_and_normal_spacing_stay_in_one_block() {
        assert_eq!(sizes(vec![line(90.0, 100.0), line(90.0, 114.0), line(90.0, 128.0)]), vec![3]);
    }

    #[test]
    fn a_line_indented_further_than_the_one_before_starts_a_block() {
        // dialogue (x=90) -> parenthetical (x=306): new block; back to x=90: same block (MuPDF behaviour)
        assert_eq!(sizes(vec![line(90.0, 100.0), line(306.0, 114.0), line(90.0, 128.0)]), vec![1, 2]);
    }

    #[test]
    fn a_big_drop_or_a_jump_up_starts_a_block() {
        assert_eq!(sizes(vec![line(90.0, 100.0), line(90.0, 150.0)]), vec![1, 1]); // > 1.45 em
        assert_eq!(sizes(vec![line(90.0, 300.0), line(90.0, 100.0)]), vec![1, 1]); // moved up
    }

    #[test]
    fn double_spacing_of_exactly_one_and_a_half_em_stays_in_one_block() {
        assert_eq!(sizes(vec![line(72.0, 617.9), line(72.0, 635.9)]), vec![2]); // 18.0 pt at 12 pt
        assert_eq!(sizes(vec![line(72.0, 617.9), line(72.0, 636.2)]), vec![1, 1]); // 18.3 pt: a new paragraph
    }

    #[test]
    fn same_baseline_lines_share_a_block() {
        assert_eq!(sizes(vec![line(72.0, 100.0), line(162.0, 100.0)]), vec![2]);
    }

    #[test]
    fn block_bbox_is_the_union_of_its_lines() {
        let b = &group_blocks(vec![line(90.0, 100.0), line(60.0, 114.0)])[0];
        assert_eq!(b.bbox, [60.0, 100.0, 190.0, 129.0]);
    }
}
