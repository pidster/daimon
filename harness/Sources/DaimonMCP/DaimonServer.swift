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
    /// Opens the agent that judges one triage chunk; tests inject one over a scripted model.
    private let makeTriageAgent: @Sendable (Conversation) throws -> Agent

    /// Creates a server over a session begun by the CLI. Threads are opened through
    /// `Session.conversation` with an elicitation approver, so every face of daimon shares one
    /// set-up path and differs only in how it asks.
    ///
    /// - Parameters:
    ///   - session: The session from `Session.begin`.
    ///   - makeThread: How threads are built; tests inject a fake that needs no model.
    ///   - makeTriageAgent: How a triage chunk's agent is opened on its conversation; tests inject a
    ///     scripted model.
    public init(
        session: Session,
        makeThread: @escaping ThreadFactory = { session, approver, id, instructions, tools, model in
            let conversation = try session.conversation(
                id: id, approver: approver, instructions: instructions, tools: tools, model: model)
            return OpenThread(
                thread: ConversationThread(id: id, agent: try conversation.openAgent()), gate: conversation.gate,
                audit: conversation.audit, receipts: conversation.receipts)
        },
        makeTriageAgent: @escaping @Sendable (Conversation) throws -> Agent = { try $0.openAgent() }
    ) {
        server = Server(
            name: Self.name, version: Self.version,
            capabilities: .init(
                resources: .init(subscribe: false, listChanged: false), tools: .init(listChanged: false)))
        self.session = session
        approver = ElicitationApprover(server: server, client: client, timeout: session.config.approvalTimeout)
        threads = ThreadStore(capacity: session.config.maxThreads)
        self.makeThread = makeThread
        self.makeTriageAgent = makeTriageAgent
    }

    private var config: Config.Resolved { session.config }
    private var audit: AuditLog { session.audit }

    /// Starts serving on stdin/stdout and returns when the client disconnects.
    ///
    /// - Throws: Transport errors from the MCP SDK.
    public func run() async throws {
        Diagnostics.mcp.info("serving on stdio")
        try await serve(transport: StdioTransport(logger: DiagnosticsLogHandler.logger()))
        await server.waitUntilCompleted()
        Diagnostics.mcp.info("client disconnected")
    }

    /// Registers the method handlers and starts the server on `transport`, wrapped in
    /// `CompatibilityTransport`; returns once the transport is up. Tests call this with an in-memory
    /// transport and a real client.
    ///
    /// - Throws: Transport errors from the MCP SDK.
    func serve(transport: any Transport) async throws {
        let transport = CompatibilityTransport(transport)
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: ToolCatalog.all) }
        await server.withMethodHandler(CallTool.self) { params in try await self.call(params) }
        await server.withMethodHandler(ListResources.self) { _ in
            .init(resources: ToolCatalog.resources, nextCursor: nil)
        }
        await server.withMethodHandler(ListResourceTemplates.self) { _ in
            .init(templates: ToolCatalog.resourceTemplates, nextCursor: nil)
        }
        await server.withMethodHandler(ReadResource.self) { params in try await self.read(params) }
        let client = client
        try await server.start(transport: transport) { info, capabilities in
            let supported = capabilities.elicitation != nil
            client.elicitation.withLock { $0 = supported }
            Diagnostics.mcp.info(
                "client \(info.name) \(info.version); elicitation \(supported ? "supported" : "unsupported")")
        }
    }

    /// Stops the server; tests call this after `serve`.
    func stop() async {
        await server.stop()
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
            case ToolCatalog.triage.name:
                let request = try TriageRequest(arguments: params.arguments)
                result = await triage(request)
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

    /// Serves the resources: the tool catalogue from the live registry, and the introspection views.
    ///
    /// - Throws: `MCPError.invalidParams` for an unknown URI; file errors reading the audit log.
    func read(_ params: ReadResource.Parameters) async throws -> ReadResource.Result {
        let registry = ToolRegistry(runner: config.runner)
        let views = session.introspection
        func json(_ value: JSONValue) -> ReadResource.Result {
            .init(contents: [.text(Introspection.render(value), uri: params.uri, mimeType: "application/json")])
        }
        func lines(_ events: [AuditEvent]) throws -> ReadResource.Result {
            let text = try events.map { String(decoding: try AuditEvent.encoder.encode($0), as: UTF8.self) }
                .joined(separator: "\n")
            return .init(contents: [.text(text, uri: params.uri, mimeType: "application/x-ndjson")])
        }
        switch params.uri {
        case ToolCatalog.toolsResourceURI:
            return .init(contents: [.text(registry.descriptionsJSON, uri: params.uri, mimeType: "application/json")])
        case ToolCatalog.toolsMarkdownResourceURI:
            return .init(contents: [.text(registry.descriptionsMarkdown, uri: params.uri, mimeType: "text/markdown")])
        case ToolCatalog.measurementsResourceURI:
            return .init(
                contents: [
                    .text(Measurements.encode(Measurements.embedded), uri: params.uri, mimeType: "application/json")
                ])
        case ToolCatalog.configResourceURI:
            return json(views.configuration)
        case ToolCatalog.statusResourceURI:
            var status = views.status()
            status["threads"] = .array(await threads.ids.map { .string($0) })
            status["standingApprovals"] = .int(await session.store.all.count)
            return json(.object(status))
        case ToolCatalog.approvalsResourceURI:
            return json(await views.approvals())
        case ToolCatalog.auditResourceURI:
            return try lines(try views.audit(AuditQuery(last: 100)))
        case let uri where uri.hasPrefix(ToolCatalog.auditResourceURI + "/"):
            let id = String(uri.dropFirst(ToolCatalog.auditResourceURI.count + 1))
            guard SafeName.isValid(id) else { throw MCPError.invalidParams("session id must be \(SafeName.rule)") }
            return try lines(try views.audit(AuditQuery(session: id)))
        default:
            throw MCPError.invalidParams("Unknown resource: \(params.uri)")
        }
    }

    /// The reply's JSON as an MCP value, or the text itself if it does not parse (it always should:
    /// guided generation produced it).
    private static func parse(_ text: String) -> Value {
        guard let data = text.data(using: .utf8), let value = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return .string(text) }
        return Value(json: value)
    }

    /// A compact JSON rendering of MCP arguments for the audit log.
    private static func render(_ value: [String: Value]) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Finds or creates the thread, runs the prompt, and reports the thread id, whether it was condensed,
    /// the gate's refusals, and the turn's receipt.
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
        let schema: OutputSchema?
        do {
            schema = try request.schema.map { try OutputSchema(json: $0) }
        } catch {
            return failure(String(describing: error))
        }
        do {
            let reply = try await opened.thread.thread.respond(to: request.prompt, schema: schema)
            let refusals = await opened.thread.gate.takeRefusals()
            let receipt = opened.thread.receipts.take(turn: opened.thread.audit.currentTurn)
            return .init(
                content: [.text(text: reply.text, annotations: nil, _meta: nil)],
                structuredContent: .object([
                    "thread_id": .string(id), "created": .bool(opened.created), "condensed": .bool(reply.condensed),
                    "text": .string(reply.text),
                    "refusals": .array(
                        refusals.map { .object(["command": .string($0.command), "reason": .string($0.reason)]) }),
                    "receipt": Value(json: receipt.json),
                    "output": schema == nil ? .null : Self.parse(reply.text),
                ]),
                isError: false
            )
        } catch LanguageModelError.contextSizeExceeded {
            return failure("thread \(id) has exhausted the model's context window; close it and start a new one")
        } catch {
            return failure(String(describing: error))
        }
    }

    /// Captures the output on a conversation of its own (so the command, the file read, and every
    /// judging turn are audited under one session), judges it chunk by chunk, and returns the findings.
    private func triage(_ request: TriageRequest) async -> CallTool.Result {
        let id = "triage-" + ShortID.make()
        do {
            let conversation = try session.conversation(id: id, approver: approver, tools: .none, model: request.model)
            defer { conversation.audit.record(.sessionEnd, details: AuditEvent.Details.sessionEnd(reason: "closed")) }
            let schema = try OutputSchema(json: Triage.schemaJSON)
            let makeAgent = makeTriageAgent
            let triage = Triage(options: .init(maxFindings: request.maxFindings)) { prompt in
                try await makeAgent(conversation).respond(to: prompt, schema: schema).text
            }
            let runner = CommandRunner(
                options: session.config.runner, audit: conversation.audit, approval: conversation.gate)
            let captured = try await triage.capture(request.source, runner: runner, gate: conversation.gate)
            let report = try await triage.run(captured, from: request.source)
            let structured: Value? = Value(json: report.json)  // the typed init, not the throwing generic one
            return .init(
                content: [.text(text: report.rendered, annotations: nil, _meta: nil)], structuredContent: structured,
                isError: false)
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
