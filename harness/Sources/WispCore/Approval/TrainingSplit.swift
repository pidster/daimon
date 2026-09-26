import Foundation

/// Labelled sets kept apart: the train, dev, and test parts of a classifier task's examples under
/// `training/<task>/`, split so that no family of near-identical examples spans two parts, and checked
/// for overlap exactly, after removing whitespace and shell plumbing, by family, and by near match
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
        /// Identical; identical once whitespace and shell plumbing are removed; the same family; or a
        /// near match.
        public enum Kind: String, Sendable { case exact, normalised, family, near }
        /// How they overlap.
        public var kind: Kind
        /// The example in the first part.
        public var first: String
        /// The example in the second part.
        public var second: String
    }

    /// Reads `label<TAB>text` lines, `#` comments and blank lines skipped. Text is kept exactly as
    /// written, leading indentation and a U+200B in a secret-looking value included, so a split writes
    /// it back unchanged; comparisons ignore the U+200B. Only a trailing carriage return goes.
    public static func parse(_ text: String) -> [Example] {
        text.split(separator: "\n").compactMap { raw in
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : String(raw)
            guard !line.hasPrefix("#"), let tab = line.firstIndex(of: "\t") else { return nil }
            let body = String(line[line.index(after: tab)...])
            guard !body.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return Example(label: String(line[..<tab]), text: body)
        }
    }

    /// The lines `parse` skips that are neither comments nor blank: each lost its tab or has no text.
    public static func malformed(_ text: String) -> [String] {
        text.split(separator: "\n").map(String.init).filter { line in
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty, !line.hasPrefix("#") else { return false }
            guard let tab = line.firstIndex(of: "\t") else { return true }
            return line[line.index(after: tab)...].trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    /// Writes examples as `label<TAB>text` lines under a header.
    public static func write(_ examples: [Example], header: [String]) -> String {
        (header.map { "# \($0)" } + examples.map { "\($0.label)\t\($0.text)" }).joined(separator: "\n") + "\n"
    }

    /// Whitespace collapsed: what makes two lines the same line. Case is kept, since it matters in
    /// flags (`git branch -D` is not `-d`).
    public static func normalised(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{200B}", with: "").split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// Shell plumbing that does not change what a command is: a `VAR=$(…)` wrapper, `VAR=value`
    /// prefixes, redirections to a file descriptor or `/dev/null`, `git -C <dir>`, and `-q`.
    static let plumbing: [(pattern: String, template: String)] = [
        (#"^[A-Za-z_][A-Za-z0-9_]*=\$\((.*)\)$"#, "$1"),
        (#"^(?:[A-Za-z_][A-Za-z0-9_]*=(?:"[^"]*"|'[^']*'|\S*) +)+"#, ""),
        (#" +\d?>&\d\b"#, ""),
        (#" +\d?> */dev/null\b"#, ""),
        (#"\bgit +-C +(?:"[^"]*"|'[^']*'|\S+)"#, "git"),
        (#" -q\b"#, ""),
    ]

    /// The patterns a family ignores, in order: URLs; hex runs, glued to a name too; numbers, glued to
    /// letters too (`v26.10.0`, `0.00s`) but not a flag's digit, so `kill -9` stays apart from
    /// `kill -0`; and file names with an extension. Quoted text is kept, since in a command it is often
    /// the code that runs; path components are replaced by `pathShape`.
    static let placeholders: [(pattern: String, template: String)] = [
        (#"[a-z][a-z0-9+.-]*://\S+"#, "<url>"),
        (#"(?<![0-9A-Za-z])[0-9a-f]{7,}(?![0-9A-Za-z])|(?<=-)[0-9a-f]{7,}\b"#, "<hex>"),
        (#"(?<! -)(?<!^-)\d+(?:[.,:]\d+)*"#, "<n>"),
        (#"\b[\w@+-][\w@.+-]*\.[A-Za-z][A-Za-z0-9]{0,11}\b"#, "<f>"),
    ]

    /// Applies each pattern in turn.
    private static func replacing(_ text: String, _ rules: [(pattern: String, template: String)]) -> String {
        var result = text
        for (pattern, template) in rules {
            guard let regex = try? RegexCache.regex(pattern) else { continue }
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: template)
        }
        return result
    }

    /// Whether every pattern the checks rely on compiles; a test fails if one does not, since a pattern
    /// that is skipped silently weakens every family.
    static var patternsCompile: Bool {
        (plumbing + placeholders).allSatisfy { (try? RegexCache.regex($0.pattern)) != nil }
    }

    /// `text` normalised with its shell plumbing removed.
    public static func canonical(_ text: String) -> String {
        normalised(replacing(normalised(text), plumbing))
    }

    /// A path's components other than dotfiles replaced, keeping whether it is under home or root:
    /// `~/.ssh/id_rsa` is `~/.ssh/<p>`, and `/tmp/a/b` is `/<p>`.
    static func pathShape(_ token: String) -> String {
        guard token.contains("/") || token.hasPrefix("~") else { return token }
        var out: [String] = []
        for component in token.split(separator: "/", omittingEmptySubsequences: false).map(String.init) {
            let kept = component.isEmpty || component == "~" || component.hasPrefix(".") || component.hasPrefix("<")
            let piece = kept ? component : "<p>"
            if piece == "<p>", out.last == "<p>" { continue }
            out.append(piece)
        }
        return out.joined(separator: "/")
    }

    /// The family of a text: its canonical form with what varies between near-identical examples
    /// replaced by placeholders.
    public static func family(of text: String) -> String {
        replacing(canonical(text), placeholders).split(separator: " ").map { pathShape(String($0)) }
            .joined(separator: " ")
    }

    /// The words of a text's family, for near matches: numbers, ids, and paths already replaced, so two
    /// lines of one template with different values share their words.
    static func words(_ text: String) -> Set<String> {
        let keep: Set<Character> = ["-", ".", "<", ">"]
        return Set(family(of: text).split { !$0.isLetter && !$0.isNumber && !keep.contains($0) }.map(String.init))
    }

    /// Whether two word sets nearly match: equal when either is under three words, otherwise sharing
    /// `nearAt` of their union.
    static func near(_ a: Set<String>, _ b: Set<String>, nearAt: Double) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a.count < 3 || b.count < 3 { return a == b }
        return Double(a.intersection(b).count) / Double(a.union(b).count) >= nearAt
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
                .key ?? members[0].label
            let have = counts[label] ?? []
            let need = { (index: Int) in fractions[index] / total * Double(perLabel[label] ?? 0) - Double(have[index]) }
            let index = fractions.indices.max { need($0) < need($1) } ?? 0
            parts[index] += members
            counts[label]?[index] += members.count
        }
        return parts
    }

    /// Examples grouped so that near-identical ones share a group: the same family, or a near match with
    /// any member, joined transitively. Keyed by the group's first family.
    public static func clusters(_ examples: [Example], nearAt: Double = 0.8) -> [String: [Example]] {
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
        for i in examples.indices {
            for j in examples.indices.dropFirst(i + 1)
            where root(i) != root(j) && near(bags[i], bags[j], nearAt: nearAt) {
                join(i, j)
            }
        }
        var groups: [Int: [Int]] = [:]
        for index in examples.indices { groups[root(index), default: []].append(index) }
        return Dictionary(
            uniqueKeysWithValues: groups.values.map { members in (keys[members[0]], members.map { examples[$0] }) })
    }

    /// Every pair of examples, one from each set, that are too alike: the same text, the same canonical
    /// text, the same family, or a near match.
    public static func overlaps(_ first: [Example], _ second: [Example], nearAt: Double = 0.8) -> [Overlap] {
        let clean = { (text: String) in text.replacingOccurrences(of: "\u{200B}", with: "") }
        let exact = Set(first.map { clean($0.text) })
        let canonicals = Dictionary(first.map { (canonical($0.text), $0.text) }, uniquingKeysWith: { a, _ in a })
        let families = Dictionary(first.map { (family(of: $0.text), $0.text) }, uniquingKeysWith: { a, _ in a })
        let firstWords = first.map { ($0.text, words($0.text)) }
        var found: [Overlap] = []
        for example in second {
            if exact.contains(clean(example.text)) {
                found.append(Overlap(kind: .exact, first: example.text, second: example.text))
            } else if let match = canonicals[canonical(example.text)] {
                found.append(Overlap(kind: .normalised, first: match, second: example.text))
            } else if let match = families[family(of: example.text)] {
                found.append(Overlap(kind: .family, first: match, second: example.text))
            } else {
                let mine = words(example.text)
                if let match = firstWords.first(where: { near(mine, $0.1, nearAt: nearAt) }) {
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
