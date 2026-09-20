import Foundation
import Synchronization

/// One measured result of a task the model performs: how many of the eval's cases passed, on which
/// model, when. Recorded by `scripts/check eval` into `Resources/measurements.json`, embedded at
/// build time, and published with the tool catalogue so a caller knows which delegations are
/// reliable ([ADR 0026](../../../../docs/decisions/0026-task-catalogue.md)). A measurement describes
/// an eval run on one Mac; it is not a certification.
public struct Measurement: Codable, Equatable, Sendable {
    /// The task, such as `triage`, `edit_file.replace`, `respond.schema`, `classifier.system-model`.
    public var task: String
    /// The model's tool the task exercises, when it is one; matches `ToolDescription.name`.
    public var tool: String?
    /// The model the eval ran on, as a `ModelSelection` spelling.
    public var model: String
    /// The day of the run, `YYYY-MM-DD`.
    public var date: String
    /// Cases that passed.
    public var passed: Int
    /// Cases in the eval.
    public var total: Int
    /// What a case is and what counted as a pass, in one sentence.
    public var notes: String

    /// Creates a measurement dated today.
    public init(task: String, tool: String? = nil, model: String, passed: Int, total: Int, notes: String) {
        self.task = task
        self.tool = tool
        self.model = model
        date = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))
        self.passed = passed
        self.total = total
        self.notes = notes
    }

    /// `passed/total` and the rate.
    public var summary: String {
        let rate = total > 0 ? Int((Double(passed) / Double(total) * 100).rounded()) : 0
        return "\(passed)/\(total) (\(rate)%)"
    }
}

/// The embedded measurements and how eval runs record new ones.
public enum Measurements {
    /// Every measurement shipped in this build, from `Resources/measurements.json`.
    public static let embedded: [Measurement] = decode(MeasurementsText.text) ?? []

    /// The environment variable naming the file eval runs record into.
    public static let recordVariable = "DAIMON_EVAL_RECORD"

    /// Decodes a JSON array of measurements.
    public static func decode(_ text: String) -> [Measurement]? {
        try? JSONDecoder().decode([Measurement].self, from: Data(text.utf8))
    }

    /// The measurements as pretty JSON, sorted by task.
    public static func encode(_ measurements: [Measurement]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(measurements.sorted { $0.task < $1.task }) else { return "[]" }
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// `existing` with `new` replacing any measurement of the same task and model.
    public static func merge(_ existing: [Measurement], with new: Measurement) -> [Measurement] {
        existing.filter { $0.task != new.task || $0.model != new.model } + [new]
    }

    /// Prints the measurement and, when `DAIMON_EVAL_RECORD` (or `path`) names a file, merges it into
    /// that file. Eval tests call this so a run leaves its numbers behind.
    ///
    /// - Parameters:
    ///   - measurement: What was measured.
    ///   - path: The record file; defaults to the environment variable, nil records nothing.
    /// - Throws: A file error from writing the record.
    public static func report(
        _ measurement: Measurement, to path: String? = ProcessInfo.processInfo.environment[recordVariable]
    ) throws {
        print("measured: \(measurement.task) on \(measurement.model): \(measurement.summary)")
        guard let path else { return }
        let url = URL(fileURLWithPath: path)
        let existing = (try? String(contentsOf: url, encoding: .utf8)).flatMap(decode) ?? []
        try Data(encode(merge(existing, with: measurement)).utf8).write(to: url)
    }

    /// The measurements for one tool, by name.
    public static func forTool(_ name: String, in measurements: [Measurement] = embedded) -> [Measurement] {
        measurements.filter { $0.tool == name }
    }
}
