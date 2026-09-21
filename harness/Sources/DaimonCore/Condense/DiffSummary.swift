import Foundation

/// Turns a diff into a per-file summary with risk flags, keeping the diff on this Mac
/// ([ADR 0023](../../../../docs/decisions/0023-condensing-tools.md)). The second condensing tool.
///
/// The diff is captured whole (bounded), cut at file boundaries into chunks a small model can read,
/// and each chunk is judged in a fresh, tool-less turn with a schema. The file list, line counts, and
/// the flags the text proves (a deleted or disabled test, a credential literal, binary content) come
/// from the diff itself, deterministically; the model adds the one-line summaries, the headline, and
/// flags the rules miss, and anything it says about a file the diff does not contain is dropped.
public struct DiffSummary: Sendable {
    /// Knobs for one summary.
    public struct Options: Equatable, Sendable {
        /// Bytes per chunk shown to the model; cut at file, then hunk, then line boundaries.
        public var chunkBytes: Int
        /// Files kept in the result; the rest is counted in `more`.
        public var maxFiles: Int
        /// Bytes of diff captured; only the tail beyond this.
        public var maxOutputBytes: Int

        /// Creates options; the defaults suit a model with a 4k-token window.
        public init(chunkBytes: Int = 4096, maxFiles: Int = 40, maxOutputBytes: Int = 1 << 20) {
            self.chunkBytes = chunkBytes
            self.maxFiles = maxFiles
            self.maxOutputBytes = maxOutputBytes
        }
    }

    /// One file in the diff.
    public struct FileChange: Equatable, Sendable {
        /// The path after the change (before it, for a deletion).
        public var path: String
        /// `added`, `modified`, `deleted`, or `renamed`, from the diff headers.
        public var change: String
        /// Lines added, from the hunks.
        public var added: Int
        /// Lines removed, from the hunks.
        public var removed: Int
        /// The model's one line about what changed; nil when it said nothing about this file.
        public var summary: String?
    }

    /// Something in the diff a reviewer should see first.
    public struct Flag: Equatable, Sendable {
        /// `deleted-test`, `secret`, `binary`, `generated`, or `large`.
        public var kind: String
        /// The file it concerns, when one.
        public var path: String?
        /// Why, in one line.
        public var note: String
    }

    /// The result of a summary.
    public struct Report: Equatable, Sendable {
        /// What was summarised.
        public var source: Triage.Source
        /// How the diff was captured.
        public var captured: Triage.Captured
        /// How many chunks the model judged.
        public var chunks: Int
        /// The files, in diff order, capped at `maxFiles`.
        public var files: [FileChange]
        /// Files in the diff beyond the cap.
        public var more: Int
        /// The model's headline for the whole change.
        public var headline: String?
        /// Flags, deduplicated by kind and path.
        public var flags: [Flag]

        /// The report as JSON, the shape the MCP tool returns (`docs/mcp.md`).
        public var json: JSONValue {
            var source: [String: JSONValue]
            switch self.source {
            case .command(let line, let directory):
                source = ["command": .string(line), "workingDirectory": directory.map { .string($0) } ?? .null]
            case .path(let path):
                source = ["path": .string(path)]
            }
            source["exitStatus"] = captured.exitStatus.map { .int(Int($0)) } ?? .null
            source["truncated"] = .bool(captured.truncated)
            source["bytes"] = .int(captured.text.utf8.count)
            return .object([
                "source": .object(source), "chunks": .int(chunks), "more": .int(more),
                "headline": headline.map { .string($0) } ?? .null,
                "added": .int(files.reduce(0) { $0 + $1.added }), "removed": .int(files.reduce(0) { $0 + $1.removed }),
                "files": .array(
                    files.map {
                        .object([
                            "path": .string($0.path), "change": .string($0.change), "added": .int($0.added),
                            "removed": .int($0.removed), "summary": $0.summary.map { .string($0) } ?? .null,
                        ])
                    }),
                "flags": .array(
                    flags.map {
                        .object([
                            "kind": .string($0.kind), "path": $0.path.map { .string($0) } ?? .null,
                            "note": .string($0.note),
                        ])
                    }),
            ])
        }

        /// The report as lines: a headline, a flag per line, then a file per line.
        public var rendered: String {
            let added = files.reduce(0) { $0 + $1.added }
            let removed = files.reduce(0) { $0 + $1.removed }
            var lines = [
                "\(files.count + more) file\(files.count + more == 1 ? "" : "s"), +\(added) -\(removed)"
                    + (more > 0 ? "; \(more) not shown" : "")
                    + (captured.truncated ? "; diff truncated to its tail" : "")
            ]
            if let headline { lines.append(headline) }
            for flag in flags { lines.append("FLAG \(flag.kind)\t\(flag.path ?? "-")\t\(flag.note)") }
            for file in files {
                lines.append("\(file.change)\t\(file.path)\t+\(file.added) -\(file.removed)\t\(file.summary ?? "")")
            }
            return lines.joined(separator: "\n")
        }
    }

