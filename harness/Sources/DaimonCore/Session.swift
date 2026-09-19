import Foundation
import FoundationModels

/// Everything an entry point needs before it creates an `Agent`, built the same way for
/// `respond`, `chat`, and `mcp` so their behaviour and audit records cannot drift.
public struct Session: Sendable {
    /// What the entry point asked for, from flags and arguments.
    public struct Request: Sendable, Equatable {
        /// `respond`, `chat`, or `mcp`, recorded in the audit log.
        public var entryPoint: String
        /// Instructions override; nil takes `config.json`'s.
        public var instructions: String?
        /// Model override; nil takes `config.json`'s.
        public var model: ModelSelection?
        /// Tools to enable; empty means all.
        public var toolNames: [String]
        /// Disable the command policy and sandbox.
        public var unsafe: Bool
        /// Approve risky commands without asking.
        public var autoApprove: Bool
        /// Transcript being resumed, for the audit record.
        public var resume: String?

        /// Creates a request.
        public init(
            entryPoint: String, instructions: String? = nil, model: ModelSelection? = nil, toolNames: [String] = [],
            unsafe: Bool = false, autoApprove: Bool = false, resume: String? = nil
        ) {
            self.entryPoint = entryPoint
            self.instructions = instructions
            self.model = model
            self.toolNames = toolNames
            self.unsafe = unsafe
            self.autoApprove = autoApprove
            self.resume = resume
        }
    }

    /// Why a session could not be set up.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// `config.json` exists but cannot be used.
        case malformedConfig(path: String, reason: String)
        /// `--tool` names not in the registry.
        case unknownTools([String])

        /// Human-readable explanation.
        public var description: String {
            switch self {
            case .malformedConfig(let path, let reason): "malformed \(path): \(reason)"
            case .unknownTools(let names): "unknown tool(s): \(names.joined(separator: ", "))"
            }
        }
    }

    /// The resolved configuration with overrides applied.
    public let config: Config.Resolved
    /// The session's audit log; `end()` closes it.
    public let audit: AuditLog
    /// Standing approvals shared by every conversation of this session.
    public let store: ApprovalStore
    /// "This session" approvals shared by every conversation of this session.
    public let sessionApprovals: SessionApprovals
    /// How risky commands are approved; `with(approver:)` swaps it for a face that has its own channel.
    public let approver: any Approver
    /// The entry point name, recorded on grants and audit events.
    public let entryPoint: String
    /// Tool names selected for the session; empty means all.
    public let toolNames: [String]
    /// The instructions in force.
    public let instructions: String
    /// The session's own conversation set-up: the tools and gate `respond` and `chat` use.
    public let main: Conversation

    /// The tools the model may use in the session's own conversation.
    public var tools: [any Tool] { main.tools }
    /// The approval gate of the session's own conversation.
    public var gate: ApprovalGate { main.gate }
    /// A note for stderr when the chosen model sends data off the machine, else nil.
    public var egressNote: String? {
        config.model.leavesDevice
            ? "note: model \(config.model) runs on Apple's Private Cloud Compute; prompts and tool output leave this Mac"
            : nil
    }

    /// Reads `config.json` under `home`, mapping every failure to `Failure.malformedConfig`.
    ///
    /// - Throws: `Failure.malformedConfig`.
    public static func loadConfig(home: Home) throws -> Config.Resolved {
        do {
            return try Config.load(from: home.configFile).resolved
        } catch {
            throw Failure.malformedConfig(path: home.configFile.path, reason: "\(error)")
        }
    }

    /// Loads config, applies the request's overrides, opens the audit log, builds the gate and tools,
    /// and records `session.start`.
    ///
    /// - Parameters:
    ///   - request: Flags and arguments from the entry point.
    ///   - home: Where config and logs live; created if the audit log is enabled.
    ///   - approver: How risky commands are approved; ignored when `request.autoApprove`.
    ///   - makeSink: Builds the audit sink; the default appends to `home.auditFile`. Tests inject a memory sink.
    /// - Returns: The ready session; call `end()` when the entry point finishes.
    /// - Throws: `Failure` or file-system errors from creating the home.
    public static func begin(
        _ request: Request, home: Home, approver: any Approver,
        makeSink: (Home, Config.Resolved) throws -> any AuditSink = { home, config in
            try home.ensure()
            return try FileAuditSink(url: home.auditFile, limits: config.auditLimits)
        }
    ) throws -> Session {
        var config = try loadConfig(home: home)
        if let model = request.model { config.model = model }
        if let instructions = request.instructions { config.instructions = instructions }
        if request.unsafe {
            config.runner.policy = .unrestricted
            FileHandle.standardError.write(Data("warning: --unsafe: run_command policy and sandbox are off\n".utf8))
        }
        let sessionID = String(UUID().uuidString.prefix(8)).lowercased()
        let sink: any AuditSink = config.auditEnabled ? try makeSink(home, config) : NullAuditSink()
        let audit = AuditLog(session: sessionID, sink: sink)
        let store = ApprovalStore(url: home.approvalsFile, lifetime: config.approvalLifetime)
        let sessionApprovals = SessionApprovals()
        let approver: any Approver = request.autoApprove ? AutoApprover() : approver
        let main = try Conversation.setUp(
            config: config, audit: audit, store: store, sessionApprovals: sessionApprovals, approver: approver,
            entryPoint: request.entryPoint, toolNames: request.toolNames)
        audit.record(
            .sessionStart,
            details: [
                "entryPoint": .string(request.entryPoint), "instructions": .string(config.instructions),
                "tools": .array(main.tools.map { .string($0.name) }), "model": .string(config.model.description),
                "unsafe": .bool(request.unsafe), "autoApprove": .bool(request.autoApprove),
                "resume": request.resume.map { .string($0) } ?? .null,
            ])
        return Session(
            config: config, audit: audit, store: store, sessionApprovals: sessionApprovals, approver: approver,
            entryPoint: request.entryPoint, toolNames: request.toolNames, instructions: config.instructions, main: main)
    }

    /// The same session with a different approver: the MCP server swaps in elicitation once it has a
    /// transport. `--yes` (an `AutoApprover`) is kept, so the flag means the same in every face.
    ///
    /// - Parameter approver: The approver for the new face.
    /// - Returns: A session sharing this one's config, audit log, store, and session approvals.
    /// - Throws: `Failure.unknownTools`, which cannot happen for a selection that already passed `begin`.
    public func with(approver: any Approver) throws -> Session {
        let approver: any Approver = self.approver is AutoApprover ? self.approver : approver
        let main = try Conversation.setUp(
            config: config, audit: audit, store: store, sessionApprovals: sessionApprovals, approver: approver,
            entryPoint: entryPoint, toolNames: toolNames)
        return Session(
            config: config, audit: audit, store: store, sessionApprovals: sessionApprovals, approver: approver,
            entryPoint: entryPoint, toolNames: toolNames, instructions: instructions, main: main)
    }

    /// Opens the session's own conversation: `respond` and `chat` call this once.
    ///
    /// - Parameter transcript: A saved conversation to resume, or nil to start fresh.
    /// - Returns: The agent over the session's tools, recording to the session's audit log.
    /// - Throws: `ModelSelection.Failure` if the model cannot be used.
    public func openAgent(transcript: Transcript? = nil) throws -> Agent {
        try main.openAgent(
            config: config, instructions: instructions, model: config.model, audit: audit, transcript: transcript)
    }

    /// Sets up a further conversation with its own audit log, gate, and tools, sharing the session's
    /// store and session approvals. Needs no model; `openConversation` adds the agent.
    ///
    /// - Parameters:
    ///   - id: The conversation's id; its audit events carry it as the session.
    ///   - toolNames: Tool selection; nil takes the session's.
    /// - Returns: The conversation and the audit log its tools record to.
    /// - Throws: `Failure.unknownTools`.
    public func conversation(
        id: String, toolNames: [String]? = nil
    ) throws -> (
        conversation: Conversation, audit: AuditLog
    ) {
        let audit = self.audit.log(forSession: id)
        let conversation = try Conversation.setUp(
            config: config, audit: audit, store: store, sessionApprovals: sessionApprovals, approver: approver,
            entryPoint: entryPoint, toolNames: toolNames ?? self.toolNames)
        return (conversation, audit)
    }

    /// Opens a further conversation with optional overrides: the MCP server calls this per `thread_id`.
    ///
    /// - Parameters:
    ///   - id: The conversation's id; its audit events carry it as the session.
    ///   - instructions: Instructions override; nil takes the session's.
    ///   - toolNames: Tool selection; nil takes the session's.
    ///   - model: Model override; nil takes the session's.
    /// - Returns: The conversation, its agent, and the audit log the agent records to.
    /// - Throws: `Failure.unknownTools` or `ModelSelection.Failure`.
    public func openConversation(
        id: String, instructions: String? = nil, toolNames: [String]? = nil, model: ModelSelection? = nil
    ) throws -> (conversation: Conversation, agent: Agent, audit: AuditLog) {
        let (conversation, audit) = try self.conversation(id: id, toolNames: toolNames)
        let agent = try conversation.openAgent(
            config: config, instructions: instructions ?? self.instructions, model: model ?? config.model, audit: audit,
            transcript: nil)
        return (conversation, agent, audit)
    }

    /// Records `session.end`.
    public func end() {
        audit.record(.sessionEnd)
    }
}

