import Foundation
import FoundationModels
import Synchronization
import Testing

@testable import DaimonCore

/// Spike: can a daimon-supplied `LanguageModel` + `LanguageModelExecutor` drive `LanguageModelSession`,
/// including the framework's tool loop and streaming, with no on-device model involved?
///
/// The scripted model answers from a fixed plan: on a transcript whose last entry is a prompt it asks
/// for `current_date`; once the transcript carries that tool's output it replies with text built from
/// it. If this works, two things follow: other local runtimes can be plugged in the same way, and
/// `Agent` becomes testable without the model.
struct ScriptedModel: LanguageModel {
    struct Executor: LanguageModelExecutor {
        typealias Configuration = Int
        typealias Model = ScriptedModel

        init(configuration: Int) throws {}

        nonisolated(nonsending) func respond(
            to request: LanguageModelExecutorGenerationRequest, model: ScriptedModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            model.script.requests.withLock { $0.append(request) }
            if model.script.overflowOnce.withLock({
                let value = $0; $0 = false; return value
            }) {
                throw LanguageModelError.contextSizeExceeded(
                    .init(contextSize: 10, tokenCount: 11, debugDescription: "scripted overflow", metadata: [:]))
            }
            let lastToolOutput: String? = request.transcript.reversed().lazy.compactMap { entry -> String? in
                if case .toolOutput(let output) = entry {
                    return output.segments.compactMap { if case .text(let text) = $0 { text.content } else { nil } }
                        .joined()
                }
                return nil
            }.first
            if let lastToolOutput, case .toolOutput? = request.transcript.last {
                for word in ["The ", "date ", "is ", lastToolOutput] {
                    await channel.send(.response(action: .appendText(word, tokenCount: 1)))
                }
                await channel.send(
                    .response(
                        action: .updateUsage(
                            input: .init(totalTokenCount: 40, cachedTokenCount: 0),
                            output: .init(totalTokenCount: 4, reasoningTokenCount: 0))))
            } else {
                await channel.send(
                    .toolCalls(
                        action: .toolCall(
                            id: "call-1", name: "current_date",
                            action: .appendArguments(#"{"timeZone":"Asia/Tokyo"}"#, tokenCount: 8))))
            }
        }
    }

    /// What the executor saw and whether it should still fail once, behind a Mutex in a class.
    final class Script: Sendable {
        let requests = Mutex<[LanguageModelExecutorGenerationRequest]>([])
        let overflowOnce: Mutex<Bool>
        init(overflowOnce: Bool) { self.overflowOnce = Mutex(overflowOnce) }
    }

    let script: Script

    init(overflowOnce: Bool = false) {
        script = Script(overflowOnce: overflowOnce)
    }

    var capabilities: LanguageModelCapabilities { .init([.toolCalling]) }
    var executorConfiguration: Int { 0 }
}

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
        #expect(try await agent.contextTokens() == nil)
    }
}
