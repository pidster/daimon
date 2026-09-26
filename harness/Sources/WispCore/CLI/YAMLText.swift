import Foundation

/// A JSON value written as YAML for a person to read, as `/config` shows the configuration: keys in
/// order, nesting by indentation, lists as `-` items, and strings quoted only where YAML would read them
/// as something else. Readable output, not a general YAML writer; a document it writes parses back to
/// the same value.
public enum YAMLText {
    /// `value` as YAML lines.
    public static func render(_ value: JSONValue) -> String {
        switch value {
        case .object(let fields) where !fields.isEmpty: lines(fields, indent: 0).joined(separator: "\n")
        case .array(let items) where !items.isEmpty: lines(items, indent: 0).joined(separator: "\n")
        default: scalar(value)
        }
    }

    private static func pad(_ indent: Int) -> String { String(repeating: "  ", count: indent) }

    private static func lines(_ fields: [String: JSONValue], indent: Int) -> [String] {
        fields.keys.sorted().flatMap { key -> [String] in
            let name = pad(indent) + quotedIfNeeded(key) + ":"
            switch fields[key] {
            case .object(let child)? where !child.isEmpty: return [name] + lines(child, indent: indent + 1)
            case .array(let items)? where !items.isEmpty: return [name] + lines(items, indent: indent + 1)
            case let other?: return [name + " " + scalar(other)]
            case nil: return []
            }
        }
    }

    private static func lines(_ items: [JSONValue], indent: Int) -> [String] {
        items.flatMap { item -> [String] in
            switch item {
            case .object(let fields) where !fields.isEmpty:
                // The first key sits on the dash's line, the rest under it.
                var nested = lines(fields, indent: indent + 1)
                nested[0] = pad(indent) + "- " + nested[0].dropFirst(pad(indent + 1).count)
                return nested
            case .array(let inner) where !inner.isEmpty:
                return [pad(indent) + "-"] + lines(inner, indent: indent + 1)
            default:
                return [pad(indent) + "- " + scalar(item)]
            }
        }
    }

    /// A scalar, or an empty collection, on one line.
    static func scalar(_ value: JSONValue) -> String {
        switch value {
        case .null: "null"
        case .bool(let flag): flag ? "true" : "false"
        case .int(let number): String(number)
        case .double(let number):
            number == number.rounded() && abs(number) < 1e15 ? String(Int(number)) + ".0" : String(number)
        case .string(let text): quotedIfNeeded(text)
        case .array: "[]"
        case .object: "{}"
        }
    }

    /// Words YAML would read as another type.
    private static let reserved: Set<String> = ["true", "false", "yes", "no", "on", "off", "null", "~", ""]

    /// `text` bare when YAML reads it back as the same string, in double quotes otherwise.
    static func quotedIfNeeded(_ text: String) -> String {
        let risky =
            reserved.contains(text.lowercased()) || Double(text) != nil || text.contains(": ") || text.contains(" #")
            || text.hasSuffix(":") || text != text.trimmingCharacters(in: .whitespaces)
            || text.contains(where: { $0.isNewline || $0 == "\"" || $0 == "\t" })
            || text.first.map { "-?[]{}!&*|>'%@`,#".contains($0) } == true
        guard risky else { return text }
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }
}
