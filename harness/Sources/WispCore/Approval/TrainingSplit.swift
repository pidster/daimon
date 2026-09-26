import Foundation

/// Labelled sets kept apart: the train, dev, and test parts of a classifier task's examples under
/// `training/<task>/`, split so that no family of near-identical examples spans two parts, and checked
/// for overlap exactly, after normalising, by family, and by near match
/// ([ADR 0038](../../../../docs/decisions/0038-fast-specialised-classifiers.md), amendment).
public enum TrainingSplit {
    /// One labelled example of any task.
    public struct Example: Equatable, Hashable, Sendable {
        /// The label.
        public var label: String
        /// The text.
        public var text: String

        /// Creates an example.
        public init(label: String, text: String) {
            self.label = label
            self.text = text
        }
    }

    /// Two examples in different parts that are too alike, and how.
    public struct Overlap: Equatable, Sendable {
        /// Identical, identical after normalising whitespace and case, the same family, or a near match.
        public enum Kind: String, Sendable { case exact, normalised, family, near }
        /// How they overlap.
        public var kind: Kind
        /// The example in the first part.
        public var first: String
        /// The example in the second part.
        public var second: String
    }

    /// Reads `label<TAB>text` lines, `#` comments and blank lines skipped. Text is kept as written, a
    /// U+200B in a secret-looking value included, so a split writes it back unchanged; comparisons
    /// ignore it.
    public static func parse(_ text: String) -> [Example] {
        text.split(separator: "\n").compactMap { raw in
            let line = String(raw)
            guard !line.hasPrefix("#"), let tab = line.firstIndex(of: "\t") else { return nil }
            let body = line[line.index(after: tab)...].trimmingCharacters(in: .whitespaces)
            return body.isEmpty ? nil : Example(label: String(line[..<tab]), text: body)
        }
    }

    /// Writes examples as `label<TAB>text` lines under a header.
    public static func write(_ examples: [Example], header: [String]) -> String {
        (header.map { "# \($0)" } + examples.map { "\($0.label)\t\($0.text)" }).joined(separator: "\n") + "\n"
    }

