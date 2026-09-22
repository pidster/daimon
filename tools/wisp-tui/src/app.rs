//! The front end's state and rendering: finished lines go above into the terminal's own scrollback,
//! the band at the bottom holds the reply in progress, an approval dialog, the input, and the status.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;
use serde_json::Value;

use crate::palette;
use crate::protocol::{Approval, Event, Inbound, Outbound, Status};

/// Rows the band occupies: reply in progress, dialog, a half-height strip, the input, a half-height
/// strip, status. The strips are rows of half-block glyphs in the tint, which read as half a line of
/// padding above and below the input; a terminal cannot tint less than a row.
pub const BAND_HEIGHT: u16 = 6;
/// The band row the input text sits on.
pub const INPUT_ROW: u16 = 3;
/// The band row the status sits on.
pub const STATUS_ROW: u16 = 5;
/// Cells of margin on each side of the band and of every committed line.
pub const MARGIN: u16 = 1;
/// The input row's placeholder when nothing is typed.
pub const PLACEHOLDER: &str = "Ask wisp to do anything";

/// A line committed to scrollback, with its style.
#[derive(Debug, Clone, PartialEq)]
pub struct HistoryLine {
    /// The text.
    pub text: String,
    /// How it is drawn.
    pub kind: LineKind,
}

/// What a history line is, for styling.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LineKind {
    /// The user's own input, echoed.
    User,
    /// The model's reply.
    Reply,
    /// A tool call or result.
    Tool,
    /// A note from wisp.
    Note,
    /// An error.
    Error,
    /// Output of a slash command.
    Output,
}

/// What the main loop should do after a key.
#[derive(Debug, Clone, PartialEq)]
pub enum Action {
    /// Nothing beyond a redraw.
    None,
    /// Send this line to wisp.
    Send(Inbound),
    /// Leave.
    Quit,
}

/// The whole state.
#[derive(Debug, Default)]
pub struct App {
    /// Lines waiting to be inserted above the band.
    pub pending: Vec<HistoryLine>,
    /// The reply so far on the current line, not yet committed.
    pub partial: String,
    /// What the user has typed.
    pub input: String,
    /// The last status wisp sent.
    pub status: Option<Status>,
    /// An approval awaiting an answer.
    pub approval: Option<Approval>,
    /// Whether a turn is in progress (input is held until the next status).
    pub busy: bool,
    /// Whether wisp said goodbye.
    pub exited: bool,
}

impl App {
    /// Applies one line from wisp.
    pub fn handle(&mut self, outbound: Outbound) {
        match outbound {
            Outbound::Output { text } => {
                self.flush_partial();
                for line in text.lines() {
                    self.push(line, LineKind::Output);
                }
            }
            Outbound::Delta { text } => {
                self.partial.push_str(&text);
                while let Some(index) = self.partial.find('\n') {
                    let line = self.partial[..index].to_string();
                    self.partial.drain(..=index);
                    self.push(&line, LineKind::Reply);
                }
            }
            Outbound::Note { text } => {
                self.flush_partial();
                let kind = if text.starts_with("error") {
                    LineKind::Error
                } else {
                    LineKind::Note
                };
                self.push(&text, kind);
            }
            Outbound::Status(status) => {
                self.flush_partial();
                self.status = Some(status);
                self.busy = false;
            }
            Outbound::Event(event) => {
                if let Some(line) = event_line(&event) {
                    self.flush_partial();
                    let kind = if event.kind == "error" {
                        LineKind::Error
                    } else {
                        LineKind::Tool
                    };
                    self.push(&line, kind);
                }
            }
            Outbound::Approval(approval) => {
                self.flush_partial();
                for reason in &approval.reasons {
                    self.push(&format!("  - {reason}"), LineKind::Note);
                }
                self.approval = Some(approval);
            }
            Outbound::Exit => self.exited = true,
            Outbound::Unknown => {}
        }
    }

    /// Commits the partial reply line, if any.
    fn flush_partial(&mut self) {
        if !self.partial.is_empty() {
            let line = std::mem::take(&mut self.partial);
            self.push(&line, LineKind::Reply);
        }
    }

    fn push(&mut self, text: &str, kind: LineKind) {
        self.pending.push(HistoryLine {
            text: text.to_string(),
            kind,
        });
    }

    /// Takes the lines to insert above the band.
    pub fn take_pending(&mut self) -> Vec<HistoryLine> {
        std::mem::take(&mut self.pending)
    }

    /// A character typed.
    pub fn type_char(&mut self, c: char) -> Action {
        if let Some(approval) = &self.approval {
            let decision = match c.to_ascii_lowercase() {
                'y' => "once",
                's' => "session",
                'p' => "project",
                'a' => "always",
                'n' => "no",
                _ => return Action::None,
            };
            let id = approval.id.clone();
            self.push(&format!("  → {decision}"), LineKind::Note);
            self.approval = None;
            return Action::Send(Inbound::Answer {
                id,
                decision: decision.to_string(),
            });
        }
        if !self.busy {
            self.input.push(c);
        }
        Action::None
    }

