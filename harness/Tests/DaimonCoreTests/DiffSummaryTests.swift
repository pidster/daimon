import DaimonTestSupport
import Foundation
import Synchronization
import Testing

@testable import DaimonCore

@Suite struct DiffSummaryTests {
    /// A three-file diff: a modification, an addition, a deletion of a test.
    static let diff = """
        diff --git a/Sources/A.swift b/Sources/A.swift
        index 1111111..2222222 100644
        --- a/Sources/A.swift
        +++ b/Sources/A.swift
        @@ -1,3 +1,4 @@
         let a = 1
        -let b = 2
        +let b = 3
        +let c = 4
        @@ -10,2 +11,2 @@
        -old
        +new
        diff --git a/Sources/New.swift b/Sources/New.swift
        new file mode 100644
        index 0000000..3333333
        --- /dev/null
        +++ b/Sources/New.swift
        @@ -0,0 +1,2 @@
        +import Foundation
        +let token = "abc"
        diff --git a/Tests/OldTests.swift b/Tests/OldTests.swift
        deleted file mode 100644
        index 4444444..0000000
        --- a/Tests/OldTests.swift
        +++ /dev/null
        @@ -1,2 +0,0 @@
        -import Testing
        -@Test func gone() {}
        """

    @Test func readsFilesAndCountsFromTheDiffItself() {
        let files = DiffSummary.files(in: Self.diff)
        #expect(files.map(\.path) == ["Sources/A.swift", "Sources/New.swift", "Tests/OldTests.swift"])
        #expect(files.map(\.change) == ["modified", "added", "deleted"])
        #expect(files.map(\.added) == [3, 2, 0] && files.map(\.removed) == [2, 0, 2])
        #expect(files.allSatisfy { $0.summary == nil })
        let renamed = "diff --git a/x.txt b/y.txt\nsimilarity index 90%\nrename from x.txt\nrename to y.txt\n"
        #expect(
            DiffSummary.files(in: renamed) == [
                .init(path: "y.txt", change: "renamed", added: 0, removed: 0, summary: nil)
            ])
        #expect(DiffSummary.files(in: "not a diff").isEmpty)
        #expect(DiffSummary.sections(of: "").isEmpty)
        #expect(DiffSummary.sections(of: "preamble\n" + Self.diff).count == 4)
    }

    @Test func chunksAtFileThenHunkThenLineBoundaries() {
        let whole = DiffSummary.chunks(Self.diff, maxBytes: 10_000)
        #expect(whole.count == 1)
        let perFile = DiffSummary.chunks(Self.diff, maxBytes: 260)
        #expect(perFile.count == 3)
        #expect(perFile.allSatisfy { $0.hasPrefix("diff --git ") })
        // A file larger than the bound is cut at hunks; the header travels with the first hunk.
        let perHunk = DiffSummary.chunks(Self.diff, maxBytes: 200)
        #expect(perHunk.count >= 4)
        #expect(perHunk[0].hasPrefix("diff --git a/Sources/A.swift") && perHunk[0].contains("@@ -1,3"))
        #expect(perHunk[1].hasPrefix("@@ -10,2"))
        // A hunk larger than the bound falls back to line cuts; nothing is lost.
        let perLine = DiffSummary.chunks(Self.diff, maxBytes: 40)
        #expect(perLine.count > perHunk.count)
        #expect(perLine.joined().filter { $0 != "\n" } == Self.diff.filter { $0 != "\n" })
        #expect(DiffSummary.chunks("", maxBytes: 100).isEmpty)
    }

    @Test func answersAreParsedNormalisedMergedAndValidated() {
        let json = """
            {"headline":" Bumps b and adds a token ","files":[{"path":"b/Sources/A.swift","summary":"b becomes 3"},\
            {"path":"`Sources/New.swift`","summary":"new file with a token"},{"path":"Made/Up.swift","summary":"x"},\
            {"path":"Tests/OldTests.swift","summary":"  "}],"flags":[{"kind":"secret","path":"a/Sources/New.swift",\
            "note":"hard-coded token"},{"kind":"deleted-test","path":"Tests/OldTests.swift","note":"test removed"},\
            {"kind":"large","path":"Nope.swift","note":"phantom"},{"kind":"binary","note":"no path"},{"note":""},\
            {"kind":"other","note":"not a kind"}]}
            """
        let answer = DiffSummary.answer(in: json)
        #expect(answer.headline == "Bumps b and adds a token")
        #expect(
            answer.summaries == [
                "Sources/A.swift": "b becomes 3", "Sources/New.swift": "new file with a token", "Made/Up.swift": "x",
            ])
        #expect(answer.flags.count == 4)
        #expect(
            DiffSummary.answer(in: json, paths: ["D.swift"]).flags[3]
                == .init(kind: "binary", path: "D.swift", note: "no path"))
        let named = DiffSummary.answer(
            in: #"{"flags":[{"kind":"secret","note":"Client.swift holds a key"}]}"#,
            paths: ["A.swift", "Net/Client.swift"])
        #expect(named.flags == [.init(kind: "secret", path: "Net/Client.swift", note: "Client.swift holds a key")])
        #expect(
            DiffSummary.answer(in: #"{"flags":[{"kind":"large","note":"x"}]}"#, paths: ["A", "B"]).flags.first?.path
                == nil)
        #expect(DiffSummary.answer(in: "nope") == .init(headline: nil, summaries: [:], flags: []))
        let files = DiffSummary.files(in: Self.diff)
        let second = DiffSummary.Answer(
            headline: "second",
            summaries: ["Tests/OldTests.swift": "deleted", "Sources/A.swift": "ignored, first wins"],
            flags: [.init(kind: "secret", path: "Sources/New.swift", note: "again")])
        let merged = DiffSummary.merge(files: files, answers: [answer, second], maxFiles: 2)
        #expect(merged.headline == "Bumps b and adds a token")
        #expect(merged.files.map(\.summary) == ["b becomes 3", "new file with a token"])
        #expect(merged.more == 1)
        // A phantom file's flag is dropped; a pathless flag is kept; duplicates collapse.
        #expect(merged.flags.map(\.kind) == ["secret", "deleted-test", "binary"])
        #expect(merged.flags.first?.path == "Sources/New.swift")
    }

    @Test func rulesFlagWhatTheDiffProves() {
        let flags = DiffSummary.ruleFlags(in: Self.diff)
        #expect(flags == [.init(kind: "deleted-test", path: "Tests/OldTests.swift", note: "test file deleted")])
        let secrets = """
            diff --git a/Sources/Client.swift b/Sources/Client.swift
            --- a/Sources/Client.swift
            +++ b/Sources/Client.swift
            @@ -1,2 +1,3 @@
            +    static let apiKey = "sk-live-4f9a2b7c1d8e0f3a6b5c9d2e1f4a7b8c"
            +    let password = "correct horse battery staple"
            diff --git a/Tests/GateTests.swift b/Tests/GateTests.swift
            --- a/Tests/GateTests.swift
            +++ b/Tests/GateTests.swift
            @@ -5,1 +5,1 @@
            -    @Test func denies() async {
            +    @Test(.disabled("flaky")) func denies() async {
            diff --git a/logo.png b/logo.png
            new file mode 100644
            Binary files /dev/null and b/logo.png differ
            diff --git a/Sources/Ok.swift b/Sources/Ok.swift
            --- a/Sources/Ok.swift
            +++ b/Sources/Ok.swift
            @@ -1,1 +1,1 @@
            -let token = value
            +let tokenCount = 3
            """
        let found = DiffSummary.ruleFlags(in: secrets)
        #expect(found.map(\.kind) == ["secret", "deleted-test", "binary"])
        #expect(found[0].path == "Sources/Client.swift" && found[0].note.contains("sk-live"))
        #expect(found[1].path == "Tests/GateTests.swift" && found[1].note.contains(".disabled"))
        #expect(found[2].path == "logo.png")
    }

    @Test func runsEveryChunkAndReports() async throws {
        let prompts = Mutex<[String]>([])
        let summary = DiffSummary(options: .init(chunkBytes: 260, maxFiles: 10)) { prompt in
            prompts.withLock { $0.append(prompt) }
            if prompt.contains("New.swift") {
                // One file in this chunk, so a pathless flag lands on it.
                return
                    #"{"headline":"adds a token","files":[{"path":"Sources/New.swift","summary":"new"}],"flags":[{"kind":"secret","note":"token"}]}"#
            }
            return #"{"headline":"part","files":[],"flags":[]}"#
        }
        let report = try await summary.run(.init(text: Self.diff), from: .command("git diff", workingDirectory: "/r"))
        #expect(report.chunks == 3)
        #expect(
            prompts.withLock { $0 }.first?.contains("part 1 of 3 of a unified diff from the command `git diff`") == true
        )
        #expect(report.files.count == 3 && report.more == 0)
        #expect(report.headline == "part")
        // The rules' deleted-test flag comes first; the model's secret flag follows.
        #expect(
            report.flags == [
                .init(kind: "deleted-test", path: "Tests/OldTests.swift", note: "test file deleted"),
                .init(kind: "secret", path: "Sources/New.swift", note: "token"),
            ])
        let json = report.json.objectValue
        #expect(json?["added"] == 5 && json?["removed"] == 4)
        #expect(json?["files"]?.arrayValue?[1].objectValue?["summary"] == "new")
        #expect(json?["files"]?.arrayValue?[0].objectValue?["summary"] == .null)
        #expect(json?["source"]?.objectValue?["command"] == "git diff")
        #expect(
            report.rendered.hasPrefix(
                "3 files, +5 -4\npart\nFLAG deleted-test\tTests/OldTests.swift\ttest file deleted\nFLAG secret"))
        let empty = try await DiffSummary { _ in "{}" }.run(.init(text: "", truncated: true), from: .path("/d"))
        #expect(empty.chunks == 0 && empty.rendered == "0 files, +0 -0; diff truncated to its tail")
        let failing = DiffSummary { _ in throw ModelSelection.Failure.unknownModel("x") }
        await #expect(throws: ModelSelection.Failure.self) {
            try await failing.run(.init(text: Self.diff), from: .path("/d"))
        }
        // Capture is the shared one.
        let dir = FileManager.default.temporaryDirectory.appending(path: "daimon-diff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "x.diff")
        try Data(Self.diff.utf8).write(to: file)
        let captured = try await summary.capture(.path(file.path), runner: CommandRunner(), gate: nil)
        #expect(captured.text == Self.diff && !captured.truncated)
    }
}
