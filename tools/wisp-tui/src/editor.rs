//! The input line's text and cursor, and every edit the keys can make to them. Pure: the terminal is
//! the caller's, so each edit is tested on its own. The cursor is an index in characters, never inside
//! one; a word is a run of alphanumeric characters, as shells and editors take it.

use unicode_width::UnicodeWidthChar;

/// One edit, as a key or a paste asks for it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Edit {
    /// Insert a character at the cursor.
    Insert(char),
    /// Insert pasted text at the cursor; carriage returns become newlines.
    Paste(String),
    /// Insert a newline at the cursor, for a message of several lines.
    Newline,
    /// Delete the character before the cursor.
    Backspace,
    /// Delete the character at the cursor.
    Delete,
    /// Move one character left.
    Left,
    /// Move one character right.
    Right,
    /// Move to the start of the previous word.
    WordLeft,
    /// Move past the end of the next word.
    WordRight,
    /// Move to the start.
    Home,
    /// Move to the end.
    End,
    /// Delete back to the previous whitespace, as readline's Ctrl-W does, so `-m msg` goes in two.
    DeleteWordBefore,
    /// Delete from the start to the cursor.
    KillToStart,
    /// Delete from the cursor to the end.
    KillToEnd,
}

/// The text being composed and where the cursor is in it.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Editor {
    /// The characters, so the cursor indexes them directly.
    chars: Vec<char>,
    /// The cursor, from 0 to `chars.len()`.
    cursor: usize,
}

impl Editor {
    /// The text.
    pub fn text(&self) -> String {
        self.chars.iter().collect()
    }

    /// Whether nothing is typed.
    pub fn is_empty(&self) -> bool {
        self.chars.is_empty()
    }

    /// Replaces the text, with the cursor at its end, as recalling a line does.
    pub fn set(&mut self, text: &str) {
        self.chars = text.chars().collect();
        self.cursor = self.chars.len();
    }

    /// Takes the text, leaving the editor empty.
    pub fn take(&mut self) -> String {
        let text = self.text();
        self.set("");
        text
    }

    /// Applies one edit.
    pub fn apply(&mut self, edit: &Edit) {
        match edit {
            Edit::Insert(c) => self.insert(&[*c]),
            Edit::Newline => self.insert(&['\n']),
            Edit::Paste(text) => {
                let normalised = text.replace("\r\n", "\n").replace('\r', "\n");
                let chars: Vec<char> = normalised
                    .chars()
                    .filter(|c| *c == '\n' || !c.is_control())
                    .collect();
                self.insert(&chars);
            }
            Edit::Backspace => {
                if self.cursor > 0 {
                    self.cursor -= 1;
                    self.chars.remove(self.cursor);
                }
            }
            Edit::Delete => {
                if self.cursor < self.chars.len() {
                    self.chars.remove(self.cursor);
                }
            }
            Edit::Left => self.cursor = self.cursor.saturating_sub(1),
            Edit::Right => self.cursor = (self.cursor + 1).min(self.chars.len()),
            Edit::WordLeft => self.cursor = self.word_start_before(),
            Edit::WordRight => self.cursor = self.word_end_after(),
            Edit::Home => self.cursor = 0,
            Edit::End => self.cursor = self.chars.len(),
            Edit::DeleteWordBefore => {
                let start = self.space_start_before();
                self.chars.drain(start..self.cursor);
                self.cursor = start;
            }
            Edit::KillToStart => {
                self.chars.drain(..self.cursor);
                self.cursor = 0;
            }
            Edit::KillToEnd => self.chars.truncate(self.cursor),
        }
    }

    fn insert(&mut self, new: &[char]) {
        self.chars
            .splice(self.cursor..self.cursor, new.iter().copied());
        self.cursor += new.len();
    }

    /// Where a word before the cursor starts: back over separators, then over the word.
    fn word_start_before(&self) -> usize {
        let mut index = self.cursor;
        while index > 0 && !self.chars[index - 1].is_alphanumeric() {
            index -= 1;
        }
        while index > 0 && self.chars[index - 1].is_alphanumeric() {
            index -= 1;
        }
        index
    }

    /// Where a whitespace-delimited word before the cursor starts: back over spaces, then over the rest.
    fn space_start_before(&self) -> usize {
        let mut index = self.cursor;
        while index > 0 && self.chars[index - 1].is_whitespace() {
            index -= 1;
        }
        while index > 0 && !self.chars[index - 1].is_whitespace() {
            index -= 1;
        }
        index
    }

    /// Where the next word ends: forward over separators, then over the word.
    fn word_end_after(&self) -> usize {
        let mut index = self.cursor;
        while index < self.chars.len() && !self.chars[index].is_alphanumeric() {
            index += 1;
        }
        while index < self.chars.len() && self.chars[index].is_alphanumeric() {
            index += 1;
        }
        index
    }

