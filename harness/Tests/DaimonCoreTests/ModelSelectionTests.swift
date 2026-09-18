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

    @Test func rejectsUnknownSpellings() {
        #expect(throws: ModelSelection.Failure.unknownModel("gpt-5")) { try ModelSelection(parsing: "gpt-5") }
        #expect(throws: ModelSelection.Failure.unknownModel("adapter:x")) { try ModelSelection(parsing: "adapter:x") }
    }

    @Test func describesAndFlagsDeviceEgress() {
        #expect(ModelSelection.system.description == "system")
        #expect(ModelSelection.privateCloud.description == "private-cloud")
        #expect(!ModelSelection.system.leavesDevice)
        #expect(ModelSelection.privateCloud.leavesDevice)
    }

    @Test func configCarriesTheModel() throws {
        #expect(Config().resolved.model == .system)
        #expect(Config(model: "private-cloud").resolved.model == .privateCloud)
        let file = FileManager.default.temporaryDirectory.appending(path: "daimon-model-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(#"{"model":"nope"}"#.utf8).write(to: file)
        #expect(throws: ModelSelection.Failure.unknownModel("nope")) { try Config.load(from: file) }
    }
}
