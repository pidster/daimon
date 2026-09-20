/// Which tools a session or conversation gets.
///
/// One type for the CLI's `--tool` and `--no-tools`, the MCP `tools` argument, and the session, so
/// "no selection" is spelled one way (`.all`) instead of as an empty array in some places and nil in
/// others, and "no tools at all" (`.none`) is distinct from it.
public enum ToolSelection: Sendable, Equatable {
    /// Every tool the context offers: the whole registry for a session, the session's set for a thread.
    case all
    /// Exactly these tools, by name, in this order.
    case named([String])
    /// No tools: a text-only conversation, which any model can run.
    case none

    /// `.all` for an empty list, `.named` otherwise: the shape a repeatable flag arrives in.
    public init(_ names: [String]) {
        self = names.isEmpty ? .all : .named(names)
    }

    /// The names, `fallback` for `.all`, or nothing for `.none`.
    public func resolved(or fallback: [String]) -> [String] {
        switch self {
        case .all: fallback
        case .named(let names): names
        case .none: []
        }
    }
}
