import Foundation
import Testing
import WispTestSupport

@testable import WispCore

/// Measures the risk classifiers against `RiskEvalSet`, for accuracy and for speed, since a classifier
/// runs on every command ([ADR 0038](../../../docs/decisions/0038-fast-specialised-classifiers.md)).
///
/// The on-device model needs the model, so the suite runs only with `WISP_MODEL_TESTS=1`
/// (`scripts/check eval`). The hard requirement is no dangerous command rated below moderate; accuracy
/// and latency are reported and recorded, not asserted.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["WISP_MODEL_TESTS"] != nil))
struct ClassifierEvalTests {
    /// Prints a report and records it as `task` on `model`.
    private func record(_ report: RiskMeasurement.Report, task: String, model: String, notes: String) {
        print("\(task):\n" + report.lines.map { "  \($0)" }.joined(separator: "\n"))
        try? Measurements.report(
            Measurement(
                task: task, model: model, passed: report.correct, total: report.total, notes: notes,
                p50Milliseconds: report.p50Milliseconds, p95Milliseconds: report.p95Milliseconds))
    }

    @Test func modelNeverRatesDangerousBelowModerate() async {
        let report = await RiskMeasurement.run(ModelRiskClassifier(), on: RiskEvalSet.labelled)
        record(
            report, task: "classifier.system-model", model: "system",
            notes: "labelled commands rated at exactly their level by the general on-device model; the hard "
                + "requirement, no dangerous command below moderate, held")
        #expect(report.holdsTheHardRequirement, "dangerous rated safe: \(report.dangerousRatedSafe)")
    }

    /// The default, `approval.classifier: system-model`, as the gate runs it: the rules beside the model,
    /// the higher level winning. The fair comparison for a trained classifier beside the rules.
    @Test func compositeCatchesEveryDangerousCommand() async {
        let composite = CompositeRiskClassifier([RuleRiskClassifier.standard, ModelRiskClassifier()])
        let report = await RiskMeasurement.run(composite, on: RiskEvalSet.labelled)
        record(
            report, task: "classifier.system-model+rules", model: "system",
            notes: "the default classifier as the gate runs it, the rules beside the on-device model, the higher "
                + "level winning")
        #expect(report.holdsTheHardRequirement, "dangerous rated safe: \(report.dangerousRatedSafe)")
        #expect(report.misses.allSatisfy { !$0.hasPrefix("dangerous -> ") }, "\(report.misses)")
    }

    /// A classifier trained on this Mac from `RiskExamples.bundled`, alone and beside the rules, as
    /// `approval.classifier: coreml` would run it. It never saw the eval set.
    @Test func trainedClassifierIsFastAndMeasured() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "wisp-risk-\(UUID().uuidString).mlmodel")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try RiskClassifierTraining.train(RiskExamples.bundled, writingTo: url, version: "eval")
        let trained = CoreMLRiskClassifier(url: url)
        record(
            await RiskMeasurement.run(trained, on: RiskEvalSet.labelled), task: "classifier.trained", model: "coreml",
            notes: "a maximum-entropy text classifier trained on device from the bundled examples, alone, on the "
                + "labelled commands it never saw")
        let composite = await RiskMeasurement.run(
            CompositeRiskClassifier([RuleRiskClassifier.standard, trained]), on: RiskEvalSet.labelled)
        record(
            composite, task: "classifier.trained+rules", model: "coreml",
            notes: "the trained classifier beside the rules, the higher level winning, as approval.classifier: "
                + "coreml runs it")
        #expect(composite.holdsTheHardRequirement, "dangerous rated safe: \(composite.dangerousRatedSafe)")
    }

    /// The Core ML classifier named by `WISP_COREML_MODEL`, against the same set and the same hard
    /// requirement. Measures a model; does not certify it.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WISP_COREML_MODEL"] != nil))
    func coreMLClassifierNeverRatesDangerousBelowModerate() async {
        let path = ProcessInfo.processInfo.environment["WISP_COREML_MODEL"] ?? ""
        let report = await RiskMeasurement.run(CoreMLRiskClassifier(url: URL(filePath: path)), on: RiskEvalSet.labelled)
        print("core ml classifier \(path):\n" + report.lines.map { "  \($0)" }.joined(separator: "\n"))
        #expect(report.holdsTheHardRequirement, "dangerous rated safe: \(report.dangerousRatedSafe)")
    }
}
