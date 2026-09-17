import MCP
import Testing

@testable import DaimonMCP

@Suite struct ToolCatalogTests {
    @Test func advertisesRespondAndRunCommand() {
        #expect(ToolCatalog.all.map(\.name) == ["respond", "run_command"])
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
        #expect(request.toolNames == ["current_date"])
    }

    @Test func respondRequestDefaults() throws {
        let request = try RespondRequest(arguments: ["prompt": .string("hi")])
        #expect(request.instructions == nil)
        #expect(request.toolNames.isEmpty)
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

    @Test func decodesRunCommandRequest() throws {
        let request = try RunCommandRequest(arguments: [
            "command": .string("ls"), "working_directory": .string("/tmp"),
        ])
        #expect(request.command == "ls")
        #expect(request.workingDirectory == "/tmp")
        #expect(throws: MCPError.self) { try RunCommandRequest(arguments: ["command": .string("")]) }
        #expect(throws: MCPError.self) {
            try RunCommandRequest(arguments: ["command": .string("ls"), "working_directory": .int(1)])
        }
    }
}
