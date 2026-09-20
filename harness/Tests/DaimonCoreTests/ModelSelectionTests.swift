import Foundation
import Testing

@testable import DaimonCore

@Suite struct ModelSelectionTests {
    @Test func parsesKnownSpellings() throws {
        #expect(try ModelSelection(parsing: "system") == .system)
        #expect(try ModelSelection(parsing: "") == .system)
        #expect(try ModelSelection(parsing: " private-cloud ") == .privateCloud)
        #expect(try ModelSelection(parsing: "pcc") == .privateCloud)
    }

    @Test func rejectsUnknownSpellings() throws {
        #expect(throws: ModelSelection.Failure.unknownModel("gpt-5")) { try ModelSelection(parsing: "gpt-5") }
        // Any scheme parses; a backend this build lacks fails when the model is resolved.
        #expect(try ModelSelection(parsing: "adapter:x") == .local(backend: "adapter", name: "x"))
        #expect(throws: ModelSelection.Failure.self) { try ModelSelection(parsing: "adapter:x").resolve() }
        #expect(throws: ModelSelection.Failure.unknownModel("adapter:")) { try ModelSelection(parsing: "adapter:") }
    }

    @Test func describesAndFlagsDeviceEgress() {
        #expect(ModelSelection.system.description == "system")
        #expect(ModelSelection.privateCloud.description == "private-cloud")
        #expect(!ModelSelection.system.leavesDevice)
        #expect(ModelSelection.privateCloud.leavesDevice)
    }

    @Test func configCarriesTheModel() throws {
        #expect(Config().resolved.model == .system)
        #expect(Config(model: .privateCloud).resolved.model == .privateCloud)
        let file = FileManager.default.temporaryDirectory.appending(path: "daimon-model-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(#"{"model":"nope"}"#.utf8).write(to: file)
        #expect(throws: DecodingError.self) { try Config.load(from: file) }
        try Config(model: .privateCloud).save(to: file)
        #expect(try String(contentsOf: file, encoding: .utf8).contains("\"private-cloud\""))
        #expect(try Config.load(from: file).model == .privateCloud)
    }
}
