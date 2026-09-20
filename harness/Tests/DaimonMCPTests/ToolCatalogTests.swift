import DaimonCore
import Foundation
import MCP
import Testing

@testable import DaimonMCP

@Suite struct ToolCatalogTests {
    @Test func advertisesRespondAndRunCommand() {
        #expect(ToolCatalog.all.map(\.name) == ["respond", "triage", "close_thread"])
    }

    @Test func everyToolHasAnObjectSchemaWithRequiredFields() {
        for tool in ToolCatalog.all {
            let schema = tool.inputSchema.objectValue
            #expect(schema?["type"]?.stringValue == "object", "\(tool.name)")
            #expect(schema?["required"]?.arrayValue != nil, "\(tool.name)")
        }
    }

    @Test func decodesRespondRequest() throws {
        let request = try RespondRequest(arguments: [
            "prompt": .string("hi"),
            "instructions": .string("be brief"),
            "tools": .array([.string("current_date")]),
        ])
        #expect(request.prompt == "hi")
        #expect(request.instructions == "be brief")
        #expect(request.tools == .named(["current_date"]))
        #expect(request.schema == nil)
        let shaped = try RespondRequest(arguments: [
            "prompt": .string("hi"), "schema": .object(["type": .string("object"), "properties": .object([:])]),
        ])
        #expect(shaped.schema == ["type": "object", "properties": [:]])
        #expect(throws: MCPError.self) {
            try RespondRequest(arguments: ["prompt": .string("hi"), "schema": .string("x")])
        }
        // The bridge from MCP values covers every shape.
        let bridged = JSONValue(
            MCP.Value.array([.null, .bool(true), .int(1), .double(1.5), .data(mimeType: nil, Data([1])), .string("s")]))
        #expect(bridged == [nil, true, 1, 1.5, "AQ==", "s"])
    }

    @Test func respondRequestDefaults() throws {
        let request = try RespondRequest(arguments: ["prompt": .string("hi")])
        #expect(request.instructions == nil)
        #expect(request.tools == .all)
    }

    @Test func respondRequestRejectsMissingPrompt() {
        #expect(throws: MCPError.self) { try RespondRequest(arguments: [:]) }
        #expect(throws: MCPError.self) { try RespondRequest(arguments: ["prompt": .string("")]) }
        #expect(throws: MCPError.self) { try RespondRequest(arguments: ["prompt": .int(1)]) }
    }

    @Test func respondRequestRejectsBadTools() {
        #expect(throws: MCPError.self) {
            try RespondRequest(arguments: ["prompt": .string("x"), "tools": .string("nope")])
        }
        #expect(throws: MCPError.self) {
            try RespondRequest(arguments: ["prompt": .string("x"), "tools": .array([.int(1)])])
        }
    }

    @Test func respondRequestThreadID() throws {
        #expect(try RespondRequest(arguments: ["prompt": .string("x")]).threadID == nil)
        #expect(
            try RespondRequest(arguments: ["prompt": .string("x"), "thread_id": .string("t-1.a")]).threadID == "t-1.a")
        for bad: Value in [.string(""), .string("has space"), .string(String(repeating: "x", count: 65)), .int(1)] {
            #expect(throws: MCPError.self) {
                try RespondRequest(arguments: ["prompt": .string("x"), "thread_id": bad])
            }
        }
    }

    @Test func respondRequestModel() throws {
        #expect(try RespondRequest(arguments: ["prompt": .string("x")]).model == nil)
        #expect(
            try RespondRequest(arguments: ["prompt": .string("x"), "model": .string("private-cloud")]).model
                == .privateCloud)
        #expect(throws: MCPError.self) {
            try RespondRequest(arguments: ["prompt": .string("x"), "model": .string("nope")])
        }
        #expect(throws: MCPError.self) { try RespondRequest(arguments: ["prompt": .string("x"), "model": .int(1)]) }
    }

    @Test func decodesCloseThreadRequest() throws {
        #expect(try CloseThreadRequest(arguments: ["thread_id": .string("abc")]).threadID == "abc")
        #expect(throws: MCPError.self) { try CloseThreadRequest(arguments: [:]) }
        #expect(throws: MCPError.self) { try CloseThreadRequest(arguments: ["thread_id": .string("a/b")]) }
    }

    @Test func emptyToolsMeansATextOnlyThread() throws {
        let request = try RespondRequest(arguments: ["prompt": .string("hi"), "tools": .array([])])
        #expect(request.tools == ToolSelection.none)
        #expect(ToolSelection.none.resolved(or: ["a"]).isEmpty)
    }
}

@Suite struct TriageRequestTests {
    @Test func decodesExactlyOneSource() throws {
        let command = try TriageRequest(arguments: [
            "command": .string("swift test"), "working_directory": .string("/r"), "max_findings": .int(3),
            "model": .string("ollama:q"),
        ])
        #expect(command.source == .command("swift test", workingDirectory: "/r"))
        #expect(command.maxFindings == 3 && command.model == .ollama("q"))
        let path = try TriageRequest(arguments: ["path": .string("/log")])
        #expect(path.source == .path("/log") && path.maxFindings == 20 && path.model == nil)
        for bad: [String: Value] in [
            [:], ["command": .string("a"), "path": .string("b")], ["command": .string("")], ["path": .int(1)],
            ["command": .string("a"), "working_directory": .int(1)], ["path": .string("p"), "max_findings": .int(0)],
            ["path": .string("p"), "model": .string("gpt")], ["path": .string("p"), "model": .int(1)],
        ] {
            #expect(throws: MCPError.self, "\(bad)") { try TriageRequest(arguments: bad) }
        }
    }
}
