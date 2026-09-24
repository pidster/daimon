import Foundation

/// Drafts a commit message, a pull request description, or a changelog line from a diff's summary
/// (`DiffSummary.Report`), for `draft_change` and `wisp draft`. The model composes in one fresh,
/// schema-shaped turn over the summary, never the raw diff, so the prompt is small whatever the diff's
/// size; the shape rules a reviewer expects (a subject of at most 72 characters without a trailing
/// period, a body wrapped at 72) are applied here, not left to the model
/// ([ADR 0035](../../../../docs/decisions/0035-change-drafts.md)).
///
/// A diff says what changed, not why. The draft says what; the commit body ends with a line for the author
/// to replace with the reason, rather than a reason the model would have to invent.
public struct ChangeDraft: Sendable {
    /// What to draft.
    public enum Kind: String, Sendable, CaseIterable {
        /// A commit message: a subject and a body.
        case commit
        /// A pull request: a title and a description.
        case pr
        /// One line for a changelog's unreleased section.
        case changelog
    }

    /// The measured task every kind routes on: summarising the diff is the costly, shared step, and the
    /// commit eval measures it ([ADR 0037](../../../../docs/decisions/0037-routing-by-input-size.md)).
    public static let routingTask = "draft_change.commit"

    /// The model to draft with: the caller's when it named one, else the ladder's choice for this input's
    /// size, else nil for the conversation's own.
    ///
    /// - Parameters:
    ///   - explicit: The model the caller asked for, which always wins.
    ///   - inputBytes: The diff's size.
    ///   - ladder: The configured ladder; empty turns routing off.
    ///   - measurements: What the eval recorded; the embedded set by default.
    ///   - opens: Whether a model can be opened here, nil when it can; a model that cannot (Ollama not
    ///     running) is passed over for the ladder's first, with the reason kept.
    /// - Returns: The decision, or nil when nothing routes.
    public static func route(
        explicit: ModelSelection?, inputBytes: Int, ladder: [ModelSelection],
        measurements: [Measurement] = Measurements.embedded, opens: (ModelSelection) -> String?
    ) -> ModelRouting.Decision? {
        guard explicit == nil,
            let decision = ModelRouting.choose(
                task: routingTask, inputBytes: inputBytes, ladder: ladder, measurements: measurements)
        else { return nil }
        if let problem = opens(decision.model) {
            return ModelRouting.Decision(
                model: ladder.first ?? decision.model,
                reason: decision.reason
                    + "; but \(decision.model) cannot be opened (\(problem)), so \(ladder.first ?? decision.model)")
        }
        return decision
    }

    /// The placeholder the commit body ends with.
    public static let whyPlaceholder = "Why: <the reason for this change, which the diff cannot say>"
    /// Characters a subject or title may have.
    public static let subjectLimit = 72
    /// Columns a body is wrapped at.
    public static let bodyWidth = 72

    /// A finished draft.
    public struct Draft: Equatable, Sendable {
        /// What was drafted.
        public var kind: Kind
        /// The subject, title, or changelog line.
        public var subject: String
        /// The body lines: the commit body, the PR description's bullets; empty for a changelog line.
        public var body: [String]
        /// The review flags the summary raised, carried over for the PR description and the caller.
        public var flags: [String]

        /// The draft as it would be pasted: the subject, a blank line, and the body.
        public var text: String {
            switch kind {
            case .changelog: return "- " + subject
            case .commit, .pr: return ([subject, ""] + body).joined(separator: "\n")
            }
        }

        /// The draft as JSON.
        public var json: JSONValue {
            [
                "kind": .string(kind.rawValue), "subject": .string(subject), "body": .array(body.map { .string($0) }),
                "flags": .array(flags.map { .string($0) }), "text": .string(text),
            ]
        }
    }

    /// The shape of the model's answer.
    public static let schemaJSON: JSONValue = [
        "type": "object",
        "properties": [
            "subject": [
                "type": "string",
                "description": "The summary line: imperative mood, what the change does, under 72 characters",
            ],
            "points": [
                "type": "array", "maxItems": 8,
                "items": ["type": "string", "description": "One change worth a reviewer's attention, one sentence"],
            ],
        ],
        "required": ["subject", "points"],
    ]

    /// Answers the prompt with JSON of `schemaJSON`'s shape.
    private let judge: Triage.Judge

    /// Creates a drafter.
    ///
    /// - Parameter judge: One fresh model turn.
    public init(judge: @escaping Triage.Judge) {
        self.judge = judge
    }

    /// The prompt: what to write and the summary to write it from.
    public static func prompt(_ kind: Kind, from report: DiffSummary.Report) -> String {
        let task =
            switch kind {
            case .commit:
                "Write a git commit message for this change: a subject line in the imperative mood saying what the "
                    + "change does to the software's behaviour (such as \"Cache parsed settings between reads\"), and a "
                    + "few points on what changed, the most important first. Tests and docs follow the code; mention "
                    + "them only briefly."
            case .pr:
                "Write a pull request for this change: a title saying what it does, and points a reviewer should read "
                    + "first, including anything flagged."
            case .changelog:
                "Write one changelog line for users of the software, saying what they can now do or what was fixed. "
                    + "Put it in subject; points may be empty."
            }
        // The summary's headline is left out: it comes from the diff's first chunk, which in path order is
        // often documentation, and it pulled drafts toward the docs.
        var lines = [task, "", "CHANGE:"]
        for file in ordered(report.files) {
            lines.append(
                "- \(file.path) (\(file.change), +\(file.added) -\(file.removed))"
                    + (file.summary.map { ": \($0)" } ?? ""))
        }
        if report.more > 0 { lines.append("- and \(report.more) more files") }
        for flag in report.flags { lines.append("Flag \(flag.kind): \(flag.path.map { "\($0): " } ?? "")\(flag.note)") }
        return lines.joined(separator: "\n")
    }

