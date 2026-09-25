//! `wisp-tui`: a terminal front end for `wisp chat --json`. The conversation scrolls in the
//! terminal's own scrollback; a four-row band at the bottom holds the reply in progress, an approval
//! dialog when there is one, the input line, and the status line (ratatui's inline viewport).
//!
//! Usage: `wisp-tui [chat arguments…]`; every argument is passed to `wisp chat`. `WISP_BIN` names the
//! wisp binary (default `wisp` on `PATH`).

mod app;
mod editor;
mod palette;
mod protocol;

use std::io::{BufRead, BufReader, Write};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::Duration;

use anyhow::{Context, Result};
use ratatui::backend::CrosstermBackend;
use ratatui::crossterm::event::{
    self, DisableBracketedPaste, EnableBracketedPaste, Event as TermEvent, KeyCode, KeyEventKind,
    KeyModifiers,
};
use ratatui::crossterm::execute;
use ratatui::layout::Rect;
use ratatui::text::{Line, Span};
use ratatui::widgets::{Paragraph, Widget, Wrap};
use ratatui::{Terminal, TerminalOptions, Viewport};

use app::{Action, App, BAND_HEIGHT, HistoryLine, LineKind, MARGIN};
use editor::Edit;
use protocol::Outbound;

/// What the main loop waits on.
enum Incoming {
    /// A line from wisp's stdout.
    Line(String),
    /// A line from wisp's stderr.
    Stderr(String),
    /// wisp's stdout closed.
    Closed,
    /// A terminal event.
    Terminal(TermEvent),
}

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if version_requested(&args) {
        println!("{}", env!("CARGO_PKG_VERSION"));
        return Ok(());
    }
    let mut child = spawn(&args)?;
    let stdout = child.stdout.take().context("wisp stdout")?;
    let stderr = child.stderr.take().context("wisp stderr")?;
    let mut stdin = child.stdin.take().context("wisp stdin")?;
    let (tx, rx) = mpsc::channel::<Incoming>();
    let out_tx = tx.clone();
    thread::spawn(move || {
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            if out_tx.send(Incoming::Line(line)).is_err() {
                return;
            }
        }
        let _ = out_tx.send(Incoming::Closed);
    });
    let err_tx = tx.clone();
    thread::spawn(move || {
        for line in BufReader::new(stderr).lines().map_while(Result::ok) {
            if err_tx.send(Incoming::Stderr(line)).is_err() {
                return;
            }
        }
    });
    thread::spawn(move || {
        loop {
            match event::poll(Duration::from_millis(100)) {
                Ok(true) => match event::read() {
                    Ok(event) => {
                        if tx.send(Incoming::Terminal(event)).is_err() {
                            return;
                        }
                    }
                    Err(_) => return,
                },
                Ok(false) => {}
                Err(_) => return,
            }
        }
    });

    let mut terminal = ratatui::init_with_options(TerminalOptions {
        viewport: Viewport::Inline(BAND_HEIGHT),
    });
    // Bracketed paste delivers a paste as one event, so its newlines and keys cannot submit or edit.
    let _ = execute!(std::io::stdout(), EnableBracketedPaste);
    let result = run(&mut terminal, &rx, &mut stdin);
    let _ = execute!(std::io::stdout(), DisableBracketedPaste);
    ratatui::restore();
    let _ = child.wait();
    result
}

/// Whether the only argument asks for the version; the front end's version is wisp's.
fn version_requested(args: &[String]) -> bool {
    args.len() == 1 && (args[0] == "--version" || args[0] == "-V")
}

/// Starts `wisp chat --json` with the given extra arguments.
fn spawn(args: &[String]) -> Result<Child> {
    let bin = std::env::var("WISP_BIN").unwrap_or_else(|_| "wisp".to_string());
    Command::new(&bin)
        .arg("chat")
        .arg("--json")
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .with_context(|| format!("cannot start {bin} chat --json"))
}

