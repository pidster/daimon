import Foundation
import Testing
import WispTestSupport

@testable import WispCore

/// The training sets under `training/` stay apart: no two parts of a task, and not the shipped examples
/// and the dev set, share an example exactly, after normalising, by family, or by near match.
@Suite(.serialized) struct TrainingSetsTests {
    static let root = RiskEvalSet.file.deletingLastPathComponent().deletingLastPathComponent()

    /// Each task's labels: a part with any other label fails.
    static let labels: [String: Set<String>] = [
        "risk": ["safe", "moderate", "dangerous"], "secrets": ["secret", "personal", "none"],
        "failures": ["error", "test-failure", "warning", "crash", "none"],
        "log-severity": ["fault", "error", "warning", "info"],
    ]

    private func text(_ task: String, _ name: String) -> String? {
        try? String(contentsOf: Self.root.appending(path: task).appending(path: "\(name).tsv"), encoding: .utf8)
    }

    private func part(_ task: String, _ name: String) -> [TrainingSplit.Example]? {
        text(task, name).map(TrainingSplit.parse)
    }

    @Test(arguments: ["risk", "secrets", "failures", "log-severity"])
    func everyLineIsWellFormedWithAKnownLabelAndNoRepeats(task: String) throws {
        for name in ["train", "dev", "test"] {
            guard let raw = text(task, name) else { continue }
            #expect(TrainingSplit.malformed(raw).isEmpty, "\(task)/\(name): \(TrainingSplit.malformed(raw).prefix(3))")
            let examples = TrainingSplit.parse(raw)
            let unknown = examples.filter { !(Self.labels[task] ?? []).contains($0.label) }
            #expect(unknown.isEmpty, "\(task)/\(name) unknown labels: \(unknown.prefix(3))")
            let texts = examples.map { TrainingSplit.canonical($0.text) }
            #expect(Set(texts).count == texts.count, "\(task)/\(name) repeats a line")
        }
    }

    @Test(arguments: ["risk", "secrets", "failures", "log-severity"])
    func noTwoPartsOfATaskOverlap(task: String) throws {
        let parts = ["train", "dev", "test"].compactMap { name in part(task, name).map { (name, $0) } }
        #expect(parts.count >= 2, "\(task) has a train and a dev part at least")
        for (index, (name, examples)) in parts.enumerated() {
            #expect(!examples.isEmpty, "\(task)/\(name) is empty")
            for (other, later) in parts.dropFirst(index + 1) {
                let found = TrainingSplit.overlaps(examples, later)
                #expect(found.isEmpty, "\(task): \(name) and \(other) overlap: \(found.prefix(5))")
            }
        }
    }

    @Test func theShippedExamplesStayApartFromTheDevAndTestSets() throws {
        let shipped = RiskExamples.bundled.map { TrainingSplit.Example(label: $0.level.rawValue, text: $0.command) }
        let dev = try #require(part("risk", "dev"))
        #expect(dev.count == RiskEvalSet.labelled.count && dev.count > 100)
        for (name, held) in [("dev", dev), ("test", part("risk", "test") ?? [])] {
            let found = TrainingSplit.overlaps(shipped, held)
            #expect(found.isEmpty, "shipped examples overlapping the \(name) set: \(found.prefix(5))")
        }
        #expect(TrainingSplit.patternsCompile)
    }

