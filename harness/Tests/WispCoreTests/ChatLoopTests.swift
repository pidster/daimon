import Foundation
import Synchronization
import Testing
import WispTestSupport

@testable import WispCore

@Suite struct ChatLoopTests {
    /// Captured output of one run, by channel.
    final class Capture: Sendable {
        let stdout = Mutex<[String]>([])
        let notes = Mutex<[String]>([])
        let prompts = Mutex<[ChatStatus]>([])
        let lines: Mutex<[String]>

        init(lines: [String]) { self.lines = Mutex(lines) }

        var io: ChatLoop.IO {
            .init(
                readLine: { self.lines.withLock { $0.isEmpty ? nil : $0.removeFirst() } },
                print: { text in self.stdout.withLock { $0.append(text + "\n") } },
                write: { text in self.stdout.withLock { $0.append(text) } },
                note: { text in self.notes.withLock { $0.append(text) } },
                prompt: { status in self.prompts.withLock { $0.append(status) } })
        }

        var output: String { stdout.withLock { $0.joined() } }
        var noted: [String] { notes.withLock { $0 } }
        var shownStatus: [ChatStatus] { prompts.withLock { $0 } }
    }

    /// A context with a fixed git answer and an inspect view that echoes its argument.
    static let context = ChatLoop.Context(
        directory: "/repo", approval: "approve at moderate", git: { _ in ("main", true) },
        inspect: { what in "inspected \(what)" }, banner: "wisp test")

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-chat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func commandsMessagesAndTheExitSaveOverAScriptedModel() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TranscriptStore(directory: dir)
        let sink = MemoryAuditSink()
        let agent = Agent(
            instructions: "x", tools: [CurrentDateTool()],
            model: ResolvedModel(selection: .system, custom: ScriptedModel(steps: [.say("hi there"), .say("second")])),
            audit: AuditLog(session: "chat", sink: sink))
        let capture = Capture(lines: [
            "/help", "/tools", "/tokens", "", "hello", "/save", "/save first", "/bogus", "/new", "again", "/save",
            "/inspect approvals", "/status", "/last", "help", "quit", "never read",
        ])
        var loop = ChatLoop(agent: agent, store: store, saveName: nil, context: Self.context, io: capture.io)
        try await loop.run()
        let out = capture.output
        #expect(out.contains(ChatInput.helpText))
        #expect(out.contains("current_date  Returns the current local date and time.\n"))
        #expect(out.contains("inspected approvals\n") && out.contains("inspected status\n"))
        #expect(out.contains("no tool has run yet\n"))
        #expect(out.components(separatedBy: ChatInput.helpText).count == 3)  // /help and bare help
        #expect(out.contains("unknown tokens in 0 turns; condensed 0 times\n"))
        #expect(out.contains("hi there\n"))
        #expect(out.contains("second\n"))
        let notes = capture.noted
        #expect(notes.first == "wisp test")
        #expect(notes[1] == "/help for commands, /quit or Ctrl-D to exit.")
        // The status line is drawn before every prompt, from the context and the agent.
        let status = capture.shownStatus
        #expect(status.count == 16)
        #expect(status.first?.rendered(style: .plain) == "system · /repo · main · changes · approve at moderate")
        #expect(notes.contains("usage: /save <name>"))
        #expect(notes.contains("saved 'first'"))
        #expect(notes.contains("unknown command /bogus; /help lists commands"))
        #expect(notes.contains("new conversation"))
        #expect(notes.filter { $0 == "saved 'first'" }.count == 3)  // /save first, bare /save, exit
        #expect(loop.saveName == "first")
        #expect(try store.list() == ["first"])
        #expect(try store.load("first").turnCount == 1)  // after /new only "again" remains
        #expect(sink.events.contains { $0.kind == .sessionStart && $0.details["reason"] == "new" })
        #expect(sink.events.filter { $0.kind == .prompt }.count == 2)
    }

    @Test func modelsListsAndModelSwitchesKeepingTheTranscript() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = Agent(
            instructions: "x", tools: [],
            model: ResolvedModel(selection: .system, custom: ScriptedModel(steps: [.say("from system")])))
        let context = ChatLoop.Context(
            directory: "/r", approval: "--yes",
            models: { current, _ in ["current \(current)", "  ollama:q\t3B"] },
            openModel: { selection, transcript in
                Agent(
                    transcript: transcript, tools: [],
                    model: ResolvedModel(selection: selection, custom: ScriptedModel(steps: [.say("from ollama")])))
            })
        let capture = Capture(lines: [
            "/models", "/model", "one", "/model ollama:q", "/model", "two", "/model gpt-5", "/quit",
        ])
        var loop = ChatLoop(
            agent: first, store: TranscriptStore(directory: dir), saveName: nil, context: context, io: capture.io)
        try await loop.run()
        let out = capture.output
        #expect(out.contains("current system\n  ollama:q\t3B\n"))
        #expect(out.contains("model: system (toolCalling, guidedGeneration)\n"))
        #expect(out.contains("from system\n") && out.contains("from ollama\n"))
        #expect(out.contains("model: ollama:q (toolCalling, guidedGeneration)\n"))
        #expect(capture.noted.contains("model: ollama:q; the transcript continues"))
        #expect(capture.noted.contains { $0.hasPrefix("error: unknown model 'gpt-5'") })
        // The transcript carried over: both turns are in the switched agent, and the status shows the model.
        #expect(loop.agent.model.selection == .ollama("q"))
        #expect(loop.agent.transcript.turnCount == 2)
        #expect(capture.shownStatus.last?.model == "ollama:q")
        // Without the closures the commands say so.
        let bare = Capture(lines: ["/models", "/model x", "/quit"])
        var plain = ChatLoop(
            agent: first, store: TranscriptStore(directory: dir), saveName: nil, context: Self.context, io: bare.io)
        try await plain.run()
        #expect(
            bare.noted.contains("models are not listed here")
                && bare.noted.contains("the model cannot be switched here"))
    }

    @Test func endOfInputSavesUnderTheDefaultNameAndErrorsAreNotes() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TranscriptStore(directory: dir)
        // Overflow with no condense policy is an error the loop reports and survives.
        let agent = Agent(
            instructions: "x", tools: [],
            model: ResolvedModel(selection: .system, custom: ScriptedModel(steps: [.say("done")], overflowOnce: true)),
            contextPolicy: .failFast)
        let capture = Capture(lines: ["boom", "fine"])
        var loop = ChatLoop(agent: agent, store: store, saveName: "session", context: Self.context, io: capture.io)
        try await loop.run()
        #expect(capture.noted.contains { $0.hasPrefix("error: ") }, "\(capture.noted)")
        #expect(capture.output.hasSuffix("done\n"), "\(capture.output)")
        #expect(capture.noted.last == "saved 'session'")
        #expect(try store.list() == ["session"])
        // A condensed turn is announced, through the tap the agent's audit log feeds.
        let tap = ChatEvents.Tap()
        let condensing = Agent(
            instructions: "x", tools: [],
            model: ResolvedModel(selection: .system, custom: ScriptedModel(steps: [.say("after")], overflowOnce: true)),
            audit: AuditLog(session: "c", sink: tap))
        let second = Capture(lines: ["go", "/quit"])
        var again = ChatLoop(
            agent: condensing, store: store, saveName: nil, tap: tap, context: Self.context, io: second.io)
        try await again.run()
        #expect(second.noted.contains { $0.hasPrefix("(context condensed, overflow: ") })
        // A save that cannot happen is a note inside the loop and an error on exit.
        let unwritable = TranscriptStore(directory: dir.appending(path: "missing"))
        let third = Capture(lines: ["/save x", "/quit"])
        var broken = ChatLoop(agent: condensing, store: unwritable, saveName: nil, context: Self.context, io: third.io)
        try await broken.run()
        #expect(third.noted.contains { $0.hasPrefix("error: ") })
        var exiting = ChatLoop(
            agent: condensing, store: unwritable, saveName: "x", context: Self.context, io: Capture(lines: []).io)
        await #expect(throws: (any Error).self) { try await exiting.run() }
    }
}
