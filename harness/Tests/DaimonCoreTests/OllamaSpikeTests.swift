import Foundation
import FoundationModels
import Synchronization
import Testing

@testable import DaimonCore

/// Spike: a `LanguageModelExecutor` over Ollama's chat API, to learn what a real local runtime needs
/// from the executor protocol. Runs only with `DAIMON_OLLAMA_TESTS=1` and a model name in
/// `DAIMON_OLLAMA_MODEL`, against a server on `http://127.0.0.1:11434`; never in the gate.
struct OllamaModel: LanguageModel {
    struct Executor: LanguageModelExecutor {
        typealias Configuration = String
        typealias Model = OllamaModel
        let baseURL: URL

        init(configuration: String) throws {
            guard let url = URL(string: configuration) else { throw URLError(.badURL) }
            baseURL = url
        }

        /// One Ollama chat message.
        struct Message: Codable {
            var role: String
            var content: String
            var tool_calls: [ToolCall]?
            var tool_name: String?
            struct ToolCall: Codable {
                var function: Function
                struct Function: Codable {
                    var name: String
                    var arguments: JSONValue
                }
            }
        }

        /// The chat request body.
        struct Request: Encodable {
            var model: String
            var messages: [Message]
            var tools: [ToolSpec]?
            var stream: Bool
            var format: JSONValue?
            struct ToolSpec: Encodable {
                var type = "function"
                var function: Function
                struct Function: Encodable {
                    var name: String
                    var description: String
                    var parameters: JSONValue
                }
            }
        }

        /// One streamed chunk.
        struct Chunk: Decodable {
            var message: Message?
            var done: Bool?
            var prompt_eval_count: Int?
            var eval_count: Int?
        }

        /// Maps the framework transcript onto chat messages.
        static func messages(from transcript: Transcript) -> [Message] {
            func text(_ segments: [Transcript.Segment]) -> String {
                segments.compactMap {
                    switch $0 {
                    case .text(let segment): segment.content
                    case .structure(let segment): segment.content.jsonString
                    default: nil
                    }
                }.joined()
            }
            var messages: [Message] = []
            for entry in transcript {
                switch entry {
                case .instructions(let instructions):
                    messages.append(Message(role: "system", content: text(instructions.segments)))
                case .prompt(let prompt):
                    messages.append(Message(role: "user", content: text(prompt.segments)))
                case .response(let response):
                    messages.append(Message(role: "assistant", content: text(response.segments)))
                case .toolCalls(let calls):
                    let mapped = calls.map { call in
                        Message.ToolCall(
                            function: .init(
                                name: call.toolName,
                                arguments: (try? JSONDecoder().decode(
                                    JSONValue.self, from: Data(call.arguments.jsonString.utf8))) ?? .object([:])))
                    }
                    messages.append(Message(role: "assistant", content: "", tool_calls: mapped))
                case .toolOutput(let output):
                    messages.append(Message(role: "tool", content: text(output.segments), tool_name: output.toolName))
                default:
                    break
                }
            }
            return messages
        }

        nonisolated(nonsending) func respond(
            to request: LanguageModelExecutorGenerationRequest, model: OllamaModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            let tools = request.enabledToolDefinitions.map { definition in
                Request.ToolSpec(
                    function: .init(
                        name: definition.name, description: definition.description,
                        parameters: (try? JSONDecoder().decode(
                            JSONValue.self, from: JSONEncoder().encode(definition.parameters))) ?? .object([:])))
            }
            var format: JSONValue?
            if let schema = request.schema {
                format = try? JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(schema))
            }
            let body = Request(
                model: model.name, messages: Self.messages(from: request.transcript),
                tools: tools.isEmpty ? nil : tools, stream: true, format: format)
            var http = URLRequest(url: baseURL.appending(path: "api/chat"))
            http.httpMethod = "POST"
            http.setValue("application/json", forHTTPHeaderField: "Content-Type")
            http.httpBody = try JSONEncoder().encode(body)
            let (bytes, response) = try await URLSession.shared.bytes(for: http)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            var callIndex = 0
            var input = 0
            var output = 0
            for try await line in bytes.lines {
                guard let chunk = try? JSONDecoder().decode(Chunk.self, from: Data(line.utf8)) else { continue }
                if let message = chunk.message {
                    if !message.content.isEmpty {
                        await channel.send(.response(action: .appendText(message.content, tokenCount: 1)))
                    }
                    for call in message.tool_calls ?? [] {
                        callIndex += 1
                        let encoded = try JSONEncoder().encode(call.function.arguments)
                        let arguments = String(decoding: encoded, as: UTF8.self)
                        await channel.send(
                            .toolCalls(
                                action: .toolCall(
                                    id: "ollama-\(request.id)-\(callIndex)", name: call.function.name,
                                    action: .appendArguments(arguments, tokenCount: 1))))
                    }
                }
                input = chunk.prompt_eval_count ?? input
                output = chunk.eval_count ?? output
            }
            await channel.send(
                .response(
                    action: .updateUsage(
                        input: .init(totalTokenCount: input, cachedTokenCount: 0),
                        output: .init(totalTokenCount: output, reasoningTokenCount: 0))))
        }
    }

    let name: String
    var capabilities: LanguageModelCapabilities { .init([.toolCalling, .guidedGeneration]) }
    var executorConfiguration: String { "http://127.0.0.1:11434" }
}

@Generable struct SpikeAnswer {
    @Guide(description: "The city named in the question")
    let city: String
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["DAIMON_OLLAMA_TESTS"] == "1"))
struct OllamaSpikeTests {
    static let modelName = ProcessInfo.processInfo.environment["DAIMON_OLLAMA_MODEL"] ?? "qwen3-coder:latest"

    @Test func toolLoopAndStreamingThroughOllama() async throws {
        let model = OllamaModel(name: Self.modelName)
        let agent = Agent(
            instructions: "You are terse. Use the current_date tool to find the date; answer with the date only.",
            tools: [CurrentDateTool()], model: ResolvedModel(selection: .system, custom: model))
        var fragments = 0
        let started = ContinuousClock.now
        let reply = try await agent.stream("What is today's date in Asia/Tokyo?") { _ in fragments += 1 }
        let elapsed = ContinuousClock.now - started
        print("OLLAMA reply: \(reply.text) | fragments \(fragments) | \(elapsed)")
        let kinds = agent.transcript.map { entry -> String in
            switch entry {
            case .instructions: "instructions"
            case .prompt: "prompt"
            case .toolCalls: "toolCalls"
            case .toolOutput: "toolOutput"
            case .response: "response"
            default: "other"
            }
        }
        print("OLLAMA transcript: \(kinds)")
        #expect(kinds.contains("toolCalls") && kinds.contains("toolOutput"))
        #expect(reply.text.contains("20"))
    }

    @Test func guidedGenerationThroughOllama() async throws {
        let model = OllamaModel(name: Self.modelName)
        let session = LanguageModelSession(model: model, instructions: "Answer as JSON only.")
        let started = ContinuousClock.now
        let answer = try await session.respond(to: "Which city is the capital of France?", generating: SpikeAnswer.self)
            .content
        print("OLLAMA guided: \(answer.city) in \(ContinuousClock.now - started)")
        #expect(answer.city.lowercased().contains("paris"))
    }
}
