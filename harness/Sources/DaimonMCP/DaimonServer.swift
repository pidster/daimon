import DaimonCore
import Foundation
import FoundationModels
import Logging
import MCP
import Synchronization

/// Serves daimon's capabilities to MCP clients over stdio.
///
/// Conversations are kept as threads in a `ThreadStore` for the life of the
/// process. Stdout is the protocol channel; nothing else in the process may
/// write to it while the server runs.
public struct DaimonServer: Sendable {
    /// Server name reported during the MCP handshake.
    public static let name = "daimon"
    /// Server version reported during the MCP handshake; the same single source as `--version`.
    public static let version = DaimonVersion.current

    /// The session every thread shares: policy, store, session approvals, audit, and the elicitation approver.
    private let session: Session
    /// Live conversations by `thread_id`, each with its gate and audit log.
    private let threads: ThreadStore<OpenThread>
    /// The MCP server; created up front so the approver can reach the client.
    private let server: Server
    /// Set from the initialize hook when the client advertises elicitation.
    private let client = ClientCapabilityFlags()
    /// Builds the record for a new `thread_id` from the conversation the session sets up for it.
    public typealias ThreadFactory =
        @Sendable (
            _ session: Session, _ approver: any Approver, _ id: String, _ instructions: String?,
            _ tools: ToolSelection, _ model: ModelSelection?
        ) throws -> OpenThread
    private let makeThread: ThreadFactory
    /// Asks the client's user through elicitation; `--yes` sessions bypass it inside the gate.
    private let approver: ElicitationApprover

    /// Creates a server over a session begun by the CLI. Threads are opened through
    /// `Session.conversation` with an elicitation approver, so every face of daimon shares one
    /// set-up path and differs only in how it asks.
    ///
    /// - Parameters:
    ///   - session: The session from `Session.begin`.
    ///   - makeThread: How threads are built; tests inject a fake that needs no model.
    public init(
        session: Session,
        makeThread: @escaping ThreadFactory = { session, approver, id, instructions, tools, model in
            let conversation = try session.conversation(
                id: id, approver: approver, instructions: instructions, tools: tools, model: model)
            return OpenThread(
                thread: ConversationThread(id: id, agent: try conversation.openAgent()), gate: conversation.gate,
                audit: conversation.audit)
        }
    ) {
        server = Server(
            name: Self.name, version: Self.version,
            capabilities: .init(
                resources: .init(subscribe: false, listChanged: false), tools: .init(listChanged: false)))
        self.session = session
        approver = ElicitationApprover(server: server, client: client, timeout: session.config.approvalTimeout)
        threads = ThreadStore(capacity: session.config.maxThreads)
        self.makeThread = makeThread
    }

    private var config: Config.Resolved { session.config }
    private var audit: AuditLog { session.audit }

