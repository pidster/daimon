import DaimonTestSupport
import Foundation
import FoundationModels
import Testing

@testable import DaimonCore

/// `Agent` over the scripted model: every path that used to need Apple's model.
@Suite struct AgentTests {
    private func agent(
        steps: [ScriptedModel.Step] = [.say("hello there")], overflowOnce: Bool = false, partial: String = "",
        sink: MemoryAuditSink = MemoryAuditSink()
    ) -> Agent {
        Agent(
            instructions: "be brief", tools: [CurrentDateTool()],
            model: ResolvedModel(
                selection: .system,
                custom: ScriptedModel(steps: steps, overflowOnce: overflowOnce, partialBeforeOverflow: partial)),
            audit: AuditLog(session: "a", sink: sink))
    }

    @Test func respondReturnsTextAndAdvancesTheClock() async throws {
        let sink = MemoryAuditSink()
        let agent = agent(steps: [.say("one"), .say("two")], sink: sink)
        #expect(try await agent.respond(to: "a") == .init(text: "one", condensed: false))
        #expect(try await agent.respond(to: "b") == .init(text: "two", condensed: false))
        #expect(agent.turns.current == 2)
        #expect(sink.events.map(\.turn) == [1, 1, 2, 2])
        #expect(agent.transcript.turnCount == 2)
        #expect(try await agent.contextTokens() == nil)
    }

    @Test func streamRecoversFromOverflowAndReportsCondensed() async throws {
        // The first request streams "Hel" then overflows. The framework discards what the failed
        // request streamed, so the caller sees only the retry's text, and the reply says it condensed.
        let agent = agent(steps: [.say("Hello again")], overflowOnce: true, partial: "Hel")
        var seen: [String] = []
        let reply = try await agent.stream("hi") { seen.append($0) }
        #expect(reply == .init(text: "Hello again", condensed: true))
        #expect(seen.joined() == "Hello again")
        #expect(agent.condensations == 1)
    }

    @Test func streamSeparatesASnapshotThatDoesNotContinueTheShownText() async throws {
        // Three fragments, the middle one a cumulative snapshot that is not a prefix of the last.
        let agent = agent(steps: [.say("Hello wide world")])
        var seen: [String] = []
        let reply = try await agent.stream("hi") { seen.append($0) }
        #expect(reply.text == "Hello wide world")
        #expect(seen.joined() == "Hello wide world")
    }

    @Test func overflowWithoutACondensePolicyIsRethrown() async {
        let agent = Agent(
            instructions: "x", tools: [],
            model: ResolvedModel(selection: .system, custom: ScriptedModel(overflowOnce: true)),
            contextPolicy: .failFast)
        await #expect(throws: LanguageModelError.self) { try await agent.respond(to: "hi") }
    }

    @Test func errorsAreAuditedAndRethrown() async {
        let sink = MemoryAuditSink()
        // Asking for a tool the session does not have is a framework error.
        let agent = agent(steps: [.call(name: "nope", arguments: "{}")], sink: sink)
        await #expect(throws: (any Error).self) { try await agent.respond(to: "hi") }
        #expect(sink.events.map(\.kind) == [.prompt, .error])
        #expect(sink.events.last?.details["context"] == "turn")
    }

    @Test func resetStartsOverAndRecordsIt() async throws {
        let sink = MemoryAuditSink()
        let agent = agent(steps: [.say("one"), .say("two")], sink: sink)
        _ = try await agent.respond(to: "a")
        agent.reset()
        #expect(agent.transcript.turnCount == 0)
        let restart = sink.events.last
        #expect(restart?.kind == .sessionStart)
        #expect(restart?.details["reason"] == "new")
        #expect(restart?.details["tools"] == .array(["current_date"]))
        #expect(restart?.details["model"] == "system")
        _ = try await agent.respond(to: "b")
        #expect(agent.transcript.turnCount == 1)
    }

    @Test func resumesATranscriptOnAResolvedModel() async throws {
        let first = agent(steps: [.say("one")])
        _ = try await first.respond(to: "a")
        let resumed = Agent(
            transcript: first.transcript, tools: [CurrentDateTool()],
            model: ResolvedModel(selection: .system, custom: ScriptedModel(steps: [.say("two")])))
        #expect(resumed.transcript.turnCount == 1)
        #expect(try await resumed.respond(to: "b").text == "two")
        #expect(resumed.transcript.turnCount == 2)
    }
}
