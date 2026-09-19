import DaimonCore
import Foundation
import MCP

/// The tools daimon advertises to MCP clients, with their JSON Schemas.
///
/// These are deliberately few: each schema costs the caller context, and the
/// on-device model behind `respond` has a small window of its own.
public enum ToolCatalog {
    /// Runs a task on the on-device model, with daimon's own tools available to it.
    public static let respond = Tool(
        name: "respond",
        description:
            "Run a task on this Mac's on-device Apple Foundation Model (or Apple's Private Cloud Compute with "
            + "model: private-cloud). The on-device model is small with a context window "
            + "of roughly 4k tokens, so keep prompts short and delegate only self-contained tasks such as "
            + "summarising a passage, classifying text, or driving a build or test through its own run_command tool. "
            + "Omit thread_id to start a new conversation; the result's structuredContent.thread_id continues it. "
            + "Read the resource daimon://tools for the tools the model can use and how to prompt for them.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "prompt": .object([
                    "type": .string("string"),
                    "description": .string("The task for the model."),
                ]),
                "thread_id": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Conversation to continue. Omit to start a new one (an id is generated), or supply an unused "
                            + "id to start one under that name. instructions and tools apply only when a thread starts."
                    ),
                ]),
                "instructions": .object([
                    "type": .string("string"),
                    "description": .string("Optional system instructions for the session."),
                ]),
                "tools": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "description": .string(
                        "Names of daimon tools the model may call. Omit to allow all registered tools."),
                ]),
                "model": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Model for a new thread: system (on device, default) or private-cloud (Apple Private Cloud "
                            + "Compute; data leaves the Mac). Only when a thread starts."),
                ]),
            ]),
            "required": .array([.string("prompt")]),
        ]),
        annotations: .init(title: "Respond on device", readOnlyHint: false, openWorldHint: false)
    )

    /// Ends a conversation thread and frees its model session.
    public static let closeThread = Tool(
        name: "close_thread",
        description: "End a respond conversation thread and free its model session.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "thread_id": .object([
                    "type": .string("string"),
                    "description": .string("The thread to close."),
                ])
            ]),
            "required": .array([.string("thread_id")]),
        ]),
        annotations: .init(title: "Close thread", readOnlyHint: false, idempotentHint: false, openWorldHint: false)
    )

    /// Every tool, in the order clients see them.
    public static var all: [Tool] { [respond, closeThread] }

    /// URI of the JSON resource describing the model's tools.
    public static let toolsResourceURI = "daimon://tools"
    /// URI of the Markdown resource describing the model's tools.
    public static let toolsMarkdownResourceURI = "daimon://tools.md"

    /// The resources daimon advertises.
    public static let resources: [Resource] = [
        Resource(
            name: "daimon tools", uri: toolsResourceURI, title: "Tools the on-device model can use",
            description:
                "Name, description, JSON Schema arguments, limits, and an example respond prompt for each tool. "
                + "Generated from the same types the model sees.",
            mimeType: "application/json"),
        Resource(
            name: "daimon tools (Markdown)", uri: toolsMarkdownResourceURI, title: "How to prompt for daimon's tools",
            description: "The same catalogue as readable Markdown with prompting rules.", mimeType: "text/markdown"),
    ]
}

/// Validates a client-supplied thread id: 1 to 64 characters from `[A-Za-z0-9._-]`.
///
/// - Throws: `MCPError.invalidParams` otherwise.
func validateThreadID(_ id: String) throws {
    guard SafeName.isValid(id) else { throw MCPError.invalidParams("'thread_id' must be \(SafeName.rule)") }
}

/// Decoded arguments for the `respond` tool.
public struct RespondRequest: Equatable, Sendable {
    /// The task for the model.
    public var prompt: String
    /// Optional session instructions; nil means the server default.
    public var instructions: String?
    /// Which daimon tools to enable; `.all` means the server's set.
    public var tools: ToolSelection
    /// Thread to continue or create; nil means start a new thread with a generated id.
    public var threadID: String?
    /// Model for a new thread; nil means the server default.
    public var model: ModelSelection?

    /// Decodes and validates MCP call arguments.
    ///
    /// - Parameter arguments: The raw `tools/call` arguments.
    /// - Throws: `MCPError.invalidParams` if `prompt` is missing or a field has the wrong type.
    public init(arguments: [String: Value]?) throws {
        guard let prompt = arguments?["prompt"]?.stringValue, !prompt.isEmpty else {
            throw MCPError.invalidParams("'prompt' is required and must be a non-empty string")
        }
        self.prompt = prompt
        if let raw = arguments?["instructions"] {
            guard let text = raw.stringValue else { throw MCPError.invalidParams("'instructions' must be a string") }
            instructions = text
        }
        if let raw = arguments?["tools"] {
            guard let items = raw.arrayValue else { throw MCPError.invalidParams("'tools' must be an array") }
            tools = ToolSelection(
                try items.map {
                    guard let name = $0.stringValue else {
                        throw MCPError.invalidParams("'tools' items must be strings")
                    }
                    return name
                })
        } else {
            tools = .all
        }
        if let raw = arguments?["thread_id"] {
            guard let id = raw.stringValue else { throw MCPError.invalidParams("'thread_id' must be a string") }
            try validateThreadID(id)
            threadID = id
        }
        if let raw = arguments?["model"] {
            guard let text = raw.stringValue else { throw MCPError.invalidParams("'model' must be a string") }
            do {
                model = try ModelSelection(parsing: text)
            } catch {
                throw MCPError.invalidParams("\(error)")
            }
        }
    }
}

/// Decoded arguments for the `close_thread` tool.
public struct CloseThreadRequest: Equatable, Sendable {
    /// The thread to close.
    public var threadID: String

    /// Decodes and validates MCP call arguments.
    ///
    /// - Parameter arguments: The raw `tools/call` arguments.
    /// - Throws: `MCPError.invalidParams` if `thread_id` is missing or malformed.
    public init(arguments: [String: Value]?) throws {
        guard let id = arguments?["thread_id"]?.stringValue else {
            throw MCPError.invalidParams("'thread_id' is required and must be a string")
        }
        try validateThreadID(id)
        threadID = id
    }
}
