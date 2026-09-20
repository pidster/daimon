import Foundation
import FoundationModels
import Testing

@testable import DaimonCore

@Suite struct IntrospectionTests {
    private func scratchHome() throws -> Home {
        let root = FileManager.default.temporaryDirectory.appending(path: "daimon-intro-\(UUID().uuidString)")
        let home = Home(root: root)
        try home.ensure()
        return home
    }

    @Test func configurationShowsEffectiveValuesAndPaths() throws {
        let home = try scratchHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let config = Config(
            systemPromptExtension: "be terse", model: .ollama("q"), commandTimeoutSeconds: 5,
            approval: .init(threshold: .never, useModel: false, timeoutSeconds: 0)
        ).resolved
        let views = Introspection(home: home, config: config)
        guard case .object(let top) = views.configuration else { Issue.record("shape"); return }
        #expect(top["version"] == .string(DaimonVersion.current))
        #expect(top["model"] == "ollama:q")
        #expect(top["systemPromptExtension"] == "be terse")
        #expect(top["home"]?.objectValue?["configFileExists"] == false)
        #expect(top["runCommand"]?.objectValue?["timeoutSeconds"] == 5)
        #expect(top["approval"]?.objectValue?["threshold"] == "never")
        #expect(top["approval"]?.objectValue?["useModel"] == false)
        #expect(top["approval"]?.objectValue?["timeoutSeconds"] == 0)
        #expect(top["approval"]?.objectValue?["persistDays"] == 30)
        #expect(top["runCommand"]?.objectValue?["policy"]?.objectValue?["sandbox"]?.objectValue?["enabled"] == true)
        let text = Introspection.render(views.configuration)
        #expect(text.hasPrefix("{\n"))
        #expect(text.contains("\"deny\" : ["))
    }

    @Test func approvalsAndAuditReadTheStores() async throws {
        let home = try scratchHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let store = ApprovalStore(url: home.approvalsFile)
        _ = try await store.grant(
            pattern: "swift *", directory: "/repo", scope: .project, level: .moderate, source: "chat")
        let sink = try FileAuditSink(url: home.auditFile)
        let log = AuditLog(session: "s1", sink: sink)
        log.beginTurn()
        log.record(.prompt, details: ["text": "hi"])
        log.record(.commandOutcome, details: ["command": "ls", "exitStatus": 0])
        log.log(forSession: "s2").record(.sessionEnd)
        let views = Introspection(home: home, config: Config().resolved, store: store)
        guard case .array(let entries) = await views.approvals(), let first = entries.first?.objectValue else {
            Issue.record("approvals shape")
            return
        }
        #expect(first["pattern"] == "swift *")
        #expect(first["workingDirectory"] == "/repo")
        #expect(first["scope"] == "project")
        #expect(first["source"] == "chat")
        #expect(try views.audit(AuditQuery()).map(\.kind) == [.prompt, .commandOutcome, .sessionEnd])
        #expect(try views.audit(AuditQuery(session: "s2")).count == 1)
        #expect(try views.audit(AuditQuery(kinds: [.commandOutcome], last: 1)).first?.details["command"] == "ls")
        #expect(await Introspection(home: home, config: Config().resolved).approvals() == .array([]))
        let empty = Introspection(home: Home(root: home.root.appending(path: "none")), config: Config().resolved)
        #expect(try empty.audit(AuditQuery()).isEmpty)
    }

    @Test func inspectToolRendersEveryViewAndBoundsOutput() async throws {
        let home = try scratchHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let sink = try FileAuditSink(url: home.auditFile)
        let log = AuditLog(session: "s", sink: sink)
        for index in 1...30 {
            log.record(.prompt, details: ["text": .string("prompt \(index) " + String(repeating: "x", count: 300))])
        }
        let views = Introspection(
            home: home, config: Config().resolved, store: ApprovalStore(url: nil),
            status: { ["session": "s", "turn": 3] })
        let tool = InspectTool(introspection: views)
        #expect(
            await tool.call(arguments: .init(what: "Config", last: nil, kind: nil, session: nil)).contains(
                "\"version\""))
        #expect(
            await tool.call(arguments: .init(what: "status", last: nil, kind: nil, session: nil)).contains(
                "\"turn\" : 3"))
        #expect(await tool.call(arguments: .init(what: "approvals", last: nil, kind: nil, session: nil)) == "[\n\n]")
        let audit = await tool.call(arguments: .init(what: "audit", last: 30, kind: "prompt", session: "s"))
        #expect(audit.contains("[truncated:"))
        #expect(audit.utf8.count <= InspectTool.maxBytes + 64)
        let two = await tool.call(arguments: .init(what: "audit", last: 2, kind: nil, session: nil))
        #expect(two.components(separatedBy: "\n").count == 2)
        #expect(two.contains("prompt 30"))
        #expect(
            await tool.call(arguments: .init(what: "audit", last: 5, kind: "nope", session: nil)).hasPrefix(
                "error: unknown kind 'nope'"))
        #expect(
            await tool.call(arguments: .init(what: "audit", last: 5, kind: nil, session: "none"))
                == "no matching audit events")
        #expect(
            await tool.call(arguments: .init(what: "everything", last: nil, kind: nil, session: nil)).hasPrefix(
                "error: unknown view"))
        #expect(ToolOutput.bounded("short", maxBytes: 10) == "short")
        #expect(ToolOutput.bounded("héllo wörld", maxBytes: 3).hasPrefix("hé\n[truncated:"))
        #expect(ToolRegistry().all.map(\.name).contains("inspect"))
    }
}
