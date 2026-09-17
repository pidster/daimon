import MCP
import Testing

@testable import DaimonMCP

@Suite struct DaimonServerTests {
    let server = DaimonServer(defaultInstructions: "test")

    @Test func runCommandReturnsRenderedOutcome() async throws {
        let result = try await server.call(.init(name: "run_command", arguments: ["command": .string("printf ok")]))
        #expect(result.isError == false)
        #expect(result.content == [.text(text: "exit status: 0\nstdout:\nok", annotations: nil, _meta: nil)])
    }

    @Test func runCommandFailureIsAToolError() async throws {
        let result = try await server.call(
            .init(name: "run_command", arguments: ["command": .string("true"), "working_directory": .string("/nope")]))
        #expect(result.isError == true)
    }

    @Test func unknownToolIsAProtocolError() async {
        await #expect(throws: MCPError.self) { try await server.call(.init(name: "nope", arguments: nil)) }
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
