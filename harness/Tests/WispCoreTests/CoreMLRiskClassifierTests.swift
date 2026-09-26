import CoreML
import CreateML
import Foundation
import TabularData
import Testing

@testable import WispCore

/// The Core ML classifier over models trained here with Create ML in well under a second, so every
/// path runs in the gate: the contract check, label and confidence mapping, and each failure.
@Suite struct CoreMLRiskClassifierTests {
    /// The twelve commands every model here is trained on.
    static let training: [(String, String)] = [
        ("ls -la", "safe"), ("git status", "safe"), ("cat README.md", "safe"), ("df -h", "safe"),
        ("swift build", "safe"),
        ("touch notes.txt", "moderate"), ("npm install", "moderate"), ("brew install jq", "moderate"),
        ("rm -rf ~/Documents", "dangerous"), ("sudo rm -rf /", "dangerous"),
        ("git push --force origin main", "dangerous"),
        ("chmod -R 777 /", "dangerous"),
    ]

    /// Trains a text classifier and writes it as `.mlmodel` with the given creator metadata.
    static func train(
        labels: [(String, String)] = training,
        metadata: [String: String] = [
            CoreMLRiskClassifier.Contract.versionKey: CoreMLRiskClassifier.Contract.version,
            CoreMLRiskClassifier.Contract.labelsKey: CoreMLRiskClassifier.Contract.labels,
        ], version: String = "test-1"
    ) throws -> URL {
        var frame = DataFrame()
        frame.append(column: Column(name: "text", contents: labels.map(\.0)))
        frame.append(column: Column(name: "label", contents: labels.map(\.1)))
        let classifier = try MLTextClassifier(
            trainingData: frame, textColumn: "text", labelColumn: "label", parameters: .init(validation: .none))
        let url = FileManager.default.temporaryDirectory.appending(path: "wisp-risk-\(UUID().uuidString).mlmodel")
        try classifier.write(
            to: url,
            metadata: MLModelMetadata(
                author: "wisp tests", shortDescription: "risk", version: version, additional: metadata))
        return url
    }

