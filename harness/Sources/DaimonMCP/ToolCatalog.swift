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
            + "model: private-cloud, or a local Ollama model with model: ollama:<name>). The on-device model is small with a context window "
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
                    "description": .string(
                        "Instructions for this thread, added under daimon's own system prompt. Only when a thread "
                            + "starts."),
                ]),
                "tools": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "description": .string(
                        "Names of daimon tools the model may call. Omit to allow all registered tools; an empty "
                            + "array gives a text-only thread, which any model can run."),
                ]),
                "model": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Model for a new thread: system (on device, default), private-cloud (Apple Private Cloud "
                            + "Compute; data leaves the Mac), or ollama:<name> (a local Ollama model). Only when a "
                            + "thread starts."),
                ]),
                "schema": .object([
                    "type": .string("object"),
                    "description": .string(
                        "JSON Schema for this reply: an object with typed properties (string with enum, integer, "
                            + "number, boolean, array of one type, nested objects; required marks the rest optional). "
                            + "The reply is JSON of that shape, also in structuredContent.output. Per call."),
                ]),
            ]),
            "required": .array([.string("prompt")]),
        ]),
        annotations: .init(title: "Respond on device", readOnlyHint: false, openWorldHint: false)
    )

    /// Runs or reads build/test output on this Mac and returns only the failures.
    public static let triage = Tool(
        name: "triage",
        description:
            "Run a build or test command on this Mac (or read an output file already here) and return only "
            + "its failures as a structured list: kind, location, message. The raw output stays on this Mac; "
            + "the on-device model reads it in chunks. Give exactly one of command or path.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "command": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Shell command line to run with /bin/sh -c under daimon's policy, sandbox, and approval, "
                            + "such as: swift test 2>&1"),
                ]),
                "working_directory": .object([
                    "type": .string("string"),
                    "description": .string("Absolute directory to run the command in. Default: daimon's."),
                ]),
                "path": .object([
                    "type": .string("string"),
                    "description": .string("Absolute path of an output file on this Mac to triage instead."),
                ]),
                "model": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Model to judge the chunks with; as for respond. Default: the configured one."),
                ]),
                "max_findings": .object([
                    "type": .string("integer"),
                    "description": .string("Findings to return at most (default 20); more is flagged."),
                ]),
            ]),
            "required": .array([]),
        ]),
        annotations: .init(title: "Triage build or test output", readOnlyHint: false, openWorldHint: false)
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
    public static var all: [Tool] { [respond, triage, closeThread] }

    /// URI of the JSON resource describing the model's tools.
    public static let toolsResourceURI = "daimon://tools"
    /// URI of the Markdown resource describing the model's tools.
    public static let toolsMarkdownResourceURI = "daimon://tools.md"
    /// URI of the effective configuration.
    public static let configResourceURI = "daimon://config"
    /// URI of the server's status: session, threads, approvals in force.
    public static let statusResourceURI = "daimon://status"
    /// URI of the standing approvals.
    public static let approvalsResourceURI = "daimon://approvals"
    /// URI of the most recent audit events across every session.
    public static let auditResourceURI = "daimon://audit"
    /// URI of the measurements: what the eval harness found each delegated task achieves.
    public static let measurementsResourceURI = "daimon://measurements"
    /// Template for one session's or thread's audit events.
    public static let auditTemplate = "daimon://audit/{session}"

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
        Resource(
            name: "daimon config", uri: configResourceURI, title: "Effective configuration",
            description: "Every setting with defaults applied, the model, the policy, and where the files are.",
            mimeType: "application/json"),
        Resource(
            name: "daimon status", uri: statusResourceURI, title: "Server status",
            description: "The server session, live threads with their turn counts, and approvals in force.",
            mimeType: "application/json"),
        Resource(
            name: "daimon approvals", uri: approvalsResourceURI, title: "Standing command approvals",
            description: "Project and always approvals with pattern, directory, scope, expiry, and source.",
            mimeType: "application/json"),
        Resource(
            name: "daimon audit", uri: auditResourceURI, title: "Recent audit events",
            description:
                "The last 100 audit events across every session, as JSON Lines; the full log is in the audit file.",
            mimeType: "application/x-ndjson"),
        Resource(
            name: "daimon measurements", uri: measurementsResourceURI, title: "What each delegated task achieved",
            description:
                "Eval results per task and model (passed/total, date, what a pass is), recorded by scripts/check "
                + "eval and shipped with this build; a caller reads them to know which delegations are reliable.",
            mimeType: "application/json"),
    ]

    /// Resource templates daimon advertises.
    public static let resourceTemplates: [Resource.Template] = [
        Resource.Template(
            uriTemplate: auditTemplate, name: "daimon audit for one session",
            title: "Audit events of one session or thread",
            description: "Every event of the given session or thread id (a respond thread_id), as JSON Lines.",
            mimeType: "application/x-ndjson")
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
    /// JSON Schema the reply must take, for this call only; nil means prose.
    public var schema: JSONValue?

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
            let names = try items.map {
                guard let name = $0.stringValue else { throw MCPError.invalidParams("'tools' items must be strings") }
                return name
            }
            tools = names.isEmpty ? ToolSelection.none : .named(names)
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
        if let raw = arguments?["schema"] {
            guard raw.objectValue != nil else { throw MCPError.invalidParams("'schema' must be a JSON Schema object") }
            schema = JSONValue(raw)
        }
    }
}

/// Decoded arguments for the `triage` tool.
public struct TriageRequest: Equatable, Sendable {
    /// What to triage.
    public var source: Triage.Source
    /// Model for the judging turns; nil means the server default.
    public var model: ModelSelection?
    /// Findings to keep at most.
    public var maxFindings: Int

    /// Decodes and validates MCP call arguments.
    ///
    /// - Parameter arguments: The raw `tools/call` arguments.
    /// - Throws: `MCPError.invalidParams` unless exactly one of `command` and `path` is a non-empty string.
    public init(arguments: [String: Value]?) throws {
        let command = arguments?["command"]
        let path = arguments?["path"]
        switch (command, path) {
        case (let command?, nil):
            guard let line = command.stringValue, !line.isEmpty else {
                throw MCPError.invalidParams("'command' must be a non-empty string")
            }
            var directory: String?
            if let raw = arguments?["working_directory"] {
                guard let text = raw.stringValue else {
                    throw MCPError.invalidParams("'working_directory' must be a string")
                }
                directory = text
            }
            source = .command(line, workingDirectory: directory)
        case (nil, let path?):
            guard let file = path.stringValue, !file.isEmpty else {
                throw MCPError.invalidParams("'path' must be a non-empty string")
            }
            source = .path(file)
        default:
            throw MCPError.invalidParams("give exactly one of 'command' and 'path'")
        }
        if let raw = arguments?["model"] {
            guard let text = raw.stringValue else { throw MCPError.invalidParams("'model' must be a string") }
            do {
                model = try ModelSelection(parsing: text)
            } catch {
                throw MCPError.invalidParams("\(error)")
            }
        }
        if let raw = arguments?["max_findings"] {
            guard let count = raw.intValue, count > 0 else {
                throw MCPError.invalidParams("'max_findings' must be a positive integer")
            }
            maxFindings = count
        } else {
            maxFindings = Triage.Options().maxFindings
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