    /// Whitespace collapsed and case folded: what makes two lines the same line.
    public static func normalised(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{200B}", with: "").lowercased().split(whereSeparator: \.isWhitespace).joined(
            separator: " ")
    }

    /// The patterns a family ignores, in order: URLs, quoted strings, hex runs, numbers, and path or file
    /// names other than dotfiles, keeping whether a path is under the home folder or absolute.
    static let placeholders: [(pattern: String, template: String)] = [
        (#"[a-z][a-z0-9+.-]*://\S+"#, "<url>"),
        (#"'[^']*'|"[^"]*""#, "<s>"),
        (#"\b[0-9a-f]{7,}\b"#, "<hex>"),
        (#"\b\d+(?:[.:]\d+)*\b"#, "<n>"),
        (#"(~|/)?(?:[\w@.+-]+/)*[\w@+-][\w@.+-]*\.[A-Za-z0-9]{1,6}\b"#, "$1<f>"),
    ]

    /// The family of a text: what is left when the parts that vary between near-identical examples are
    /// replaced by placeholders.
    public static func family(of text: String) -> String {
        var result = normalised(text)
        for (pattern, template) in placeholders {
            guard let regex = try? RegexCache.regex(pattern) else { continue }
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: template)
        }
        return result
    }

    /// The words of a text, for near matches.
    static func words(_ text: String) -> Set<String> {
        Set(normalised(text).split { !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "." }.map(String.init))
    }

    /// Splits examples into parts of the given fractions, a whole family always in one part, and each
    /// label spread across the parts in proportion by dealing families by their commonest label. The same
    /// examples and seed always give the same parts.
    ///
    /// - Parameters:
    ///   - examples: What to split.
    ///   - fractions: Each part's share, such as `[0.85, 0.15]`; they need not sum to 1.
    ///   - seed: Chooses the order families are dealt in.
    /// - Returns: The parts, in the order of `fractions`.
    public static func split(_ examples: [Example], fractions: [Double], seed: UInt64) -> [[Example]] {
        var parts = Array(repeating: [Example](), count: fractions.count)
        let total = fractions.reduce(0, +)
        var generator = SeededGenerator(seed: seed)
        var families = clusters(examples).sorted { $0.key < $1.key }
        families.shuffle(using: &generator)
        let perLabel = Dictionary(grouping: examples, by: \.label).mapValues(\.count)
        var counts: [String: [Int]] = perLabel.mapValues { _ in Array(repeating: 0, count: fractions.count) }
        for (_, members) in families {
            let label =
                Dictionary(grouping: members, by: \.label).max { ($0.value.count, $1.key) < ($1.value.count, $0.key) }?
                .key
                ?? members[0].label
            let have = counts[label] ?? []
            let need = { (index: Int) in fractions[index] / total * Double(perLabel[label] ?? 0) - Double(have[index]) }
            let index = fractions.indices.max { need($0) < need($1) } ?? 0
            parts[index] += members
            counts[label]?[index] += members.count
        }
        return parts
    }

    /// Examples grouped so that near-identical ones share a group: the same family, or a near match
    /// (`nearAt` of their words) with any member, joined transitively. Keyed by the group's first family.
    static func clusters(_ examples: [Example], nearAt: Double = 0.8) -> [String: [Example]] {
        var parent = Array(examples.indices)
        func root(_ index: Int) -> Int {
            var index = index
            while parent[index] != index {
                parent[index] = parent[parent[index]]
                index = parent[index]
            }
            return index
        }
        func join(_ a: Int, _ b: Int) { parent[root(a)] = root(b) }
        var byFamily: [String: Int] = [:]
        let keys = examples.map { family(of: $0.text) }
        for (index, key) in keys.enumerated() {
            if let first = byFamily[key] { join(index, first) } else { byFamily[key] = index }
        }
        let bags = examples.map { words($0.text) }
        for i in examples.indices where bags[i].count >= 3 {
            for j in examples.indices.dropFirst(i + 1) where bags[j].count >= 3 && root(i) != root(j) {
                let shared = bags[i].intersection(bags[j]).count
                if Double(shared) / Double(bags[i].union(bags[j]).count) >= nearAt { join(i, j) }
            }
        }
        var groups: [Int: [Example]] = [:]
        for index in examples.indices { groups[root(index), default: []].append(examples[index]) }
        return Dictionary(uniqueKeysWithValues: groups.values.map { (keys[examples.firstIndex(of: $0[0]) ?? 0], $0) })
    }

    /// Every pair of examples, one from each set, that are too alike: the same text, the same after
    /// normalising, the same family, or sharing at least `nearAt` of their words.
    public static func overlaps(_ first: [Example], _ second: [Example], nearAt: Double = 0.8) -> [Overlap] {
        let exact = Set(first.map { $0.text.replacingOccurrences(of: "\u{200B}", with: "") })
        let normal = Dictionary(first.map { (normalised($0.text), $0.text) }, uniquingKeysWith: { a, _ in a })
        let families = Dictionary(first.map { (family(of: $0.text), $0.text) }, uniquingKeysWith: { a, _ in a })
        let firstWords = first.map { ($0.text, words($0.text)) }
        var found: [Overlap] = []
        for example in second {
            if exact.contains(example.text.replacingOccurrences(of: "\u{200B}", with: "")) {
                found.append(Overlap(kind: .exact, first: example.text, second: example.text))
            } else if let match = normal[normalised(example.text)] {
                found.append(Overlap(kind: .normalised, first: match, second: example.text))
            } else if let match = families[family(of: example.text)] {
                found.append(Overlap(kind: .family, first: match, second: example.text))
            } else {
                let mine = words(example.text)
                guard mine.count >= 3 else { continue }
                if let match = firstWords.first(where: { _, theirs in
                    theirs.count >= 3
                        && Double(mine.intersection(theirs).count) / Double(mine.union(theirs).count) >= nearAt
                }) {
                    found.append(Overlap(kind: .near, first: match.0, second: example.text))
                }
            }
        }
        return found
    }
}

/// SplitMix64: a small, seeded, repeatable random source, so a split is the same on every Mac.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    /// A generator starting from `seed`.
    init(seed: UInt64) { state = seed }

    /// The next value.
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
