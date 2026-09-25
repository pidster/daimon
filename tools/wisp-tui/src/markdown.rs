//! The little Markdown a reply uses, rendered as its lines are committed to the scrollback: headings,
//! bullets, `code`, **strong**, and *emphasis* on a line, and fenced blocks across lines (the caller
//! keeps the fence state). Pure; the palette is the caller's. Anything that is not clearly markup is
//! left as typed, so an unpaired `*` or backtick shows as itself.

/// How a piece of a line is shown.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tone {
    /// Ordinary reply text.
    Plain,
    /// `**strong**` or `__strong__`.
    Strong,
    /// `*emphasis*` or `_emphasis_`.
    Emphasis,
    /// `` `code` ``.
    Code,
    /// A `#` heading's text.
    Heading,
    /// A bullet's mark.
    Bullet,
}

/// Whether `line` opens or closes a fenced block.
pub fn is_fence(line: &str) -> bool {
    let trimmed = line.trim_start();
    trimmed.starts_with("```") || trimmed.starts_with("~~~")
}

/// The pieces of one reply line outside a fenced block, markers removed.
pub fn spans(line: &str) -> Vec<(String, Tone)> {
    let trimmed = line.trim_start();
    let hashes = trimmed.chars().take_while(|c| *c == '#').count();
    if (1..=6).contains(&hashes) && trimmed[hashes..].starts_with(' ') {
        return vec![(trimmed[hashes + 1..].trim().to_string(), Tone::Heading)];
    }
    let indent = &line[..line.len() - trimmed.len()];
    if let Some(rest) = trimmed
        .strip_prefix("- ")
        .or_else(|| trimmed.strip_prefix("* "))
        .or_else(|| trimmed.strip_prefix("+ "))
    {
        let mut pieces = vec![(format!("{indent}• "), Tone::Bullet)];
        pieces.extend(inline(rest));
        return pieces;
    }
    inline(line)
}

/// Inline markup: code first, since nothing inside it is markup, then strong before emphasis.
fn inline(text: &str) -> Vec<(String, Tone)> {
    let chars: Vec<char> = text.chars().collect();
    let mut pieces: Vec<(String, Tone)> = Vec::new();
    let mut plain = String::new();
    let mut index = 0;
    while index < chars.len() {
        let found = if chars[index] == '`' {
            closing(&chars, index + 1, &['`']).map(|end| (index + 1, end, 1, Tone::Code))
        } else if let Some(marker) = double(&chars, index) {
            closing(&chars, index + 2, &[marker, marker])
                .map(|end| (index + 2, end, 2, Tone::Strong))
        } else if matches!(chars[index], '*' | '_') && opens(&chars, index) {
            let marker = chars[index];
            closing(&chars, index + 1, &[marker]).map(|end| (index + 1, end, 1, Tone::Emphasis))
        } else {
            None
        };
        if let Some((start, end, width, tone)) = found {
            if !plain.is_empty() {
                pieces.push((std::mem::take(&mut plain), Tone::Plain));
            }
            pieces.push((chars[start..end].iter().collect(), tone));
            index = end + width;
        } else {
            plain.push(chars[index]);
            index += 1;
        }
    }
    if !plain.is_empty() || pieces.is_empty() {
        pieces.push((plain, Tone::Plain));
    }
    pieces
}

/// The marker when `**` or `__` starts at `index`.
fn double(chars: &[char], index: usize) -> Option<char> {
    let marker = chars[index];
    (matches!(marker, '*' | '_') && chars.get(index + 1) == Some(&marker) && opens(chars, index))
        .then_some(marker)
}

/// Whether a marker at `index` can open a span: text follows it at once, and an underscore is not
/// inside a word, so `snake_case_name` stays as typed.
fn opens(chars: &[char], index: usize) -> bool {
    let marker = chars[index];
    let after = chars[index..].iter().find(|c| **c != marker);
    let before = index.checked_sub(1).map(|i| chars[i]);
    after.is_some_and(|c| !c.is_whitespace())
        && !(marker == '_' && before.is_some_and(char::is_alphanumeric))
}

/// Where the span opened before `from` closes: the next `marker` after at least one character, not
/// preceded by whitespace (code excepted) and, for an underscore, not inside a word.
fn closing(chars: &[char], from: usize, marker: &[char]) -> Option<usize> {
    let code = marker == ['`'];
    (from + 1..=chars.len().saturating_sub(marker.len())).find(|&at| {
        chars[at..].starts_with(marker)
            && (code || !chars[at - 1].is_whitespace())
            && !(marker[0] == '_'
                && chars
                    .get(at + marker.len())
                    .is_some_and(|c| c.is_alphanumeric()))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Asserts that `line` renders as `pieces`.
    fn check(line: &str, pieces: &[(&str, Tone)]) {
        let want: Vec<(String, Tone)> = pieces
            .iter()
            .map(|(text, tone)| ((*text).to_string(), *tone))
            .collect();
        assert_eq!(spans(line), want, "{line:?}");
    }

    #[test]
    fn inline_markup_is_styled_with_its_markers_removed() {
        check(
            "Run `git status` then **commit** it *now*.",
            &[
                ("Run ", Tone::Plain),
                ("git status", Tone::Code),
                (" then ", Tone::Plain),
                ("commit", Tone::Strong),
                (" it ", Tone::Plain),
                ("now", Tone::Emphasis),
                (".", Tone::Plain),
            ],
        );
        check(
            "__bold__ and _it_",
            &[
                ("bold", Tone::Strong),
                (" and ", Tone::Plain),
                ("it", Tone::Emphasis),
            ],
        );
        // Nothing inside code is markup.
        check("`**x**`", &[("**x**", Tone::Code)]);
    }

    #[test]
    fn what_is_not_clearly_markup_is_left_as_typed() {
        check("2 * 3 * 4", &[("2 * 3 * 4", Tone::Plain)]);
        check("a lone ` tick", &[("a lone ` tick", Tone::Plain)]);
        check("snake_case_name", &[("snake_case_name", Tone::Plain)]);
        check("**unclosed", &[("**unclosed", Tone::Plain)]);
        check("``", &[("``", Tone::Plain)]);
        check("", &[("", Tone::Plain)]);
    }

    #[test]
    fn headings_and_bullets_lose_their_marks() {
        check("## Next steps", &[("Next steps", Tone::Heading)]);
        check("#hashtag", &[("#hashtag", Tone::Plain)]);
        check(
            "  - read `a.txt`",
            &[
                ("  • ", Tone::Bullet),
                ("read ", Tone::Plain),
                ("a.txt", Tone::Code),
            ],
        );
        check("* one", &[("• ", Tone::Bullet), ("one", Tone::Plain)]);
        assert!(is_fence("```swift") && is_fence("  ~~~") && !is_fence("`x`"));
    }
}