    /// Starts serving on stdin/stdout and returns when the client disconnects.
    ///
    /// - Throws: Transport errors from the MCP SDK.
    public func run() async throws {
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: ToolCatalog.all) }
        await server.withMethodHandler(CallTool.self) { params in try await self.call(params) }
        await server.withMethodHandler(ListResources.self) { _ in
            .init(resources: ToolCatalog.resources, nextCursor: nil)
        }
        await server.withMethodHandler(ReadResource.self) { params in try self.read(params) }
        Diagnostics.mcp.info("serving on stdio")
        let client = client
        try await server.start(transport: StdioTransport(logger: DiagnosticsLogHandler.logger())) {
            info, capabilities in
            let supported = capabilities.elicitation != nil
            client.elicitation.withLock { $0 = supported }
            Diagnostics.mcp.info(
                "client \(info.name) \(info.version); elicitation \(supported ? "supported" : "unsupported")")
        }
        await server.waitUntilCompleted()
        Diagnostics.mcp.info("client disconnected")
    }

    /// Dispatches one `tools/call`. Argument errors surface as MCP protocol
    /// errors; execution failures come back as tool results with `isError`.
    func call(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let call = ShortID.make()
        let arguments = params.arguments.map { Self.render($0) } ?? "{}"
        audit.record(
            .mcpRequest, call: call, details: AuditEvent.Details.mcpRequest(tool: params.name, arguments: arguments))
        Diagnostics.mcp.debug("request \(call) \(params.name) \(arguments)")
        let started = Date()
        let result: CallTool.Result
        do {
            switch params.name {
            case ToolCatalog.respond.name:
                let request = try RespondRequest(arguments: params.arguments)
                result = await respond(request)
            case ToolCatalog.closeThread.name:
                let request = try CloseThreadRequest(arguments: params.arguments)
                result = await closeThread(request)
            default:
                throw MCPError.invalidParams("Unknown tool: \(params.name)")
            }
        } catch {
            audit.error(error, call: call, context: "mcp \(params.name)")
            throw error
        }
        let text = result.content.compactMap { if case .text(let t, _, _) = $0 { t } else { nil } }.joined(
            separator: "\n")
        audit.record(
            .mcpResult, call: call,
            details: AuditEvent.Details.mcpResult(
                tool: params.name, isError: result.isError ?? false, text: text,
                seconds: Date().timeIntervalSince(started)))
        return result
    }

    /// Serves the tool catalogue resources, generated from the live registry.
    func read(_ params: ReadResource.Parameters) throws -> ReadResource.Result {
        let registry = ToolRegistry(runner: config.runner)
        switch params.uri {
        case ToolCatalog.toolsResourceURI:
            return .init(contents: [.text(registry.descriptionsJSON, uri: params.uri, mimeType: "application/json")])
        case ToolCatalog.toolsMarkdownResourceURI:
            return .init(contents: [.text(registry.descriptionsMarkdown, uri: params.uri, mimeType: "text/markdown")])
        default:
            throw MCPError.invalidParams("Unknown resource: \(params.uri)")
        }
    }

    /// A compact JSON rendering of MCP arguments for the audit log.
    private static func render(_ value: [String: Value]) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Finds or creates the thread, runs the prompt, and reports the thread id and whether it was condensed.
    private func respond(_ request: RespondRequest) async -> CallTool.Result {
        let id = request.threadID ?? UUID().uuidString.lowercased()
        let opened: ThreadStore<OpenThread>.Opened
        do {
            opened = try await threads.findOrCreate(id: id) {
                try makeThread(
                    session, approver, id, request.instructions, request.tools, request.model)
            }
        } catch {
            return failure(String(describing: error))
        }
        if let evicted = opened.evicted {
            evicted.thread.audit.record(.sessionEnd, details: AuditEvent.Details.sessionEnd(reason: "evicted"))
            Diagnostics.mcp.info("evicted thread \(evicted.id) to make room for \(id)")
        }
        if !opened.created, request.instructions != nil || request.tools != .all || request.model != nil {
            return failure("instructions, tools, and model apply only when a thread is created; \(id) already exists")
        }
        do {
            let reply = try await opened.thread.thread.respond(to: request.prompt)
            let refusals = await opened.thread.gate.takeRefusals()
            return .init(
                content: [.text(text: reply.text, annotations: nil, _meta: nil)],
                structuredContent: .object([
                    "thread_id": .string(id), "created": .bool(opened.created), "condensed": .bool(reply.condensed),
                    "text": .string(reply.text),
                    "refusals": .array(
                        refusals.map { .object(["command": .string($0.command), "reason": .string($0.reason)]) }),
                ]),
                isError: false
            )
        } catch LanguageModelError.contextSizeExceeded {
            return failure("thread \(id) has exhausted the model's context window; close it and start a new one")
        } catch {
            return failure(String(describing: error))
        }
    }

    /// Frees a thread; unknown ids are tool errors.
    private func closeThread(_ request: CloseThreadRequest) async -> CallTool.Result {
        do {
            let closed = try await threads.close(request.threadID)
            closed.audit.record(.sessionEnd, details: AuditEvent.Details.sessionEnd(reason: "closed"))
            return success("closed \(request.threadID)")
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