    /// The part of the text to show in `width` cells so the cursor is visible, and the cursor's column
    /// within it. Newlines show as `⏎`; wide characters take two cells. The view keeps the cursor at the
    /// right edge when the text runs past it, so the most recent typing stays in sight.
    pub fn view(&self, width: usize) -> (String, usize) {
        let shown = |c: char| if c == '\n' { '⏎' } else { c };
        let cells = |c: char| shown(c).width().unwrap_or(0);
        let width = width.max(1);
        // Walk back from the cursor until the window is full, leaving a cell for the cursor itself.
        let mut start = self.cursor;
        let mut used = 0;
        while start > 0 && used + cells(self.chars[start - 1]) < width {
            start -= 1;
            used += cells(self.chars[start]);
        }
        let column = used;
        let mut end = self.cursor;
        while end < self.chars.len() && used + cells(self.chars[end]) <= width {
            used += cells(self.chars[end]);
            end += 1;
        }
        (
            self.chars[start..end].iter().map(|c| shown(*c)).collect(),
            column,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn editor(text: &str, cursor: usize) -> Editor {
        let mut editor = Editor::default();
        editor.set(text);
        editor.cursor = cursor;
        editor
    }

    fn after(text: &str, cursor: usize, edit: &Edit) -> (String, usize) {
        let mut editor = editor(text, cursor);
        editor.apply(edit);
        (editor.text(), editor.cursor)
    }

    #[test]
    fn characters_go_in_at_the_cursor_and_come_out_around_it() {
        assert_eq!(after("helo", 3, &Edit::Insert('l')), ("hello".into(), 4));
        assert_eq!(after("hello", 5, &Edit::Backspace), ("hell".into(), 4));
        assert_eq!(after("hello", 0, &Edit::Backspace), ("hello".into(), 0));
        assert_eq!(after("hello", 1, &Edit::Delete), ("hllo".into(), 1));
        assert_eq!(after("hello", 5, &Edit::Delete), ("hello".into(), 5));
        assert_eq!(after("ab", 1, &Edit::Newline), ("a\nb".into(), 2));
        assert_eq!(after("naïve", 3, &Edit::Backspace), ("nave".into(), 2));
    }

    #[test]
    fn the_cursor_moves_by_character_word_and_line() {
        assert_eq!(after("abc", 0, &Edit::Left), ("abc".into(), 0));
        assert_eq!(after("abc", 3, &Edit::Right), ("abc".into(), 3));
        assert_eq!(after("run the tests", 13, &Edit::WordLeft).1, 8);
        assert_eq!(after("run the  tests", 9, &Edit::WordLeft).1, 4);
        assert_eq!(after("run the tests", 0, &Edit::WordRight).1, 3);
        assert_eq!(after("run the tests", 3, &Edit::WordRight).1, 7);
        assert_eq!(after("abc", 2, &Edit::Home).1, 0);
        assert_eq!(after("abc", 0, &Edit::End).1, 3);
    }

    #[test]
    fn words_and_ends_are_deleted_up_to_the_cursor() {
        assert_eq!(
            after("git commit -m msg", 17, &Edit::DeleteWordBefore),
            ("git commit -m ".into(), 14)
        );
        assert_eq!(
            after("git commit -m ", 14, &Edit::DeleteWordBefore),
            ("git commit ".into(), 11)
        );
        assert_eq!(after("abc def", 4, &Edit::KillToStart), ("def".into(), 0));
        assert_eq!(after("abc def", 3, &Edit::KillToEnd), ("abc".into(), 3));
    }

    #[test]
    fn paste_inserts_text_whole_with_line_ends_normalised_and_controls_dropped() {
        assert_eq!(
            after("[]", 1, &Edit::Paste("a\r\nb\rc\td".into())),
            ("[a\nb\ncd]".into(), 7)
        );
        let mut editor = Editor::default();
        editor.set("draft");
        assert_eq!(editor.cursor, 5);
        assert_eq!(editor.take(), "draft");
        assert!(editor.is_empty() && editor.cursor == 0);
    }

    #[test]
    fn the_view_keeps_the_cursor_in_sight() {
        assert_eq!(editor("hello", 5).view(10), ("hello".into(), 5));
        assert_eq!(editor("hello", 2).view(10), ("hello".into(), 2));
        // Longer than the width: the window ends at the cursor, with a cell left for it.
        let (text, column) = editor("abcdefghij", 10).view(5);
        assert_eq!((text.as_str(), column), ("ghij", 4));
        // Near the start, the window runs on past the cursor as far as it fits.
        let (text, column) = editor("abcdefghij", 3).view(5);
        assert_eq!((text.as_str(), column), ("abcde", 3));
        // Newlines are shown as a mark; wide characters take two cells.
        assert_eq!(editor("a\nb", 3).view(10), ("a⏎b".into(), 3));
        assert_eq!(editor("日本", 2).view(10), ("日本".into(), 4));
        assert_eq!(editor("", 0).view(0), (String::new(), 0));
    }
}
