import Foundation
import MCP
import Testing

@testable import WispMCP

/// The Codex `initialize` that SDK 0.12.1 refuses, as captured from a failing 0.1.4 process.
private let codexInitialize = #"""
    {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"experimental":{"codex/auth-change":{}}},"clientInfo":{"name":"codex","version":"0.1"}}}
    """#

@Suite struct CompatibilityTransportTests {
    @Test func stringifiesObjectValuedExperimentalCapabilities() throws {
        let out = CompatibilityTransport.normalise(Data(codexInitialize.utf8))
        let message = try #require(JSONSerialization.jsonObject(with: out) as? [String: Any])
        let params = try #require(message["params"] as? [String: Any])
        let capabilities = try #require(params["capabilities"] as? [String: Any])
        #expect(capabilities["experimental"] as? [String: String] == ["codex/auth-change": "{}"])
        #expect((params["clientInfo"] as? [String: Any])?["name"] as? String == "codex")
        #expect(message["id"] as? Int == 1)
        // The SDK can now decode it.
        _ = try JSONDecoder().decode(Request<Initialize>.self, from: out)
    }

    @Test func leavesEverythingElseAlone() {
        let stringValued = Data(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{"experimental":{"a":"b"}}}}"#.utf8
        )
        #expect(CompatibilityTransport.normalise(stringValued) == stringValued)
        let otherMethod = Data(
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{"experimental":{"x":{}}}}"#.utf8)
        #expect(CompatibilityTransport.normalise(otherMethod) == otherMethod)
        let notJSON = Data("hello".utf8)
        #expect(CompatibilityTransport.normalise(notJSON) == notJSON)
        let noCapabilities = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#.utf8)
        #expect(CompatibilityTransport.normalise(noCapabilities) == noCapabilities)
    }

    /// Regression: the captured request, byte for byte, through the server on a real transport.
    @Test func codexInitializeSucceedsOverTheWire() async throws {
        let server = WispServer(session: try scratchSession())
        let transports = await InMemoryTransport.createConnectedPair()
        try await server.serve(transport: transports.server)
        try await transports.client.connect()
        try await transports.client.send(Data(codexInitialize.utf8))
        var reply: Data?
        for try await message in await transports.client.receive() {
            reply = message
            break
        }
        let text = String(decoding: try #require(reply), as: UTF8.self)
        #expect(text.contains(#""result""#), "\(text)")
        #expect(!text.contains("-32603"), "\(text)")
        #expect(text.contains(#""name":"wisp""#), "\(text)")
        await transports.client.disconnect()
        await server.stop()
    }
}