/// The loop: apply wisp's lines and the keys, insert finished lines above, redraw the band.
fn run(
    terminal: &mut ratatui::DefaultTerminal,
    rx: &mpsc::Receiver<Incoming>,
    stdin: &mut impl Write,
) -> Result<()> {
    let mut app = App::default();
    let mut height = BAND_HEIGHT;
    terminal.draw(|frame| app.render(frame, frame.area()))?;
    loop {
        let incoming = match rx.recv_timeout(Duration::from_millis(250)) {
            Ok(incoming) => Some(incoming),
            Err(mpsc::RecvTimeoutError::Timeout) => None,
            Err(mpsc::RecvTimeoutError::Disconnected) => return Ok(()),
        };
        match incoming {
            Some(Incoming::Line(line)) => app.handle(Outbound::parse(&line)),
            Some(Incoming::Stderr(line)) => app.handle(Outbound::Note { text: line }),
            Some(Incoming::Closed) => app.exited = true,
            Some(Incoming::Terminal(TermEvent::Paste(text))) => app.edit(&Edit::Paste(text)),
            Some(Incoming::Terminal(TermEvent::Key(key))) if key.kind == KeyEventKind::Press => {
                let action = match command_for(key.code, key.modifiers) {
                    Key::Interrupt => app.interrupt(),
                    Key::Submit => app.submit(),
                    Key::Type(c) => app.type_char(c),
                    Key::Edit(edit) => {
                        app.edit(&edit);
                        Action::None
                    }
                    Key::RecallPrevious => {
                        app.recall_previous();
                        Action::None
                    }
                    Key::RecallNext => {
                        app.recall_next();
                        Action::None
                    }
                    Key::Nothing => Action::None,
                };
                match action {
                    Action::None => {}
                    Action::Send(inbound) => {
                        stdin.write_all(inbound.line().as_bytes())?;
                        stdin.flush()?;
                    }
                    Action::Quit => return Ok(()),
                }
            }
            Some(Incoming::Terminal(_)) | None => {}
        }
        let width = terminal.size()?.width;
        for line in app.take_pending() {
            insert(terminal, &line, width)?;
        }
        let wanted = app.band_height(width);
        if wanted != height {
            regrow(terminal, wanted)?;
            height = wanted;
        }
        terminal.draw(|frame| app.render(frame, frame.area()))?;
        if app.exited {
            return Ok(());
        }
    }
}

/// What a key asks for.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Key {
    /// Cancel a dialog, or quit.
    Interrupt,
    /// Send the input.
    Submit,
    /// A character: typed into the input, or an answer to a dialog.
    Type(char),
    /// An edit to the input.
    Edit(Edit),
    /// The previous submitted line.
    RecallPrevious,
    /// The next submitted line, or back to the draft.
    RecallNext,
    /// Nothing wisp-tui uses.
    Nothing,
}

/// The key map. Readline's bindings where a terminal user expects them (Ctrl-A, E, U, K, W), Alt with an
/// arrow or `b`/`f` for words (what macOS terminals send for Option-arrow), and Alt-Enter for a newline,
/// since a terminal cannot tell Shift-Enter from Enter without the keyboard protocol few support.
fn command_for(code: KeyCode, modifiers: KeyModifiers) -> Key {
    let control = modifiers.contains(KeyModifiers::CONTROL);
    let alt = modifiers.contains(KeyModifiers::ALT);
    match code {
        KeyCode::Char('c' | 'd') if control => Key::Interrupt,
        KeyCode::Char('a') if control => Key::Edit(Edit::Home),
        KeyCode::Char('e') if control => Key::Edit(Edit::End),
        KeyCode::Char('u') if control => Key::Edit(Edit::KillToStart),
        KeyCode::Char('k') if control => Key::Edit(Edit::KillToEnd),
        KeyCode::Char('w') if control => Key::Edit(Edit::DeleteWordBefore),
        KeyCode::Char('b') if alt => Key::Edit(Edit::WordLeft),
        KeyCode::Char('f') if alt => Key::Edit(Edit::WordRight),
        KeyCode::Char(_) if control => Key::Nothing,
        KeyCode::Char(c) => Key::Type(c),
        KeyCode::Enter if alt => Key::Edit(Edit::Newline),
        KeyCode::Enter => Key::Submit,
        KeyCode::Backspace if alt || control => Key::Edit(Edit::DeleteWordBefore),
        KeyCode::Backspace => Key::Edit(Edit::Backspace),
        KeyCode::Delete => Key::Edit(Edit::Delete),
        KeyCode::Left if alt || control => Key::Edit(Edit::WordLeft),
        KeyCode::Right if alt || control => Key::Edit(Edit::WordRight),
        KeyCode::Left => Key::Edit(Edit::Left),
        KeyCode::Right => Key::Edit(Edit::Right),
        KeyCode::Home => Key::Edit(Edit::Home),
        KeyCode::End => Key::Edit(Edit::End),
        KeyCode::Up => Key::RecallPrevious,
        KeyCode::Down => Key::RecallNext,
        _ => Key::Nothing,
    }
}

/// Gives the band a new height. ratatui fixes an inline viewport's height when the terminal is made, so
/// the band is cleared, the cursor put at its top, and a terminal made afresh there: growing reserves
/// the new rows by scrolling when the band is at the bottom; shrinking leaves the band where it starts,
/// and the lines inserted above it later close the gap below.
fn regrow(terminal: &mut ratatui::DefaultTerminal, height: u16) -> Result<()> {
    let top = terminal.get_frame().area().as_position();
    terminal.clear()?;
    terminal.set_cursor_position(top)?;
    *terminal = Terminal::with_options(
        CrosstermBackend::new(std::io::stdout()),
        TerminalOptions {
            viewport: Viewport::Inline(height),
        },
    )?;
    Ok(())
}

