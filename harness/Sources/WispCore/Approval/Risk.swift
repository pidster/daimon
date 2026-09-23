import Foundation
import FoundationModels

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
}

/// Something that judges the risk of running a shell command.
public protocol RiskClassifier: Sendable {
    /// Assesses `command` as it would run in `workingDirectory`. Never throws: a
    /// classifier that cannot decide reports a conservative level with a reason.
    func classify(command: String, workingDirectory: String) async -> RiskAssessment
}

/// Takes the highest verdict across several classifiers.
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
            result = result.merged(
                with: await classifier.classify(command: command, workingDirectory: workingDirectory))
        }
        return result
    }
}

/// Times each classification by another classifier into a session's `CallStats`, as a `classifier`
/// call; an assessment carrying `RiskAssessment.failureKey` is recorded as failed. The verdict passes
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
        stats.record(
            CallStats.Call(
                kind: .classifier, model: name, started: started, seconds: Date().timeIntervalSince(started),
                failure: assessment.metadata[RiskAssessment.failureKey]?.stringValue))
        return assessment
    }
}
