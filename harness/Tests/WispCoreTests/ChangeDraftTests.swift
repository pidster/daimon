import Foundation
import Testing

@testable import WispCore

@Suite struct ChangeDraftTests {
    static let report = DiffSummary.Report(
        source: .command("git diff --cached", workingDirectory: nil), captured: .init(text: "diff"), chunks: 1,
        files: [
            .init(path: "CHANGELOG.md", change: "modified", added: 2, removed: 0, summary: "notes the retry"),
            .init(path: "Tests/UploadTests.swift", change: "modified", added: 10, removed: 0, summary: "tests retry"),
            .init(path: "Sources/Upload.swift", change: "modified", added: 12, removed: 3, summary: "retries twice"),
        ], more: 0, headline: "Adds retry to uploads",
        flags: [.init(kind: "secret", path: "Sources/Upload.swift", note: "credential added (openai-key): sk-…")])

    @Test func subjectsAreOneCapitalisedLineUnder72WithoutAPeriod() {
        #expect(ChangeDraft.subject("  add retry\nto uploads. ") == "Add retry to uploads")
        let long = ChangeDraft.subject(String(repeating: "word ", count: 30))
        #expect(long.count <= ChangeDraft.subjectLimit && !long.hasSuffix(" ") && long.hasPrefix("Word"))
        #expect(ChangeDraft.subject(String(repeating: "x", count: 90)).count == 72)
        let hanging = ChangeDraft.subject(
            "Update AGENTS.md, CHANGELOG.md, and CLAUDE.md with new tools and the drafting commands")
        #expect(hanging == "Update AGENTS.md, CHANGELOG.md, and CLAUDE.md with new tools", "\(hanging)")
        #expect(ChangeDraft.oneLine(" a \n b\tc ") == "a b c")
    }

    @Test func bodiesWrapAndFilesAreOrderedCodeThenTestsThenDocs() {
        let wrapped = ChangeDraft.wrap(String(repeating: "abcdefghi ", count: 12), width: 40, first: "- ", rest: "  ")
        #expect(wrapped.count > 1 && wrapped.allSatisfy { $0.count <= 40 } && wrapped[0].hasPrefix("- "))
        #expect(wrapped.dropFirst().allSatisfy { $0.hasPrefix("  ") })
        #expect(
            ChangeDraft.ordered(Self.report.files).map(\.path) == [
                "Sources/Upload.swift", "Tests/UploadTests.swift", "CHANGELOG.md",
            ])
        #expect(ChangeDraft.role(of: "docs/mcp.md") == 2 && ChangeDraft.role(of: "harness/Tests/A.swift") == 1)
        let prompt = ChangeDraft.prompt(.commit, from: Self.report)
        #expect(
            !prompt.contains("Overall:") && prompt.contains("Flag secret: Sources/Upload.swift"))
        #expect(prompt.range(of: "Sources/Upload.swift (")!.lowerBound < prompt.range(of: "CHANGELOG.md (")!.lowerBound)
    }

    @Test func eachKindAsksForItsOwnText() {
        #expect(ChangeDraft.prompt(.commit, from: Self.report).hasPrefix("Write a git commit message"))
        #expect(ChangeDraft.prompt(.pr, from: Self.report).hasPrefix("Write a pull request"))
        #expect(ChangeDraft.prompt(.changelog, from: Self.report).hasPrefix("Write one changelog line"))
    }

    @Test func eachKindTakesItsShape() {
        let answer = #"{"subject":"add retry to uploads.","points":["Retries a failed upload twice", "  "]}"#
        let commit = ChangeDraft.draft(.commit, answer: answer, report: Self.report)
        #expect(
            commit.text == "Add retry to uploads\n\n- Retries a failed upload twice\n\n\(ChangeDraft.whyPlaceholder)")
        let pr = ChangeDraft.draft(.pr, answer: answer, report: Self.report)
        #expect(
            pr.text.hasPrefix("Add retry to uploads\n\n- Retries a failed upload twice\n\nReview flags:\n- secret in"))
        #expect(pr.body.last == "Files: `CHANGELOG.md`, `Tests/UploadTests.swift`, `Sources/Upload.swift`")
        let changelog = ChangeDraft.draft(
            .changelog, answer: #"{"subject":"Uploads retry.","points":[]}"#, report: Self.report)
        #expect(changelog.text == "- Uploads retry." && changelog.body.isEmpty)
        // A malformed answer falls back to the summary's headline.
        let fallback = ChangeDraft.draft(.commit, answer: "not json", report: Self.report)
        #expect(fallback.subject == "Adds retry to uploads" && fallback.body == [ChangeDraft.whyPlaceholder])
        #expect(commit.json.objectValue?["kind"] == "commit" && pr.flags.count == 1)
    }

    @Test func aDraftSummarisesThenWritesAndRefusesAnEmptyDiff() async throws {
        let diff = """
            diff --git a/Sources/Upload.swift b/Sources/Upload.swift
            --- a/Sources/Upload.swift
            +++ b/Sources/Upload.swift
            @@ -1,1 +1,2 @@
             func upload() {
            +    retry(2)
            """
        let prompts = PromptLog()
        let draft = try await ChangeDraft.draft(
            .commit, from: .init(text: diff), source: .path("x.diff"),
            summarise: { prompt in
                prompts.append(prompt)
                return
                    #"{"headline":"Adds retry","files":[{"path":"Sources/Upload.swift","summary":"retries"}],"flags":[]}"#
            },
            write: { prompt in
                prompts.append(prompt)
                return #"{"subject":"Retry failed uploads","points":["Calls retry twice"]}"#
            })
        #expect(draft.subject == "Retry failed uploads" && prompts.all.count == 2)
        #expect(prompts.all[1].contains("- Sources/Upload.swift (modified, +1 -0): retries"), "\(prompts.all[1])")
        await #expect(throws: ChangeDraft.Failure.emptyDiff) {
            try await ChangeDraft.draft(
                .pr, from: .init(text: " \n"), source: .path("x"), summarise: { _ in "" }, write: { _ in "" })
        }
        #expect(ChangeDraft.Failure.emptyDiff.description.hasPrefix("nothing to describe"))
    }
}
