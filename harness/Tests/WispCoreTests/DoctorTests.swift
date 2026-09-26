import Foundation
import Testing

@testable import WispCore

@Suite struct DoctorTests {
    @Test func rendersAndJudgesFindings() {
        let findings = [
            Doctor.Finding(name: "a", ok: true, detail: "fine"), Doctor.Finding(name: "b", ok: false, detail: "broken"),
        ]
        #expect(Doctor.render(findings) == "ok   a: fine\nFAIL b: broken")
        #expect(!Doctor.allPassed(findings))
        #expect(Doctor.allPassed([findings[0]]))
    }

    @Test func checksConfigAndHomeWithoutTheModel() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "wisp-doctor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let healthy = Doctor.Probes(systemModel: { nil }, configuredModel: { _, _, _ in nil })
        let doctor = Doctor(home: Home(root: root), probes: healthy)
        var findings = doctor.run()
        // The default classifier is the shipped Core ML one, so the doctor checks it too.
        #expect(findings.map(\.name) == ["macOS", "model", "classifier", "sandbox", "config", "home"])
        let broken = Doctor.Probes(
            systemModel: { "not enabled" }, configuredModel: { model, _, _ in "\(model) is down" })
        let extra = Doctor(home: Home(root: root), model: .privateCloud, probes: broken).run()
        #expect(
            extra.map(\.name) == ["macOS", "model", "classifier", "configured model", "sandbox", "config", "home"])
        #expect(!extra[1].ok && extra[1].detail == "not enabled")
        #expect(!extra[3].ok && extra[3].detail == "private-cloud is down")
        #expect(findings[4].ok && findings[4].detail.contains("defaults apply"))
        #expect(findings[5].ok)
        try Data("{bad".utf8).write(to: Home(root: root).configFile)
        findings = doctor.run()
        #expect(!findings[4].ok)
        #expect(findings[3].ok)
    }
}
