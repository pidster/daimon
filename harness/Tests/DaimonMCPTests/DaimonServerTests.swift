import MCP
import Testing

@testable import DaimonMCP

@Suite struct DaimonServerTests {
    let server = DaimonServer()

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
