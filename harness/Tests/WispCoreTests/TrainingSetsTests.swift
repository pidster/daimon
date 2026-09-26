import Foundation
import Testing
import WispTestSupport

@testable import WispCore

/// The training sets under `training/` stay apart: no two parts of a task, and not the shipped examples
/// and the dev set, share an example exactly, after normalising, by family, or by near match.
@Suite struct TrainingSetsTests {
    static let root = RiskEvalSet.file.deletingLastPathComponent().deletingLastPathComponent()

    private func part(_ task: String, _ name: String) -> [TrainingSplit.Example]? {
        let url = Self.root.appending(path: task).appending(path: "\(name).tsv")
        return (try? String(contentsOf: url, encoding: .utf8)).map(TrainingSplit.parse)
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

    @Test func theShippedExamplesStayApartFromTheDevSet() throws {
        let shipped = RiskExamples.bundled.map { TrainingSplit.Example(label: $0.level.rawValue, text: $0.command) }
        let dev = try #require(part("risk", "dev"))
        #expect(dev.count == RiskEvalSet.labelled.count && dev.count > 100)
        let found = TrainingSplit.overlaps(shipped, dev)
        #expect(found.isEmpty, "shipped examples overlapping the dev set: \(found)")
    }

    @Test func familiesIgnoreWhatVariesAndKeepWhatMatters() {
        #expect(TrainingSplit.family(of: "cat README.md") == TrainingSplit.family(of: "cat  notes.txt"))
        #expect(TrainingSplit.family(of: "cat ~/.ssh/id_rsa") != TrainingSplit.family(of: "cat notes.txt"))
        #expect(TrainingSplit.family(of: "curl -O https://a.example/x.tgz") == "curl -o <url>")
        #expect(TrainingSplit.family(of: "sleep 30") == TrainingSplit.family(of: "sleep 5"))
        #expect(TrainingSplit.family(of: "git show 3f9a2b1c") == "git show <hex>")
        #expect(TrainingSplit.normalised("a\u{200B}b  C") == "ab c")
    }

    @Test func splitsKeepFamiliesWholeTheLabelsInProportionAndRepeat() {
        var examples: [TrainingSplit.Example] = []
        for n in 0..<60 { examples.append(.init(label: "a", text: "tool\(n) --flag file\(n).txt")) }
        for n in 0..<40 { examples.append(.init(label: "b", text: "other\(n) run")) }
        examples += (0..<5).map { .init(label: "a", text: "cat note\($0).md") }  // one family of five
        let parts = TrainingSplit.split(examples, fractions: [0.8, 0.2], seed: 7)
        #expect(parts.map(\.count).reduce(0, +) == examples.count)
        #expect(parts[1].filter { $0.label == "b" }.count == 8)
        let family = parts.map { $0.filter { $0.text.hasPrefix("cat ") }.count }
        #expect(family.contains(5) && family.contains(0), "a family stays in one part: \(family)")
        #expect(TrainingSplit.split(examples, fractions: [0.8, 0.2], seed: 7) == parts)
        #expect(TrainingSplit.overlaps(parts[0], parts[1]).isEmpty)
    }

    @Test func overlapsAreFoundByEachKind() {
        let train: [TrainingSplit.Example] = [
            .init(label: "x", text: "git status"), .init(label: "x", text: "cat notes.txt"),
            .init(label: "x", text: "docker compose -f dev.yml up --build --remove-orphans --wait web"),
        ]
        let kinds = TrainingSplit.overlaps(
            train,
            [
                .init(label: "x", text: "git status"), .init(label: "x", text: "Git   Status"),
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
