import DaimonCore
import Foundation
import FoundationModels
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

    private let config: Config.Resolved
    private let registry: ToolRegistry
    private let threads: ThreadStore<ConversationThread>

    /// Creates a server from resolved configuration: default instructions for
    /// `respond`, limits for `run_command`, and the thread capacity.
    public init(config: Config.Resolved = Config().resolved) {
        self.config = config
        registry = ToolRegistry(runner: config.runner)
        threads = ThreadStore(capacity: config.maxThreads)
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
        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }

    /// Dispatches one `tools/call`. Argument errors surface as MCP protocol
    /// errors; execution failures come back as tool results with `isError`.
    func call(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        switch params.name {
        case ToolCatalog.respond.name:
            let request = try RespondRequest(arguments: params.arguments)
            return await respond(request)
        case ToolCatalog.runCommand.name:
            let request = try RunCommandRequest(arguments: params.arguments)
            return await runCommand(request)
        case ToolCatalog.closeThread.name:
            let request = try CloseThreadRequest(arguments: params.arguments)
            return await closeThread(request)
        default:
            throw MCPError.methodNotFound("Unknown tool: \(params.name)")
        }
    }

    private func respond(_ request: RespondRequest) async -> CallTool.Result {
        let thread: ConversationThread
        var created = false
        if let id = request.threadID, let existing = await threads.find(id) {
            guard request.instructions == nil, request.toolNames.isEmpty else {
                return failure("instructions and tools apply only when a thread is created; \(id) already exists")
            }
            thread = existing
        } else {
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
            let id = request.threadID ?? UUID().uuidString.lowercased()
            let instructions = request.instructions ?? config.instructions
            do {
                thread = try await threads.create(id: id) {
                    try ConversationThread(id: id, instructions: instructions, tools: tools)
                }
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

    private func closeThread(_ request: CloseThreadRequest) async -> CallTool.Result {
        do {
            try await threads.close(request.threadID)
            return success("closed \(request.threadID)")
        } catch {
            return failure(String(describing: error))
        }
    }

    private func runCommand(_ request: RunCommandRequest) async -> CallTool.Result {
        var runner = CommandRunner(options: config.runner)
        if let directory = request.workingDirectory {
            runner.options.workingDirectory = directory
        }
        do {
            return success(try await runner.run(request.command).rendered)
        } catch {
            return failure(String(describing: error))
        }
    }

    private func success(_ text: String) -> CallTool.Result {
        .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
    }

    private func failure(_ message: String) -> CallTool.Result {
        .init(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
    }
}
