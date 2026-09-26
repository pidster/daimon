import Foundation

/// Failures in the formats compilers and test runners print, found exactly and without the model:
/// `file:line:col: error:` (Swift, clang, XCTest), rustc's `error[E…]` with its `-->` line, swift-testing's
/// `✘ Test … recorded an issue at`, cargo test's `test … FAILED` and `panicked at`, pytest's `FAILED`
/// and `ERROR` summary lines, and go test's `--- FAIL:`.
///
/// `Triage` runs this first on every chunk. When it explains every line that looks like a failure,
/// the chunk needs no model turn; otherwise the model reads the chunk and its findings are merged with
/// these, so an unfamiliar format is still read. Exact where it can be, the model where it must.
public enum KnownFailures {
    /// What a scan of one chunk found.
    public struct Scan: Equatable, Sendable {
        /// The failures, in the order they were printed.
        public var findings: [Triage.Finding]
        /// Lines that look like failures but that no pattern accounted for.
        public var unexplained: [String]

        /// Whether the scan found failures and accounts for every line that looks like one, so the
        /// model has nothing to add.
        public var explainsEverything: Bool { !findings.isEmpty && unexplained.isEmpty }
    }

    /// A line format: its pattern with named groups `loc`, `msg`, `name`, and `kind` where it has
    /// them, and how a match becomes a finding.
    struct Format: Sendable {
        /// The pattern, matched against one whole line.
        let pattern: String
        /// The finding a match's named groups make.
        let finding: @Sendable ([String: String]) -> Triage.Finding
    }

    /// The line formats, tried in order; the first that matches a line reads it.
    static let formats: [Format] = [
        // Swift, clang, and XCTest: path:line[:col]: error|warning|fatal error: message
        Format(pattern: #"^(?<loc>[^\s:]+:\d+(?::\d+)?): (?<kind>error|warning|fatal error): (?<msg>.+)$"#) { g in
            Triage.Finding(
                kind: g["kind"] == "warning" ? "warning" : "error", location: g["loc"], message: g["msg"] ?? "")
        },
        // swift-testing: ✘ Test name() recorded an issue at File.swift:88:9: message
        Format(pattern: #"^✘ Test (?<name>.+?) recorded an issue at (?<loc>[^\s:]+:\d+(?::\d+)?): (?<msg>.+)$"#) { g in
            Triage.Finding(kind: "test-failure", location: g["loc"], message: "\(g["name"] ?? ""): \(g["msg"] ?? "")")
        },
        // cargo test: test path::name ... FAILED
        Format(pattern: #"^test (?<name>\S+) \.\.\. FAILED$"#) { g in
            Triage.Finding(kind: "test-failure", location: g["name"], message: "\(g["name"] ?? "") failed")
        },
        // Rust: thread 'name' panicked at src/lib.rs:12:5: message
        Format(pattern: #"^thread '(?<name>[^']+)' panicked at (?<loc>[^\s:]+:\d+:\d+):?\s*(?<msg>.*)$"#) { g in
            let detail = g["msg"] ?? ""
            return Triage.Finding(
                kind: "test-failure", location: g["loc"],
                message: "\(g["name"] ?? "") panicked" + (detail.isEmpty ? "" : ": \(detail)"))
        },
        // pytest: FAILED tests/test_x.py::test_y - message; ERROR for collection and fixture errors
        Format(pattern: #"^(?<kind>FAILED|ERROR) (?<loc>\S+::\S+)(?: - (?<msg>.+))?$"#) { g in
            Triage.Finding(
                kind: g["kind"] == "ERROR" ? "error" : "test-failure", location: g["loc"],
                message: g["msg"] ?? "\(g["loc"] ?? "") failed")
        },
        // go test: --- FAIL: TestName (0.00s)
        Format(pattern: #"^\s*--- FAIL: (?<name>\S+)"#) { g in
            Triage.Finding(kind: "test-failure", location: g["name"], message: "\(g["name"] ?? "") failed")
        },
    ]

