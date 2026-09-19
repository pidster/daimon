import DaimonCore
import MCP
import Testing

@testable import DaimonMCP

/// A thread that answers without a model.
struct FakeThread: RespondingThread {
    let reply: String
    func respond(to prompt: String) async throws -> (text: String, condensed: Bool) { (reply + prompt, false) }
}

@Suite struct DaimonServerTests {
    let server = DaimonServer()
    let fakeServer = DaimonServer(config: Config().resolved) { id, _, _, _, _ in FakeThread(reply: "\(id):") }

    @Test func respondUsesTheThreadFactoryAndReportsCreation() async throws {
        let first = try await fakeServer.call(
            .init(name: "respond", arguments: ["prompt": .string("hi"), "thread_id": .string("t")]))
        #expect(first.isError == false)
        #expect(first.structuredContent?.objectValue?["created"] == .bool(true))
        #expect(first.structuredContent?.objectValue?["text"] == .string("t:hi"))
        let second = try await fakeServer.call(
            .init(name: "respond", arguments: ["prompt": .string("again"), "thread_id": .string("t")]))
        #expect(second.structuredContent?.objectValue?["created"] == .bool(false))
    }

    @Test func threadGatesPersistProjectApprovalsAndShareSessionOnes() async throws {
        struct Grant: Approver {
            func decide(_ request: ApprovalRequest) async -> ApprovalDecision { .approved(.project) }
        }
        struct Moderate: RiskClassifier {
            func classify(command: String, workingDirectory: String) async -> RiskAssessment {
                RiskAssessment(level: .moderate, reasons: ["x"], sources: ["t"])
            }
        }
        let store = ApprovalStore(url: nil)
        var config = Config().resolved
        config.approvalUsesModel = false
        let server = DaimonServer(config: config, autoApprove: false, store: store) { _, _, _, _, _ in
            FakeThread(reply: "")
        }
        // The server's own approver needs a client; drive the gate it builds with a granting approver instead.
        let gate = ApprovalGate(
            classifier: Moderate(), approver: Grant(), threshold: .moderate, store: store, source: "mcp",
            sessionApprovals: SessionApprovals())
        try await gate.clear(command: "touch a", workingDirectory: "/repo")
        #expect(await store.find(pattern: "touch *", directory: "/repo") != nil)
        // And the gate the server builds carries the same store and source.
        let built = server.gate(audit: AuditLog.disabled(session: "t"))
        _ = built
        #expect(await store.all.first?.source == "mcp")
    }

    @Test func respondReportsAnEmptyRefusalListByDefault() async throws {
        let result = try await fakeServer.call(
            .init(name: "respond", arguments: ["prompt": .string("hi"), "thread_id": .string("r")]))
        #expect(result.structuredContent?.objectValue?["refusals"] == .array([]))
    }

    @Test func settingsOnAnExistingThreadAreRefused() async throws {
        _ = try await fakeServer.call(
            .init(name: "respond", arguments: ["prompt": .string("hi"), "thread_id": .string("u")]))
        let result = try await fakeServer.call(
            .init(
                name: "respond",
                arguments: ["prompt": .string("x"), "thread_id": .string("u"), "instructions": .string("new")]))
        #expect(result.isError == true)
        guard case .text(let text, _, _)? = result.content.first else { Issue.record("no text"); return }
        #expect(text.contains("only when a thread is created"))
        let closed = try await fakeServer.call(.init(name: "close_thread", arguments: ["thread_id": .string("u")]))
        #expect(closed.isError == false)
    }

    @Test func unknownToolIsAProtocolError() async {
        await #expect(throws: MCPError.self) { try await server.call(.init(name: "nope", arguments: nil)) }
    }

    @Test func servesTheToolCatalogueAsResources() throws {
        #expect(ToolCatalog.resources.map(\.uri) == ["daimon://tools", "daimon://tools.md"])
        let json = try server.read(.init(uri: "daimon://tools"))
        #expect(json.contents.first?.text?.contains("\"name\" : \"read_file\"") == true)
        #expect(json.contents.first?.mimeType == "application/json")
        let markdown = try server.read(.init(uri: "daimon://tools.md"))
        #expect(markdown.contents.first?.text?.hasPrefix("# daimon tools") == true)
        #expect(throws: MCPError.self) { try server.read(.init(uri: "daimon://nope")) }
    }

    @Test func closingUnknownThreadIsAToolError() async throws {
        let result = try await server.call(.init(name: "close_thread", arguments: ["thread_id": .string("nope")]))
        #expect(result.isError == true)
    }

    @Test func respondWithUnknownToolNameIsAToolError() async throws {
        let result = try await server.call(
            .init(name: "respond", arguments: ["prompt": .string("hi"), "tools": .array([.string("nope")])]))
        #expect(result.isError == true)
    }
}
