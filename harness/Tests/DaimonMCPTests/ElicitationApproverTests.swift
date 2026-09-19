import DaimonCore
import MCP
import Synchronization
import Testing

@testable import DaimonMCP

/// Drives `ElicitationApprover` through a real in-process MCP client and server.
@Suite struct ElicitationApproverTests {
    private let request = ApprovalRequest(
        command: "touch x", pattern: "touch *", workingDirectory: "/tmp",
        assessment: RiskAssessment(level: .moderate, reasons: ["modifies files"], sources: ["rules"]))

    /// A connected client whose elicitation handler answers with `answer`, and the server it talks to.
    private func connectedPair(
        answering answer: @escaping @Sendable () async throws -> CreateElicitation.Result
    )
        async throws -> (client: Client, server: Server, flags: ClientCapabilityFlags)
    {
        let transports = await InMemoryTransport.createConnectedPair()
        let server = Server(name: "t", version: "0", capabilities: .init(tools: .init(listChanged: false)))
        let flags = ClientCapabilityFlags()
        try await server.start(transport: transports.server) { _, capabilities in
            flags.elicitation.withLock { $0 = capabilities.elicitation != nil }
        }
        let client = Client(
            name: "test-client", version: "0", capabilities: .init(elicitation: .init(form: .init())))
        _ = await client.withElicitationHandler { _ in try await answer() }
        _ = try await client.connect(transport: transports.client)
        return (client, server, flags)
    }

    @Test func clientWithoutElicitationIsDeniedWithGuidance() async {
        let server = Server(name: "t", version: "0")
        let approver = ElicitationApprover(server: server, client: ClientCapabilityFlags(), timeout: .seconds(1))
        let decision = await approver.decide(request)
        guard case .denied(let reason) = decision else { Issue.record("expected denial, got \(decision)"); return }
        #expect(reason.contains("does not support elicitation"))
        #expect(reason.contains("touch x") == false)
        #expect(reason.contains("modifies files"))
    }

    @Test(arguments: [
        (CreateElicitation.Result.Action.accept, ApprovalDecision.approved(.once)),
        (CreateElicitation.Result.Action.decline, ApprovalDecision.denied("declined by the user")),
        (CreateElicitation.Result.Action.cancel, ApprovalDecision.denied("cancelled by the user")),
    ])
    func mapsTheClientsAnswer(action: CreateElicitation.Result.Action, expected: ApprovalDecision) async throws {
        let pair = try await connectedPair { CreateElicitation.Result(action: action, content: nil) }
        #expect(pair.flags.elicitation.withLock { $0 })
        let approver = ElicitationApprover(server: pair.server, client: pair.flags, timeout: .seconds(5))
        #expect(await approver.decide(request) == expected)
        await pair.client.disconnect()
        await pair.server.stop()
    }

    @Test func silenceIsUnanswered() async throws {
        let pair = try await connectedPair {
            try await Task.sleep(for: .seconds(2))
            return CreateElicitation.Result(action: .accept, content: nil)
        }
        let approver = ElicitationApprover(server: pair.server, client: pair.flags, timeout: .milliseconds(300))
        #expect(await approver.decide(request) == .unanswered(.milliseconds(300)))
        await pair.client.disconnect()
        await pair.server.stop()
    }
}