    /// rustc's first line, `error[E0425]: message` or `warning: message`; its location is a `-->` line
    /// within the next three.
    static let rustHead = #"^(?<kind>error|warning)(?:\[(?<code>E\d+)\])?: (?<msg>.+)$"#
    /// rustc's location line.
    static let rustArrow = #"^\s*--> (?<loc>[^\s:]+:\d+:\d+)"#

    /// Tallies and framing that mention failure but report nothing a finding does not already say.
    static let summaries = [
        #"^✘ Test run with \d+ tests?"#, #"^✘ (Test|Suite) .+ failed after"#, #"^error: could not compile"#,
        #"^error: aborting due to"#, #"^error: fatalError$"#, #"^test result: FAILED"#, #"^failures:$"#,
        #"^    [\w:]+$"#, #"^---- \S+ stdout ----$"#, #"^=+ .*\b\d+ (failed|errors?)\b.*=+$"#, #"^FAIL\s*$"#,
        #"^FAIL\s+\S+\s+[\d.]+s$"#, #"^note: run with `RUST_BACKTRACE"#, #"^=+ (FAILURES|ERRORS) =+$"#,
    ]

    /// Words that make a line look like a failure.
    static let suspicious =
        #"(?i)\b(error|errors|failed|failure|failures|panicked|panic|fatal|crash|crashed|exception|assertion)\b"#

    /// The named groups of `pattern`'s match in `line`, or nil when it does not match. Only the names
    /// the pattern declares are asked for: `range(withName:)` raises for a name it does not have.
    static func groups(_ pattern: String, in line: String, names: [String]? = nil) -> [String: String]? {
        guard let regex = try? RegexCache.regex(pattern),
            let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
        else { return nil }
        let declared = declaredNames(pattern)
        var groups: [String: String] = [:]
        for name in (names ?? declared) where declared.contains(name) {
            let range = match.range(withName: name)
            if range.location != NSNotFound, let bounds = Range(range, in: line) { groups[name] = String(line[bounds]) }
        }
        return groups
    }

    /// The group names `pattern` declares with `(?<name>…)`.
    static func declaredNames(_ pattern: String) -> [String] {
        guard let finder = try? RegexCache.regex(#"\(\?<([A-Za-z]\w*)>"#) else { return [] }
        return finder.matches(in: pattern, range: NSRange(pattern.startIndex..., in: pattern)).compactMap { match in
            Range(match.range(at: 1), in: pattern).map { String(pattern[$0]) }
        }
    }

    /// Finds the failures in `text` and the failure-looking lines it could not account for.
    public static func scan(_ text: String) -> Scan {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var findings: [Triage.Finding] = []
        var explained = Set<Int>()
        for (index, line) in lines.enumerated() {
            if let (format, found) = formats.lazy.compactMap({ f in groups(f.pattern, in: line).map { (f, $0) } }).first
            {
                findings.append(format.finding(found))
                explained.insert(index)
                continue
            }
            if let head = groups(rustHead, in: line) {
                let window = (index + 1)..<min(index + 4, lines.count)
                if let arrowIndex = window.first(where: { groups(rustArrow, in: lines[$0]) != nil }),
                    let arrow = groups(rustArrow, in: lines[arrowIndex])
                {
                    let code = head["code"].map { "[\($0)] " } ?? ""
                    findings.append(
                        Triage.Finding(
                            kind: head["kind"] == "warning" ? "warning" : "error", location: arrow["loc"],
                            message: code + (head["msg"] ?? "")))
                    explained.formUnion([index, arrowIndex])
                    continue
                }
            }
            if summaries.contains(where: { groups($0, in: line) != nil }) { explained.insert(index) }
        }
        let unexplained = lines.enumerated()
            .filter { index, line in !explained.contains(index) && groups(suspicious, in: line) != nil }
            .map(\.element)
        return Scan(findings: findings, unexplained: unexplained)
    }
}
