import Foundation
import FoundationModels

/// Everything an entry point needs before it creates an `Agent`, built the same way for
/// `respond`, `chat`, and `mcp` so their behaviour and audit records cannot drift.
///
/// A session owns what every conversation shares: the resolved config, the audit log, the
/// approval store, the "this session" approvals, and the risk classifier. A face adds its own
/// approver when it opens a conversation, because how a human is asked is the one thing that
/// differs between the terminal and an MCP client.
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

    /// The behaviour a session constructs from its configuration, injectable so tests never
    /// touch the model or the file system.
    public struct Dependencies: Sendable {
        /// Builds the risk classifier the configuration calls for.
        public var makeClassifier: @Sendable (Config.Resolved) -> any RiskClassifier
        /// Builds the audit sink; called only when the audit log is enabled.
        public var makeSink: @Sendable (Home, Config.Resolved) throws -> any AuditSink

        /// Creates dependencies.
        public init(
            makeClassifier: @escaping @Sendable (Config.Resolved) -> any RiskClassifier,
            makeSink: @escaping @Sendable (Home, Config.Resolved) throws -> any AuditSink
        ) {
            self.makeClassifier = makeClassifier
            self.makeSink = makeSink
        }

        /// The real thing: the on-device classifier when `approval.useModel` is set, and the audit
        /// file under the home directory, which is created on demand.
        public static let live = Dependencies(
            makeClassifier: { config in
                guard config.approvalUsesModel else { return RuleRiskClassifier.standard }
                return CompositeRiskClassifier([RuleRiskClassifier.standard, ModelRiskClassifier()])
            },
            makeSink: { home, config in
                try home.ensure()
                return try FileAuditSink(url: home.auditFile, limits: config.auditLimits)
            })

        /// Rules-only classification and the given sink, for tests: no model, no audit file.
        public static func testing(sink: any AuditSink = MemoryAuditSink()) -> Dependencies {
            Dependencies(makeClassifier: { _ in RuleRiskClassifier.standard }, makeSink: { _, _ in sink })
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

    /// What the entry point asked for.
    public let request: Request
    /// The resolved configuration with overrides applied.
    public let config: Config.Resolved
    /// The session's audit log; `end()` closes it.
    public let audit: AuditLog
    /// Standing approvals shared by every conversation of this session.
    public let store: ApprovalStore
    /// "This session" approvals shared by every conversation of this session.
    public let sessionApprovals: SessionApprovals
    /// Warnings for the face to show the user on stderr, such as `--unsafe` or an off-device model.
    public let notes: [String]
    /// Names of the tools the session's conversations get by default; never empty.
    public let toolNames: [String]
    /// The classifier every conversation's gate uses.
    let classifier: any RiskClassifier

    /// The entry point name, recorded on grants and audit events.
    public var entryPoint: String { request.entryPoint }
    /// The instructions in force.
    public var instructions: String { config.instructions }

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

    /// Loads config, applies the request's overrides, opens the audit log and the approval store,
    /// checks the tool selection, and records `session.start`.
    ///
    /// - Parameters:
    ///   - request: Flags and arguments from the entry point.
    ///   - home: Where config, logs, and approvals live.
    ///   - dependencies: What the session builds from its config; tests pass `.testing()`.
    /// - Returns: The ready session; call `end()` when the entry point finishes.
    /// - Throws: `Failure`, or whatever `dependencies.makeSink` throws.
    public static func begin(_ request: Request, home: Home, dependencies: Dependencies = .live) throws -> Session {
        var config = try loadConfig(home: home)
        var notes: [String] = []
        if let model = request.model { config.model = model }
        if let instructions = request.instructions { config.instructions = instructions }
        if request.unsafe {
            config.runner.policy = .unrestricted
            notes.append("warning: --unsafe: run_command policy and sandbox are off")
        }
        if config.model.leavesDevice {
            notes.append(
                "note: model \(config.model) runs on Apple's Private Cloud Compute; prompts and tool output leave this Mac"
            )
        }
        let toolNames = try Self.resolve(toolNames: request.toolNames, runner: config.runner)
        let sessionID = String(UUID().uuidString.prefix(8)).lowercased()
        let sink: any AuditSink = config.auditEnabled ? try dependencies.makeSink(home, config) : NullAuditSink()
        let audit = AuditLog(session: sessionID, sink: sink)
        audit.record(
            .sessionStart,
            details: [
                "entryPoint": .string(request.entryPoint), "instructions": .string(config.instructions),
                "tools": .array(toolNames.map { .string($0) }), "model": .string(config.model.description),
                "unsafe": .bool(request.unsafe), "autoApprove": .bool(request.autoApprove),
                "resume": request.resume.map { .string($0) } ?? .null,
            ])
        return Session(
            request: request, config: config, audit: audit,
            store: ApprovalStore(url: home.approvalsFile, lifetime: config.approvalLifetime),
            sessionApprovals: SessionApprovals(), notes: notes, toolNames: toolNames,
            classifier: dependencies.makeClassifier(config))
    }

    /// The full tool list for an empty selection, or the names as given once each is known.
    ///
    /// - Throws: `Failure.unknownTools`.
    private static func resolve(toolNames: [String], runner: CommandRunner.Options) throws -> [String] {
        let registry = ToolRegistry(runner: runner)
        guard !toolNames.isEmpty else { return registry.all.map(\.name) }
        let unknown = registry.select(toolNames).unknown
        guard unknown.isEmpty else { throw Failure.unknownTools(unknown) }
        return toolNames
    }

    /// Opens the session's own conversation: `respond` and `chat` call this once.
    ///
    /// - Parameters:
    ///   - approver: How the face asks a human; replaced by `AutoApprover` when the request said `--yes`.
    ///   - transcript: A saved conversation to resume, or nil to start fresh.
    /// - Returns: The agent over the session's tools, recording to the session's audit log.
    /// - Throws: `ModelSelection.Failure` if the model cannot be used.
    public func openAgent(approver: any Approver, transcript: Transcript? = nil) throws -> Agent {
        let conversation = try Conversation.setUp(
            session: self, audit: audit, approver: approver, instructions: instructions, toolNames: toolNames,
            model: config.model)
        return try conversation.openAgent(transcript: transcript)
    }

    /// Sets up a further conversation with its own audit session, gate, and tools, sharing the
    /// session's store and session approvals, and records its `session.start`. Needs no model;
    /// `Conversation.openAgent` adds the agent. The MCP server calls this per `thread_id`.
    ///
    /// - Parameters:
    ///   - id: The conversation's id; its audit events carry it as the session.
    ///   - approver: How the face asks a human; replaced by `AutoApprover` when the request said `--yes`.
    ///   - instructions: Instructions override; nil takes the session's.
    ///   - toolNames: Tool selection; nil takes the session's.
    ///   - model: Model override; nil takes the session's.
    /// - Returns: The conversation, ready to open.
    /// - Throws: `Failure.unknownTools`.
    public func conversation(
        id: String, approver: any Approver, instructions: String? = nil, toolNames: [String]? = nil,
        model: ModelSelection? = nil
    ) throws -> Conversation {
        let audit = self.audit.log(forSession: id)
        let conversation = try Conversation.setUp(
            session: self, audit: audit, approver: approver, instructions: instructions ?? self.instructions,
            toolNames: toolNames ?? self.toolNames, model: model ?? config.model)
        audit.record(
            .sessionStart,
            details: [
                "entryPoint": .string("\(entryPoint)-thread"), "parent": .string(self.audit.session),
                "instructions": .string(conversation.instructions),
                "tools": .array(conversation.tools.map { .string($0.name) }),
                "model": .string(conversation.model.description), "unsafe": .bool(request.unsafe),
                "autoApprove": .bool(request.autoApprove), "resume": .null,
            ])
        return conversation
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
    /// The log the conversation's turns and tool calls are recorded to.
    public let audit: AuditLog
    /// The instructions the agent starts with.
    public let instructions: String
    /// The model the agent runs on.
    public let model: ModelSelection

    /// Builds the gate and the tool registry for one conversation of `session`.
    ///
    /// - Throws: `Session.Failure.unknownTools` for names not in the registry.
    static func setUp(
        session: Session, audit: AuditLog, approver: any Approver, instructions: String, toolNames: [String],
        model: ModelSelection
    ) throws -> Conversation {
        let gate = ApprovalGate(
            classifier: session.classifier, approver: session.request.autoApprove ? AutoApprover() : approver,
            threshold: session.config.approvalThreshold, audit: audit, store: session.store,
            source: session.entryPoint, sessionApprovals: session.sessionApprovals)
        let registry = ToolRegistry(runner: session.config.runner, audit: audit, approval: gate)
        let selection = registry.select(toolNames)
        guard selection.unknown.isEmpty else { throw Session.Failure.unknownTools(selection.unknown) }
        return Conversation(gate: gate, tools: selection.tools, audit: audit, instructions: instructions, model: model)
    }

    /// Creates the agent that runs this conversation.
    ///
    /// - Parameter transcript: A saved conversation to resume, or nil to start from the instructions.
    /// - Returns: The agent, recording to this conversation's audit log and advancing its turn clock.
    /// - Throws: `ModelSelection.Failure` if the model cannot be used.
    public func openAgent(transcript: Transcript? = nil) throws -> Agent {
        if let transcript {
            return try Agent(transcript: transcript, tools: tools, model: model, audit: audit)
        }
        return try Agent(instructions: instructions, tools: tools, model: model, audit: audit)
    }
}
