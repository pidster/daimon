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

    /// Creates an assessment.
    public init(level: RiskLevel, reasons: [String], sources: [String]) {
        self.level = level
        self.reasons = reasons
        self.sources = sources
    }

    /// The more severe of two assessments, with reasons and sources merged.
    public func merged(with other: RiskAssessment) -> RiskAssessment {
        RiskAssessment(
            level: max(level, other.level), reasons: reasons + other.reasons, sources: sources + other.sources)
    }
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
