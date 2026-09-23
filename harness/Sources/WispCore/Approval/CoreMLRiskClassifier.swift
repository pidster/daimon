import CoreML
import Foundation
import NaturalLanguage
import Synchronization

/// Which classifier judges commands before the approval gate asks a human.
public enum RiskClassifierChoice: String, Codable, Sendable, CaseIterable {
    /// The rule set only: fast and deterministic.
    case rules
    /// The rules plus Apple's on-device model; the default.
    case systemModel = "system-model"
    /// The rules plus a Core ML text classifier from `approval.coremlModel`.
    case coreml

    /// The default.
    public static let `default` = RiskClassifierChoice.systemModel
}

/// A Core ML text classifier over the command line, run beside the rules
/// ([ADR 0020](../../../../docs/decisions/0020-coreml-risk-classifier.md)).
///
/// The model asset must follow contract version 1 (`Contract`): one string input named `text`, one
/// string output named `label` whose values are wisp's risk levels, and creator metadata that says
/// so. Anything else is rejected at load. Every failure, from a missing asset to an unknown label,
/// reports `moderate` with the reason, so a broken classifier asks for approval rather than waving
/// commands through; the rules still run beside it and the higher level wins.
public struct CoreMLRiskClassifier: RiskClassifier {
    /// What a model asset must satisfy, and the preprocessing it can expect.
    public enum Contract {
        /// The contract this build speaks; a model declaring another is rejected.
        public static let version = "1"
        /// Creator metadata key carrying the contract version.
        public static let versionKey = "wisp.classifier.contract"
        /// Creator metadata key listing the labels, comma-separated, in severity order.
        public static let labelsKey = "wisp.classifier.labels"
        /// The labels, which are `RiskLevel`'s raw values in severity order.
        public static let labels = RiskLevel.allCases.map(\.rawValue).joined(separator: ",")
        /// The string input the model takes: the preprocessed command line.
        public static let input = "text"
        /// The string output the model gives: one of `labels`.
        public static let output = "label"

        /// What the model is given: the command line trimmed, with runs of whitespace collapsed to one
        /// space. Case and punctuation are kept, because `rm -rf` and `RM` are not the same command.
        public static func preprocess(_ command: String) -> String {
            command.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }

        /// Checks a loaded model's metadata and feature names against the contract.
        ///
        /// - Throws: `Failure.wrongContract`, `Failure.wrongLabels`, or `Failure.wrongFeatures`.
        public static func validate(metadata: [String: String], inputs: Set<String>, outputs: Set<String>) throws {
            guard metadata[versionKey] == version else { throw Failure.wrongContract(found: metadata[versionKey]) }
            guard metadata[labelsKey] == labels else { throw Failure.wrongLabels(found: metadata[labelsKey]) }
            guard inputs == [input], outputs.contains(output) else {
                throw Failure.wrongFeatures(inputs: inputs.sorted(), outputs: outputs.sorted())
            }
        }
    }

    /// Why the classifier could not use its model. Each is reported as a `moderate` verdict.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// No model path is configured.
        case notConfigured
        /// Nothing at the path.
        case missingAsset(String)
        /// Core ML could not compile or load it.
        case unreadable(String, String)
        /// The model does not declare contract version 1.
        case wrongContract(found: String?)
        /// The model declares labels other than wisp's risk levels.
        case wrongLabels(found: String?)
        /// The model's features are not `text` in and `label` out.
        case wrongFeatures(inputs: [String], outputs: [String])

