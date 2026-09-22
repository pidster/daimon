import Foundation
import Testing

@testable import WispCore

@Suite struct MeasurementsTests {
    @Test func decodesMergesEncodesAndAttachesToTools() throws {
        let triage = Measurement(task: "triage", model: "system", passed: 7, total: 7, notes: "found")
        let edit = Measurement(
            task: "edit_file.replace", tool: "edit_file", model: "system", passed: 3, total: 5, notes: "x")
        #expect(triage.summary == "7/7 (100%)" && edit.summary == "3/5 (60%)")
        #expect(Measurement(task: "t", model: "m", passed: 0, total: 0, notes: "").summary == "0/0 (0%)")
        #expect(triage.date.count == 10 && triage.date.hasPrefix("20"))
        let text = Measurements.encode([triage, edit])
        #expect(text.hasPrefix("[\n") && text.hasSuffix("]\n"))
        #expect(text.firstRange(of: "edit_file.replace")!.lowerBound < text.firstRange(of: "\"triage\"")!.lowerBound)
        #expect(Measurements.decode(text) == [edit, triage])
        #expect(Measurements.decode("not json") == nil)
        // Merging replaces the same task on the same model and keeps the rest.
        var newer = triage
        newer.passed = 5
        let merged = Measurements.merge([triage, edit], with: newer)
        #expect(merged == [edit, newer])
        let other = Measurement(task: "triage", model: "ollama:q", passed: 1, total: 7, notes: "")
        #expect(Measurements.merge(merged, with: other).count == 3)
        #expect(Measurements.forTool("edit_file", in: merged) == [edit])
        #expect(Measurements.forTool("read_file", in: merged).isEmpty)
        // The embedded resource decodes; it may be empty in a fresh tree.
        #expect(Measurements.decode(MeasurementsText.text) != nil)
        // Reporting without a record file only prints; with one it merges into it, creating it first.
        #expect(throws: Never.self) { try Measurements.report(triage, to: nil) }
        #expect(throws: Never.self) { try Measurements.report(triage, to: "") }  // an empty variable records nothing
        let record = FileManager.default.temporaryDirectory.appending(path: "wisp-measure-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: record) }
        try? Measurements.report(triage, to: record.path)
        try? Measurements.report(edit, to: record.path)
        try? Measurements.report(newer, to: record.path)
        #expect(Measurements.decode(try String(contentsOf: record, encoding: .utf8)) == [edit, newer])
        #expect(throws: (any Error).self) { try Measurements.report(triage, to: "/nonexistent/dir/x.json") }
        // Descriptions attach measurements by tool and render them.
        let registry = ToolRegistry()
        let described = registry.descriptions(measurements: merged)
        #expect(described.first { $0.name == "edit_file" }?.measurements == [edit])
        #expect(described.first { $0.name == "read_file" }?.measurements.isEmpty == true)
        #expect(registry.descriptions.map(\.name) == registry.all.map(\.name))
    }
}
