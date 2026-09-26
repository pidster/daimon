import Foundation
import FoundationModels
import Synchronization

/// How risky an action is, from a human's point of view.
@Generable
public enum RiskLevel: String, Sendable, CaseIterable, Codable {
    /// Read-only, or reversible within the working directory.
    case safe
    /// Modifies files or state but is recoverable, or reaches the network.
    case moderate
    /// Destructive, irreversible, privilege-escalating, or exfiltrates data.
    case dangerous
}

extension RiskLevel: Comparable {
    /// Orders by severity.
    public static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool {
        lhs.rank < rhs.rank
    }

    private var rank: Int {
        switch self {
        case .safe: 0
        case .moderate: 1
        case .dangerous: 2
        }
    }
}

/// A classifier's opinion of an action.
public struct RiskAssessment: Equatable, Sendable {
    /// The level; when classifiers disagree, the highest wins.
    public var level: RiskLevel
    /// Why, one short sentence per signal, shown to whoever approves.
    public var reasons: [String]
    /// Which classifier(s) produced it, for the audit log.
    public var sources: [String]
    /// Classifier-specific facts for the audit, such as a model's identity, version, label, and
    /// confidence; keys are prefixed with the source (`coreml.label`).
    public var metadata: [String: JSONValue]

    /// Creates an assessment.
    public init(level: RiskLevel, reasons: [String], sources: [String], metadata: [String: JSONValue] = [:]) {
        self.level = level
        self.reasons = reasons
        self.sources = sources
        self.metadata = metadata
    }

    /// The more severe of two assessments, with reasons, sources, and metadata merged.
    public func merged(with other: RiskAssessment) -> RiskAssessment {
        RiskAssessment(
            level: max(level, other.level), reasons: reasons + other.reasons, sources: sources + other.sources,
            metadata: metadata.merging(other.metadata) { $1 })
    }
}

extension RiskAssessment {
    /// The metadata key a model classifier sets, with the reason, when its verdict is a fallback because
    /// it could not judge (unavailable, failed, no usable answer). A low-confidence verdict is a judgement
    /// and does not set it. `TimedRiskClassifier` counts these as failures in `/stats`.
    public static let failureKey = "classifier.failure"

    /// The metadata key the rules set on a command on their read-only list. A composite stops there:
    /// the verdict is safe and final, and no model is asked.
    public static let knownSafeKey = "rules.knownSafe"

    /// Whether this verdict is final: a command the rules know to be read-only.
    public var isKnownSafe: Bool { level == .safe && metadata[Self.knownSafeKey] == true }
}

/// Something that judges the risk of running a shell command.
public protocol RiskClassifier: Sendable {
    /// Assesses `command` as it would run in `workingDirectory`. Never throws: a
    /// classifier that cannot decide reports a conservative level with a reason.
    func classify(command: String, workingDirectory: String) async -> RiskAssessment
}

/// Takes the highest verdict across several classifiers, in order, stopping at a verdict that is known
/// safe (`RiskAssessment.isKnownSafe`), so the rules, listed first, spare the model the commands they
/// know to be read-only.
public struct CompositeRiskClassifier: RiskClassifier {
    private let classifiers: [any RiskClassifier]

    /// Creates a composite; an empty list assesses everything as safe.
    public init(_ classifiers: [any RiskClassifier]) {
        self.classifiers = classifiers
    }

    /// Runs every classifier and merges.
    public func classify(command: String, workingDirectory: String) async -> RiskAssessment {
        var result = RiskAssessment(level: .safe, reasons: [], sources: [])
        for classifier in classifiers {
            let verdict = await classifier.classify(command: command, workingDirectory: workingDirectory)
            result = result.merged(with: verdict)
            if verdict.isKnownSafe { break }
        }
        return result
    }
}

/// Times each classification by another classifier into a session's `CallStats`, as a `classifier`
/// call; an assessment carrying `RiskAssessment.failureKey` is recorded as failed, and a known-safe one,
/// which no model judged, is not recorded. The verdict passes
/// through unchanged.
public struct TimedRiskClassifier: RiskClassifier {
    private let classifier: any RiskClassifier
    private let name: String
    private let stats: CallStats

    /// Creates the wrapper.
    ///
    /// - Parameters:
    ///   - classifier: The classifier to time.
    ///   - name: What `/stats` calls it: the `approval.classifier` value.
    ///   - stats: Where calls are recorded.
    public init(_ classifier: any RiskClassifier, name: String, stats: CallStats) {
        self.classifier = classifier
        self.name = name
        self.stats = stats
    }

    /// Classifies with the wrapped classifier and records how long it took.
    public func classify(command: String, workingDirectory: String) async -> RiskAssessment {
        let started = Date()
        let assessment = await classifier.classify(command: command, workingDirectory: workingDirectory)
        // A command the rules know to be read-only never reached a model, so it is not a model call.
        guard !assessment.isKnownSafe else { return assessment }
        stats.record(
            CallStats.Call(
                kind: .classifier, model: name, started: started, seconds: Date().timeIntervalSince(started),
                failure: assessment.metadata[RiskAssessment.failureKey]?.stringValue))
        return assessment
    }
}

/// Remembers a session's verdicts per command line and working directory, so a line the model has
/// judged is not judged again: the model classifier costs about 1.4 s a call and its verdicts are
/// repeatable (greedy sampling; the rules are fixed). Only the classification is reused; the gate still
/// decides and asks by the level as before. A fallback verdict (`RiskAssessment.failureKey`) is never
/// kept, so a transient failure is retried. Bounded: the oldest entry goes first once `capacity` is
/// reached. A reused verdict carries `classifier.cached` in its metadata.
public final class CachingRiskClassifier: RiskClassifier {
    /// The metadata key a reused verdict carries.
    public static let cachedKey = "classifier.cached"

    private struct State {
        var verdicts: [String: RiskAssessment] = [:]
        var order: [String] = []
    }

    private let classifier: any RiskClassifier
    private let capacity: Int
    private let state = Mutex(State())

    /// Creates the cache.
    ///
    /// - Parameters:
    ///   - classifier: The classifier whose verdicts are kept.
    ///   - capacity: Verdicts kept; at least one.
    public init(_ classifier: any RiskClassifier, capacity: Int = 256) {
        self.classifier = classifier
        self.capacity = max(1, capacity)
    }

    /// The kept verdict for this line and directory, or a fresh one, kept unless it is a fallback.
    public func classify(command: String, workingDirectory: String) async -> RiskAssessment {
        let key = command + "\u{0}" + workingDirectory
        if var kept = state.withLock({ $0.verdicts[key] }) {
            kept.metadata[Self.cachedKey] = true
            return kept
        }
        let assessment = await classifier.classify(command: command, workingDirectory: workingDirectory)
        guard assessment.metadata[RiskAssessment.failureKey] == nil else { return assessment }
        let capacity = capacity
        state.withLock { state in
            if state.verdicts[key] == nil { state.order.append(key) }
            state.verdicts[key] = assessment
            while state.order.count > capacity { state.verdicts[state.order.removeFirst()] = nil }
        }
        return assessment
    }

    /// Verdicts kept now.
    var count: Int { state.withLock { $0.verdicts.count } }
}
