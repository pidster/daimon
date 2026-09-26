import Foundation

/// A command labelled with the risk level the approval gate should give it: a training example for
/// a specialised classifier, or a case to measure one against.
public struct RiskExample: Equatable, Sendable {
    /// The command line.
    public var command: String
    /// The level it should be rated.
    public var level: RiskLevel

    /// Creates an example.
    public init(command: String, level: RiskLevel) {
        self.command = command
        self.level = level
    }
}

/// Labelled commands in wisp's text format: one per line, `level<TAB>command`, with `#` comments and
/// blank lines ignored ([ADR 0038](../../../../docs/decisions/0038-fast-specialised-classifiers.md)).
public enum RiskExamples {
    /// A line that is not a labelled command.
    public struct Problem: Error, CustomStringConvertible, Equatable {
        /// The 1-based line number.
        public var line: Int
        /// What is wrong with it.
        public var reason: String

        /// Human-readable explanation.
        public var description: String { "line \(line): \(reason)" }
    }

    /// The examples shipped with wisp, from `Resources/risk-examples.tsv`: what `wisp classifier
    /// train` learns from when given nothing else. Kept apart from the eval set that measures it.
    public static let bundled: [RiskExample] = (try? parse(RiskExamplesText.text)) ?? []

    /// Parses labelled lines.
    ///
    /// - Throws: `Problem` for the first line that has no tab, an unknown level, or no command.
    public static func parse(_ text: String) throws -> [RiskExample] {
        var examples: [RiskExample] = []
        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            // Spaces and a carriage return around the line go; a tab is the separator, so it stays.
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \r"))
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let tab = line.firstIndex(of: "\t") else {
                throw Problem(line: index + 1, reason: "expected level<TAB>command")
            }
            let label = String(line[..<tab])
            guard let level = RiskLevel(rawValue: label) else {
                throw Problem(line: index + 1, reason: "unknown level '\(label)'; use safe, moderate, or dangerous")
            }
            let command = line[line.index(after: tab)...].trimmingCharacters(in: .whitespaces)
            guard !command.isEmpty else { throw Problem(line: index + 1, reason: "no command after the level") }
            examples.append(RiskExample(command: command, level: level))
        }
        return examples
    }

    /// Reads and parses a file of labelled lines.
    ///
    /// - Throws: A read error, or `Problem`.
    public static func load(_ url: URL) throws -> [RiskExample] {
        try parse(String(contentsOf: url, encoding: .utf8))
    }
}
