//! wisp's colours: one ghostly green-blue in four tones for everything wisp itself says, an amber
//! accent for things that want attention, an ember accent for danger and errors, and white for the
//! conversation. True colour; the same values live in the Swift chat's `Style`.

use ratatui::style::{Color, Modifier, Style};

/// The brightest tone: the prompt and things to look at.
pub const GLOW: Color = Color::Rgb(0xA8, 0xF0, 0xDC);
/// The main tone: model, status facts, ok states.
pub const WISP: Color = Color::Rgb(0x5F, 0xCD, 0xB0);
/// The quiet tone: tool lines, notes, separators.
pub const MIST: Color = Color::Rgb(0x4A, 0x8C, 0x7C);
/// The deep tone: the input row's background.
pub const DEEP: Color = Color::Rgb(0x14, 0x2A, 0x26);
/// Attention: approvals, moderate, a nearly full context.
pub const AMBER: Color = Color::Rgb(0xF2, 0xB9, 0x50);
/// Danger and errors.
pub const EMBER: Color = Color::Rgb(0xFF, 0x6B, 0x6B);
/// The conversation.
pub const WHITE: Color = Color::Rgb(0xE6, 0xED, 0xF0);

/// The user's own words.
pub fn user() -> Style {
    Style::default().fg(WHITE).add_modifier(Modifier::BOLD)
}
/// The model's replies and command output.
pub fn body() -> Style {
    Style::default().fg(WHITE)
}
/// Tool lines, notes, separators.
pub fn muted() -> Style {
    Style::default().fg(MIST)
}
/// The prompt.
pub fn prompt() -> Style {
    Style::default().fg(GLOW).add_modifier(Modifier::BOLD)
}
/// Status facts and ok states.
pub fn wisp() -> Style {
    Style::default().fg(WISP)
}
/// Attention.
pub fn amber() -> Style {
    Style::default().fg(AMBER)
}
/// Danger.
pub fn ember() -> Style {
    Style::default().fg(EMBER)
}
/// The input row's background.
pub fn input_background() -> Style {
    Style::default().bg(DEEP)
}
/// A risk level in its colour.
pub fn level(level: &str) -> Style {
    match level {
        "dangerous" => ember(),
        "moderate" => amber(),
        _ => wisp(),
    }
}
