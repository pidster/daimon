import DaimonTestSupport
import Foundation
import Synchronization
import Testing

@testable import DaimonCore

@Suite struct TriageTests {
    @Test func chunksCutAtLineEndsWithinTheBound() {
        let text = "aaaa\nbbbb\ncccc\ndddd"
        #expect(Triage.chunks(text, maxBytes: 9) == ["aaaa\nbbbb", "cccc\ndddd"])
        #expect(Triage.chunks(text, maxBytes: 100) == [text])
        #expect(Triage.chunks("", maxBytes: 9).isEmpty)
        #expect(Triage.chunks("\n\n", maxBytes: 9).isEmpty)
        // A line longer than the bound is cut mid-line; what follows starts a new chunk.
        #expect(Triage.chunks("abcdefghijkl\nxy", maxBytes: 5) == ["abcde", "fghij", "kl\nxy"])
        // Multi-byte text is measured in bytes, never split inside a character.
        let accented = "éé\néé"
        #expect(Triage.chunks(accented, maxBytes: 4) == ["éé", "éé"])
    }

    @Test func findingsAreParsedMergedDedupedAndCapped() {
        let json =
            #"{"failures":[{"kind":"error","location":" A.swift:1 ","message":"bad"},{"kind":"other","message":"  "},{"message":"no kind","location":""},7]}"#
        let parsed = Triage.findings(in: json)
        #expect(
            parsed == [
                .init(kind: "error", location: "A.swift:1", message: "bad"),
                .init(kind: "other", location: nil, message: "no kind"),
            ])
        #expect(Triage.findings(in: "not json").isEmpty)
        #expect(Triage.findings(in: #"{"failures":"x"}"#).isEmpty)
        let a = Triage.Finding(kind: "error", location: "a.swift:1", message: "Bad thing")
        let same = Triage.Finding(kind: "error", location: "A.swift:1", message: "bad thing ")
        let b = Triage.Finding(kind: "test-failure", location: nil, message: "x")
        let merged = Triage.merge([[a, b], [same, b, a]], max: 1)
        #expect(merged.findings == [a] && merged.more)
        let all = Triage.merge([[a], [same, b]], max: 10)
        #expect(all.findings == [a, b] && !all.more)
    }

    @Test func runsEveryChunkThroughTheJudgeAndReports() async throws {
        let prompts = Mutex<[String]>([])
        let triage = Triage(options: .init(chunkBytes: 12, maxFindings: 5)) { prompt in
            prompts.withLock { $0.append(prompt) }
            let n = prompts.withLock { $0.count }
            return #"{"failures":[{"kind":"error","location":"f.swift:\#(n)","message":"m\#(n)"}]}"#
        }
        let captured = Triage.Captured(text: "line one\nline two\nline three", exitStatus: 1)
        let report = try await triage.run(captured, from: .command("make", workingDirectory: "/w"))
        #expect(report.chunks == 3)
        #expect(report.findings.map(\.location) == ["f.swift:1", "f.swift:2", "f.swift:3"])
        #expect(!report.more)
        let sent = prompts.withLock { $0 }
        #expect(sent.first?.contains("part 1 of 3 of the output of the command `make`") == true)
        #expect(sent.first?.hasSuffix("OUTPUT:\nline one") == true)
        let json = report.json.objectValue
        #expect(json?["source"]?.objectValue?["command"] == "make")
        #expect(json?["source"]?.objectValue?["workingDirectory"] == "/w")
        #expect(json?["source"]?.objectValue?["exitStatus"] == 1)
        #expect(json?["source"]?.objectValue?["bytes"] == .int(captured.text.utf8.count))
        #expect(json?["findings"]?.arrayValue?.count == 3)
        #expect(report.rendered.hasPrefix("exit status 1; 3 findings; 28 bytes in 3 chunks\nerror\tf.swift:1\tm1\n"))
        // A file source, no findings, truncated.
        let empty = Triage { _ in #"{"failures":[]}"# }
        let file = try await empty.run(.init(text: "ok\n", truncated: true), from: .path("/tmp/log"))
        #expect(file.findings.isEmpty && file.chunks == 1)
        #expect(file.rendered == "0 findings; 3 bytes in 1 chunk; output truncated to its tail")
        #expect(file.json.objectValue?["source"]?.objectValue?["path"] == "/tmp/log")
        #expect(file.json.objectValue?["source"]?.objectValue?["exitStatus"] == .null)
        // A judge failure fails the triage.
        let failing = Triage { _ in throw ModelSelection.Failure.unknownModel("x") }
        await #expect(throws: ModelSelection.Failure.self) { try await failing.run(captured, from: .path("/p")) }
        // Nothing to read means no judging at all.
        let none = try await failing.run(.init(text: ""), from: .path("/p"))
        #expect(none.chunks == 0 && none.rendered == "0 findings; 0 bytes in 0 chunks")
    }

    @Test func capturesACommandsOutputThroughTheRunnerAndAFileThroughTheGate() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "daimon-triage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = MemoryAuditSink()
        let audit = AuditLog(session: "t", sink: sink)
        let runner = CommandRunner(options: .init(writableRoot: dir.path, maxOutputBytes: 10), audit: audit)
        let triage = Triage(options: .init(maxOutputBytes: 64)) { _ in "{}" }
        // The runner's cap is raised to the triage's for the run; stdout then stderr are joined.
        let captured = try await triage.capture(
            .command("echo out; echo err 1>&2; exit 3", workingDirectory: dir.path), runner: runner, gate: nil)
        #expect(captured == .init(text: "out\nerr\n", exitStatus: 3, timedOut: false, truncated: false))
        #expect(sink.events.contains { $0.kind == .commandOutcome })
        let long = String(repeating: "x", count: 100)
        let file = dir.appending(path: "log.txt")
        try Data(long.utf8).write(to: file)
        let read = try await triage.capture(.path(file.path), runner: runner, gate: nil)
        #expect(read.text.count == 64 && read.truncated && read.exitStatus == nil)
        // A denying gate refuses the read as it would for read_file.
        let gate = ApprovalGate(
            classifier: RuleRiskClassifier.standard, approver: DenyingApprover(reason: "no"), threshold: .level(.safe),
            audit: audit)
        await #expect(throws: ApprovalGate.Failure.self) {
            try await triage.capture(.path(file.path), runner: runner, gate: gate)
        }
        await #expect(throws: (any Error).self) {
            try await triage.capture(.path(dir.appending(path: "missing").path), runner: runner, gate: nil)
        }
    }
}