    /// Backspace.
    pub fn backspace(&mut self) {
        if self.approval.is_none() {
            self.input.pop();
        }
    }

    /// Enter: sends the input as a message, echoing it into history.
    pub fn submit(&mut self) -> Action {
        if self.approval.is_some() || self.busy {
            return Action::None;
        }
        let text = self.input.trim().to_string();
        self.input.clear();
        if text.is_empty() {
            return Action::None;
        }
        self.push(&format!("› {text}"), LineKind::User);
        self.busy = true;
        Action::Send(Inbound::Message { text })
    }

    /// Ctrl-C or Ctrl-D: cancel a dialog first, otherwise quit.
    pub fn interrupt(&mut self) -> Action {
        if let Some(approval) = self.approval.take() {
            return Action::Send(Inbound::Answer {
                id: approval.id,
                decision: "no".into(),
            });
        }
        Action::Quit
    }

    /// Draws the band into `area`. Text is inset by the margin everywhere; the input's tint runs edge
    /// to edge with half-block strips above and below it.
    pub fn render(&self, frame: &mut Frame, area: Rect) {
        let margin = MARGIN.min(area.width / 2);
        let inset = Rect {
            x: area.x + margin,
            width: area.width.saturating_sub(margin * 2),
            ..area
        };
        let row = |index: u16, rect: Rect| Rect::new(rect.x, rect.y + index, rect.width, 1);
        let plain = |frame: &mut Frame, index: u16, line: Line<'static>| {
            if index < area.height {
                frame.render_widget(Paragraph::new(line), row(index, inset));
            }
        };
        plain(
            frame,
            0,
            Line::from(Span::styled(self.partial.clone(), palette::body())),
        );
        plain(frame, 1, self.dialog_line());
        let strip = |frame: &mut Frame, index: u16, glyph: &str| {
            if index < area.height {
                let text = glyph.repeat(usize::from(area.width));
                frame.render_widget(
                    Paragraph::new(text).style(palette::input_edge()),
                    row(index, area),
                );
            }
        };
        strip(frame, INPUT_ROW - 1, "▄");
        if INPUT_ROW < area.height {
            frame.render_widget(
                Paragraph::new("").style(palette::input_background()),
                row(INPUT_ROW, area),
            );
            frame.render_widget(
                Paragraph::new(self.input_line()).style(palette::input_background()),
                row(INPUT_ROW, inset),
            );
        }
        strip(frame, INPUT_ROW + 1, "▀");
        plain(frame, STATUS_ROW, self.status_line());
    }

    fn dialog_line(&self) -> Line<'static> {
        let Some(approval) = &self.approval else {
            return Line::default();
        };
        Line::from(vec![
            Span::styled("⚠ approve ", palette::amber()),
            Span::styled(
                format!("[{}] ", approval.level),
                palette::level(&approval.level),
            ),
            Span::styled(approval.command.clone(), palette::user()),
            Span::styled(
                format!("  remembered as {}  ", approval.pattern),
                palette::muted(),
            ),
            Span::styled("[y]once [s]ession [p]roject [a]lways [n]o", palette::body()),
        ])
    }

    fn input_line(&self) -> Line<'static> {
        let prompt = if self.busy { "…" } else { "›" };
        let text = if self.input.is_empty() && !self.busy {
            Span::styled(PLACEHOLDER, palette::muted())
        } else {
            Span::styled(self.input.clone(), palette::user())
        };
        Line::from(vec![
            Span::styled(format!("{prompt} "), palette::prompt()),
            text,
        ])
    }

    fn status_line(&self) -> Line<'static> {
        let Some(status) = &self.status else {
            return Line::from(Span::styled("connecting…", palette::muted()));
        };
        let sep = || Span::styled(" · ", palette::muted());
        let mut spans = vec![
            Span::styled(status.model.clone(), palette::wisp()),
            sep(),
            Span::styled(status.directory.clone(), palette::wisp()),
        ];
        if let Some(branch) = &status.branch {
            spans.push(sep());
            spans.push(Span::styled(branch.clone(), palette::wisp()));
        }
        if let Some(dirty) = status.dirty {
            spans.push(sep());
            spans.push(Span::styled(
                if dirty { "changes" } else { "clean" },
                palette::wisp(),
            ));
        }
        spans.push(sep());
        spans.push(Span::styled(status.approval.clone(), palette::muted()));
        if let Some(used) = status.context_used {
            spans.push(sep());
            #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
            let percent = (used * 100.0).round() as u8;
            let style = if used >= 0.8 {
                palette::amber()
            } else {
                palette::muted()
            };
            spans.push(Span::styled(format!("context {percent}% used"), style));
        }
        Line::from(spans)
    }
}

