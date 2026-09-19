import Foundation
import Testing

@testable import DaimonCore

@Suite struct ApprovalStoreTests {
    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "daimon-approvals-\(UUID().uuidString)/approvals.json")
    }

    @Test func grantsFindsPersistsAndRevokes() async throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ApprovalStore(url: url)
        let project = try await store.grant(
            command: "swift test", directory: "/a", scope: .project, level: .moderate, source: "chat")
        let always = try await store.grant(
            command: "git push", directory: "/a", scope: .always, level: .moderate, source: "mcp")
        #expect(await store.find(command: "swift test", directory: "/a")?.id == project.id)
        #expect(await store.find(command: "swift test", directory: "/b") == nil)
        #expect(await store.find(command: "git push", directory: "/anywhere")?.id == always.id)
        #expect(await store.find(command: "git push --force", directory: "/a") == nil)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        let reloaded = ApprovalStore(url: url)
        #expect(await reloaded.all.map(\.id).sorted() == [project.id, always.id].sorted())
        #expect(try await reloaded.revoke(id: project.id))
        #expect(!(try await reloaded.revoke(id: project.id)))
        #expect(await ApprovalStore(url: url).all.map(\.id) == [always.id])
        try await reloaded.clear()
        #expect(await ApprovalStore(url: url).all.isEmpty)
    }

    @Test func expiredEntriesAreIgnoredAndDroppedOnLoad() async throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let short = ApprovalStore(url: url, lifetime: .seconds(0))
        _ = try await short.grant(command: "ls", directory: "/", scope: .always, level: .moderate, source: "t")
        #expect(await short.find(command: "ls", directory: "/") == nil)
        #expect(await ApprovalStore(url: url).all.isEmpty)
    }

    @Test func unreadableFileMeansEmpty() async throws {
        let url = temporaryFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Data("{not json".utf8).write(to: url)
        #expect(await ApprovalStore(url: url).all.isEmpty)
    }

    @Test func configResolvesLifetime() {
        #expect(Config().resolved.approvalLifetime == .seconds(30 * 24 * 3600))
        #expect(Config(approval: .init(persistDays: 1)).resolved.approvalLifetime == .seconds(24 * 3600))
    }
}

@Suite struct PersistedApprovalGateTests {
    struct Fixed: RiskClassifier {
        let level: RiskLevel
        func classify(command: String, workingDirectory: String) async -> RiskAssessment {
            RiskAssessment(level: level, reasons: ["because"], sources: ["fixed"])
        }
    }

    final class Answering: Approver {
        let decision: ApprovalDecision
        let asked = MemoryAuditSink()
        init(_ decision: ApprovalDecision) { self.decision = decision }
        func decide(_ request: ApprovalRequest) async -> ApprovalDecision {
            asked.write(AuditEvent(session: "x", kind: .approvalRequested))
            return decision
        }
    }

    @Test func projectApprovalPersistsAcrossGatesAndIsAudited() async throws {
        let store = ApprovalStore(url: nil)
        let sink = MemoryAuditSink()
        let approver = Answering(.approved(.project))
        let first = ApprovalGate(
            classifier: Fixed(level: .moderate), approver: approver, threshold: .moderate,
            audit: AuditLog(session: "s", sink: sink), store: store, source: "test")
        try await first.clear(command: "swift test", workingDirectory: "/repo")
        #expect(sink.events.last?.details["decision"] == "approved")
        #expect(sink.events.last?.details["scope"] == "project")
        #expect(sink.events.last?.details["approvalID"] != nil)
        // A new gate (new process) with the same store does not ask.
        let second = ApprovalGate(
            classifier: Fixed(level: .moderate), approver: Answering(.denied("should not ask")), threshold: .moderate,
            audit: AuditLog(session: "s2", sink: sink), store: store, source: "test")
        try await second.clear(command: "swift test", workingDirectory: "/repo")
        #expect(sink.events.last?.details["decision"] == "cached-project")
        // A different directory asks again.
        await #expect(throws: CommandRunner.Failure.self) {
            try await second.clear(command: "swift test", workingDirectory: "/other")
        }
        #expect(approver.asked.events.count == 1)
    }

    @Test func dangerousCommandsAreNeverPersisted() async throws {
        let store = ApprovalStore(url: nil)
        let sink = MemoryAuditSink()
        let gate = ApprovalGate(
            classifier: Fixed(level: .dangerous), approver: Answering(.approved(.always)), threshold: .moderate,
            audit: AuditLog(session: "s", sink: sink), store: store, source: "test")
        try await gate.clear(command: "rm -rf build", workingDirectory: "/repo")
        #expect(sink.events.last?.details["scope"] == "session")
        #expect(sink.events.last?.details["downgradedFrom"] == "always")
        #expect(await store.all.isEmpty)
        // Cached for the session, though.
        try await gate.clear(command: "rm -rf build", workingDirectory: "/repo")
        #expect(sink.events.last?.details["decision"] == "cached")
    }

    @Test func onceIsNotRemembered() async throws {
        let approver = Answering(.approved(.once))
        let gate = ApprovalGate(
            classifier: Fixed(level: .moderate), approver: approver, threshold: .moderate,
            store: ApprovalStore(url: nil))
        try await gate.clear(command: "touch x", workingDirectory: "/")
        try await gate.clear(command: "touch x", workingDirectory: "/")
        #expect(approver.asked.events.count == 2)
    }
}
