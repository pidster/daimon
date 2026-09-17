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
            "Run a task on this Mac's on-device Apple Foundation Model. The model is small with a context window "
            + "of roughly 4k tokens, so keep prompts short and delegate only self-contained tasks such as "
            + "summarising a passage, classifying text, or driving a build or test via its run_command tool. "
            + "Omit thread_id to start a new conversation; the result's structuredContent.thread_id continues it.",
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
            ]),
            "required": .array([.string("prompt")]),
        ]),
        annotations: .init(title: "Respond on device", readOnlyHint: false, openWorldHint: false)
    )

    /// Runs a shell command on this machine without involving the model.
    public static let runCommand = Tool(
        name: "run_command",
        description:
            "Run a shell command on this Mac with /bin/sh -c and return its exit status and the tail of its output.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "command": .object([
                    "type": .string("string"),
                    "description": .string("POSIX shell command line."),
                ]),
                "working_directory": .object([
                    "type": .string("string"),
                    "description": .string("Absolute path to run in. Defaults to the server's current directory."),
                ]),
            ]),
            "required": .array([.string("command")]),
        ]),
        annotations: .init(title: "Run command", readOnlyHint: false, destructiveHint: true, openWorldHint: false)
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
    public static var all: [Tool] { [respond, runCommand, closeThread] }
}

/// Validates a client-supplied thread id: 1 to 64 characters from `[A-Za-z0-9._-]`.
///
/// - Throws: `MCPError.invalidParams` otherwise.
func validateThreadID(_ id: String) throws {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
    guard !id.isEmpty, id.count <= 64, id.unicodeScalars.allSatisfy(allowed.contains) else {
        throw MCPError.invalidParams("'thread_id' must be 1-64 characters from [A-Za-z0-9._-]")
    }
}

/// Decoded arguments for the `respond` tool.
public struct RespondRequest: Equatable, Sendable {
    /// The task for the model.
    public var prompt: String
    /// Optional session instructions; nil means the server default.
    public var instructions: String?
    /// Names of daimon tools to enable; empty means all registered tools.
    public var toolNames: [String]
    /// Thread to continue or create; nil means start a new thread with a generated id.
    public var threadID: String?

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
            toolNames = try items.map {
                guard let name = $0.stringValue else { throw MCPError.invalidParams("'tools' items must be strings") }
                return name
            }
        } else {
            toolNames = []
        }
        if let raw = arguments?["thread_id"] {
            guard let id = raw.stringValue else { throw MCPError.invalidParams("'thread_id' must be a string") }
            try validateThreadID(id)
            threadID = id
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

/// Decoded arguments for the `run_command` tool.
public struct RunCommandRequest: Equatable, Sendable {
    /// POSIX shell command line.
    public var command: String
    /// Optional absolute directory to run in.
    public var workingDirectory: String?

    /// Decodes and validates MCP call arguments.
    ///
    /// - Parameter arguments: The raw `tools/call` arguments.
    /// - Throws: `MCPError.invalidParams` if `command` is missing or a field has the wrong type.
    public init(arguments: [String: Value]?) throws {
        guard let command = arguments?["command"]?.stringValue, !command.isEmpty else {
            throw MCPError.invalidParams("'command' is required and must be a non-empty string")
        }
        self.command = command
        if let raw = arguments?["working_directory"] {
            guard let path = raw.stringValue else {
                throw MCPError.invalidParams("'working_directory' must be a string")
            }
            workingDirectory = path
        }
    }
}
