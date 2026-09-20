import DaimonCore
import DaimonTestSupport
import Foundation
import MCP
import Testing

@testable import DaimonMCP

/// Drives `DaimonServer` over the real protocol: a `Client` on an in-memory transport, so every
/// request and result passes through the SDK's JSON encoding and decoding exactly as it does on
/// stdio. The thread behind `respond` runs a `ScriptedModel` through the framework's tool loop, so the
/// server's tools, gate, audit, and result shapes are exercised end to end with no on-device model.
/// Calls a tool and returns the whole result, structured content included, through the wire.
func call(_ client: Client, _ name: String, _ arguments: [String: Value]? = nil) async throws -> CallTool.Result {
    let context = try await client.send(CallTool.request(.init(name: name, arguments: arguments)))
    return try await context.value
}

@Suite struct DaimonServerWireTests {
    /// A connected client and server. `steps` scripts what the model does on each thread.
    private func connected(
        steps: [ScriptedModel.Step] = [
            .call(name: "current_date", arguments: #"{"timeZone":"Asia/Tokyo"}"#), .say("The date is {tool}"),
        ],
        approver: any Approver = DenyingApprover(reason: "not in tests"), elicitation: Bool = false
    ) async throws -> (client: Client, server: DaimonServer, sink: MemoryAuditSink) {
        let sink = MemoryAuditSink()
        let session = try scratchSession(dependencies: .testing(sink: sink))
        let server = DaimonServer(session: session) { session, _, id, instructions, tools, model in
            let conversation = try session.conversation(
                id: id, approver: approver, instructions: instructions, tools: tools, model: model)
            let agent = Agent(
                instructions: conversation.prompting.rendered, tools: conversation.tools,
                model: ResolvedModel(selection: .system, custom: ScriptedModel(steps: steps)), audit: conversation.audit
            )
            return OpenThread(
                thread: ConversationThread(id: id, agent: agent), gate: conversation.gate, audit: conversation.audit,
                receipts: conversation.receipts)
        }
        let transports = await InMemoryTransport.createConnectedPair()
        try await server.serve(transport: transports.server)
        let client = Client(
            name: "wire-test", version: "0",
            capabilities: elicitation ? .init(elicitation: .init(form: .init())) : .init())
        _ = try await client.connect(transport: transports.client)
        return (client, server, sink)
    }

    @Test func listsToolsAndResourcesOverTheProtocol() async throws {
        let pair = try await connected()
        let tools = try await pair.client.listTools().tools
        #expect(tools.map(\.name) == ["respond", "close_thread"])
        #expect(tools.first?.inputSchema.objectValue?["required"] == .array([.string("prompt")]))
        let resources = try await pair.client.listResources().resources
        #expect(
            resources.map(\.uri) == [
                "daimon://tools", "daimon://tools.md", "daimon://config", "daimon://status", "daimon://approvals",
                "daimon://audit",
            ])
        let json = try await pair.client.readResource(uri: "daimon://tools")
        #expect(json.first?.mimeType == "application/json")
        #expect(json.first?.text?.contains("run_command") == true)
        let markdown = try await pair.client.readResource(uri: "daimon://tools.md")
        #expect(markdown.first?.text?.hasPrefix("# daimon tools") == true)
        await #expect(throws: MCPError.self) { _ = try await pair.client.readResource(uri: "daimon://nope") }
        await pair.client.disconnect()
        await pair.server.stop()
    }

    @Test func introspectionResourcesAndTemplateOverTheProtocol() async throws {
        let pair = try await connected(steps: [.say("one")])
        _ = try await call(pair.client, "respond", ["prompt": .string("a"), "thread_id": .string("intro")])
        let config = try await pair.client.readResource(uri: "daimon://config").first?.text ?? ""
        #expect(config.contains("\"version\" : \"\(DaimonVersion.current)\""))
        #expect(config.contains("\"threshold\" : \"moderate\""))
        let status = try await pair.client.readResource(uri: "daimon://status").first?.text ?? ""
        #expect(status.contains("\"threads\" : [\n    \"intro\"\n  ]"), "\(status)")
        #expect(status.contains("\"entryPoint\" : \"mcp\""))
        #expect(try await pair.client.readResource(uri: "daimon://approvals").first?.text == "[\n\n]")
        let templates = try await pair.client.send(ListResourceTemplates.request(.init())).value.templates
        #expect(templates.map(\.uriTemplate) == ["daimon://audit/{session}"])
        // The audit resources read the file, and the test session writes to a memory sink, so they are
        // empty here; the shape and the id check are what the wire test pins.
        let thread = try await pair.client.readResource(uri: "daimon://audit/intro")
        #expect(thread.first?.mimeType == "application/x-ndjson")
        await #expect(throws: MCPError.self) { _ = try await pair.client.readResource(uri: "daimon://audit/bad id") }
        await pair.client.disconnect()
        await pair.server.stop()
    }

