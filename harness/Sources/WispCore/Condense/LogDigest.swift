import Foundation

/// Condenses a log to its distinct messages: each line is reduced to a template (timestamp removed;
/// numbers, hex, UUIDs, and ids replaced by placeholders), lines with the same template are counted
/// together, and the groups are ranked by severity and then by how often they occur. Deterministic, so a
/// megabyte of `log show` or an app's log costs no model turns, and the caller reads a few kilobytes
/// ([ADR 0032](../../../../docs/decisions/0032-log-and-json-condensers.md)).
public struct LogDigest: Sendable {
    /// How serious a line reads.
    public enum Severity: String, Sendable, CaseIterable, Comparable {
        /// A crash, panic, fault, or fatal error.
        case fault
        /// An error or failure.
        case error
        /// A warning.
        case warning
        /// Anything else.
        case info

        /// Faults first.
        var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }

        /// Orders by rank, faults first.
        public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rank < rhs.rank }
    }

    /// Knobs for one digest.
    public struct Options: Equatable, Sendable {
        /// Groups returned at most, most severe and most frequent first.
        public var maxGroups: Int
        /// Characters of a template or example kept.
        public var maxLineLength: Int

        /// Creates options.
        public init(maxGroups: Int = 30, maxLineLength: Int = 240) {
            self.maxGroups = maxGroups
            self.maxLineLength = maxLineLength
        }
    }

    /// Lines that share a template.
    public struct Group: Equatable, Sendable {
        /// The most serious severity of its lines.
        public var severity: Severity
        /// How many lines.
        public var count: Int
        /// The line with its variable parts replaced by placeholders.
        public var template: String
        /// The first such line as it was, timestamp included, with credentials redacted.
        public var example: String
        /// The 1-based line numbers of the first and last occurrence.
        public var firstLine: Int
        /// The last occurrence's line number.
        public var lastLine: Int
        /// The first and last timestamps as printed, when the lines had them.
        public var firstSeen: String?
        /// The last occurrence's timestamp.
        public var lastSeen: String?

        /// The group as JSON.
        public var json: JSONValue {
            [
                "severity": .string(severity.rawValue), "count": .int(count), "template": .string(template),
                "example": .string(example), "firstLine": .int(firstLine), "lastLine": .int(lastLine),
                "firstSeen": firstSeen.map { .string($0) } ?? .null, "lastSeen": lastSeen.map { .string($0) } ?? .null,
            ]
        }
    }

    /// The digest of one log.
    public struct Report: Equatable, Sendable {
        /// Non-empty lines read.
        public var lines: Int
        /// Distinct templates found, before the cap.
        public var templates: Int
        /// Lines per severity.
        public var severities: [Severity: Int]
        /// The groups kept, most severe and most frequent first.
        public var groups: [Group]
        /// Whether groups beyond the cap were dropped.
        public var more: Bool

        /// The report as JSON.
        public var json: JSONValue {
            [
                "kind": "log", "lines": .int(lines), "templates": .int(templates), "more": .bool(more),
                "severities": .object(
                    Dictionary(uniqueKeysWithValues: Severity.allCases.map { ($0.rawValue, .int(severities[$0] ?? 0)) })
                ),
                "groups": .array(groups.map(\.json)),
            ]
        }

        /// The report as text: a headline, then one line per group with its count and template.
        public var rendered: String {
            let counts = Severity.allCases.compactMap { severity in
                severities[severity].map { "\($0) \(severity.rawValue)" }
            }
            var lines = [
                "\(self.lines) lines, \(templates) distinct\(more ? "; the top \(groups.count) shown" : "")"
                    + (counts.isEmpty ? "" : " (\(counts.joined(separator: ", ")))")
            ]
            lines += TextTable.render(
                header: ["SEVERITY", "COUNT", "LINES", "TEMPLATE"],
                rows: groups.map {
                    [
                        $0.severity.rawValue, "\($0.count)",
                        $0.firstLine == $0.lastLine ? "\($0.firstLine)" : "\($0.firstLine)-\($0.lastLine)", $0.template,
                    ]
                }, rightAligned: [1])
            return lines.joined(separator: "\n")
        }
    }

    /// The options in force.
    public let options: Options

    /// Creates a digest.
    public init(options: Options = Options()) {
        self.options = options
    }

    /// Leading timestamps in the forms logs print: ISO 8601 and `log show` (`2026-09-23 22:01:36.725161+0100`),
    /// syslog (`Sep 23 22:01:36`), and either in brackets.
    static let timestampPattern =
        #"^\[?(?:\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:[.,]\d+)?(?:Z|[+-]\d{2}:?\d{2})?|[A-Z][a-z]{2} +\d{1,2} \d{2}:\d{2}:\d{2}(?:\.\d+)?)\]?\s*"#

    /// Variable parts replaced to form a template, in order: a `log show` compact `[pid:thread]`, UUIDs,
    /// hex literals, bare hex such as thread ids, long mixed ids, then numbers.
    static let placeholders: [(pattern: String, replacement: String)] = [
        (#"\[\d+:[0-9A-Fa-f]+\]"#, "[<pid>]"),
        (#"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b"#, "<uuid>"),
        (#"\b0x[0-9A-Fa-f]+\b"#, "<hex>"),
        (#"\b(?=[0-9a-f]*[a-f])(?=[0-9a-f]*\d)[0-9a-f]{6,}\b"#, "<hex>"),
        (#"\b(?=[A-Za-z]*\d)(?=\d*[A-Za-z])[A-Za-z0-9]{12,}\b"#, "<id>"),
        (#"\b\d+(?:\.\d+)*\b"#, "<n>"),
    ]

    /// `log show`'s own columns after the timestamp, which state the line's type: the default style's
    /// thread, type, activity, pid, and TTL, and the compact style's type code.
    static let declaredColumns: [(pattern: String, types: [String: Severity])] = [
        (#"^0x[0-9a-f]+\s+([A-Z][a-z]+)\s+0x[0-9a-f]+\s+\d+\s+\d+\s+"#, ["Fault": .fault, "Error": .error]),
        (#"^(Df|Db|Fa|I|E|F|A)\s+"#, ["F": .fault, "Fa": .fault, "E": .error]),
    ]

    /// Words that mark a line's severity when the log states none, most serious first.
    static let severityPatterns: [(Severity, String)] = [
        (.fault, #"(?i)\b(?:fault|fatal|panic(?:ked)?|critical|crash(?:ed|ing)?|segfault|abort(?:ed)?)\b"#),
        (.error, #"(?i)\b(?:error|errors|failed|failure|fails|exception|denied|refused|timed out|timeout|unable)\b"#),
        (.warning, #"(?i)\b(?:warn|warning|deprecated)\b"#),
    ]

    /// The severity a line's words suggest.
    static func severity(of line: String) -> Severity {
        for (severity, pattern) in severityPatterns
        where (try? RegexCache.regex(pattern))?.matches(anywhereIn: line) == true {
            return severity
        }
        return .info
    }

    /// One line taken apart.
    struct Parsed: Equatable {
        /// The leading timestamp as printed, if any.
        var timestamp: String?
        /// The severity the log itself states, when it has a type column.
        var declared: Severity?
        /// The rest, with variable parts replaced and whitespace collapsed.
        var template: String
    }

    /// Splits a line into its timestamp, any declared type, and its template.
    static func parse(_ line: String) -> Parsed {
        var rest = line
        var timestamp: String?
        var declared: Severity?
        if let match = firstMatch(timestampPattern, in: rest) {
            timestamp = rest[match.range].trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
            rest = String(rest[match.range.upperBound...])
        }
        for (pattern, types) in declaredColumns {
            guard let match = firstMatch(pattern, in: rest) else { continue }
            declared = types[match.group] ?? .info
            rest = String(rest[match.range.upperBound...])
            break
        }
        for (pattern, replacement) in placeholders {
            guard let regex = try? RegexCache.regex(pattern) else { continue }
            rest = regex.stringByReplacingMatches(
                in: rest, range: NSRange(rest.startIndex..., in: rest), withTemplate: replacement)
        }
        return Parsed(
            timestamp: timestamp, declared: declared,
            template: rest.split(whereSeparator: \.isWhitespace).joined(separator: " "))
    }

    /// The first match of `pattern` at the start of `text`: its range and its first group.
    static func firstMatch(_ pattern: String, in text: String) -> (range: Range<String.Index>, group: String)? {
        guard let regex = try? RegexCache.regex(pattern),
            let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let range = Range(match.range, in: text)
        else { return nil }
        let group = match.numberOfRanges > 1 ? Range(match.range(at: 1), in: text).map { String(text[$0]) } : nil
        return (range, group ?? "")
    }

    /// Digests `text`.
    public func run(_ text: String) -> Report {
        var order: [String] = []
        var groups: [String: Group] = [:]
        var severities: [Severity: Int] = [:]
        var lines = 0
        var previous: Severity?
        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(raw)
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            lines += 1
            let parsed = Self.parse(line)
            let (timestamp, template) = (parsed.timestamp, parsed.template)
            // In a log whose lines carry timestamps, a line without one continues the line before it, a
            // multi-line message, and takes its severity rather than its own words'.
            let continues = parsed.timestamp == nil && previous != nil
            let severity = continues ? (previous ?? .info) : parsed.declared ?? Self.severity(of: parsed.template)
            if parsed.timestamp != nil || previous != nil { previous = severity }
            severities[severity, default: 0] += 1
            if var group = groups[template] {
                group.count += 1
                group.lastLine = index + 1
                group.lastSeen = timestamp ?? group.lastSeen
                group.severity = min(group.severity, severity)
                groups[template] = group
            } else {
                order.append(template)
                var redactor = Redactor()
                let example = redactor.apply(SecretScanner.scan(line, categories: [.secret]), to: line)
                groups[template] = Group(
                    severity: severity, count: 1, template: Self.cut(template, to: options.maxLineLength),
                    example: Self.cut(example, to: options.maxLineLength), firstLine: index + 1, lastLine: index + 1,
                    firstSeen: timestamp, lastSeen: timestamp)
            }
        }
        let ranked = order.compactMap { groups[$0] }.enumerated().sorted { left, right in
            if left.element.severity != right.element.severity { return left.element.severity < right.element.severity }
            if left.element.count != right.element.count { return left.element.count > right.element.count }
            return left.offset < right.offset
        }.map(\.element)
        return Report(
            lines: lines, templates: ranked.count, severities: severities,
            groups: Array(ranked.prefix(options.maxGroups)), more: ranked.count > options.maxGroups)
    }

    /// `text` cut to `limit` characters with an ellipsis.
    static func cut(_ text: String, to limit: Int) -> String {
        text.count > limit ? String(text.prefix(max(0, limit - 1))) + "…" : text
    }
}

/// A macOS crash or diagnostic report (`.ips`, as under `~/Library/Logs/DiagnosticReports`) reduced to what
/// explains it: the process, the exception, the termination reason, and the faulting thread's top frames
/// with their images. The format is a JSON header line followed by a JSON body.
public struct CrashReport: Equatable, Sendable {
    /// One stack frame.
    public struct Frame: Equatable, Sendable {
        /// The image the frame is in, by name.
        public var image: String
        /// The symbol, or nil when the report has none.
        public var symbol: String?
        /// The offset into the image.
        public var offset: Int?

        /// The frame as one line: `image  symbol` or `image + offset`.
        public var rendered: String {
            if let symbol { return "\(image)  \(symbol)" }
            return "\(image) + \(offset.map(String.init) ?? "?")"
        }
    }

    /// The process name.
    public var process: String
    /// The app's version, when given.
    public var version: String?
    /// The OS the report was taken on.
    public var os: String?
    /// When it happened, as printed.
    public var timestamp: String?
    /// The report's `bug_type`.
    public var bugType: String?
    /// The exception type, signal, subtype, and message joined, when there is one.
    public var exception: String?
    /// The termination's indicator and namespace, when there is one.
    public var termination: String?
    /// The index of the thread that faulted.
    public var faultingThread: Int?
    /// That thread's top frames.
    public var frames: [Frame]

    /// Frames kept from the faulting thread.
    public static let maxFrames = 12

    /// Parses a report; nil when `text` is not one.
    public init?(_ text: String) {
        let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let header = Self.object(String(parts[0])), header["bug_type"] != nil,
            let body = Self.object(String(parts[1]))
        else { return nil }
        process = header["app_name"]?.stringValue ?? header["name"]?.stringValue ?? body["procName"]?.stringValue ?? "?"
        version = header["app_version"]?.stringValue
        os = header["os_version"]?.stringValue
        timestamp = header["timestamp"]?.stringValue
        bugType = header["bug_type"]?.stringValue
        if let raised = body["exception"]?.objectValue {
            exception = ["type", "signal", "subtype", "message"].compactMap { raised[$0]?.stringValue }.joined(
                separator: " · ")
        }
        if let termination = body["termination"]?.objectValue {
            let parts = [termination["indicator"]?.stringValue, termination["namespace"]?.stringValue].compactMap(
                \.self)
            self.termination = parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
        let images = body["usedImages"]?.arrayValue?.map { $0.objectValue?["name"]?.stringValue ?? "?" } ?? []
        let threads = body["threads"]?.arrayValue ?? []
        let faulting =
            body["faultingThread"]?.intValue
            ?? threads.firstIndex { $0.objectValue?["triggered"]?.boolValue == true }
        faultingThread = faulting
        let thread = faulting.flatMap { threads.indices.contains($0) ? threads[$0].objectValue : nil }
        frames = (thread?["frames"]?.arrayValue ?? []).prefix(Self.maxFrames).map { frame in
            let fields = frame.objectValue ?? [:]
            let index = fields["imageIndex"]?.intValue
            return Frame(
                image: index.flatMap { images.indices.contains($0) ? images[$0] : nil } ?? "?",
                symbol: fields["symbol"]?.stringValue, offset: fields["imageOffset"]?.intValue)
        }
    }

    /// A JSON object from one piece of text, or nil.
    static func object(_ text: String) -> [String: JSONValue]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue
    }

    /// The report as JSON.
    public var json: JSONValue {
        [
            "kind": "crash", "process": .string(process), "version": version.map { .string($0) } ?? .null,
            "os": os.map { .string($0) } ?? .null, "timestamp": timestamp.map { .string($0) } ?? .null,
            "bugType": bugType.map { .string($0) } ?? .null, "exception": exception.map { .string($0) } ?? .null,
            "termination": termination.map { .string($0) } ?? .null,
            "faultingThread": faultingThread.map { .int($0) } ?? .null,
            "frames": .array(
                frames.map {
                    [
                        "image": .string($0.image), "symbol": $0.symbol.map { .string($0) } ?? .null,
                        "offset": $0.offset.map { .int($0) } ?? .null,
                    ]
                }),
        ]
    }

    /// The report as text: what crashed and why, then the faulting thread's frames.
    public var rendered: String {
        var lines = ["\(process)\(version.map { " \($0)" } ?? "") on \(os ?? "?") at \(timestamp ?? "?")"]
        if let exception { lines.append("exception: \(exception)") }
        if let termination { lines.append("termination: \(termination)") }
        if let faultingThread { lines.append("thread \(faultingThread) faulted:") }
        lines += frames.enumerated().map { "  \($0.offset)  \($0.element.rendered)" }
        return lines.joined(separator: "\n")
    }
}
