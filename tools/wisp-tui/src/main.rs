//! `wisp-tui`: a terminal front end for `wisp chat --json`. The conversation scrolls in the
//! terminal's own scrollback; a four-row band at the bottom holds the reply in progress, an approval
//! dialog when there is one, the input line, and the status line (ratatui's inline viewport).
//!
//! Usage: `wisp-tui [chat arguments…]`; every argument is passed to `wisp chat`. `WISP_BIN` names the
//! wisp binary (default `wisp` on `PATH`).

mod app;
mod palette;
mod protocol;

use std::io::{BufRead, BufReader, Write};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::Duration;

use anyhow::{Context, Result};
use ratatui::crossterm::event::{self, Event as TermEvent, KeyCode, KeyEventKind, KeyModifiers};
use ratatui::layout::Rect;
use ratatui::text::{Line, Span};
use ratatui::widgets::{Paragraph, Widget, Wrap};
use ratatui::{TerminalOptions, Viewport};

use app::{Action, App, BAND_HEIGHT, HistoryLine, LineKind, MARGIN};
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
    let result = run(&mut terminal, &rx, &mut stdin);
    ratatui::restore();
    let _ = child.wait();
    result
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
            Some(Incoming::Terminal(TermEvent::Key(key))) if key.kind == KeyEventKind::Press => {
                let action = match (key.code, key.modifiers) {
                    (KeyCode::Char('c' | 'd'), KeyModifiers::CONTROL) => app.interrupt(),
                    (KeyCode::Enter, _) => app.submit(),
                    (KeyCode::Backspace, _) => {
                        app.backspace();
                        Action::None
                    }
                    (KeyCode::Char(c), _) => app.type_char(c),
                    _ => Action::None,
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
        terminal.draw(|frame| app.render(frame, frame.area()))?;
        if app.exited {
            return Ok(());
        }
    }
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
    use super::wrapped_height;

    #[test]
    fn wrapped_height_counts_rows() {
        assert_eq!(wrapped_height("", 10), 1);
        assert_eq!(wrapped_height("short", 10), 1);
        assert_eq!(wrapped_height("exactly ten", 11), 1);
        assert_eq!(wrapped_height("twelve chars", 10), 2);
        assert_eq!(wrapped_height("a\nb", 10), 2);
    }
}
