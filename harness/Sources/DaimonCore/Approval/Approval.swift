import Foundation

/// A command awaiting a human decision.
public struct ApprovalRequest: Equatable, Sendable {
    /// The command line.
    public var command: String
    /// Where it would run.
    public var workingDirectory: String
    /// Why it needs approval.
    public var assessment: RiskAssessment

    /// Creates a request.
    public init(command: String, workingDirectory: String, assessment: RiskAssessment) {
        self.command = command
        self.workingDirectory = workingDirectory
        self.assessment = assessment
    }
}

/// What the approver decided.
public enum ApprovalDecision: Equatable, Sendable {
    /// Run it, and remember the approval for `scope`.
    case approved(ApprovalScope)
    /// Do not run it; the reason is returned to the model.
    case denied(String)
    /// Nobody answered within the wait; treated as a denial, because no answer is not an answer.
    case unanswered(Duration)
}

/// A channel to a human (or a policy standing in for one).
public protocol Approver: Sendable {
    /// Decides. Must not throw: a channel that fails should deny with a reason.
    func decide(_ request: ApprovalRequest) async -> ApprovalDecision
}

/// Approves everything (`--yes`).
public struct AutoApprover: Approver {
    /// Creates the approver.
    public init() {}
    /// Always approves, once.
    public func decide(_ request: ApprovalRequest) async -> ApprovalDecision { .approved(.once) }
}

/// Denies everything with a fixed explanation, for non-interactive entry points.
public struct DenyingApprover: Approver {
    /// The reason given to the model.
    public let reason: String

    /// Creates the approver.
    public init(reason: String) {
        self.reason = reason
    }

    /// Always denies.
    public func decide(_ request: ApprovalRequest) async -> ApprovalDecision { .denied(reason) }
}

/// Asks on the terminal: prints the command and reasons to stderr, reads one line from stdin.
public struct TerminalApprover: Approver {
    /// Creates the approver.
    public init() {}

    /// Prompts and parses the answer; end of input denies.
    public func decide(_ request: ApprovalRequest) async -> ApprovalDecision {
        let text = """

            approval needed (\(request.assessment.level.rawValue)): \(request.command)
              in \(request.workingDirectory)
              \(request.assessment.reasons.map { "- \($0)" }.joined(separator: "\n  "))
            run it? [y]es once / [s]ession / [p]roject (30 days, this directory) / [a]lways (30 days) / [n]o:\u{20}
            """
        FileHandle.standardError.write(Data(text.utf8))
        guard let line = readLine() else { return .denied("no answer (end of input)") }
        return Self.parse(line)
    }

    /// Maps an answer to a decision; anything unrecognised denies.
    public static func parse(_ answer: String) -> ApprovalDecision {
        switch answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "y", "yes", "once": .approved(.once)
        case "s", "session": .approved(.session)
        case "p", "project": .approved(.project)
        case "a", "always": .approved(.always)
        case "n", "no", "": .denied("declined by the user")
        default: .denied("unrecognised answer '\(answer)'")
        }
    }
}

