import Foundation
import Testing

@testable import DaimonCore

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
        let root = FileManager.default.temporaryDirectory.appending(path: "daimon-doctor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let doctor = Doctor(home: Home(root: root))
        var findings = doctor.run()
        #expect(findings.map(\.name) == ["macOS", "model", "sandbox", "config", "home"])
        let extra = Doctor(home: Home(root: root), model: .privateCloud).run()
        #expect(extra.map(\.name) == ["macOS", "model", "configured model", "sandbox", "config", "home"])
        #expect(findings[3].ok && findings[3].detail.contains("defaults apply"))
        #expect(findings[4].ok)
        try Data("{bad".utf8).write(to: Home(root: root).configFile)
        findings = doctor.run()
        #expect(!findings[3].ok)
        #expect(findings[2].ok)
    }
}
