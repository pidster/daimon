import Foundation
import Testing

@testable import WispCore

/// Whether the configured model's commit subjects name what a change is about. Needs the model
/// (`scripts/check eval`). The shape rules (length, capital, no trailing period) are applied in code, so
/// the eval measures content: a pass is a subject containing one of the words a reviewer would expect.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["WISP_MODEL_TESTS"] != nil))
struct DraftEvalTests {
    struct Fixture {
        let name: String
        let diff: String
        /// Any one of these, case-insensitively, in the subject.
        let words: [String]
    }

    static let fixtures: [Fixture] = [
        Fixture(
            name: "retry",
            diff: """
                diff --git a/Sources/Upload.swift b/Sources/Upload.swift
                --- a/Sources/Upload.swift
                +++ b/Sources/Upload.swift
                @@ -10,6 +10,14 @@ struct Uploader {
                     func send(_ data: Data) async throws {
                -        try await client.post(data)
                +        var attempt = 0
                +        while true {
                +            do { return try await client.post(data) } catch where attempt < 2 {
                +                attempt += 1
                +                try await Task.sleep(for: .seconds(attempt))
                +            }
                +        }
                     }
                """, words: ["retry", "retries", "retrying"]),
        Fixture(
            name: "timeout default",
            diff: """
                diff --git a/Sources/Config.swift b/Sources/Config.swift
                --- a/Sources/Config.swift
                +++ b/Sources/Config.swift
                @@ -3,3 +3,3 @@ struct Config {
                -    var timeoutSeconds = 30
                +    var timeoutSeconds = 120
                """, words: ["timeout", "time out"]),
        Fixture(
            name: "new flag",
            diff: """
                diff --git a/Sources/CLI.swift b/Sources/CLI.swift
                --- a/Sources/CLI.swift
                +++ b/Sources/CLI.swift
                @@ -8,4 +8,7 @@ struct List: ParsableCommand {
                     @Flag var all = false
                +    /// Print JSON instead of text.
                +    @Flag(name: .long, help: "Print JSON.") var json = false
                     func run() throws {
                -        print(items.map(\\.name).joined(separator: "\\n"))
                +        print(json ? encode(items) : items.map(\\.name).joined(separator: "\\n"))
                """, words: ["json"]),
        Fixture(
            name: "bug fix",
            diff: """
                diff --git a/Sources/Paging.swift b/Sources/Paging.swift
                --- a/Sources/Paging.swift
                +++ b/Sources/Paging.swift
                @@ -20,3 +20,3 @@ func page(_ items: [Item], number: Int, size: Int) -> [Item] {
                -    let start = number * size + 1
                +    let start = number * size
                     return Array(items[start..<min(start + size, items.count)])
                """, words: ["off-by-one", "off by one", "page", "paging", "pagination", "first item", "start"]),
        Fixture(
            name: "docs only",
            diff: """
                diff --git a/README.md b/README.md
                --- a/README.md
                +++ b/README.md
                @@ -12,2 +12,6 @@ ## Install
                 brew install tool
                +
                +## Configuration
                +
                +Settings live in `~/.tool/config.json`; `tool config` prints the effective values.
                """, words: ["config", "configuration", "readme", "document", "docs"]),
    ]

    @Test func subjectsNameWhatTheChangeIsAbout() async throws {
        let model = try ModelSelection.default.resolve()
        let instructions = Prompting().rendered(toolsAvailable: false)
        let summarySchema = try OutputSchema(json: DiffSummary.schemaJSON)
        let draftSchema = try OutputSchema(json: ChangeDraft.schemaJSON)
        let attempts = 2
        var passed = 0
        for (round, fixture) in (1...attempts).flatMap({ round in Self.fixtures.map { (round, $0) } }) {
            let draft = try await ChangeDraft.draft(
                .commit, from: .init(text: fixture.diff), source: .path(fixture.name),
                summarise: {
                    try await Agent(instructions: instructions, tools: [], model: model).respond(
                        to: $0, schema: summarySchema
                    )
                    .text
                },
                write: {
                    try await Agent(instructions: instructions, tools: [], model: model).respond(
                        to: $0, schema: draftSchema
                    )
                    .text
                })
            let lower = draft.subject.lowercased()
            let ok = fixture.words.contains { lower.contains($0) }
            if ok { passed += 1 }
            print("draft eval: #\(round) \(fixture.name): \(ok ? "pass" : "FAIL") \(draft.subject)")
        }
        let total = Self.fixtures.count * attempts
        try? Measurements.report(
            Measurement(
                task: "draft_change.commit", model: model.selection.description, passed: passed, total: total,
                notes: "commit subjects for five small diffs (a retry loop, a default changed, a new flag, an "
                    + "off-by-one fix, a docs addition), twice each; a pass is a subject naming what the change is about"
            ))
        #expect(passed * 2 >= total, "draft subjects passed \(passed)/\(total)")
    }
}
