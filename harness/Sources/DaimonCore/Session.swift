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
    /// The approval gate shared by the session's tools.
    public let gate: ApprovalGate
    /// The tools the model may use.
    public let tools: [any Tool]
    /// The instructions in force.
    public let instructions: String
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
        let gate = ApprovalGate(
            classifier: config.classifier, approver: request.autoApprove ? AutoApprover() : approver,
            threshold: config.approvalThreshold, audit: audit, store: store, source: request.entryPoint)
        let registry = ToolRegistry(runner: config.runner, audit: audit, approval: gate)
        let tools: [any Tool]
        if request.toolNames.isEmpty {
            tools = registry.all
        } else {
            let selection = registry.select(request.toolNames)
            guard selection.unknown.isEmpty else { throw Failure.unknownTools(selection.unknown) }
            tools = selection.tools
        }
        audit.record(
            .sessionStart,
            details: [
                "entryPoint": .string(request.entryPoint), "instructions": .string(config.instructions),
                "tools": .array(tools.map { .string($0.name) }), "model": .string(config.model.description),
                "unsafe": .bool(request.unsafe), "autoApprove": .bool(request.autoApprove),
                "resume": request.resume.map { .string($0) } ?? .null,
            ])
        return Session(config: config, audit: audit, gate: gate, tools: tools, instructions: config.instructions)
    }

    /// Records `session.end`.
    public func end() {
        audit.record(.sessionEnd)
    }
}