    /// What part of a project a path is: 0 code, 1 tests, 2 docs and the changelog. A diff lists files in
    /// path order, which puts `CHANGELOG.md` and `docs/` ahead of the code they describe.
    static func role(of path: String) -> Int {
        let lower = path.lowercased()
        let name = lower.split(separator: "/").last.map(String.init) ?? lower
        if lower.hasPrefix("docs/") || name.hasSuffix(".md") || name.hasPrefix("changelog") { return 2 }
        if lower.contains("test") || lower.contains("spec/") { return 1 }
        return 0
    }

    /// Files with code first, then tests, then docs, each group in its diff order.
    static func ordered(_ files: [DiffSummary.FileChange]) -> [DiffSummary.FileChange] {
        files.enumerated().sorted { left, right in
            let (a, b) = (role(of: left.element.path), role(of: right.element.path))
            return a != b ? a < b : left.offset < right.offset
        }.map(\.element)
    }

    /// Drafts `kind` from `report`.
    ///
    /// - Throws: Whatever the judge throws; an answer without a subject falls back to the summary's headline.
    public func run(_ kind: Kind, from report: DiffSummary.Report) async throws -> Draft {
        let answer = try await judge(Self.prompt(kind, from: report))
        return Self.draft(kind, answer: answer, report: report)
    }

    /// Why a draft cannot be made.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// The diff is empty.
        case emptyDiff

        /// Human-readable explanation.
        public var description: String {
            switch self {
            case .emptyDiff: "nothing to describe: the diff is empty (stage the changes, or name a command or file)"
            }
        }
    }

    /// Summarises a captured diff with one judge and drafts from the summary with another: the whole of
    /// `draft_change` and `wisp draft` once the diff is in hand.
    ///
    /// - Parameters:
    ///   - kind: What to draft.
    ///   - captured: The diff.
    ///   - source: Where it came from, for the summary's prompts.
    ///   - summarise: Answers `DiffSummary`'s chunk prompts.
    ///   - write: Answers the drafting prompt.
    /// - Returns: The draft.
    /// - Throws: `Failure.emptyDiff`, or whatever a judge throws.
    public static func draft(
        _ kind: Kind, from captured: Triage.Captured, source: Triage.Source, summarise: @escaping Triage.Judge,
        write: @escaping Triage.Judge
    ) async throws -> Draft {
        guard !captured.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.emptyDiff }
        let report = try await DiffSummary(judge: summarise).run(captured, from: source)
        return try await ChangeDraft(judge: write).run(kind, from: report)
    }

    /// The draft from the model's answer, with the shape rules applied.
    static func draft(_ kind: Kind, answer: String, report: DiffSummary.Report) -> Draft {
        let fields =
            answer.data(using: .utf8).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }?.objectValue
            ?? [:]
        let raw = fields["subject"]?.stringValue ?? report.headline ?? "Update \(report.files.count) files"
        let points = (fields["points"]?.arrayValue ?? []).compactMap(\.stringValue).map(Self.oneLine).filter {
            !$0.isEmpty
        }
        let flags = report.flags.map { "\($0.kind)\($0.path.map { " in \($0)" } ?? ""): \($0.note)" }
        var body: [String] = []
        switch kind {
        case .commit:
            for point in points { body += wrap(point, width: bodyWidth, first: "- ", rest: "  ") }
            if !body.isEmpty { body.append("") }
            body.append(whyPlaceholder)
        case .pr:
            body = points.map { "- " + $0 }
            if !flags.isEmpty { body += ["", "Review flags:"] + flags.map { "- " + $0 } }
            body += ["", "Files: " + report.files.map { "`\($0.path)`" }.joined(separator: ", ")]
        case .changelog: break
        }
        let subject = kind == .changelog ? Self.oneLine(raw) : Self.subject(raw)
        return Draft(kind: kind, subject: subject, body: body, flags: flags)
    }

    /// A subject line: one line, a leading capital, no trailing period, at most `subjectLimit` characters,
    /// cut at a word.
    static func subject(_ text: String) -> String {
        var line = oneLine(text).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if let first = line.first, first.isLowercase { line = first.uppercased() + line.dropFirst() }
        guard line.count > subjectLimit else { return line }
        let cut = line.prefix(subjectLimit)
        var words = (cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)).split(separator: " ")
        // A cut must not leave the subject hanging on a connective.
        while words.count > 1, let last = words.last,
            danglers.contains(last.lowercased().trimmingCharacters(in: .punctuationCharacters))
        {
            words.removeLast()
        }
        return words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ",;: "))
    }

    /// Words a cut subject must not end on.
    static let danglers: Set<String> = [
        "and", "or", "with", "to", "of", "for", "the", "a", "an", "in", "on", "by", "from", "into", "as", "at",
    ]

    /// `text` on one line, whitespace collapsed.
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// `text` wrapped at `width`, the first line prefixed with `first` and the rest with `rest`.
    static func wrap(_ text: String, width: Int, first: String, rest: String) -> [String] {
        var lines: [String] = []
        var current = first
        for word in text.split(separator: " ") {
            let prefix = lines.isEmpty ? first : rest
            if current.count > prefix.count, current.count + 1 + word.count > width {
                lines.append(current)
                current = rest + word
            } else {
                current += (current.count > prefix.count ? " " : "") + word
            }
        }
        if current.count > (lines.isEmpty ? first : rest).count { lines.append(current) }
        return lines
    }
}
