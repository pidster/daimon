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
        let lines: Mutex<[String]>

        init(lines: [String]) { self.lines = Mutex(lines) }

        var io: ChatLoop.IO {
            .init(
                readLine: { self.lines.withLock { $0.isEmpty ? nil : $0.removeFirst() } },
                print: { text in self.stdout.withLock { $0.append(text + "\n") } },
                write: { text in if text != "> " { self.stdout.withLock { $0.append(text) } } },
                note: { text in self.notes.withLock { $0.append(text) } })
        }

        var output: String { stdout.withLock { $0.joined() } }
        var noted: [String] { notes.withLock { $0 } }
    }

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
            "quit", "never read",
        ])
        var loop = ChatLoop(agent: agent, store: store, saveName: nil, io: capture.io)
        try await loop.run()
        let out = capture.output
        #expect(out.contains(ChatInput.helpText))
        #expect(out.contains("current_date\t"))
        #expect(out.contains("unknown tokens in 0 turns; condensed 0 times\n"))
        #expect(out.contains("hi there\n"))
        #expect(out.contains("second\n"))
        let notes = capture.noted
        #expect(notes.first == "wisp chat. /help for commands, /quit or Ctrl-D to exit.")
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
        var loop = ChatLoop(agent: agent, store: store, saveName: "session", io: capture.io)
        try await loop.run()
        #expect(capture.noted.contains { $0.hasPrefix("error: ") }, "\(capture.noted)")
        #expect(capture.output.hasSuffix("done\n"), "\(capture.output)")
        #expect(capture.noted.last == "saved 'session'")
        #expect(try store.list() == ["session"])
        // A condensed turn is announced.
        let condensing = Agent(
            instructions: "x", tools: [],
            model: ResolvedModel(selection: .system, custom: ScriptedModel(steps: [.say("after")], overflowOnce: true)))
        let second = Capture(lines: ["go", "/quit"])
        var again = ChatLoop(agent: condensing, store: store, saveName: nil, io: second.io)
        try await again.run()
        #expect(second.noted.contains("(context was full; older turns were dropped to continue)"))
        // A save that cannot happen is a note inside the loop and an error on exit.
        let unwritable = TranscriptStore(directory: dir.appending(path: "missing"))
        let third = Capture(lines: ["/save x", "/quit"])
        var broken = ChatLoop(agent: condensing, store: unwritable, saveName: nil, io: third.io)
        try await broken.run()
        #expect(third.noted.contains { $0.hasPrefix("error: ") })
        var exiting = ChatLoop(agent: condensing, store: unwritable, saveName: "x", io: Capture(lines: []).io)
        await #expect(throws: (any Error).self) { try await exiting.run() }
    }
}