/// The one-line rendering of an audit event, as the terminal chat shows it; nil for kinds not shown.
pub fn event_line(event: &Event) -> Option<String> {
    let d = &event.details;
    let text = |key: &str| d.get(key).and_then(Value::as_str).unwrap_or("").to_string();
    let number = |key: &str| d.get(key).and_then(Value::as_i64).unwrap_or(0);
    match event.kind.as_str() {
        "tool.call" => {
            let tool = text("tool");
            let arguments: Value = serde_json::from_str(&text("arguments")).unwrap_or(Value::Null);
            let key = match tool.as_str() {
                "run_command" => "command",
                "read_file" | "edit_file" => "path",
                "inspect" => "what",
                _ => "",
            };
            let summary = arguments.get(key).and_then(Value::as_str).map_or_else(
                || shortened(&text("arguments")),
                |value| {
                    let mode = arguments.get("mode").and_then(Value::as_str);
                    match (tool.as_str(), mode) {
                        ("edit_file", Some(mode)) => shortened(&format!("{mode} {value}")),
                        _ => shortened(value),
                    }
                },
            );
            Some(format!("⚙ {tool} {summary}"))
        }
        "tool.result" if text("tool") != "run_command" => {
            let seconds = d.get("seconds").and_then(Value::as_f64).unwrap_or(0.0);
            let head = shortened(text("output").lines().next().unwrap_or(""));
            Some(format!(
                "  ↳ {} bytes in {seconds:.1} s: {head}",
                number("bytes")
            ))
        }
        "command.outcome" => {
            let mut extras = Vec::new();
            if d.get("timedOut").and_then(Value::as_bool) == Some(true) {
                extras.push("timed out");
            }
            if d.get("truncated").and_then(Value::as_bool) == Some(true) {
                extras.push("output truncated");
            }
            let suffix = if extras.is_empty() {
                String::new()
            } else {
                format!(" ({})", extras.join(", "))
            };
            Some(format!("  ↳ exit {}{suffix}", number("exitStatus")))
        }
        "file.write" => Some(format!(
            "  ↳ {} {}, now {} bytes",
            text("mode"),
            text("path"),
            number("bytesAfter")
        )),
        "error" if event.call.is_some() => Some(format!("  ↳ error: {}", text("message"))),
        "context.condensation" => Some(format!(
            "(context condensed, {}: {} → {} turns)",
            text("reason"),
            number("turnsBefore"),
            number("turnsAfter")
        )),
        _ => None,
    }
}

