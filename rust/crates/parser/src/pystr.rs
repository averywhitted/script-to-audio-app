//! Python `str` semantics the parser relies on (`strip`, `isalpha`, `isupper`, `len`), so the port behaves the same
//! on non-ASCII text.

/// Python's `str.isspace` for one character: Unicode White_Space plus the ASCII separators U+001C..U+001F.
pub fn is_space(c: char) -> bool {
    c.is_whitespace() || ('\u{1c}'..='\u{1f}').contains(&c)
}

pub fn strip(s: &str) -> &str {
    s.trim_matches(is_space)
}

pub fn lstrip(s: &str) -> &str {
    s.trim_start_matches(is_space)
}

pub fn rstrip(s: &str) -> &str {
    s.trim_end_matches(is_space)
}

/// Python `str.isalpha` for one character (letters; not numerals such as Roman numeral characters).
pub fn is_alpha(c: char) -> bool {
    c.is_alphabetic() && !c.is_numeric()
}

pub fn is_upper(c: char) -> bool {
    c.is_uppercase()
}

/// Python `len(str)`: code points.
pub fn len(s: &str) -> usize {
    s.chars().count()
}

/// Fraction of alphabetic characters that are uppercase (0 when there are none), as the parser computes it.
pub fn caps_ratio(s: &str) -> f64 {
    let (mut alpha, mut upper) = (0usize, 0usize);
    for c in s.chars().filter(|c| is_alpha(*c)) {
        alpha += 1;
        if is_upper(c) {
            upper += 1;
        }
    }
    upper as f64 / alpha.max(1) as f64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strip_matches_python() {
        assert_eq!(strip(" \u{a0}ab\u{1f}\t"), "ab");
        assert_eq!(lstrip("  a "), "a ");
        assert_eq!(rstrip("  a "), "  a");
    }

    #[test]
    fn caps_ratio_counts_letters_only() {
        assert_eq!(caps_ratio("AB cd 12"), 0.5);
        assert_eq!(caps_ratio("123"), 0.0);
        assert_eq!(caps_ratio("É é"), 0.5);
    }

    #[test]
    fn len_counts_code_points() {
        assert_eq!(len("é—"), 2);
    }
}
