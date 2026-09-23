import Foundation

/// The structure of a JSON document or a JSON Lines file without its data: each key's types, whether it
/// is always present, array lengths, number ranges, and a short string example with credentials and
/// personal data redacted. Arrays are merged element by element, so a thousand records read as one.
/// Deterministic; for a caller that needs to know what a large response or export looks like before
/// deciding what to extract ([ADR 0032](../../../../docs/decisions/0032-log-and-json-condensers.md)).
public struct JSONShape: Sendable {
    /// Knobs for one outline.
    public struct Options: Equatable, Sendable {
        /// Levels of nesting described; deeper values are summarised by type.
        public var maxDepth: Int
        /// Keys listed per object; the rest are counted.
        public var maxKeys: Int
        /// Lines of outline returned.
        public var maxLines: Int
        /// Whether string examples are shown.
        public var examples: Bool

        /// Creates options.
        public init(maxDepth: Int = 8, maxKeys: Int = 60, maxLines: Int = 200, examples: Bool = true) {
            self.maxDepth = maxDepth
            self.maxKeys = maxKeys
            self.maxLines = maxLines
            self.examples = examples
        }
    }

    /// What was seen at one place in the document, merged over every value found there.
    struct Node: Equatable, Sendable {
        /// How many values were seen here.
        var seen = 0
        /// The JSON types seen, in first-seen order.
        var types: [String] = []
        /// The smallest and largest number.
        var minimum: Double?
        /// The largest number.
        var maximum: Double?
        /// Whether every number was whole.
        var integral = true
        /// The first string, redacted and cut.
        var example: String?
        /// The shortest and longest array.
        var shortest: Int?
        /// The longest array.
        var longest: Int?
        /// Every element of every array, merged; empty or one node.
        var element: [Node] = []
        /// Object keys in first-seen order.
        var keys: [String] = []
        /// Each key's merged values.
        var children: [String: Node] = [:]
        /// How many objects were seen, to tell a key that is sometimes absent.
        var objects = 0

        /// Adds one value.
        mutating func absorb(_ value: JSONValue, depth: Int, options: Options) {
            seen += 1
            let type = Self.type(of: value)
            if !types.contains(type) { types.append(type) }
            guard depth < options.maxDepth else { return }
            switch value {
            case .int(let number): record(Double(number), integral: true)
            case .double(let number): record(number, integral: number.rounded() == number)
            case .string(let text):
                if example == nil, options.examples { example = Self.example(text) }
            case .array(let items):
                shortest = min(shortest ?? items.count, items.count)
                longest = max(longest ?? items.count, items.count)
                for item in items {
                    if element.isEmpty { element = [Node()] }
                    element[0].absorb(item, depth: depth + 1, options: options)
                }
            case .object(let fields):
                objects += 1
                for key in fields.keys.sorted() {
                    guard let child = fields[key] else { continue }
                    if children[key] == nil { keys.append(key) }
                    children[key, default: Node()].absorb(child, depth: depth + 1, options: options)
                }
            case .bool, .null: break
            }
        }

        /// Widens the number range.
        private mutating func record(_ number: Double, integral: Bool) {
            minimum = min(minimum ?? number, number)
            maximum = max(maximum ?? number, number)
            self.integral = self.integral && integral
        }

        /// The JSON type name of a value; integers and other numbers are both `number`.
        static func type(of value: JSONValue) -> String {
            switch value {
            case .null: "null"
            case .bool: "boolean"
            case .int, .double: "number"
            case .string: "string"
            case .array: "array"
            case .object: "object"
            }
        }

        /// A string as an example: credentials and personal data replaced, line breaks escaped, cut to
        /// 40 characters.
        static func example(_ text: String) -> String {
            var redactor = Redactor()
            let clean = redactor.apply(SecretScanner.scan(text), to: text)
                .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t")
            return clean.count > 40 ? String(clean.prefix(39)) + "…" : clean
        }

        /// Whether anything is nested under this node.
        var isContainer: Bool { !keys.isEmpty || !element.isEmpty }

        /// The node's type in words: `number 1…42`, `array[3] of string`, `null | object`.
        func summary() -> String {
            types.map { type in
                switch type {
                case "number":
                    guard let minimum, let maximum else { return "number" }
                    let kind = integral ? "integer" : "number"
                    return minimum == maximum
                        ? "\(kind) \(Self.format(minimum))" : "\(kind) \(Self.format(minimum))…\(Self.format(maximum))"
                case "string": return example.map { "string e.g. \"\($0)\"" } ?? "string"
                case "array":
                    let length =
                        shortest == longest ? "\(shortest ?? 0)" : "\(shortest ?? 0)…\(longest ?? 0)"
                    let of = element.first.map { " of \($0.types.joined(separator: " | "))" } ?? ""
                    return "array[\(length)]\(of)"
                default: return type
                }
            }.joined(separator: " | ")
        }

