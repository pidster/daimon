import DaimonCore
import Foundation
import FoundationModels
import Logging
import MCP

/// Serves daimon's capabilities to MCP clients over stdio.
///
/// Conversations are kept as threads in a `ThreadStore` for the life of the
/// process. Stdout is the protocol channel; nothing else in the process may
/// write to it while the server runs.
public struct DaimonServer: Sendable {
    /// Server name reported during the MCP handshake.
    public static let name = "daimon"
    /// Server version reported during the MCP handshake.
    public static let version = "0.1.0"

    /// Default instructions, `run_command` limits, and thread capacity.
    private let config: Config.Resolved
    /// Live conversations by `thread_id`.
    private let threads: ThreadStore<ConversationThread>
    /// Audit log for the server session; threads get sibling logs keyed by thread id.
    private let audit: AuditLog

    /// Creates a server from resolved configuration: default instructions for
    /// `respond`, limits for `run_command`, and the thread capacity.
    ///
    /// - Parameters:
    ///   - config: Resolved configuration.
    ///   - audit: Where MCP requests and thread activity are recorded; defaults to nothing.
    public init(config: Config.Resolved = Config().resolved, audit: AuditLog? = nil) {
        self.config = config
        threads = ThreadStore(capacity: config.maxThreads)
        self.audit = audit ?? .disabled(session: "mcp")
    }

    /// Starts serving on stdin/stdout and returns when the client disconnects.
    ///
    /// - Throws: Transport errors from the MCP SDK.
    public func run() async throws {
        let server = Server(
            name: Self.name,
            version: Self.version,
            capabilities: .init(tools: .init(listChanged: false))
        )
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: ToolCatalog.all) }
        await server.withMethodHandler(CallTool.self) { params in try await self.call(params) }
        Diagnostics.mcp.info("serving on stdio")
        try await server.start(transport: StdioTransport(logger: DiagnosticsLogHandler.logger()))
        await server.waitUntilCompleted()
        Diagnostics.mcp.info("client disconnected")
    }

    /// Dispatches one `tools/call`. Argument errors surface as MCP protocol
    /// errors; execution failures come back as tool results with `isError`.
    func call(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let call = String(UUID().uuidString.prefix(8)).lowercased()
        let arguments = params.arguments.map { Self.render($0) } ?? "{}"
        audit.record(.mcpRequest, call: call, details: ["tool": .string(params.name), "arguments": .string(arguments)])
        Diagnostics.mcp.debug("request \(call) \(params.name) \(arguments)")
        let started = Date()
        let result: CallTool.Result
        do {
            switch params.name {
            case ToolCatalog.respond.name:
                let request = try RespondRequest(arguments: params.arguments)
                result = await respond(request)
            case ToolCatalog.runCommand.name:
                let request = try RunCommandRequest(arguments: params.arguments)
                result = await runCommand(request)
            case ToolCatalog.closeThread.name:
                let request = try CloseThreadRequest(arguments: params.arguments)
                result = await closeThread(request)
            default:
                throw MCPError.methodNotFound("Unknown tool: \(params.name)")
            }
        } catch {
            audit.error(error, call: call, context: "mcp \(params.name)")
            throw error
        }
        let text = result.content.compactMap { if case .text(let t, _, _) = $0 { t } else { nil } }.joined(
            separator: "\n")
        audit.record(
            .mcpResult, call: call,
            details: [
                "tool": .string(params.name), "isError": .bool(result.isError ?? false), "text": .string(text),
                "seconds": .double(Date().timeIntervalSince(started)),
            ])
        return result
    }

    /// A compact JSON rendering of MCP arguments for the audit log.
    private static func render(_ value: [String: Value]) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Finds or creates the thread, runs the prompt, and reports the thread id and whether it was condensed.
    private func respond(_ request: RespondRequest) async -> CallTool.Result {
        let thread: ConversationThread
        var created = false
        if let id = request.threadID, let existing = await threads.find(id) {
            guard request.instructions == nil, request.toolNames.isEmpty else {
                return failure("instructions and tools apply only when a thread is created; \(id) already exists")
            }
            thread = existing
        } else {
            let id = request.threadID ?? UUID().uuidString.lowercased()
            let threadAudit = audit.log(forSession: id)
            let registry = ToolRegistry(runner: config.runner, audit: threadAudit)
            let tools: [any FoundationModels.Tool]
            if request.toolNames.isEmpty {
                tools = registry.all
            } else {
                let selection = registry.select(request.toolNames)
                guard selection.unknown.isEmpty else {
                    return failure("Unknown tool(s): \(selection.unknown.joined(separator: ", "))")
                }
                tools = selection.tools
            }
            let instructions = request.instructions ?? config.instructions
            do {
                thread = try await threads.create(id: id) {
                    try ConversationThread(id: id, instructions: instructions, tools: tools, audit: threadAudit)
                }
                threadAudit.record(
                    .sessionStart,
                    details: [
                        "entryPoint": "mcp-thread", "instructions": .string(instructions),
                        "tools": .array(tools.map { .string($0.name) }),
                    ])
                created = true
            } catch {
                return failure(String(describing: error))
            }
        }
        do {
            let reply = try await thread.respond(to: request.prompt)
            return .init(
                content: [.text(text: reply.text, annotations: nil, _meta: nil)],
                structuredContent: .object([
                    "thread_id": .string(thread.id), "created": .bool(created), "condensed": .bool(reply.condensed),
                    "text": .string(reply.text),
                ]),
                isError: false
            )
        } catch LanguageModelError.contextSizeExceeded {
            return failure(
                "thread \(thread.id) has exhausted the model's context window; close it and start a new one")
        } catch {
            return failure(String(describing: error))
        }
    }

    /// Frees a thread; unknown ids are tool errors.
    private func closeThread(_ request: CloseThreadRequest) async -> CallTool.Result {
        do {
            try await threads.close(request.threadID)
            audit.log(forSession: request.threadID).record(.sessionEnd, details: ["reason": "closed"])
            return success("closed \(request.threadID)")
        } catch {
            return failure(String(describing: error))
        }
    }

    /// Runs a command with the configured limits, without involving the model.
    private func runCommand(_ request: RunCommandRequest) async -> CallTool.Result {
        var runner = CommandRunner(options: config.runner, audit: audit)
        if let directory = request.workingDirectory {
            runner.options.workingDirectory = directory
        }
        do {
            return success(try await runner.run(request.command).rendered)
        } catch {
            return failure(String(describing: error))
        }
    }

    /// A text result with `isError: false`.
    private func success(_ text: String) -> CallTool.Result {
        .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
    }

    /// A text result with `isError: true`, the MCP shape for execution failures.
    private func failure(_ message: String) -> CallTool.Result {
        .init(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
    }
}