    @Test func preprocessingAndContractAreStrict() {
        #expect(CoreMLRiskClassifier.Contract.preprocess("  git   commit\t-am\n wip ") == "git commit -am wip")
        #expect(CoreMLRiskClassifier.Contract.labels == "safe,moderate,dangerous")
        let good = [
            CoreMLRiskClassifier.Contract.versionKey: "1",
            CoreMLRiskClassifier.Contract.labelsKey: "safe,moderate,dangerous",
        ]
        #expect(throws: Never.self) {
            try CoreMLRiskClassifier.Contract.validate(
                metadata: good, inputs: ["text"], outputs: ["label", "labelProbability"])
        }
        #expect(throws: CoreMLRiskClassifier.Failure.wrongContract(found: nil)) {
            try CoreMLRiskClassifier.Contract.validate(metadata: [:], inputs: ["text"], outputs: ["label"])
        }
        #expect(throws: CoreMLRiskClassifier.Failure.wrongLabels(found: "low,high")) {
            try CoreMLRiskClassifier.Contract.validate(
                metadata: [
                    CoreMLRiskClassifier.Contract.versionKey: "1", CoreMLRiskClassifier.Contract.labelsKey: "low,high",
                ],
                inputs: ["text"], outputs: ["label"])
        }
        #expect(throws: CoreMLRiskClassifier.Failure.wrongFeatures(inputs: ["command"], outputs: ["label"])) {
            try CoreMLRiskClassifier.Contract.validate(metadata: good, inputs: ["command"], outputs: ["label"])
        }
    }

    @Test func classifiesWithIdentityLabelAndConfidenceInTheMetadata() async throws {
        let url = try Self.train()
        defer { try? FileManager.default.removeItem(at: url) }
        let classifier = CoreMLRiskClassifier(url: url, minimumConfidence: 0)
        let prepared = try CoreMLRiskClassifier.prepare(url)
        #expect(prepared.name == url.lastPathComponent && prepared.version == "test-1")
        let verdict = await classifier.classify(command: "sudo rm -rf /", workingDirectory: "/")
        #expect(verdict.level == .dangerous, "\(verdict)")
        #expect(verdict.sources == ["coreml"])
        #expect(verdict.metadata["coreml.model"] == .string(url.lastPathComponent))
        #expect(verdict.metadata["coreml.version"] == "test-1")
        #expect(verdict.metadata["coreml.label"] == "dangerous")
        guard case .double(let confidence)? = verdict.metadata["coreml.confidence"] else {
            Issue.record("no confidence"); return
        }
        #expect(confidence > 0 && confidence <= 1)
        #expect(verdict.metadata["coreml.fallback"] == nil)
        #expect(verdict.reasons.first?.hasPrefix("core ml classifier: dangerous (confidence") == true)
        // A source .mlmodel is compiled once; the compiled form loads directly too.
        let direct = CoreMLRiskClassifier(url: prepared.compiledURL, minimumConfidence: 0)
        #expect(await direct.classify(command: "ls -la", workingDirectory: "/").level == .safe)
    }

    @Test func lowConfidenceRaisesToModerateAndTheRulesStillWin() async throws {
        let url = try Self.train()
        defer { try? FileManager.default.removeItem(at: url) }
        let strict = CoreMLRiskClassifier(url: url, minimumConfidence: 1.01)
        let verdict = await strict.classify(command: "ls -la", workingDirectory: "/")
        #expect(verdict.level == .moderate)
        #expect(verdict.metadata["coreml.fallback"]?.stringValue?.hasPrefix("confidence") == true)
        #expect(verdict.reasons.first?.contains("below 1.01") == true)
        // Composite: a dangerous rule verdict is never lowered by a confident "safe" from the model.
        let composite = CompositeRiskClassifier([
            RuleRiskClassifier.standard, CoreMLRiskClassifier(url: url, minimumConfidence: 0),
        ])
        let merged = await composite.classify(command: "rm -rf /", workingDirectory: "/")
        #expect(merged.level == .dangerous)
        #expect(merged.sources == ["rules", "coreml"])
        #expect(merged.metadata["coreml.label"] != nil)
    }

    @Test func everyFailureIsAModerateVerdictThatSaysWhy() async throws {
        let missing = CoreMLRiskClassifier(url: URL(filePath: "/nonexistent/risk.mlmodel"))
        let verdict = await missing.classify(command: "ls", workingDirectory: "/")
        #expect(verdict.level == .moderate)
        #expect(
            verdict.metadata["coreml.fallback"]?.stringValue?.contains("no Core ML model at /nonexistent/risk.mlmodel")
                == true)
        #expect(verdict.reasons.first?.hasPrefix("core ml classifier unavailable") == true)
        let unconfigured = await CoreMLRiskClassifier(url: nil).classify(command: "ls", workingDirectory: "/")
        #expect(unconfigured.level == .moderate)
        #expect(unconfigured.metadata["coreml.fallback"]?.stringValue?.contains("coremlModel is not set") == true)
        let wrongContract = try Self.train(metadata: [CoreMLRiskClassifier.Contract.versionKey: "0"])
        defer { try? FileManager.default.removeItem(at: wrongContract) }
        let rejected = await CoreMLRiskClassifier(url: wrongContract).classify(command: "ls", workingDirectory: "/")
        #expect(rejected.level == .moderate)
        #expect(rejected.metadata["coreml.fallback"]?.stringValue?.contains("declares contract 0") == true)
        #expect(throws: CoreMLRiskClassifier.Failure.wrongContract(found: "0")) {
            try CoreMLRiskClassifier.prepare(wrongContract)
        }
        // A model that passes the contract but predicts a label outside the levels.
        let odd = try Self.train(
            labels: [
                ("ls", "low"), ("cat x", "low"), ("df", "low"), ("rm -rf /", "high"), ("sudo x", "high"),
                ("chmod 777 /", "high"),
            ])
        defer { try? FileManager.default.removeItem(at: odd) }
        let unknown = await CoreMLRiskClassifier(url: odd, minimumConfidence: 0).classify(
            command: "rm -rf /", workingDirectory: "/")
        #expect(unknown.level == .moderate)
        #expect(unknown.metadata["coreml.fallback"]?.stringValue?.hasPrefix("unknown label") == true)
        let unreadable = FileManager.default.temporaryDirectory.appending(
            path: "wisp-bad-\(UUID().uuidString).mlmodel")
        try Data("nope".utf8).write(to: unreadable)
        defer { try? FileManager.default.removeItem(at: unreadable) }
        #expect(throws: CoreMLRiskClassifier.Failure.self) { try CoreMLRiskClassifier.prepare(unreadable) }
    }

    @Test func configurationSelectsTheClassifierAndTheDoctorChecksIt() throws {
        let home = Home(root: FileManager.default.temporaryDirectory.appending(path: "wisp-cml-\(UUID().uuidString)"))
        try home.ensure()
        defer { try? FileManager.default.removeItem(at: home.root) }
        #expect(Config().resolved.approvalClassifier == .systemModel)
        #expect(Config(approval: .init(useModel: false)).resolved.approvalClassifier == .rules)
        #expect(Config(approval: .init(classifier: .coreml, useModel: false)).resolved.approvalClassifier == .coreml)
        let file = home.configFile
        try Data(
            #"{"approval":{"classifier":"coreml","coremlModel":"risk.mlmodel","coremlMinimumConfidence":0.8}}"#.utf8
        ).write(to: file)
        let config = try Config.load(from: file).resolved
        #expect(config.coremlModel == "risk.mlmodel" && config.coremlMinimumConfidence == 0.8)
        #expect(
            Session.coremlModelURL(config: config, home: home)?.path
                == home.models.appending(path: "coreml/risk.mlmodel").path)
        #expect(
            Session.coremlModelURL(config: Config(approval: .init(coremlModel: "/x/y.mlmodelc")).resolved, home: home)?
                .path == "/x/y.mlmodelc")
        // No model named is the default this build ships, installed into the store (ADR 0038, amendment).
        #expect(
            Session.coremlModelURL(config: Config().resolved, home: home)
                == ClassifierStore(home: home).model(ClassifierStore.defaultVersion()))
        #expect(Session.Dependencies.live.makeClassifier(config, home) is CompositeRiskClassifier)
        #expect(
            Session.Dependencies.live.makeClassifier(Config(approval: .init(useModel: false)).resolved, home)
                is RuleRiskClassifier)
        // The doctor reports a missing model as a failed classifier check, and a prepared one as ok.
        let broken = Doctor(home: home, config: config, probes: .live).run()
        #expect(broken.contains { $0.name == "classifier" && !$0.ok && $0.detail.contains("no Core ML model") })
        let url = try Self.train()
        defer { try? FileManager.default.removeItem(at: url) }
        let good = Config(approval: .init(classifier: .coreml, coremlModel: url.path)).resolved
        let healthy = Doctor(home: home, config: good, probes: .live).run()
        #expect(healthy.contains { $0.name == "classifier" && $0.ok })
        #expect(
            Doctor(home: home, config: Config().resolved, probes: .live).run().contains { $0.name == "classifier" }
                == false)
        let views = Introspection(home: home, config: good)
        #expect(views.configuration.objectValue?["approval"]?.objectValue?["classifier"] == "coreml")
    }
}
