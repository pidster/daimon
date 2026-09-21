/// The three layers of what the model is told before any prompt, and how they become one
/// `Instructions` value ([ADR 0017](../../../../docs/decisions/0017-three-layer-instructions.md)).
///
/// 1. wisp's system prompt: fixed in code, the same for every face and release. Cannot be removed.
/// 2. The system prompt extension: this Mac's operator, from `config.json`, for every session.
/// 3. The conversation's instructions: the caller, from `--instructions` or MCP `instructions`, for one
///    session or one thread.
public struct Prompting: Equatable, Sendable {
    /// Layer 1: the text of `Resources/system-prompt.md`, embedded at build time by the
    /// `EmbedSystemPrompt` plugin, trimmed. Identity, tool discipline, faithful reporting, and brevity,
    /// kept short because the on-device model's window is about 4k tokens.
    public static let systemPrompt = SystemPromptText.text.trimmingCharacters(in: .whitespacesAndNewlines)

    /// Layer 2, or nil when the operator set none.
    public var systemPromptExtension: String?
    /// Layer 3, or nil when the caller gave none.
    public var instructions: String?

    /// Creates the layers.
    public init(systemPromptExtension: String? = nil, instructions: String? = nil) {
        self.systemPromptExtension = systemPromptExtension
        self.instructions = instructions
    }

    /// The three layers as one text, in order, each optional layer under a short heading so the model
    /// and a log reader can tell whose words they are.
    public var rendered: String { rendered(toolsAvailable: true) }

    /// `rendered`, with one more sentence of wisp's own when the conversation has no tools, so a
    /// model told about tool discipline does not invent tool calls it cannot make.
    ///
    /// - Parameter toolsAvailable: Whether the conversation has any tools.
    /// - Returns: The text the framework is given as instructions.
    public func rendered(toolsAvailable: Bool) -> String {
        var parts = [Self.systemPrompt]
        if !toolsAvailable {
            parts[0] += " This conversation has no tools; answer directly from what you know."
        }
        if let extra = systemPromptExtension?.trimmingCharacters(in: .whitespacesAndNewlines), !extra.isEmpty {
            parts.append("Guidance for this Mac:\n\(extra)")
        }
        if let task = instructions?.trimmingCharacters(in: .whitespacesAndNewlines), !task.isEmpty {
            parts.append("Instructions for this conversation:\n\(task)")
        }
        return parts.joined(separator: "\n\n")
    }
}
