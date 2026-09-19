import MCP
import Testing

@testable import DaimonMCP

@Suite struct DaimonServerTests {
    let server = DaimonServer()

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
