import Foundation
import OSLog

/// Reads the unified log in wisp's own process through `OSLogStore`, for `condense_log`. `/usr/bin/log`
/// cannot serve: it checks whether it is sandboxed and exits (`log: Cannot run while sandboxed`, even
/// under a profile that allows everything, verified on macOS 27 on 2026-09-24), and every command wisp
/// runs is sandboxed. The entries are written as lines in `log show`'s compact style, so `LogDigest`
/// reads their declared type ([ADR 0032](../../../../docs/decisions/0032-log-and-json-condensers.md)).
public enum UnifiedLog {
    /// What to read.
    public struct Query: Equatable, Sendable {
        /// How far back, in seconds.
        public var seconds: Int
        /// Only entries from this process name, when given.
        public var process: String?
        /// Only entries whose subsystem starts with this, when given.
        public var subsystem: String?

        /// Creates a query.
        public init(seconds: Int, process: String? = nil, subsystem: String? = nil) {
            self.seconds = seconds
            self.process = process
            self.subsystem = subsystem
        }
    }

    /// The longest window read: a day.
    public static let maxSeconds = 86_400

    /// Why a query cannot run.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// `last` is not a duration such as `90s`, `10m`, or `2h`, or is longer than a day.
        case badDuration(String)
        /// The log store could not be opened or read.
        case unreadable(String)

        /// Human-readable explanation.
        public var description: String {
            switch self {
            case .badDuration(let text): "'\(text)' is not a duration from 1s to 24h, such as 90s, 10m, or 2h"
            case .unreadable(let detail): "the unified log could not be read: \(detail)"
            }
        }
    }

    /// Seconds in a duration written `90s`, `10m`, `2h`, or a bare number of seconds.
    ///
    /// - Throws: `Failure.badDuration` for anything else, zero, or more than a day.
    public static func seconds(in text: String) throws -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        let units: [Character: Int] = ["s": 1, "m": 60, "h": 3600]
        let (digits, scale) =
            trimmed.last.flatMap { units[$0] }.map { (String(trimmed.dropLast()), $0) } ?? (trimmed, 1)
        guard let value = Int(digits), value > 0, value * scale <= maxSeconds else { throw Failure.badDuration(text) }
        return value * scale
    }

    /// The query as a predicate `OSLogStore` evaluates, or nil when it filters nothing.
    static func predicate(_ query: Query) -> NSPredicate? {
        var parts: [NSPredicate] = []
        if let process = query.process { parts.append(NSPredicate(format: "process ==[c] %@", process)) }
        if let subsystem = query.subsystem { parts.append(NSPredicate(format: "subsystem BEGINSWITH %@", subsystem)) }
        return parts.isEmpty ? nil : NSCompoundPredicate(andPredicateWithSubpredicates: parts)
    }

    /// The compact-style type code for a level: `F` fault, `E` error, `Df` default, `I` info, `Db` debug.
    static func code(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .fault: "F"
        case .error: "E"
        case .info: "I"
        case .debug: "Db"
        default: "Df"
        }
    }

    /// One entry as a compact-style line, local time with its offset:
    /// `2026-09-24T10:02:11.482+01:00 E  proc[pid:thread] [sub:cat] message`.
    static func line(
        date: Date, level: String, process: String, pid: Int32, thread: UInt64, subsystem: String, category: String,
        message: String, timeZone: TimeZone = .current
    ) -> String {
        let stamp = date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: timeZone))
        let origin = subsystem.isEmpty ? "" : " [\(subsystem):\(category)]"
        let flat = message.replacingOccurrences(of: "\n", with: " ")
        return
            "\(stamp) \(level.padding(toLength: 2, withPad: " ", startingAt: 0)) \(process)[\(pid):\(String(thread, radix: 16))]\(origin) \(flat)"
    }

    /// Reads the entries of the last `query.seconds`, as compact lines, up to `maxBytes`, keeping the latest.
    ///
    /// - Returns: The text and whether older entries were dropped to fit.
    /// - Throws: `Failure.unreadable` when the store cannot be opened or read.
    public static func read(_ query: Query, maxBytes: Int) throws -> (text: String, truncated: Bool) {
        let store: OSLogStore
        do {
            store = try OSLogStore.local()
        } catch {
            throw Failure.unreadable("\(error)")
        }
        let start = store.position(date: Date().addingTimeInterval(-Double(query.seconds)))
        var collector = Collector(maxBytes: maxBytes)
        do {
            for entry in try store.getEntries(at: start, matching: predicate(query)) {
                guard let log = entry as? OSLogEntryLog else { continue }
                collector.add(
                    line(
                        date: log.date, level: code(log.level), process: log.process, pid: log.processIdentifier,
                        thread: log.threadIdentifier, subsystem: log.subsystem, category: log.category,
                        message: log.composedMessage))
            }
        } catch {
            throw Failure.unreadable("\(error)")
        }
        return collector.result
    }

    /// Keeps the newest lines that fit in a byte budget as they arrive, dropping from the front in batches
    /// (once twice the budget is held) so a busy log costs linear time. Separate from `read` so the trimming
    /// is tested with chosen lines rather than whatever the live log holds.
    struct Collector {
        /// Bytes kept at most.
        let maxBytes: Int
        /// The lines held.
        private(set) var lines: [String] = []
        /// Their size, with a newline each.
        private(set) var bytes = 0
        /// Whether any line was dropped.
        private(set) var truncated = false

        /// Creates a collector.
        init(maxBytes: Int) {
            self.maxBytes = maxBytes
        }

        /// Adds one line, trimming the oldest once twice the budget is held.
        mutating func add(_ line: String) {
            lines.append(line)
            bytes += line.utf8.count + 1
            if bytes > maxBytes * 2 {
                (lines, bytes) = UnifiedLog.tail(lines, maxBytes: maxBytes)
                truncated = true
            }
        }

        /// The kept lines joined, and whether any were dropped.
        var result: (text: String, truncated: Bool) {
            let (kept, size) = UnifiedLog.tail(lines, maxBytes: maxBytes)
            return (kept.joined(separator: "\n"), truncated || size < bytes)
        }
    }

    /// The latest lines that fit in `maxBytes`, and their size.
    static func tail(_ lines: [String], maxBytes: Int) -> (lines: [String], bytes: Int) {
        var size = 0
        var start = lines.count
        while start > 0, size + lines[start - 1].utf8.count + 1 <= maxBytes {
            start -= 1
            size += lines[start].utf8.count + 1
        }
        return (Array(lines[start...]), size)
    }
}
