import Foundation
import FoundationModels
import Testing

@testable import DaimonCore

/// Drives the production `OllamaModel` against a live server. Runs only with `DAIMON_OLLAMA_TESTS=1`
/// and, optionally, a model name in `DAIMON_OLLAMA_MODEL`; never in the gate. See ADR 0016.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DAIMON_OLLAMA_TESTS"] == "1"))
struct OllamaLiveTests {
    static let selection = ModelSelection.ollama(
        ProcessInfo.processInfo.environment["DAIMON_OLLAMA_MODEL"] ?? "qwen3-coder:latest")

    @Test func toolLoopAndStreaming() async throws {
        let agent = Agent(
            instructions: "You are terse. Use the current_date tool to find the date; answer with the date only.",
            tools: [CurrentDateTool()], model: try Self.selection.resolve())
        var fragments = 0
        let started = ContinuousClock.now
        let reply = try await agent.stream("What is today's date in Asia/Tokyo?") { _ in fragments += 1 }
        print("OLLAMA reply: \(reply.text) | fragments \(fragments) | \(ContinuousClock.now - started)")
        let kinds = agent.transcript.map { entry -> String in
            switch entry {
            case .toolCalls: "toolCalls"
            case .toolOutput: "toolOutput"
            default: "other"
            }
        }
        #expect(kinds.contains("toolCalls") && kinds.contains("toolOutput"))
        #expect(reply.text.contains("20"))
    }

    @Generable struct Answer {
        @Guide(description: "The city named in the question")
        let city: String
    }

    @Test func guidedGeneration() async throws {
        let session = LanguageModelSession(
            model: OllamaModel(name: Self.selection.description.replacingOccurrences(of: "ollama:", with: "")),
            instructions: "Answer as JSON only.")
        let answer = try await session.respond(to: "Which city is the capital of France?", generating: Answer.self)
            .content
        print("OLLAMA guided: \(answer.city)")
        #expect(answer.city.lowercased().contains("paris"))
    }

    @Test func unknownModelIsUnavailable() {
        #expect(throws: ModelSelection.Failure.self) { try ModelSelection.ollama("no-such-model-xyz").resolve() }
    }
}