        /// Human-readable explanation.
        public var description: String {
            switch self {
            case .notConfigured: "approval.classifier is coreml but approval.coremlModel is not set"
            case .missingAsset(let path): "no Core ML model at \(path)"
            case .unreadable(let path, let detail): "cannot load Core ML model at \(path): \(detail)"
            case .wrongContract(let found):
                "Core ML model declares contract \(found ?? "none"), this build needs \(Contract.version) "
                    + "(metadata key \(Contract.versionKey))"
            case .wrongLabels(let found):
                "Core ML model declares labels \(found ?? "none"), expected \(Contract.labels) "
                    + "(metadata key \(Contract.labelsKey))"
            case .wrongFeatures(let inputs, let outputs):
                "Core ML model has inputs \(inputs) and outputs \(outputs); expected input \(Contract.input) and "
                    + "output \(Contract.output)"
            }
        }
    }

    /// A model that passed the contract check: where its compiled form is and what it calls itself.
    public struct Prepared: Sendable, Equatable {
        /// The compiled model directory Core ML loads.
        public var compiledURL: URL
        /// The asset's file name, the classifier's identity in the audit.
        public var name: String
        /// The model's own version string from its metadata, or `unversioned`.
        public var version: String
    }

    /// The `.mlmodel` or `.mlmodelc` path, or nil when none was configured.
    public let url: URL?
    /// Below this top-label probability the verdict is raised to at least `moderate`.
    public let minimumConfidence: Double
    private let prepared = Slot()

    /// Holds the one-time preparation result.
    private final class Slot: Sendable {
        let result = Mutex<Result<Prepared, Failure>?>(nil)
    }

    /// Creates a classifier over the asset at `url`; nothing is loaded until the first verdict.
    public init(url: URL?, minimumConfidence: Double = 0.6) {
        self.url = url
        self.minimumConfidence = minimumConfidence
    }

    /// Compiles the asset if it is a source `.mlmodel`, loads it once, and checks the contract.
    ///
    /// - Returns: The prepared model.
    /// - Throws: `Failure`.
    public static func prepare(_ url: URL?) throws -> Prepared {
        guard let url else { throw Failure.notConfigured }
        let path = (url.path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else { throw Failure.missingAsset(path) }
        let compiledURL: URL
        do {
            if url.pathExtension == "mlmodelc" {
                compiledURL = URL(filePath: path)
            } else {
                compiledURL = try Blocking.run { try await MLModel.compileModel(at: URL(filePath: path)) }
            }
        } catch {
            throw Failure.unreadable(path, "\(error)")
        }
        let model: MLModel
        do {
            model = try MLModel(contentsOf: compiledURL)
        } catch {
            throw Failure.unreadable(path, "\(error)")
        }
        let description = model.modelDescription
        let metadata = description.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
        try Contract.validate(
            metadata: metadata, inputs: Set(description.inputDescriptionsByName.keys),
            outputs: Set(description.outputDescriptionsByName.keys))
        let version = description.metadata[.versionString] as? String
        return Prepared(
            compiledURL: compiledURL, name: url.lastPathComponent,
            version: (version?.isEmpty == false) ? version ?? "unversioned" : "unversioned")
    }

    /// The prepared model, preparing it on first use and remembering the outcome either way.
    private func preparedModel() -> Result<Prepared, Failure> {
        prepared.result.withLock { cached in
            if let cached { return cached }
            let result: Result<Prepared, Failure>
            do {
                result = .success(try Self.prepare(url))
            } catch let failure as Failure {
                result = .failure(failure)
            } catch {
                result = .failure(.unreadable(url?.path ?? "", "\(error)"))
            }
            cached = result
            return result
        }
    }

    /// Classifies with the model; every failure is a `moderate` verdict that says why.
    public func classify(command: String, workingDirectory: String) async -> RiskAssessment {
        let prepared: Prepared
        switch preparedModel() {
        case .success(let value): prepared = value
        case .failure(let failure):
            return RiskAssessment(
                level: .moderate, reasons: ["core ml classifier unavailable: \(failure)"], sources: ["coreml"],
                metadata: [
                    "coreml.fallback": .string(failure.description),
                    RiskAssessment.failureKey: .string(failure.description),
                ])
        }
        var metadata: [String: JSONValue] = [
            "coreml.model": .string(prepared.name), "coreml.version": .string(prepared.version),
        ]
        let hypotheses: [String: Double]
        do {
            let model = try NLModel(mlModel: MLModel(contentsOf: prepared.compiledURL))
            hypotheses = model.predictedLabelHypotheses(for: Contract.preprocess(command), maximumCount: 3)
        } catch {
            metadata["coreml.fallback"] = .string("inference failed: \(error)")
            metadata[RiskAssessment.failureKey] = metadata["coreml.fallback"]
            return RiskAssessment(
                level: .moderate, reasons: ["core ml classifier failed: \(error)"], sources: ["coreml"],
                metadata: metadata)
        }
        guard let top = hypotheses.max(by: { $0.value < $1.value }) else {
            metadata["coreml.fallback"] = .string("no prediction")
            metadata[RiskAssessment.failureKey] = metadata["coreml.fallback"]
            return RiskAssessment(
                level: .moderate, reasons: ["core ml classifier gave no prediction"], sources: ["coreml"],
                metadata: metadata)
        }
        metadata["coreml.label"] = .string(top.key)
        metadata["coreml.confidence"] = .double(top.value)
        guard let level = RiskLevel(rawValue: top.key) else {
            metadata["coreml.fallback"] = .string("unknown label \(top.key)")
            metadata[RiskAssessment.failureKey] = metadata["coreml.fallback"]
            return RiskAssessment(
                level: .moderate, reasons: ["core ml classifier gave an unknown label '\(top.key)'"],
                sources: ["coreml"], metadata: metadata)
        }
        let confidence = String(format: "%.2f", top.value)
        if top.value < minimumConfidence {
            metadata["coreml.fallback"] = .string("confidence \(confidence) below \(minimumConfidence)")
            return RiskAssessment(
                level: max(level, .moderate),
                reasons: ["core ml classifier: \(top.key) at confidence \(confidence), below \(minimumConfidence)"],
                sources: ["coreml"], metadata: metadata)
        }
        return RiskAssessment(
            level: level, reasons: ["core ml classifier: \(top.key) (confidence \(confidence))"], sources: ["coreml"],
            metadata: metadata)
    }
}
