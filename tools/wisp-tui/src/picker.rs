//! A choice a chat command asks (`/config set` without a value, say), picked with the arrow keys or
//! answered by typing when the choice takes text. Pure: the terminal and the protocol are the caller's.

use ratatui::text::{Line, Span};

use crate::palette;
use crate::protocol::Choice;

/// Options shown at once; a longer list scrolls to keep the selection in sight.
pub const VISIBLE: usize = 8;

/// A choice being answered.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Picker {
    /// What was asked.
    pub choice: Choice,
    /// The highlighted option.
    pub selected: usize,
}

impl Picker {
    /// Opens a choice with the current value highlighted.
    pub fn new(choice: Choice) -> Self {
        let selected = choice
            .current
            .as_ref()
            .and_then(|current| choice.options.iter().position(|o| &o.value == current))
            .unwrap_or(0);
        Self { choice, selected }
    }

    /// Moves the highlight up, or down with `down`, stopping at the ends.
    pub fn step(&mut self, down: bool) {
        let last = self.choice.options.len().saturating_sub(1);
        self.selected = if down {
            (self.selected + 1).min(last)
        } else {
            self.selected.saturating_sub(1)
        };
    }

    /// The answer Enter gives: the typed text when the choice takes text and some is typed, otherwise
    /// the highlighted option; `None` when there is nothing to give.
    pub fn answer(&self, typed: &str) -> Option<String> {
        let typed = typed.trim();
        if self.choice.accepts_text && !typed.is_empty() {
            return Some(typed.to_string());
        }
        self.choice
            .options
            .get(self.selected)
            .map(|option| option.value.clone())
    }

    /// The first option shown when only `VISIBLE` fit.
    fn first_shown(&self) -> usize {
        let count = self.choice.options.len();
        if count <= VISIBLE {
            0
        } else {
            (self.selected + 1)
                .saturating_sub(VISIBLE)
                .min(count - VISIBLE)
        }
    }

    /// The lines inside the picker's border: the question, the options around the highlight (`▸` on
    /// it, `*` on the current value), and the keys. The typed-text row, when there is one, is the
    /// caller's, so it can carry the cursor.
    pub fn lines(&self) -> Vec<Line<'static>> {
        let mut lines = vec![Line::from(Span::styled(
            self.choice.title.clone(),
            palette::body(),
        ))];
        let first = self.first_shown();
        for (index, option) in self
            .choice
            .options
            .iter()
            .enumerate()
            .skip(first)
            .take(VISIBLE)
        {
            let chosen = index == self.selected;
            let current = self.choice.current.as_deref() == Some(option.value.as_str());
            let mut spans = vec![
                Span::styled(if chosen { "▸ " } else { "  " }, palette::prompt()),
                Span::styled(
                    option.label.clone(),
                    if chosen {
                        palette::user()
                    } else {
                        palette::body()
                    },
                ),
            ];
            if current {
                spans.push(Span::styled(" *", palette::wisp()));
            }
            if !option.detail.is_empty() {
                spans.push(Span::styled(
                    format!("  {}", option.detail),
                    palette::muted(),
                ));
            }
            lines.push(Line::from(spans));
        }
        let keys = match (self.choice.options.is_empty(), self.choice.accepts_text) {
            (true, _) => "type a value · Enter to set · Esc to leave it",
            (false, true) => "↑↓ to move · or type a value · Enter to choose · Esc to leave it",
            (false, false) => "↑↓ to move · Enter to choose · Esc to leave it",
        };
        lines.push(Line::from(Span::styled(keys, palette::muted())));
        lines
    }

    /// Rows the picker takes inside its border: its lines, and the typed-text row when it has one.
    pub fn rows(&self) -> usize {
        self.lines().len() + usize::from(self.choice.accepts_text)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::ChoiceOption;

    fn choice(values: &[&str], current: Option<&str>, accepts_text: bool) -> Choice {
        Choice {
            id: "c".into(),
            title: "pick".into(),
            options: values
                .iter()
                .map(|v| ChoiceOption {
                    value: (*v).into(),
                    label: (*v).into(),
                    detail: String::new(),
                })
                .collect(),
            current: current.map(str::to_string),
            accepts_text,
        }
    }

    fn text(line: &Line) -> String {
        line.spans.iter().map(|s| s.content.as_ref()).collect()
    }

    #[test]
    fn the_current_value_is_highlighted_and_the_arrows_stop_at_the_ends() {
        let mut picker = Picker::new(choice(
            &["rules", "system-model", "coreml"],
            Some("coreml"),
            false,
        ));
        assert_eq!(picker.selected, 2);
        picker.step(true);
        assert_eq!(picker.selected, 2);
        picker.step(false);
        picker.step(false);
        picker.step(false);
        assert_eq!(picker.answer(""), Some("rules".into()));
        assert_eq!(
            picker.answer("typed"),
            Some("rules".into()),
            "typed text only where it is taken"
        );
        let lines = picker.lines();
        assert_eq!(text(&lines[1]), "▸ rules");
        assert_eq!(text(&lines[3]), "  coreml *");
        assert_eq!(
            text(lines.last().unwrap_or(&Line::default())),
            "↑↓ to move · Enter to choose · Esc to leave it"
        );
        assert_eq!(picker.rows(), 5);
    }

    #[test]
    fn typed_text_answers_where_the_choice_takes_it() {
        let open = Picker::new(choice(&[], None, true));
        assert_eq!(open.answer(" 30 "), Some("30".into()));
        assert_eq!(open.answer(""), None);
        assert_eq!(open.rows(), 3, "the question, the keys, and the typed row");
        let both = Picker::new(choice(&["system"], None, true));
        assert_eq!(both.answer(""), Some("system".into()));
        assert_eq!(both.answer("ollama:x"), Some("ollama:x".into()));
    }

    #[test]
    fn a_long_list_scrolls_to_keep_the_highlight_in_sight() {
        let values: Vec<String> = (1..=20).map(|n| format!("option{n}")).collect();
        let refs: Vec<&str> = values.iter().map(String::as_str).collect();
        let mut picker = Picker::new(choice(&refs, Some("option15"), false));
        assert_eq!(picker.first_shown(), 7);
        let lines = picker.lines();
        assert_eq!(lines.len(), 1 + VISIBLE + 1);
        assert_eq!(text(&lines[VISIBLE]), "▸ option15 *");
        picker.selected = 0;
        assert_eq!(picker.first_shown(), 0);
    }
}