/// `text` cut to 100 characters with an ellipsis.
fn shortened(text: &str) -> String {
    if text.chars().count() > 100 {
        format!("{}…", text.chars().take(100).collect::<String>())
    } else {
        text.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::Terminal;
    use ratatui::backend::TestBackend;

    fn event(kind: &str, details: Value) -> Event {
        Event {
            kind: kind.into(),
            call: Some("c".into()),
            details,
        }
    }

    #[test]
    fn deltas_commit_whole_lines_and_status_flushes_the_rest() {
        let mut app = App::default();
        app.handle(Outbound::Delta {
            text: "The ".into(),
        });
        app.handle(Outbound::Delta {
            text: "date\nis".into(),
        });
        assert_eq!(
            app.take_pending(),
            vec![HistoryLine {
                text: "The date".into(),
                kind: LineKind::Reply
            }]
        );
        assert_eq!(app.partial, "is");
        app.handle(Outbound::Status(Status::default()));
        assert_eq!(app.take_pending()[0].text, "is");
        assert!(app.partial.is_empty());
        assert!(!app.busy);
    }

    #[test]
    fn events_render_like_the_terminal_chat() {
        let call = event(
            "tool.call",
            serde_json::json!({"tool":"run_command","arguments":"{\"command\":\"git status\"}"}),
        );
        assert_eq!(
            event_line(&call).as_deref(),
            Some("⚙ run_command git status")
        );
        let edit = event(
            "tool.call",
            serde_json::json!({"tool":"edit_file","arguments":"{\"path\":\"a.txt\",\"mode\":\"append\"}"}),
        );
        assert_eq!(
            event_line(&edit).as_deref(),
            Some("⚙ edit_file append a.txt")
        );
        let outcome = event(
            "command.outcome",
            serde_json::json!({"exitStatus":1,"timedOut":true}),
        );
        assert_eq!(
            event_line(&outcome).as_deref(),
            Some("  ↳ exit 1 (timed out)")
        );
        let result = event(
            "tool.result",
            serde_json::json!({"tool":"read_file","output":"1\tx\n2\ty","bytes":7,"seconds":0.04}),
        );
        assert_eq!(
            event_line(&result).as_deref(),
            Some("  ↳ 7 bytes in 0.0 s: 1\tx")
        );
        let skipped = event(
            "tool.result",
            serde_json::json!({"tool":"run_command","output":"exit status: 0"}),
        );
        assert_eq!(event_line(&skipped), None);
        assert_eq!(event_line(&event("prompt", serde_json::json!({}))), None);
    }

    #[test]
    fn keys_drive_input_and_approvals() {
        let mut app = App {
            status: Some(Status::default()),
            ..Default::default()
        };
        for c in "hi".chars() {
            assert_eq!(app.type_char(c), Action::None);
        }
        app.backspace();
        app.type_char('o');
        assert_eq!(
            app.submit(),
            Action::Send(Inbound::Message { text: "ho".into() })
        );
        assert!(app.busy);
        assert_eq!(
            app.take_pending()[0],
            HistoryLine {
                text: "› ho".into(),
                kind: LineKind::User
            }
        );
        // Typing while busy is dropped; a dialog takes over the keys.
        app.type_char('x');
        assert!(app.input.is_empty());
        app.handle(Outbound::Approval(Approval {
            id: "a1".into(),
            command: "git push".into(),
            line: "git push".into(),
            pattern: "git push *".into(),
            directory: "/r".into(),
            level: "dangerous".into(),
            reasons: vec!["changes repository state".into()],
        }));
        assert_eq!(app.take_pending()[0].text, "  - changes repository state");
        assert_eq!(app.type_char('q'), Action::None);
        assert_eq!(
            app.type_char('S'),
            Action::Send(Inbound::Answer {
                id: "a1".into(),
                decision: "session".into()
            })
        );
        assert!(app.approval.is_none());
        assert_eq!(app.interrupt(), Action::Quit);
    }

    #[test]
    fn the_band_renders_status_input_and_dialog() {
        let app = App {
            status: Some(Status {
                model: "system".into(),
                directory: "~/x".into(),
                branch: Some("main".into()),
                dirty: Some(false),
                approval: "--yes".into(),
                context_used: Some(0.137),
            }),
            input: "hello".into(),
            partial: "so far".into(),
            ..Default::default()
        };
        let backend = TestBackend::new(60, BAND_HEIGHT);
        let mut terminal = Terminal::new(backend).expect("test terminal");
        terminal
            .draw(|frame| app.render(frame, frame.area()))
            .expect("draw");
        let buffer = terminal.backend().buffer();
        let row = |index: u16| -> String {
            (0..60)
                .map(|x| buffer[(x, index)].symbol().to_string())
                .collect::<String>()
                .trim_end()
                .to_string()
        };
        assert_eq!(row(0), " so far");
        assert_eq!(row(1), "");
        assert_eq!(row(INPUT_ROW), " › hello");
        assert_eq!(
            row(STATUS_ROW),
            " system · ~/x · main · clean · --yes · context 14% used"
        );
        // The input row's tint runs edge to edge, with half-block strips above and below in the tint.
        assert_eq!(buffer[(0, INPUT_ROW)].bg, palette::DEEP);
        assert_eq!(buffer[(59, INPUT_ROW)].bg, palette::DEEP);
        assert_eq!(buffer[(0, INPUT_ROW - 1)].symbol(), "▄");
        assert_eq!(buffer[(59, INPUT_ROW - 1)].fg, palette::DEEP);
        assert_eq!(buffer[(0, INPUT_ROW + 1)].symbol(), "▀");
        assert_eq!(buffer[(0, INPUT_ROW + 1)].bg, ratatui::style::Color::Reset);
        assert_eq!(buffer[(0, STATUS_ROW)].bg, ratatui::style::Color::Reset);
        assert_eq!(buffer[(1, INPUT_ROW)].fg, palette::GLOW);
        // An empty input shows the placeholder; a nearly full context turns amber.
        let mut status = app.status.clone().unwrap_or_default();
        status.context_used = Some(0.9);
        let empty = App {
            status: Some(status),
            ..Default::default()
        };
        terminal
            .draw(|frame| empty.render(frame, frame.area()))
            .expect("draw");
        let buffer = terminal.backend().buffer();
        let text: String = (0..60)
            .map(|x| buffer[(x, INPUT_ROW)].symbol().to_string())
            .collect();
        assert_eq!(text.trim_end(), format!(" › {PLACEHOLDER}"));
        let row3: String = (0..60)
            .map(|x| buffer[(x, STATUS_ROW)].symbol().to_string())
            .collect();
        let at = row3.find("context").unwrap_or(0);
        let column = u16::try_from(row3[..at].chars().count()).unwrap_or(0);
        assert!(at > 0, "no context part in {row3}");
        assert_eq!(buffer[(column, STATUS_ROW)].fg, palette::AMBER);
    }
}
