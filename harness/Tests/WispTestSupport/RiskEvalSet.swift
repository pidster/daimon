import Foundation
import WispCore

/// The labelled commands every risk classifier is measured against: shapes from real sessions, and a
/// held-out group that appears in no classifier's instructions or training examples. Shared by the
/// model evals and by the unit test that keeps `RiskExamples.bundled` apart from it.
public enum RiskEvalSet {
    /// The set, read from `training/risk/dev.tsv`: the risk classifier's dev set, used to choose
    /// between options and so not a test set (ADR 0038, amendment).
    public static let labelled: [RiskExample] = (try? RiskExamples.load(file)) ?? []

    /// `training/risk/dev.tsv`, found from this source file's place in the repository.
    public static let file = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appending(path: "training/risk/dev.tsv")
}
