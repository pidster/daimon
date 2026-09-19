import Foundation
import Testing

@testable import DaimonCore

@Suite struct SessionTests {
    private func temporaryHome(config: String? = nil) throws -> Home {
        let root = FileManager.default.temporaryDirectory.appending(path: "daimon-session-\(UUID().uuidString)")
        let home = Home(root: root)
        try home.ensure()
        if let config { try Data(config.utf8).write(to: home.configFile) }
        return home
    }

    private func begin(_ request: Session.Request, home: Home) throws -> (Session, MemoryAuditSink) {
        let sink = MemoryAuditSink()
        let session = try Session.begin(request, home: home, approver: DenyingApprover(reason: "test")) { _, _ in sink }
        return (session, sink)
    }

    @Test func appliesOverridesAndRecordsSessionStart() throws {
        let home = try temporaryHome(config: #"{"instructions":"from file","model":"system"}"#)
        defer { try? FileManager.default.removeItem(at: home.root) }
        let (session, sink) = try begin(
            .init(
                entryPoint: "respond", instructions: "override", model: .privateCloud, toolNames: ["current_date"],
                unsafe: true, autoApprove: true, resume: "chat1"), home: home)
        #expect(session.instructions == "override")
        #expect(session.config.model == .privateCloud)
        #expect(session.config.runner.policy == .unrestricted)
        #expect(session.tools.map(\.name) == ["current_date"])
        #expect(session.egressNote?.contains("leave this Mac") == true)
        let start = sink.events.first
        #expect(start?.kind == .sessionStart)
        #expect(start?.details["entryPoint"] == "respond")
        #expect(start?.details["instructions"] == "override")
        #expect(start?.details["model"] == "private-cloud")
        #expect(start?.details["unsafe"] == true)
        #expect(start?.details["autoApprove"] == true)
        #expect(start?.details["resume"] == "chat1")
        session.end()
        #expect(sink.events.last?.kind == .sessionEnd)
    }

    @Test func defaultsComeFromConfigAndAllToolsAreEnabled() throws {
        let home = try temporaryHome(config: #"{"instructions":"from file"}"#)
        defer { try? FileManager.default.removeItem(at: home.root) }
        let (session, _) = try begin(.init(entryPoint: "chat"), home: home)
        #expect(session.instructions == "from file")
        #expect(session.config.model == .system)
        #expect(session.config.runner.policy == .default)
        #expect(session.tools.map(\.name) == ToolRegistry().all.map(\.name))
        #expect(session.egressNote == nil)
    }

    @Test func rejectsUnknownToolsAndMalformedConfig() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        #expect(throws: Session.Failure.unknownTools(["nope"])) {
            try begin(.init(entryPoint: "respond", toolNames: ["current_date", "nope"]), home: home)
        }
        try Data("{bad".utf8).write(to: home.configFile)
        #expect(throws: Session.Failure.self) { try Session.loadConfig(home: home) }
    }

    @Test func disabledAuditRecordsNothing() throws {
        let home = try temporaryHome(config: #"{"audit":{"enabled":false}}"#)
        defer { try? FileManager.default.removeItem(at: home.root) }
        var sinkBuilt = false
        let session = try Session.begin(
            .init(entryPoint: "respond"), home: home, approver: DenyingApprover(reason: "x")
        ) { _, _ in
            sinkBuilt = true
            return MemoryAuditSink()
        }
        #expect(!sinkBuilt)
        #expect(session.audit.currentTurn == 0)
    }
}
