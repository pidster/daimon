import Foundation
import Synchronization
import Testing

@testable import WispCore

@Suite struct WatcherTests {
    /// What a watch did, collected from its closures.
    final class Record: Sendable {
        let notified = Mutex<[Notifier.Message]>([])
        let reported = Mutex<[Watcher.Run]>([])
        let triaged = Mutex(0)
        let outcomes: Mutex<[Triage.Captured]>

        init(_ outcomes: [Triage.Captured]) { self.outcomes = Mutex(outcomes) }

        func watcher(
            _ options: Watcher.Options = .init(), triage: Bool = true, failTriage: Bool = false
        ) -> Watcher {
            let judge: @Sendable (Triage.Captured) async throws -> [Triage.Finding] = { _ in
                self.triaged.withLock { $0 += 1 }
                if failTriage { throw Busy() }
                return [.init(kind: "test-failure", location: "A.swift:3", message: "expected 1")]
            }
            return Watcher(
                command: "swift test", options: options,
                execute: { self.outcomes.withLock { $0.removeFirst() } },
                triage: triage ? judge : nil,
                notify: { message in self.notified.withLock { $0.append(message) } },
                report: { run in self.reported.withLock { $0.append(run) } })
        }
    }

    /// A judge that cannot answer.
    struct Busy: Error, CustomStringConvertible {
        var description: String { "model busy" }
    }

    static let pass = Triage.Captured(text: "ok", exitStatus: 0)
    static let fail = Triage.Captured(text: "boom", exitStatus: 1)

    static func triggers(_ list: [Watcher.Trigger]) -> AsyncStream<Watcher.Trigger> {
        AsyncStream { continuation in
            for trigger in list { continuation.yield(trigger) }
            continuation.finish()
        }
    }

    @Test func notificationsFollowThePolicy() {
        let turns: [(Watcher.State?, Watcher.State)] = [
            (nil, .pass), (nil, .fail), (.pass, .pass), (.pass, .fail), (.fail, .fail), (.fail, .pass),
        ]
        func pattern(_ policy: Watcher.NotifyPolicy) -> [Bool] {
            turns.map { Watcher.shouldNotify(policy, previous: $0.0, current: $0.1) }
        }
        #expect(pattern(.change) == [false, true, false, true, false, true])
        #expect(pattern(.failure) == [false, true, false, true, true, false])
        #expect(pattern(.always) == [true, true, true, true, true, true])
        #expect(pattern(.never) == [false, false, false, false, false, false])
        var run = Watcher.Run(
            number: 1, trigger: .start, exitStatus: 0, timedOut: false, state: .pass, previous: nil, seconds: 1,
            findings: nil, triageError: nil, notified: false)
        #expect(Watcher.message(for: run, command: "make").body == "Passing")
        #expect(Watcher.message(for: run, command: "make").sound == false)
        run.state = .fail
        run.exitStatus = 2
        run.findings = [
            .init(kind: "error", location: nil, message: "linker failed"),
            .init(kind: "error", location: "b", message: "x"),
        ]
        #expect(Watcher.message(for: run, command: "make").body == "Failing (exit 2): linker failed (+1 more)")
        #expect(Watcher.message(for: run, command: "make").sound)
    }

