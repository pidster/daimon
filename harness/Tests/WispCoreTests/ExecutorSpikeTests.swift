import Foundation
import FoundationModels
import Synchronization
import Testing
import WispTestSupport

@testable import WispCore

/// Spike, kept as the proof: a wisp-supplied `LanguageModel` drives `LanguageModelSession`, its
/// tool loop, and streaming with no on-device model. `ScriptedModel` lives in `WispTestSupport`.
@Suite struct ExecutorSpikeTests {
    @Test func aCustomModelDrivesTheFrameworkToolLoopAndStreams() async throws {
        let model = ScriptedModel()
        let session = LanguageModelSession(model: model, tools: [CurrentDateTool()], instructions: "be brief")
        var deltas: [String] = []
        for try await snapshot in session.streamResponse(to: "what is the date?") {
            deltas.append(snapshot.content)
        }
        let final = deltas.last ?? ""
        #expect(final.hasPrefix("The date is 20"))
        #expect(final.hasSuffix("(Asia/Tokyo)"))
        #expect(deltas.count >= 2, "streamed in fragments: \(deltas.count)")

        // The framework ran the tool loop: two executor requests, the second carrying the tool output.
        let requests = model.script.requests.withLock { $0 }
        #expect(requests.count == 2)
        #expect(requests.first?.enabledToolDefinitions.map(\.name) == ["current_date"])
        let kinds = session.transcript.map { entry -> String in
            switch entry {
            case .instructions: "instructions"
            case .prompt: "prompt"
            case .toolCalls: "toolCalls"
            case .toolOutput: "toolOutput"
            case .response: "response"
            default: "other"
            }
        }
        #expect(kinds == ["instructions", "prompt", "toolCalls", "toolOutput", "response"])
    }

    @Test func agentRunsOnACustomModelWithAuditAndOverflowRecovery() async throws {
        let sink = MemoryAuditSink()
        let audit = AuditLog(session: "spike", sink: sink)
        let model = ScriptedModel(overflowOnce: true)
        // Spike seam: a resolved model over a custom LanguageModel. A real third selection would name it.
        let agent = Agent(
            instructions: "be brief", tools: [CurrentDateTool()],
            model: ResolvedModel(selection: .system, custom: model), audit: audit)
        let reply = try await agent.respond(to: "date?")
        #expect(reply.text.hasPrefix("The date is"))
        #expect(reply.condensed, "the scripted overflow should have been recovered by condensing")
        #expect(sink.events.map(\.kind) == [.prompt, .condensation, .response])
        #expect(try await agent.contextTokens() == 40)  // the runtime's report, since the model cannot count
    }
}
