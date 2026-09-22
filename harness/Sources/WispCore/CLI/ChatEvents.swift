import Foundation
import Synchronization

/// Shows the model's tool activity in chat as it happens: one dim line per call and result, drawn
/// from the same audit events the log records, so what the user sees is what was audited.
public enum ChatEvents {
    /// The line for `event`, or nil for an event chat does not show.
    public static func render(_ event: AuditEvent, style: Style) -> String? {
        let d = event.details
        switch event.kind {
        case .toolCall:
            let tool = d["tool"]?.stringValue ?? "?"
            return style.muted("⚙ \(tool) \(summary(ofArguments: d["arguments"]?.stringValue ?? "", tool: tool))")
        case .toolResult:
            // A command's outcome line already says what happened; its rendered result adds nothing.
            if d["tool"]?.stringValue == "run_command" { return nil }
            let bytes = d["bytes"]?.intValue ?? 0
            let seconds = d["seconds"]?.doubleValue ?? 0
            let head = firstLine(of: d["output"]?.stringValue ?? "")
            return style.muted("  ↳ \(bytes) bytes in \(String(format: "%.1f", seconds)) s: \(head)")
        case .commandOutcome:
            let status = d["exitStatus"]?.intValue ?? 0
            let mark = status == 0 ? style.wisp("exit \(status)") : style.ember("exit \(status)")
            var extras: [String] = []
            if d["timedOut"]?.boolValue == true { extras.append("timed out") }
            if d["truncated"]?.boolValue == true { extras.append("output truncated") }
            return style.muted("  ↳ ") + mark
                + style.muted(extras.isEmpty ? "" : " (\(extras.joined(separator: ", ")))")
        case .fileWrite:
            let mode = d["mode"]?.stringValue ?? "?"
            let path = d["path"]?.stringValue ?? "?"
            let after = d["bytesAfter"]?.intValue ?? 0
            return style.muted("  ↳ \(mode) \(path), now \(after) bytes")
        case .error where event.call != nil:
            return style.ember("  ↳ error: \(d["message"]?.stringValue ?? "")")
        case .condensation:
            let reason = d["reason"]?.stringValue ?? ""
            return style.muted(
                "(context condensed, \(reason): \(d["turnsBefore"]?.intValue ?? 0) → \(d["turnsAfter"]?.intValue ?? 0) turns)"
            )
        default:
            return nil
        }
    }

    /// The argument that identifies a call, so the line reads `⚙ read_file README.md` or
    /// `⚙ run_command git status`, falling back to the whole JSON shortened.
    static func summary(ofArguments json: String, tool: String) -> String {
        let fields = (try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))?.objectValue ?? [:]
        let key: String
        switch tool {
        case "run_command": key = "command"
        case "read_file", "edit_file": key = "path"
        case "inspect": key = "what"
        case "current_date": key = "timeZone"
        default: key = ""
        }
        if let value = fields[key]?.stringValue {
            var parts = [value]
            if tool == "edit_file", let mode = fields["mode"]?.stringValue { parts.insert(mode, at: 0) }
            if tool == "read_file", let offset = fields["offset"]?.intValue { parts.append("from line \(offset)") }
            return shortened(parts.joined(separator: " "))
        }
        return shortened(json)
    }

    /// The first sentence of `text`, for the compact tool list.
    public static func firstSentence(of text: String) -> String {
        if let end = text.firstRange(of: ". ") { return String(text[..<end.lowerBound]) + "." }
        return text
    }

    /// The first line of `text`, shortened.
    static func firstLine(of text: String) -> String {
        shortened(text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? "")
    }

    /// `text` cut to 100 characters with an ellipsis.
    static func shortened(_ text: String) -> String {
        text.count > 100 ? String(text.prefix(100)) + "…" : text
    }

    /// The sink chat attaches to its conversation: forwards each event to a handler set once the
    /// loop exists, and keeps the last tool result whole for `/last`.
    public final class Tap: AuditSink, Sendable {
        private let handler = Mutex<(@Sendable (AuditEvent) -> Void)?>(nil)
        private let last = Mutex<String?>(nil)

        /// Creates a tap with no handler yet.
        public init() {}

        /// Sets what happens with each event.
        public func onEvent(_ handle: @escaping @Sendable (AuditEvent) -> Void) {
            handler.withLock { $0 = handle }
        }

        /// The last tool result's full output, or nil before any.
        public var lastToolOutput: String? { last.withLock { $0 } }

        /// Forwards the event and remembers a tool result.
        public func write(_ event: AuditEvent) {
            if event.kind == .toolResult, let output = event.details["output"]?.stringValue {
                last.withLock { $0 = output }
            }
            handler.withLock { $0 }?(event)
        }
    }
}