/// One conversation's tools and approval gate, built the same way for every face of daimon.
public struct Conversation: Sendable {
    /// The gate every tool in this conversation consults.
    public let gate: ApprovalGate
    /// The tools the model may use.
    public let tools: [any Tool]

    /// Builds the gate and the tool registry for one conversation.
    ///
    /// - Throws: `Session.Failure.unknownTools` for names not in the registry.
    static func setUp(
        config: Config.Resolved, audit: AuditLog, store: ApprovalStore, sessionApprovals: SessionApprovals,
        approver: any Approver, entryPoint: String, toolNames: [String]
    ) throws -> Conversation {
        let gate = ApprovalGate(
            classifier: config.classifier, approver: approver, threshold: config.approvalThreshold, audit: audit,
            store: store, source: entryPoint, sessionApprovals: sessionApprovals)
        let registry = ToolRegistry(runner: config.runner, audit: audit, approval: gate)
        let tools: [any Tool]
        if toolNames.isEmpty {
            tools = registry.all
        } else {
            let selection = registry.select(toolNames)
            guard selection.unknown.isEmpty else { throw Session.Failure.unknownTools(selection.unknown) }
            tools = selection.tools
        }
        return Conversation(gate: gate, tools: tools)
    }

    /// Creates the agent that runs this conversation.
    ///
    /// - Throws: `ModelSelection.Failure` if the model cannot be used.
    func openAgent(
        config: Config.Resolved, instructions: String, model: ModelSelection, audit: AuditLog, transcript: Transcript?
    ) throws -> Agent {
        if let transcript {
            return try Agent(transcript: transcript, tools: tools, model: model, audit: audit)
        }
        return try Agent(instructions: instructions, tools: tools, model: model, audit: audit)
    }
}
