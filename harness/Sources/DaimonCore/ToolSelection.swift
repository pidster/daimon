/// Which tools a session or conversation gets.
///
/// One type for the CLI's `--tool`, the MCP `tools` argument, and the session, so "no selection"
/// is spelled one way (`.all`) instead of as an empty array in some places and nil in others.
public enum ToolSelection: Sendable, Equatable {
    /// Every tool the context offers: the whole registry for a session, the session's set for a thread.
    case all
    /// Exactly these tools, by name, in this order.
    case named([String])

    /// `.all` for an empty list, `.named` otherwise: the shape flags and JSON arrays arrive in.
    public init(_ names: [String]) {
        self = names.isEmpty ? .all : .named(names)
    }

    /// The names, or `fallback` for `.all`.
    public func resolved(or fallback: [String]) -> [String] {
        switch self {
        case .all: fallback
        case .named(let names): names
        }
    }
}