    @Test func aWatchRunsPerTriggerAndSpeaksUpWhenTheOutcomeTurns() async throws {
        let record = Record([Self.fail, Self.fail, Self.pass, Self.pass, Self.fail])
        let runs = try await record.watcher().run(Self.triggers([.start, .change, .change, .interval, .change]))
        #expect(runs.map(\.state) == [.fail, .fail, .pass, .pass, .fail])
        #expect(runs.map(\.trigger) == [.start, .change, .change, .interval, .change])
        #expect(runs.map(\.notified) == [true, false, true, false, true])
        #expect(runs.map(\.changed) == [false, false, true, false, true])
        // A failure that repeats unannounced is not triaged again.
        #expect(record.triaged.withLock { $0 } == 2)
        #expect(runs[1].findings == nil && runs[0].findings?.count == 1)
        let bodies = record.notified.withLock { $0.map(\.body) }
        #expect(
            bodies == [
                "Failing (exit 1): A.swift:3 expected 1", "Passing again", "Failing (exit 1): A.swift:3 expected 1",
            ])
        #expect(record.notified.withLock { $0.allSatisfy { $0.title == "wisp watch" && $0.subtitle == "swift test" } })
        #expect(record.reported.withLock { $0.count } == 5)
        #expect(runs[2].summary.hasPrefix("run 3 (change): pass, exit 0, ") && runs[2].summary.hasSuffix("; was fail"))
    }

    @Test func maxRunsTriageFailuresAndTimeoutsAreReported() async throws {
        let timedOut = Triage.Captured(text: "", exitStatus: nil, timedOut: true)
        let record = Record([timedOut, Self.pass, Self.pass])
        let runs = try await record.watcher(.init(notify: .always, maxRuns: 2), failTriage: true)
            .run(Self.triggers([.start, .change, .change]))
        #expect(runs.count == 2)
        #expect(runs[0].state == .fail && runs[0].triageError?.contains("model busy") == true)
        #expect(runs[0].summary.contains("timed out") && runs[0].summary.contains("triage failed"))
        #expect(record.notified.withLock { $0.map(\.body) } == ["Timed out", "Passing again"])
        let quiet = Record([Self.fail])
        let unTriaged = try await quiet.watcher(.init(triage: false)).run(Self.triggers([.start]))
        #expect(unTriaged[0].findings == nil && quiet.triaged.withLock { $0 } == 0)
    }

    @Test func eachRunIsAuditedWithTheDocumentedFields() {
        let run = Watcher.Run(
            number: 2, trigger: .change, exitStatus: 1, timedOut: false, state: .fail, previous: .pass, seconds: 1.5,
            findings: [.init(kind: "error", location: nil, message: "x")], triageError: nil, notified: true)
        let details = AuditEvent.Details.watchRun(run, command: "make")
        #expect(Set(details.keys).isSubset(of: AuditEvent.fields(for: .watchRun)))
        #expect(details["state"] == "fail" && details["previous"] == "pass" && details["changed"] == true)
        #expect(details["findings"] == .int(1) && details["exitStatus"] == .int(1) && details["trigger"] == "change")
        var first = run
        first.previous = nil
        first.findings = nil
        first.exitStatus = nil
        let bare = AuditEvent.Details.watchRun(first, command: "make")
        #expect(bare["previous"] == .null && bare["findings"] == .null && bare["exitStatus"] == .null)
    }

    @Test func aRefusedCommandEndsTheWatch() async {
        let watcher = Watcher(
            command: "rm -rf /", execute: { throw CommandRunner.Failure.denied("no") }, triage: nil,
            notify: { _ in }, report: { _ in })
        await #expect(throws: CommandRunner.Failure.self) { try await watcher.run(Self.triggers([.start])) }
    }

    @Test func buildOutputAndScratchFilesDoNotCount() {
        #expect(FileWatcher.counts("/repo/Sources/A.swift"))
        #expect(!FileWatcher.counts("/repo/.build/debug/wisp") && !FileWatcher.counts("/repo/.git/index"))
        #expect(!FileWatcher.counts("/repo/node_modules/x/y.js") && !FileWatcher.counts("/repo/target/debug/a"))
        #expect(!FileWatcher.counts("/repo/.A.swift.swp") && !FileWatcher.counts("/repo/notes.txt~"))
        #expect(!FileWatcher.counts("/repo/.DS_Store"))
    }

    @Test func fsEventsReportAChangeUnderTheWatchedDirectory() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let (events, continuation) = AsyncStream.makeStream(of: Void.self)
        let watcher = try #require(FileWatcher(paths: [dir.path], latency: 0.1) { continuation.yield() })
        defer { withExtendedLifetime(watcher) {} }
        // FSEvents can miss a write made before the stream settles; write until one is seen.
        let writer = Task {
            for index in 0..<50 where !Task.isCancelled {
                try? Data("\(index)".utf8).write(to: dir.appending(path: "file.txt"))
                try? await Task.sleep(for: .milliseconds(200))
            }
            continuation.finish()
        }
        defer { writer.cancel() }
        var seen = false
        for await _ in events {
            seen = true
            break
        }
        #expect(seen, "no FSEvents change within ten seconds")
    }
}