    @Test func theBundledExamplesAreTheRiskTrainSet() throws {
        // `scripts/check classifier-default` copies the train set into the bundle; editing either alone fails.
        let train = try #require(part("risk", "train")).map {
            "\($0.label)\t\($0.text.replacingOccurrences(of: "\u{200B}", with: ""))"
        }
        #expect(RiskExamples.bundled.map { "\($0.level.rawValue)\t\($0.command)" } == train)
    }

    @Test func familiesIgnoreWhatVariesAndKeepWhatMatters() {
        let family = TrainingSplit.family(of:)
        #expect(family("cat README.md") == family("cat  notes.txt"))
        #expect(family("cat ~/.ssh/id_rsa") == "cat ~/.ssh/<p>" && family("cat notes.txt") == "cat <f>")
        #expect(family("curl -O https://a.example/x.tgz") == "curl -O <url>")
        #expect(family("sleep 30") == family("sleep 5") && family("git show 3f9a2b1c") == "git show <hex>")
        #expect(TrainingSplit.normalised("a\u{200B}b  C") == "ab C", "case is kept")
        // Plumbing goes: redirections, a $( ) wrapper, assignments, git -C, and -q.
        #expect(TrainingSplit.canonical("h=$(git -C \"$dir\" rev-parse HEAD 2>/dev/null)") == "git rev-parse HEAD")
        #expect(TrainingSplit.canonical("swift build -c release 2>&1") == "swift build -c release")
        #expect(TrainingSplit.canonical("GIT_EDITOR=true git checkout -q main") == "git checkout main")
        // What changes the meaning stays: a flag's case and digit, and quoted code.
        #expect(family("git branch -D x") != family("git branch -d x"))
        #expect(family("kill -9 1") != family("kill -0 60442"))
        #expect(family("python3 -c 'print(1)'") != family("python3 -c 'import socket'"))
        // Numbers and ids glued to letters vary like any other.
        #expect(family("Node.js v26.10.0") == family("Node.js v22.9.0"))
        #expect(family("finished in 0.00s") == family("finished in 0.37s"))
        #expect(family("Running unittests rsdemo-d72c121ff0da5ac6") == "Running unittests rsdemo-<hex>")
        #expect(family("rm -rf /tmp/scratch-clone") == family("rm -rf /Users/me"))
        // Short lines match when their words are the same.
        #expect(TrainingSplit.near(["df", "-h"], ["df", "-h"], nearAt: 0.8))
        #expect(!TrainingSplit.near(["df", "-h"], ["du", "-h"], nearAt: 0.8))
        #expect(TrainingSplit.malformed("# c\nsafe\tls\nno tab\nsafe\t  \n") == ["no tab", "safe\t  "])
        #expect(TrainingSplit.parse("none\t    tests::first") == [.init(label: "none", text: "    tests::first")])
    }

    @Test func splitsKeepFamiliesWholeTheLabelsInProportionAndRepeat() {
        var examples: [TrainingSplit.Example] = []
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        let words: [String] = (0..<100).map { (n: Int) -> String in String([letters[n % 26], letters[n / 26]]) }
        for word in words.prefix(60) { examples.append(.init(label: "a", text: "tool\(word) --flag-\(word) now")) }
        for word in words.suffix(40) { examples.append(.init(label: "b", text: "other\(word) run-\(word)")) }
        examples += (0..<5).map { .init(label: "a", text: "cat note\($0).md") }  // one family of five
        let parts = TrainingSplit.split(examples, fractions: [0.8, 0.2], seed: 7)
        #expect(parts.map(\.count).reduce(0, +) == examples.count)
        #expect(parts[1].filter { $0.label == "b" }.count == 8)
        let family = parts.map { $0.filter { $0.text.hasPrefix("cat ") }.count }
        #expect(family.contains(5) && family.contains(0), "a family stays in one part: \(family)")
        #expect(TrainingSplit.split(examples, fractions: [0.8, 0.2], seed: 7) == parts)
        #expect(TrainingSplit.overlaps(parts[0], parts[1]).isEmpty)
    }

    @Test func theNearIndexMissesNoNearMatchThatComparingEveryPairFinds() throws {
        let bags = try #require(part("risk", "train")).prefix(400).map { TrainingSplit.words($0.text) }
        let index = NearIndex(Array(bags), nearAt: 0.8)
        var pairs = 0
        for i in bags.indices {
            let candidates = Set(index.candidates(for: bags[i]))
            for j in bags.indices where j != i && TrainingSplit.near(bags[i], bags[j], nearAt: 0.8) {
                pairs += 1
                #expect(candidates.contains(j), "\(bags[i]) and \(bags[j])")
            }
        }
        #expect(pairs > 0)
    }

    @Test func overlapsAreFoundByEachKind() {
        let train: [TrainingSplit.Example] = [
            .init(label: "x", text: "git status"), .init(label: "x", text: "cat notes.txt"),
            .init(label: "x", text: "docker compose -f dev.yml up --build --remove-orphans --wait web"),
        ]
        let kinds = TrainingSplit.overlaps(
            train,
            [
                .init(label: "x", text: "git status"), .init(label: "x", text: "git   status 2>&1"),
                .init(label: "x", text: "cat other.txt"),
                .init(label: "x", text: "docker compose -f dev.yml up --build --remove-orphans --wait api"),
                .init(label: "x", text: "ls -la"),
            ]
        ).map(\.kind)
        #expect(kinds == [.exact, .normalised, .family, .near])
        let parsed = TrainingSplit.parse("# c\nsecret\tkey=ab\u{200B}cd\n\nbad line\n")
        #expect(parsed == [.init(label: "secret", text: "key=ab\u{200B}cd")])
        #expect(TrainingSplit.write(parsed, header: ["h"]) == "# h\nsecret\tkey=ab\u{200B}cd\n")
    }
}