    /// Answers one chunk's prompt with JSON of `schemaJSON`'s shape.
    public typealias Judge = @Sendable (String) async throws -> String

    /// The shape each chunk's answer must take.
    public static let schemaJSON: JSONValue = [
        "type": "object",
        "properties": [
            "headline": ["type": "string", "description": "What this part of the change does, in one sentence"],
            "files": [
                "type": "array", "maxItems": 20,
                "items": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "The file path exactly as in the diff header"],
                        "summary": ["type": "string", "description": "What changed in this file, in one line"],
                    ],
                    "required": ["path", "summary"],
                ],
            ],
            "flags": [
                "type": "array", "maxItems": 10,
                "items": [
                    "type": "object",
                    "properties": [
                        "kind": [
                            "type": "string",
                            "enum": ["deleted-test", "secret", "binary", "generated", "large"],
                            "description":
                                "A test removed or disabled; a password, key, token, or credential value written into code; binary or generated content; a very large change",
                        ],
                        "path": ["type": "string", "description": "The file concerned, as in the diff header"],
                        "note": ["type": "string", "description": "Why, in one line"],
                    ],
                    "required": ["kind", "note"],
                ],
            ],
        ],
        "required": ["headline", "files", "flags"],
    ]

    /// The options in force.
    public let options: Options
    private let judge: Judge

    /// Creates a summary that judges chunks with `judge`.
    ///
    /// - Parameters:
    ///   - options: Chunk size and caps.
    ///   - judge: Answers a chunk's prompt with JSON of the schema's shape; a fresh model turn each time.
    public init(options: Options = Options(), judge: @escaping Judge) {
        self.options = options
        self.judge = judge
    }

    /// The per-file sections of a unified diff, each starting at its `diff --git` line, in order.
    /// Text before the first header is one section of its own.
    public static func sections(of diff: String) -> [String] {
        var sections: [String] = []
        var current = ""
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git "), !current.isEmpty {
                sections.append(current)
                current = ""
            }
            if !current.isEmpty { current += "\n" }
            current += line
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { sections.append(current) }
        return sections
    }

    /// Cuts the diff into chunks of at most `maxBytes`: whole files while they fit, a file larger than
    /// that at hunk boundaries, and a hunk larger than that at line ends.
    public static func chunks(_ diff: String, maxBytes: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty { chunks.append(current) }
            current = ""
        }
        for section in sections(of: diff) {
            if section.utf8.count > maxBytes {
                flush()
                // The header travels with the first hunk; later hunks start at their own `@@`.
                var hunks = section.components(separatedBy: "\n@@").enumerated().map {
                    $0.offset == 0 ? $0.element : "@@" + $0.element
                }
                if hunks.count > 1 { hunks.replaceSubrange(0...1, with: [hunks[0] + "\n" + hunks[1]]) }
                for hunk in hunks {
                    if hunk.utf8.count > maxBytes {
                        flush()
                        chunks += Triage.chunks(hunk, maxBytes: maxBytes)
                    } else if current.utf8.count + hunk.utf8.count + 1 > maxBytes {
                        flush()
                        current = hunk
                    } else {
                        current += current.isEmpty ? hunk : "\n" + hunk
                    }
                }
                flush()
            } else if current.utf8.count + section.utf8.count + 1 > maxBytes {
                flush()
                current = section
            } else {
                current += current.isEmpty ? section : "\n" + section
            }
        }
        flush()
        return chunks
    }

    /// The files in a diff with their change kind and line counts, from the headers and hunks alone.
    public static func files(in diff: String) -> [FileChange] {
        var files: [FileChange] = []
        for section in sections(of: diff) where section.hasPrefix("diff --git ") {
            let lines = section.split(separator: "\n", omittingEmptySubsequences: false)
            guard let header = lines.first else { continue }
            let parts = header.dropFirst("diff --git ".count).split(separator: " ", maxSplits: 1)
            let before = parts.first.map { String($0).hasPrefix("a/") ? String($0.dropFirst(2)) : String($0) } ?? ""
            let after =
                parts.count > 1
                ? (String(parts[1]).hasPrefix("b/") ? String(parts[1].dropFirst(2)) : String(parts[1])) : before
            var change = "modified"
            var added = 0
            var removed = 0
            var inHunk = false
            for line in lines.dropFirst() {
                if line.hasPrefix("@@") { inHunk = true; continue }
                if !inHunk {
                    if line.hasPrefix("new file mode") { change = "added" }
                    if line.hasPrefix("deleted file mode") { change = "deleted" }
                    if line.hasPrefix("rename from") || line.hasPrefix("similarity index") { change = "renamed" }
                    continue
                }
                if line.hasPrefix("+"), !line.hasPrefix("+++") { added += 1 }
                if line.hasPrefix("-"), !line.hasPrefix("---") { removed += 1 }
            }
            files.append(
                FileChange(path: change == "deleted" ? before : after, change: change, added: added, removed: removed))
        }
        return files
    }

    /// Flags the diff text itself proves, found without the model: a deleted or disabled test, a
    /// credential literal on an added line, binary content. The model's flags are added to these,
    /// never instead of them, as the rules and the model classifier combine for commands.
    public static func ruleFlags(in diff: String) -> [Flag] {
        var flags: [Flag] = []
        for section in sections(of: diff) where section.hasPrefix("diff --git ") {
            guard let file = files(in: section).first else { continue }
            let path = file.path
            let lower = path.lowercased()
            let isTest = lower.contains("test") || lower.contains("spec")
            if file.change == "deleted", isTest {
                flags.append(Flag(kind: "deleted-test", path: path, note: "test file deleted"))
            }
            if section.contains("\nBinary files ") || section.contains("\nGIT binary patch") {
                flags.append(Flag(kind: "binary", path: path, note: "binary content"))
            }
            for line in section.split(separator: "\n") where line.hasPrefix("+") && !line.hasPrefix("+++") {
                let added = line.dropFirst()
                if isTest, disabledTest.contains(where: { added.contains($0) }) {
                    flags.append(
                        Flag(
                            kind: "deleted-test", path: path,
                            note: "test disabled: \(added.trimmingCharacters(in: .whitespaces).prefix(80))"))
                    break
                }
            }
            for line in section.split(separator: "\n") where line.hasPrefix("+") && !line.hasPrefix("+++") {
                let added = String(line.dropFirst())
                if secretPatterns.contains(where: {
                    added.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil
                }) {
                    flags.append(
                        Flag(
                            kind: "secret", path: path,
                            note: "credential literal added: \(added.trimmingCharacters(in: .whitespaces).prefix(60))"))
                    break
                }
            }
        }
        return flags
    }

    /// Added text in a test file that turns a test off.
    static let disabledTest = [
        ".disabled(", "@Test(.disabled", "XCTSkip", "xit(", "xdescribe(", "it.skip(", "describe.skip(",
        "@pytest.mark.skip",
        "@unittest.skip", "#[ignore]", "t.Skip(",
    ]

    /// Credential shapes on one line: known key prefixes, private key blocks, or a secret-named
    /// assignment of a long literal.
    static let secretPatterns = [
        #"\b(sk-[a-z]+-|sk-|AKIA|ghp_|gho_|xox[bpa]-|AIza)[A-Za-z0-9_\-]{12,}"#,
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#,
        #"(api[_-]?key|secret|token|password|passwd|credential)\w*\s*[:=]\s*["'][^"']{12,}["']"#,
    ]

    /// The prompt for one chunk.
    public static func prompt(chunk: String, index: Int, count: Int, label: String) -> String {
        """
        Below is part \(index) of \(count) of a unified diff from \(label). Give a one-sentence headline for what \
        this part does, one line per file saying what changed in it (path exactly as in its diff header), and a \
        flag only for these: a test deleted or disabled; a password, API key, token, or other credential value \
        written into code; binary or generated content; a very large change. Most changes need no flag; an empty \
        flags list is the right answer for an ordinary change, and never a flag saying there is no concern.

        DIFF:
        \(chunk)
        """
    }

    /// One chunk's parsed answer; anything malformed reads as nothing.
    public struct Answer: Equatable, Sendable {
        /// The headline, if any.
        public var headline: String?
        /// Summaries by path.
        public var summaries: [String: String]
        /// The flags.
        public var flags: [Flag]
    }

    /// Reads a chunk's JSON answer. The model often gives a flag's kind and not its file: a pathless
    /// flag lands on the file its note names among `paths` (the chunk's files), or on the only one.
    public static func answer(in json: String, paths: [String] = []) -> Answer {
        guard let data = json.data(using: .utf8), let value = try? JSONDecoder().decode(JSONValue.self, from: data),
            let object = value.objectValue
        else { return Answer(headline: nil, summaries: [:], flags: []) }
        var summaries: [String: String] = [:]
        for item in object["files"]?.arrayValue ?? [] {
            guard let fields = item.objectValue, let path = fields["path"]?.stringValue,
                let summary = fields["summary"]?.stringValue, !summary.trimmingCharacters(in: .whitespaces).isEmpty
            else { continue }
            summaries[Self.normalised(path)] = summary
        }
        let flags = (object["flags"]?.arrayValue ?? []).compactMap { item -> Flag? in
            guard let fields = item.objectValue, let note = fields["note"]?.stringValue,
                !note.trimmingCharacters(in: .whitespaces).isEmpty
            else { return nil }
            guard let kind = fields["kind"]?.stringValue, Self.flagKinds.contains(kind) else { return nil }
            let path = fields["path"]?.stringValue.map(Self.normalised).flatMap { $0.isEmpty ? nil : $0 }
            // A pathless flag lands on the chunk's only file, or on the file its note names.
            let named = paths.first { path in
                let name = path.split(separator: "/").last.map(String.init) ?? path
                return note.contains(name)
            }
            return Flag(kind: kind, path: path ?? named ?? (paths.count == 1 ? paths[0] : nil), note: note)
        }
        let headline = object["headline"]?.stringValue?.trimmingCharacters(in: .whitespaces)
        return Answer(headline: headline?.isEmpty == false ? headline : nil, summaries: summaries, flags: flags)
    }

    /// The flag kinds the schema allows; anything else the model writes is dropped.
    static let flagKinds: Set<String> = ["deleted-test", "secret", "binary", "generated", "large"]

    /// A path as the model may write it, brought to the diff's spelling: no `a/` or `b/` prefix, no
    /// surrounding quotes or whitespace.
    static func normalised(_ path: String) -> String {
        var path = path.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(
            in: CharacterSet(charactersIn: "`'\""))
        if path.hasPrefix("a/") || path.hasPrefix("b/") { path = String(path.dropFirst(2)) }
        return path
    }

    /// Joins chunk answers onto the diff's own file list: summaries attach by path (a summary for a
    /// path not in the diff is dropped), flags are deduplicated, the first headline is kept, and the
    /// file list is capped.
    public static func merge(
        files: [FileChange], answers: [Answer], maxFiles: Int
    ) -> (
        files: [FileChange], more: Int, headline: String?, flags: [Flag]
    ) {
        var merged = files
        var flags: [Flag] = []
        var seen: Set<String> = []
        var headline: String?
        for answer in answers {
            if headline == nil { headline = answer.headline }
            for index in merged.indices where merged[index].summary == nil {
                if let summary = answer.summaries[merged[index].path] { merged[index].summary = summary }
            }
            for flag in answer.flags where seen.insert("\(flag.kind)|\(flag.path ?? "")").inserted {
                if let path = flag.path, !files.contains(where: { $0.path == path }) { continue }
                flags.append(flag)
            }
        }
        let kept = Array(merged.prefix(maxFiles))
        return (kept, max(0, merged.count - maxFiles), headline, flags)
    }

    /// Judges every chunk of `captured` and merges the answers onto the diff's file list.
    ///
    /// - Parameters:
    ///   - captured: The diff, however it was obtained.
    ///   - source: What it came from, for the prompt and the report.
    /// - Returns: The report.
    /// - Throws: Whatever the judge throws; one failed chunk fails the summary.
    public func run(_ captured: Triage.Captured, from source: Triage.Source) async throws -> Report {
        let pieces = Self.chunks(captured.text, maxBytes: options.chunkBytes)
        var answers: [Answer] = []
        for (index, piece) in pieces.enumerated() {
            let reply = try await judge(
                Self.prompt(chunk: piece, index: index + 1, count: pieces.count, label: source.label))
            answers.append(Self.answer(in: reply, paths: Self.files(in: piece).map(\.path)))
        }
        let rules = Answer(headline: nil, summaries: [:], flags: Self.ruleFlags(in: captured.text))
        let merged = Self.merge(
            files: Self.files(in: captured.text), answers: [rules] + answers, maxFiles: options.maxFiles)
        return Report(
            source: source, captured: captured, chunks: pieces.count, files: merged.files, more: merged.more,
            headline: merged.headline, flags: merged.flags)
    }

    /// Obtains the diff for `source` through the shared capture (`Triage.capture`).
    ///
    /// - Throws: `CommandRunner.Failure`, `ApprovalGate.Failure`, or a file error.
    public func capture(
        _ source: Triage.Source, runner: CommandRunner, gate: ApprovalGate?
    ) async throws -> Triage.Captured {
        try await Triage.capture(source, runner: runner, gate: gate, maxOutputBytes: options.maxOutputBytes)
    }
}