    @Test func theModelCanInspectItsOwnStatus() async throws {
        let pair = try await connected(steps: [
            .call(name: "inspect", arguments: #"{"what":"status"}"#), .say("Status: {tool}"),
        ])
        let result = try await call(
            pair.client, "respond", ["prompt": .string("where are you?"), "thread_id": .string("self")])
        guard case .text(let text, _, _)? = result.content.first else { Issue.record("no text"); return }
        #expect(text.contains("\"session\" : \"self\""), "\(text)")
        #expect(text.contains("\"entryPoint\" : \"mcp-thread\"") == false)  // threads record the session's face
        #expect(text.contains("\"turn\" : 1"))
        #expect(text.contains("\"inspect\""))
        await pair.client.disconnect()
        await pair.server.stop()
    }

    @Test func respondRunsTheToolLoopAndReturnsStructuredContent() async throws {
        let pair = try await connected()
        let result = try await call(pair.client, "respond", ["prompt": .string("date?"), "thread_id": .string("t1")])
        #expect(result.isError == false)
        guard case .text(let text, _, _)? = result.content.first else { Issue.record("no text content"); return }
        #expect(text.hasPrefix("The date is 20"))
        #expect(text.hasSuffix("(Asia/Tokyo)"))
        let structured = result.structuredContent?.objectValue
        #expect(structured?["thread_id"] == .string("t1"))
        #expect(structured?["created"] == .bool(true))
        #expect(structured?["condensed"] == .bool(false))
        #expect(structured?["text"] == .string(text))
        #expect(structured?["refusals"] == .array([]))
        // The receipt folds the turn's audit events for the caller.
        let receipt = structured?["receipt"]?.objectValue
        #expect(receipt?["turn"] == .int(1))
        let tool = receipt?["tools"]?.arrayValue?.first?.objectValue
        #expect(tool?["name"] == .string("current_date"))
        #expect(tool?["arguments"]?.stringValue?.contains("Asia/Tokyo") == true)  // the framework re-serialises
        #expect((tool?["bytes"]?.intValue ?? 0) > 0)
        #expect(receipt?["commands"] == .array([]) && receipt?["errors"] == .array([]))
        #expect(receipt?["condensed"] == .bool(false))
        // The thread's audit session saw the whole loop.
        let thread = pair.sink.events.filter { $0.session == "t1" }.map(\.kind)
        #expect(thread == [.sessionStart, .prompt, .toolCall, .toolResult, .response])
        let server = pair.sink.events.filter { $0.kind == .mcpRequest || $0.kind == .mcpResult }
        #expect(server.count == 2)
        #expect(server.first?.details["arguments"]?.stringValue?.contains("\"prompt\"") == true)
        await pair.client.disconnect()
        await pair.server.stop()
    }

    @Test func refusedCommandsAreReportedInTheResult() async throws {
        // The model asks to touch a file; the gate (rules only, moderate) asks the denying approver.
        let pair = try await connected(steps: [
            .call(name: "run_command", arguments: #"{"command":"touch spike.txt"}"#), .say("It said: {tool}"),
        ])
        let result = try await call(pair.client, "respond", ["prompt": .string("go"), "thread_id": .string("t2")])
        #expect(result.isError == false)
        guard case .text(let text, _, _)? = result.content.first else { Issue.record("no text"); return }
        #expect(text.contains("not approved"))
        let refusals = result.structuredContent?.objectValue?["refusals"]?.arrayValue
        #expect(refusals?.count == 1)
        #expect(refusals?.first?.objectValue?["command"] == .string("touch spike.txt"))
        #expect(refusals?.first?.objectValue?["reason"] == .string("not in tests"))
        let receipt = result.structuredContent?.objectValue?["receipt"]?.objectValue
        let approval = receipt?["approvals"]?.arrayValue?.first?.objectValue
        #expect(approval?["command"] == .string("touch spike.txt"))
        #expect(approval?["decision"] == .string("denied"))
        #expect(approval?["level"] == .string("moderate"))
        #expect(receipt?["denials"]?.arrayValue?.first?.objectValue?["verdict"] == .string("disapproved"))
        #expect(receipt?["commands"] == .array([]))
        await pair.client.disconnect()
        await pair.server.stop()
    }

    @Test func approvalThroughElicitationRunsTheCommand() async throws {
        // A client that renders elicitation and accepts with scope "session".
        let sink = MemoryAuditSink()
        let session = try scratchSession(dependencies: .testing(sink: sink))
        let dir = FileManager.default.temporaryDirectory.appending(path: "daimon-wire-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let steps: [ScriptedModel.Step] = [
            .call(
                name: "run_command",
                arguments: #"{"command":"touch marker.txt && echo approved","workingDirectory":"\#(dir.path)"}"#),
            .say("{tool}"),
        ]
        let server = DaimonServer(session: session) { session, approver, id, instructions, tools, model in
            let conversation = try session.conversation(
                id: id, approver: approver, instructions: instructions, tools: tools, model: model)
            let agent = Agent(
                instructions: "x", tools: conversation.tools,
                model: ResolvedModel(selection: .system, custom: ScriptedModel(steps: steps)), audit: conversation.audit
            )
            return OpenThread(
                thread: ConversationThread(id: id, agent: agent), gate: conversation.gate, audit: conversation.audit,
                receipts: conversation.receipts)
        }
        let transports = await InMemoryTransport.createConnectedPair()
        try await server.serve(transport: transports.server)
        let client = Client(name: "wire-test", version: "0", capabilities: .init(elicitation: .init(form: .init())))
        _ = await client.withElicitationHandler { _ in
            CreateElicitation.Result(action: .accept, content: ["scope": .string("session")])
        }
        _ = try await client.connect(transport: transports.client)
        let result = try await call(client, "respond", ["prompt": .string("go"), "thread_id": .string("t3")])
        guard case .text(let text, _, _)? = result.content.first else { Issue.record("no text"); return }
        #expect(text.contains("exit status: 0"))
        #expect(text.contains("approved"))
        let decided = sink.events.last { $0.kind == .approvalDecided }
        #expect(decided?.details["decision"] == "approved")
        #expect(decided?.details["scope"] == "session")
        let receipt = result.structuredContent?.objectValue?["receipt"]?.objectValue
        let command = receipt?["commands"]?.arrayValue?.first?.objectValue
        #expect(command?["command"] == .string("touch marker.txt && echo approved"))
        #expect(command?["exitStatus"] == .int(0))
        #expect(receipt?["approvals"]?.arrayValue?.first?.objectValue?["scope"] == .string("session"))
        await client.disconnect()
        await server.stop()
    }

    @Test func settingsOnAnExistingThreadAndCloseThreadOverTheProtocol() async throws {
        let pair = try await connected(steps: [.say("one"), .say("two")])
        _ = try await call(pair.client, "respond", ["prompt": .string("a"), "thread_id": .string("t4")])
        let again = try await call(
            pair.client, "respond",
            ["prompt": .string("b"), "thread_id": .string("t4"), "model": .string("private-cloud")])
        #expect(again.isError == true)
        let closed = try await call(pair.client, "close_thread", ["thread_id": .string("t4")])
        #expect(closed.isError == false)
        #expect(pair.sink.events.last { $0.session == "t4" }?.kind == .sessionEnd)
        let missing = try await pair.client.callTool(name: "close_thread", arguments: ["thread_id": .string("t4")])
            .value
        #expect(missing.isError == true)
        await #expect(throws: MCPError.self) { _ = try await call(pair.client, "nope") }
        await #expect(throws: MCPError.self) {
            _ = try await call(pair.client, "respond", [:])
        }
        await pair.client.disconnect()
        await pair.server.stop()
    }

    @Test func resultsSerialiseToTheWireShape() throws {
        // What a client receives for a respond result, byte for byte.
        let result = CallTool.Result(
            content: [.text(text: "hi", annotations: nil, _meta: nil)],
            structuredContent: .object(["thread_id": .string("t"), "created": .bool(true), "refusals": .array([])]),
            isError: false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(result), as: UTF8.self)
        #expect(
            json
                == #"{"content":[{"text":"hi","type":"text"}],"isError":false,"structuredContent":{"created":true,"refusals":[],"thread_id":"t"}}"#
        )
        let decoded = try JSONDecoder().decode(CallTool.Result.self, from: Data(json.utf8))
        #expect(decoded.structuredContent == result.structuredContent)
    }
}