        /// A number without a needless fraction.
        static func format(_ number: Double) -> String {
            number.rounded() == number && abs(number) < 1e15 ? String(Int(number)) : String(number)
        }
    }

    /// The outline of one document.
    public struct Report: Equatable, Sendable {
        /// `json` or `jsonl`.
        public var format: String
        /// Top-level records: 1 for a document, the line count for JSON Lines.
        public var records: Int
        /// Bytes read.
        public var bytes: Int
        /// The outline, one line per place, indented by depth.
        public var outline: [String]
        /// Whether lines beyond the cap were dropped.
        public var more: Bool

        /// The report as JSON.
        public var json: JSONValue {
            [
                "format": .string(format), "records": .int(records), "bytes": .int(bytes), "more": .bool(more),
                "outline": .array(outline.map { .string($0) }),
            ]
        }

        /// The report as text: a headline and the outline.
        public var rendered: String {
            let head =
                "\(format == "jsonl" ? "\(records) JSON Lines records" : "JSON document"), \(bytes) bytes"
                + (more ? "; outline cut to \(outline.count) lines" : "")
            return ([head] + outline).joined(separator: "\n")
        }
    }

    /// Why text has no shape.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// Neither a JSON document nor JSON Lines.
        case notJSON(String)

        /// Human-readable explanation.
        public var description: String {
            switch self {
            case .notJSON(let detail): "not JSON or JSON Lines: \(detail)"
            }
        }
    }

    /// The options in force.
    public let options: Options

    /// Creates an outliner.
    public init(options: Options = Options()) {
        self.options = options
    }

    /// Outlines `text`: a JSON document, or JSON Lines when the whole does not parse and every non-empty
    /// line does.
    ///
    /// - Throws: `Failure.notJSON` otherwise.
    public func run(_ text: String) throws -> Report {
        var root = Node()
        let format: String
        let records: Int
        if let value = Self.decode(text) {
            root.absorb(value, depth: 0, options: options)
            (format, records) = ("json", 1)
        } else {
            let lines = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let values = lines.compactMap { Self.decode(String($0)) }
            guard !values.isEmpty, values.count == lines.count else {
                throw Failure.notJSON(lines.isEmpty ? "empty input" : "line \(values.count + 1) does not parse")
            }
            root.absorb(.array(values), depth: 0, options: options)
            (format, records) = ("jsonl", values.count)
        }
        var outline: [String] = []
        describe(root, name: "(root)", optional: false, depth: 0, into: &outline)
        let more = outline.count > options.maxLines
        return Report(
            format: format, records: records, bytes: text.utf8.count, outline: Array(outline.prefix(options.maxLines)),
            more: more)
    }

    /// Appends the lines for `node` and everything under it.
    private func describe(_ node: Node, name: String, optional: Bool, depth: Int, into lines: inout [String]) {
        guard lines.count <= options.maxLines else { return }
        let indent = String(repeating: "  ", count: depth)
        lines.append("\(indent)\(name)\(optional ? "?" : ""): \(node.summary())")
        if let element = node.element.first {
            if !element.keys.isEmpty {
                describeKeys(of: element, depth: depth + 1, into: &lines)
            } else if let nested = element.element.first, !nested.keys.isEmpty {
                describe(element, name: "[]", optional: false, depth: depth + 1, into: &lines)
            }
        }
        if !node.keys.isEmpty { describeKeys(of: node, depth: depth + 1, into: &lines) }
    }

    /// Appends one line per key of an object node, marking keys some objects lack. Plain values come
    /// before nested ones, so one large subtree cannot push its siblings past the line cap.
    private func describeKeys(of node: Node, depth: Int, into lines: inout [String]) {
        let listed = node.keys.prefix(options.maxKeys)
        let ordered =
            listed.filter { node.children[$0]?.isContainer == false }
            + listed.filter { node.children[$0]?.isContainer == true }
        for key in ordered {
            guard let child = node.children[key] else { continue }
            describe(child, name: key, optional: child.seen < node.objects, depth: depth, into: &lines)
        }
        if node.keys.count > options.maxKeys {
            lines.append("\(String(repeating: "  ", count: depth))… \(node.keys.count - options.maxKeys) more keys")
        }
    }

    /// A JSON value from text, or nil.
    static func decode(_ text: String) -> JSONValue? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }
}
