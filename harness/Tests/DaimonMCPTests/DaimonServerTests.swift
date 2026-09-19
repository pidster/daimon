import DaimonCore
import Foundation
import MCP
import Testing

@testable import DaimonMCP

/// A thread that answers without a model.
struct FakeThread: RespondingThread {
    let reply: String
    func respond(to prompt: String) async throws -> (text: String, condensed: Bool) { (reply + prompt, false) }
}

/// A session over a scratch home, with a memory audit sink and a denying approver.
func scratchSession(entryPoint: String = "mcp") throws -> Session {
    let root = FileManager.default.temporaryDirectory.appending(path: "daimon-mcp-tests-\(UUID().uuidString)")
    let home = Home(root: root)
    try home.ensure()
    return try Session.begin(.init(entryPoint: entryPoint), home: home, approver: DenyingApprover(reason: "test")) {
        _, _ in
        MemoryAuditSink()
    }
}

@Suite struct DaimonServerTests {
    let server: DaimonServer
    let fakeServer: DaimonServer

    init() throws {
        server = try DaimonServer(session: try scratchSession())
        fakeServer = try DaimonServer(session: try scratchSession()) { session, id, _, _, _ in
            (FakeThread(reply: "\(id):"), nil, session.audit.log(forSession: id))
        }
    }

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

    @Test func threadsShareTheSessionsStoreAndSessionApprovals() async throws {
        struct Grant: Approver {
            func decide(_ request: ApprovalRequest) async -> ApprovalDecision { .approved(.project) }
        }
        let session = try scratchSession().with(approver: Grant())
        // Two threads opened from the same session share one store and one session-approval set.
        let first = try session.conversation(id: "a").conversation
        try await first.gate.clear(command: "touch a", workingDirectory: "/repo")
        #expect(await session.store.find(pattern: "touch *", directory: "/repo")?.source == "mcp")
        let second = try session.with(approver: DenyingApprover(reason: "must not ask")).conversation(id: "b")
        try await second.conversation.gate.clear(command: "touch b", workingDirectory: "/repo")
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
