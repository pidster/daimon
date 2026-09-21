import Foundation

/// Terminal styling for the CLI faces: on when stdout is a terminal and `NO_COLOR` is unset, off when
/// piped, so transcripts, tests, and other programs see plain text. Every method returns the text
/// unchanged when styling is off.
public struct Style: Sendable, Equatable {
    /// Whether escape sequences are emitted.
    public let enabled: Bool

    /// Creates a style.
    public init(enabled: Bool) { self.enabled = enabled }

    /// No styling.
    public static let plain = Style(enabled: false)

    /// Styling on for a terminal unless `NO_COLOR` is set or `TERM` is `dumb` (the `no-color.org` rule).
    public static func detect(
        isTerminal: Bool, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Style {
        Style(enabled: isTerminal && environment["NO_COLOR"] == nil && environment["TERM"] != "dumb")
    }

    private func wrap(_ code: String, _ text: String) -> String {
        enabled ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
    }

    /// Bold.
    public func bold(_ text: String) -> String { wrap("1", text) }
    /// Dim, for wisp's own notes and tool activity.
    public func dim(_ text: String) -> String { wrap("2", text) }
    /// Red, for errors and dangerous.
    public func red(_ text: String) -> String { wrap("31", text) }
    /// Green.
    public func green(_ text: String) -> String { wrap("32", text) }
    /// Yellow, for approvals and moderate.
    public func yellow(_ text: String) -> String { wrap("33", text) }
    /// Blue.
    public func blue(_ text: String) -> String { wrap("34", text) }
    /// Magenta.
    public func magenta(_ text: String) -> String { wrap("35", text) }
    /// Cyan, for the prompt.
    public func cyan(_ text: String) -> String { wrap("36", text) }

    /// A risk level in its colour: safe green, moderate yellow, dangerous red.
    public func level(_ level: RiskLevel) -> String {
        switch level {
        case .safe: green(level.rawValue)
        case .moderate: yellow(level.rawValue)
        case .dangerous: red(level.rawValue)
        }
    }

    /// Strips this style's escape sequences from `text`, for tests and width arithmetic.
    public static func stripped(_ text: String) -> String {
        text.replacing(/\u{1B}\[[0-9;]*m/, with: "")
    }
}
