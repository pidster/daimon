/// Which face of wisp a session belongs to. Recorded on `session.start` and on standing approvals,
/// and the closed set `docs/logging.md` documents.
public enum EntryPoint: String, Sendable, Codable, CaseIterable {
    /// `wisp respond`: one prompt, one reply.
    case respond
    /// `wisp chat`: the interactive REPL.
    case chat
    /// `wisp mcp`: the server session that owns every thread.
    case mcp
    /// One MCP `thread_id`, a conversation under an `mcp` session.
    case mcpThread = "mcp-thread"

    /// The entry point of a further conversation opened under this one.
    public var thread: EntryPoint {
        self == .mcp ? .mcpThread : self
    }
}