/// Classifies a command and asks for approval when it is risky enough.
///
/// One gate per session holds the approvals granted "for this session", keyed
/// by the exact command line. Every verdict and decision is audited.
public actor ApprovalGate {
    /// The lowest level that requires approval; `nil` never asks.
    public let threshold: RiskLevel?
    private let classifier: any RiskClassifier
    private let approver: any Approver
    private let audit: AuditLog?
    private let store: ApprovalStore?
    private let source: String
    private var sessionApprovals: Set<String> = []

    /// Session approvals are keyed on the exact command line in the exact directory.
    private static func key(_ command: String, _ workingDirectory: String) -> String {
        "\(workingDirectory)\u{0}\(command)"
    }

    /// Creates a gate.
    ///
    /// - Parameters:
    ///   - classifier: Produces the assessment.
    ///   - approver: Decides when the level is at or above `threshold`.
    ///   - threshold: Ask at this level and above; nil disables asking (still audits verdicts).
    ///   - audit: Where verdicts and decisions are recorded.
    ///   - store: Standing approvals that outlive the process; nil keeps only session approvals.
    ///   - source: Entry point name recorded on grants.
    public init(
        classifier: any RiskClassifier, approver: any Approver, threshold: RiskLevel?, audit: AuditLog? = nil,
        store: ApprovalStore? = nil, source: String = "unknown"
    ) {
        self.classifier = classifier
        self.approver = approver
        self.threshold = threshold
        self.audit = audit
        self.store = store
        self.source = source
    }

    /// Returns normally if reading `path` is acceptable.
    ///
    /// Reads are cheap and frequent, so only the rule classifier runs, over the equivalent
    /// `cat <path>`: credential paths are rated dangerous and ask (or are refused) exactly as the
    /// command would be; ordinary files pass without a model call.
    ///
    /// - Throws: `CommandRunner.Failure.disapproved` with the reason otherwise.
    public func clear(readingFile path: String, workingDirectory: String) async throws {
        try await clear(
            command: "cat \(path)", workingDirectory: workingDirectory, classifier: RuleRiskClassifier.standard)
    }

    /// Returns normally if the command may run.
    ///
    /// - Throws: `CommandRunner.Failure.disapproved` with the reason otherwise.
    public func clear(command: String, workingDirectory: String) async throws {
        try await clear(command: command, workingDirectory: workingDirectory, classifier: classifier)
    }

    private func clear(command: String, workingDirectory: String, classifier: any RiskClassifier) async throws {
        let started = Date()
        let assessment = await classifier.classify(command: command, workingDirectory: workingDirectory)
        audit?.record(
            .classifierVerdict,
            details: [
                "command": .string(command), "level": .string(assessment.level.rawValue),
                "reasons": .array(assessment.reasons.map { .string($0) }),
                "sources": .array(assessment.sources.map { .string($0) }),
                "seconds": .double(Date().timeIntervalSince(started)),
            ])
        guard let threshold, assessment.level >= threshold else { return }
        if sessionApprovals.contains(Self.key(command, workingDirectory)) {
            audit?.record(.approvalDecided, details: ["command": .string(command), "decision": "cached"])
            return
        }
        if assessment.level < .dangerous,
            let standing = await store?.find(command: command, directory: workingDirectory)
        {
            audit?.record(
                .approvalDecided,
                details: [
                    "command": .string(command), "decision": .string("cached-\(standing.scope.rawValue)"),
                    "approvalID": .string(standing.id),
                ])
            return
        }
        audit?.record(
            .approvalRequested, details: ["command": .string(command), "level": .string(assessment.level.rawValue)])
        let decision = await approver.decide(
            ApprovalRequest(command: command, workingDirectory: workingDirectory, assessment: assessment))
        switch decision {
        case .approved(let requested):
            // A dangerous command is never remembered beyond the session, whatever was chosen.
            let scope = (requested.isPersistent && assessment.level == .dangerous) ? .session : requested
            var details: [String: JSONValue] = [
                "command": .string(command), "decision": "approved", "scope": .string(scope.rawValue),
            ]
            if scope != requested { details["downgradedFrom"] = .string(requested.rawValue) }
            if scope != .once { sessionApprovals.insert(Self.key(command, workingDirectory)) }
            if scope.isPersistent, let store {
                do {
                    let entry = try await store.grant(
                        command: command, directory: workingDirectory, scope: scope, level: assessment.level,
                        source: source)
                    details["approvalID"] = .string(entry.id)
                    details["expiresAt"] = .string(entry.expiresAt.ISO8601Format())
                } catch {
                    details["persistError"] = .string("\(error)")
                    Diagnostics.policy.error("could not persist approval: \(error)")
                }
            }
            audit?.record(.approvalDecided, details: details)
        case .denied(let reason):
            audit?.record(
                .approvalDecided,
                details: ["command": .string(command), "decision": "denied", "reason": .string(reason)])
            throw CommandRunner.Failure.disapproved(reason)
        case .unanswered(let waited):
            let reason = "no answer within \(waited); an unanswered approval counts as declined"
            audit?.record(
                .approvalDecided,
                details: ["command": .string(command), "decision": "timed-out", "reason": .string(reason)])
            throw CommandRunner.Failure.disapproved(reason)
        }
    }
}
