import CoreML
import CreateML
import Foundation
import TabularData

// Trains an MLTextClassifier from a `text,label` CSV and writes it with daimon's contract metadata.
// Invoked by scripts/train-risk-classifier; see that file for usage.
let arguments = CommandLine.arguments.dropFirst()
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: train-risk-classifier.swift <labels.csv> <out.mlmodel> [version]\n".utf8))
    exit(64)
}
let input = URL(filePath: (arguments[arguments.startIndex] as NSString).expandingTildeInPath)
let output = URL(filePath: (arguments[arguments.startIndex + 1] as NSString).expandingTildeInPath)
let version = arguments.count >= 3 ? arguments[arguments.startIndex + 2] : "1"
let labels = ["safe", "moderate", "dangerous"]

let frame = try DataFrame(contentsOfCSVFile: input, columns: ["text", "label"])
let seen = Set(frame["label", String.self].compactMap { $0 })
guard seen.isSubset(of: labels) else {
    FileHandle.standardError.write(Data("labels must be among \(labels): found \(seen.sorted())\n".utf8))
    exit(65)
}
let classifier = try MLTextClassifier(
    trainingData: frame, textColumn: "text", labelColumn: "label", parameters: .init(validation: .none))
let metadata = MLModelMetadata(
    author: "daimon", shortDescription: "daimon command risk classifier, contract 1", version: version,
    additional: ["daimon.classifier.contract": "1", "daimon.classifier.labels": labels.joined(separator: ",")])
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
try classifier.write(to: output, metadata: metadata)
let rows = frame.rows.count
let trainingError = classifier.trainingMetrics.classificationError
print("trained on \(rows) rows; training error \(String(format: "%.3f", trainingError)); wrote \(output.path) (version \(version))")
print("evaluate before relying on it: DAIMON_MODEL_TESTS=1 DAIMON_COREML_MODEL=\(output.path) scripts/check eval")