/// Writes one history line into scrollback above the band, wrapped to the width.
fn insert(terminal: &mut ratatui::DefaultTerminal, line: &HistoryLine, width: u16) -> Result<()> {
    let style = match line.kind {
        LineKind::User => palette::user(),
        LineKind::Reply | LineKind::Output => palette::body(),
        LineKind::Tool | LineKind::Note => palette::muted(),
        LineKind::Error => palette::ember(),
    };
    let inner = width.saturating_sub(MARGIN * 2).max(1);
    let height = wrapped_height(&line.text, inner);
    let text = line.text.clone();
    terminal.insert_before(height, move |buffer| {
        Paragraph::new(Line::from(Span::styled(text, style)))
            .wrap(Wrap { trim: false })
            .render(Rect::new(MARGIN.min(width / 2), 0, inner, height), buffer);
    })?;
    Ok(())
}

/// Rows `text` takes at `width`, counting characters (wide glyphs may take one more).
fn wrapped_height(text: &str, width: u16) -> u16 {
    let width = usize::from(width.max(1));
    let rows: usize = text
        .split('\n')
        .map(|part| part.chars().count().max(1).div_ceil(width))
        .sum();
    rows.try_into().unwrap_or(u16::MAX).max(1)
}

#[cfg(test)]
mod tests {
    use super::{Edit, Key, KeyCode, KeyModifiers, command_for, version_requested, wrapped_height};

    #[test]
    fn keys_map_to_the_edits_a_terminal_user_expects() {
        let none = KeyModifiers::NONE;
        let ctrl = KeyModifiers::CONTROL;
        let alt = KeyModifiers::ALT;
        assert_eq!(command_for(KeyCode::Char('x'), none), Key::Type('x'));
        assert_eq!(
            command_for(KeyCode::Char('X'), KeyModifiers::SHIFT),
            Key::Type('X')
        );
        assert_eq!(command_for(KeyCode::Char('c'), ctrl), Key::Interrupt);
        assert_eq!(command_for(KeyCode::Char('d'), ctrl), Key::Interrupt);
        assert_eq!(command_for(KeyCode::Char('a'), ctrl), Key::Edit(Edit::Home));
        assert_eq!(command_for(KeyCode::Char('e'), ctrl), Key::Edit(Edit::End));
        assert_eq!(
            command_for(KeyCode::Char('u'), ctrl),
            Key::Edit(Edit::KillToStart)
        );
        assert_eq!(
            command_for(KeyCode::Char('k'), ctrl),
            Key::Edit(Edit::KillToEnd)
        );
        assert_eq!(
            command_for(KeyCode::Char('w'), ctrl),
            Key::Edit(Edit::DeleteWordBefore)
        );
        assert_eq!(command_for(KeyCode::Char('z'), ctrl), Key::Nothing);
        assert_eq!(
            command_for(KeyCode::Char('b'), alt),
            Key::Edit(Edit::WordLeft)
        );
        assert_eq!(
            command_for(KeyCode::Char('f'), alt),
            Key::Edit(Edit::WordRight)
        );
        assert_eq!(command_for(KeyCode::Enter, none), Key::Submit);
        assert_eq!(command_for(KeyCode::Enter, alt), Key::Edit(Edit::Newline));
        assert_eq!(
            command_for(KeyCode::Backspace, none),
            Key::Edit(Edit::Backspace)
        );
        assert_eq!(
            command_for(KeyCode::Backspace, alt),
            Key::Edit(Edit::DeleteWordBefore)
        );
        assert_eq!(command_for(KeyCode::Delete, none), Key::Edit(Edit::Delete));
        assert_eq!(command_for(KeyCode::Left, none), Key::Edit(Edit::Left));
        assert_eq!(command_for(KeyCode::Right, alt), Key::Edit(Edit::WordRight));
        assert_eq!(command_for(KeyCode::Left, ctrl), Key::Edit(Edit::WordLeft));
        assert_eq!(command_for(KeyCode::Home, none), Key::Edit(Edit::Home));
        assert_eq!(command_for(KeyCode::End, none), Key::Edit(Edit::End));
        assert_eq!(command_for(KeyCode::Up, none), Key::RecallPrevious);
        assert_eq!(command_for(KeyCode::Down, none), Key::RecallNext);
        assert_eq!(command_for(KeyCode::F(1), none), Key::Nothing);
    }

    #[test]
    fn version_is_only_the_bare_flag() {
        assert!(version_requested(&["--version".to_string()]));
        assert!(version_requested(&["-V".to_string()]));
        assert!(!version_requested(&[
            "--model".to_string(),
            "--version".to_string()
        ]));
        assert!(!version_requested(&[]));
    }

    #[test]
    fn wrapped_height_counts_rows() {
        assert_eq!(wrapped_height("", 10), 1);
        assert_eq!(wrapped_height("short", 10), 1);
        assert_eq!(wrapped_height("exactly ten", 11), 1);
        assert_eq!(wrapped_height("twelve chars", 10), 2);
        assert_eq!(wrapped_height("a\nb", 10), 2);
    }
}
