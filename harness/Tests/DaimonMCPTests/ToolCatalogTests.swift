import DaimonCore
import MCP
import Testing

@testable import DaimonMCP

@Suite struct ToolCatalogTests {
    @Test func advertisesRespondAndRunCommand() {
        #expect(ToolCatalog.all.map(\.name) == ["respond", "close_thread"])
    }

    @Test func everyToolHasAnObjectSchemaWithRequiredFields() {
        for tool in ToolCatalog.all {
            let schema = tool.inputSchema.objectValue
            #expect(schema?["type"]?.stringValue == "object", "\(tool.name)")
            #expect(schema?["required"]?.arrayValue?.isEmpty == false, "\(tool.name)")
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
