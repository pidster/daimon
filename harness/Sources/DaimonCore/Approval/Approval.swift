import Foundation
import Synchronization

/// A simple command awaiting a human decision.
public struct ApprovalRequest: Equatable, Sendable {
    /// The simple command being approved.
    public var command: String
    /// The whole line it is part of, for context; equal to `command` when the line is simple.
    public var line: String
    /// The key an approval is remembered under, such as `head *`.
    public var pattern: String
    /// Where it would run.
    public var workingDirectory: String
    /// Why it needs approval.
    public var assessment: RiskAssessment

    /// Creates a request.
    public init(
        command: String, line: String? = nil, pattern: String? = nil, workingDirectory: String,
        assessment: RiskAssessment
    ) {
        self.command = command
        self.line = line ?? command
        self.pattern = pattern ?? (CommandSplitter.split(command).first?.pattern ?? command)
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
        let context = request.line == request.command ? "" : "\n  part of: \(request.line)"
        let text = """

            approval needed (\(request.assessment.level.rawValue)): \(request.command)\(context)
              in \(request.workingDirectory)
              \(request.assessment.reasons.map { "- \($0)" }.joined(separator: "\n  "))
              remembered as: \(request.pattern)
            run it? [y]es (this turn) / [s]ession / [p]roject (30 days, this directory) / [a]lways (30 days) / [n]o:\u{20}
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

/// Session-scoped approvals shared by every gate in a process, so an answer of "this session" given
/// on one MCP thread covers the others.
public final class SessionApprovals: Sendable {
    private let keys = Mutex<Set<String>>([])

    /// Creates an empty set.
    public init() {}

    /// Whether `key` was approved for the session.
    func contains(_ key: String) -> Bool { keys.withLock { $0.contains(key) } }

    /// Records `key` as approved for the session.
    func insert(_ key: String) { keys.withLock { _ = $0.insert(key) } }
}

/// One refusal within a turn, reported to callers so a refusal is detectable without parsing prose.
public struct Refusal: Equatable, Sendable {
    /// The simple command that was refused.
    public var command: String
    /// Why.
    public var reason: String
}

/// Classifies a command and asks for approval when it is risky enough.
///
/// One gate per conversation. Once-approvals and refusals belong to the turn they happened in, as
/// told by the conversation's `TurnClock`; session approvals are shared through `SessionApprovals`;
/// project and always approvals live in the `ApprovalStore`. Every verdict and decision is audited.
public actor ApprovalGate {
    /// Why a command may not run.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// The approver (or a standing policy) said no; the reason is for the model.
        case refused(String)

        /// Human-readable explanation.
        public var description: String {
            switch self {
            case .refused(let reason): "not approved: \(reason)"
            }
        }
    }

    /// The lowest level that requires approval; `nil` never asks.
    public let threshold: RiskLevel?
    private let classifier: any RiskClassifier
    private let approver: any Approver
    private let audit: AuditLog?
    private let store: ApprovalStore?
    private let source: String
    private let sessionApprovals: SessionApprovals
    private let turns: TurnClock
    /// Per-turn state: once-approvals and refusals, dropped when the clock moves on.
    private var turnState: (turn: Int, approved: Set<String>, refusals: [Refusal]) = (0, [], [])

    /// The state for the current turn, discarding an earlier turn's.
    private func currentTurn() -> Int {
        let turn = turns.current
        if turnState.turn != turn { turnState = (turn, [], []) }
        return turn
    }

    /// Session approvals are keyed on the pattern (`head *`) in the exact directory.
    private static func key(_ pattern: String, _ workingDirectory: String) -> String {
        "\(workingDirectory)\u{0}\(pattern)"
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
    ///   - sessionApprovals: Session-scoped approvals; share one instance across gates of one process.
    ///   - turns: The conversation's clock; defaults to the audit log's, or a clock that never
    ///     advances, under which "this turn" means the life of the gate.
    public init(
        classifier: any RiskClassifier, approver: any Approver, threshold: RiskLevel?, audit: AuditLog? = nil,
        store: ApprovalStore? = nil, source: String = "unknown",
        sessionApprovals: SessionApprovals = SessionApprovals(),
        turns: TurnClock? = nil
    ) {
        self.classifier = classifier
        self.approver = approver
        self.threshold = threshold
        self.audit = audit
        self.store = store
        self.source = source
        self.sessionApprovals = sessionApprovals
        self.turns = turns ?? audit?.turns ?? TurnClock()
    }

    /// Returns and clears the refusals recorded in the current turn since the last call.
    public func takeRefusals() -> [Refusal] {
        _ = currentTurn()
        defer { turnState.refusals.removeAll() }
        return turnState.refusals
    }

    /// Returns normally if reading `path` is acceptable.
    ///
    /// Reads are cheap and frequent, so only the rule classifier runs, over the equivalent
    /// `cat <path>`: credential paths are rated dangerous and ask (or are refused) exactly as the
    /// command would be; ordinary files pass without a model call.
    ///
    /// - Throws: `Failure.refused` with the reason otherwise.
    public func clear(readingFile path: String, workingDirectory: String) async throws {
        try await clear(
            command: "cat \(path)", workingDirectory: workingDirectory, classifier: RuleRiskClassifier.standard)
    }

    /// Returns normally if the command may run.
    ///
    /// - Throws: `Failure.refused` with the reason otherwise.
    public func clear(command: String, workingDirectory: String) async throws {
        try await clear(command: command, workingDirectory: workingDirectory, classifier: classifier)
    }

    private func clear(command line: String, workingDirectory: String, classifier: any RiskClassifier) async throws {
        // Every simple command in the line is checked and approved on its own, so a dangerous part
        // cannot hide behind a safe first command, and approvals are remembered per pattern.
        let parts = CommandSplitter.split(line)
        let segments = parts.isEmpty ? [SimpleCommand(text: line, executable: line)] : parts
        for segment in segments {
            do {
                try await clearSegment(segment, line: line, workingDirectory: workingDirectory, classifier: classifier)
            } catch Failure.refused(let reason) where segments.count > 1 {
                throw Failure.refused("\(segment.text): \(reason)")
            }
        }
    }

    private func clearSegment(
        _ segment: SimpleCommand, line: String, workingDirectory: String, classifier: any RiskClassifier
    ) async throws {
        let started = Date()
        let assessment = await classifier.classify(command: segment.text, workingDirectory: workingDirectory)
        var base: [String: JSONValue] = ["command": .string(segment.text), "pattern": .string(segment.pattern)]
        if line != segment.text { base["line"] = .string(line) }
        audit?.record(
            .classifierVerdict,
            details: base.merging([
                "level": .string(assessment.level.rawValue),
                "reasons": .array(assessment.reasons.map { .string($0) }),
                "sources": .array(assessment.sources.map { .string($0) }),
                "seconds": .double(Date().timeIntervalSince(started)),
            ]) { $1 })
        guard let threshold, assessment.level >= threshold else { return }
        if sessionApprovals.contains(Self.key(segment.pattern, workingDirectory)) {
            audit?.record(.approvalDecided, details: base.merging(["decision": "cached"]) { $1 })
            return
        }
        _ = currentTurn()
        if turnState.approved.contains(Self.key(segment.pattern, workingDirectory)) {
            audit?.record(.approvalDecided, details: base.merging(["decision": "cached-turn"]) { $1 })
            return
        }
        if assessment.level < .dangerous,
            let standing = await store?.find(pattern: segment.pattern, directory: workingDirectory)
        {
            audit?.record(
                .approvalDecided,
                details: base.merging([
                    "decision": .string("cached-\(standing.scope.rawValue)"), "approvalID": .string(standing.id),
                ]) { $1 })
            return
        }
        audit?.record(.approvalRequested, details: base.merging(["level": .string(assessment.level.rawValue)]) { $1 })
        let decision = await approver.decide(
            ApprovalRequest(
                command: segment.text, line: line, pattern: segment.pattern, workingDirectory: workingDirectory,
                assessment: assessment))
        switch decision {
        case .approved(let requested):
            // A dangerous command is never remembered beyond the session, whatever was chosen.
            let scope = (requested.isPersistent && assessment.level == .dangerous) ? .session : requested
            var details = base.merging(["decision": "approved", "scope": .string(scope.rawValue)]) { $1 }
            if scope != requested { details["downgradedFrom"] = .string(requested.rawValue) }
            if scope == .once {
                turnState.approved.insert(Self.key(segment.pattern, workingDirectory))
            } else {
                sessionApprovals.insert(Self.key(segment.pattern, workingDirectory))
            }
            if scope.isPersistent, let store {
                do {
                    let entry = try await store.grant(
                        pattern: segment.pattern, directory: workingDirectory, scope: scope, level: assessment.level,
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
                .approvalDecided, details: base.merging(["decision": "denied", "reason": .string(reason)]) { $1 })
            turnState.refusals.append(Refusal(command: segment.text, reason: reason))
            throw Failure.refused(reason)
        case .unanswered(let waited):
            let reason = "no answer within \(waited); an unanswered approval counts as declined"
            audit?.record(
                .approvalDecided, details: base.merging(["decision": "timed-out", "reason": .string(reason)]) { $1 })
            turnState.refusals.append(Refusal(command: segment.text, reason: reason))
            throw Failure.refused(reason)
        }
    }
}
