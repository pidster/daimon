import Foundation

/// Flaky tests found by comparing runs: each run's output read, without the model, into a pass or fail
/// per test, and the tests whose outcome differs between runs reported, with the ones that always
/// fail beside them ([ADR 0039](../../../../docs/decisions/0039-exact-condensers.md)). Reads
/// swift-testing, XCTest, cargo test, pytest with `-rA` or `-v`, and go test with `-v`.
public struct FlakyTests: Sendable {
    /// A test's outcome in one run.
    public enum Outcome: String, Sendable, Equatable {
        /// It passed.
        case pass
        /// It failed.
        case fail
    }

    /// One test across the runs.
    public struct Test: Equatable, Sendable {
        /// Its name as the runner printed it.
        public var name: String
        /// Its outcome in each run, nil where the run did not report it.
        public var outcomes: [Outcome?]

        /// Runs it passed.
        public var passes: Int { outcomes.filter { $0 == .pass }.count }
        /// Runs it failed.
        public var failures: Int { outcomes.filter { $0 == .fail }.count }
    }

    /// Why the runs could not be compared.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// Fewer than two runs.
        case tooFewRuns(Int)
        /// A run in which no test outcome could be read.
        case unreadable(run: Int)

        /// Human-readable explanation.
        public var description: String {
            switch self {
            case .tooFewRuns(let count): "comparing needs at least two runs, got \(count)"
            case .unreadable(let run):
                "run \(run) reports no test outcomes this reads (swift test, XCTest, cargo test, pytest -rA, go test -v)"
            }
        }
    }

    /// The comparison.
    public struct Report: Equatable, Sendable {
        /// Runs compared.
        public var runs: Int
        /// Distinct tests seen.
        public var tests: Int
        /// Tests that passed in some runs and failed in others, most often failing first.
        public var flaky: [Test]
        /// Tests that failed in every run that reported them.
        public var alwaysFailing: [Test]
        /// Tests beyond the cap, left out of both lists.
        public var more: Int

        /// The report as JSON, the shape the MCP tool returns.
        public var json: JSONValue {
            let encode = { (tests: [Test]) -> JSONValue in
                .array(
                    tests.map { test in
                        .object([
                            "name": .string(test.name), "passes": .int(test.passes), "failures": .int(test.failures),
                            "outcomes": .array(test.outcomes.map { $0.map { .string($0.rawValue) } ?? .null }),
                        ])
                    })
            }
            return .object([
                "runs": .int(runs), "tests": .int(tests), "flaky": encode(flaky),
                "alwaysFailing": encode(alwaysFailing),
                "more": .int(more),
            ])
        }

        /// The report as lines: a headline, then each test with its outcome per run (`P`, `F`, `-`).
        public var rendered: String {
            var lines = [
                "\(runs) runs, \(tests) tests: \(flaky.count) flaky, \(alwaysFailing.count) failing in every run"
            ]
            let marks = { (test: Test) in test.outcomes.map { $0 == .pass ? "P" : $0 == .fail ? "F" : "-" }.joined() }
            lines += flaky.map {
                "flaky\t\(marks($0))\t\($0.name) (failed \($0.failures) of \($0.passes + $0.failures))"
            }
            lines += alwaysFailing.map { "failing\t\(marks($0))\t\($0.name)" }
            if more > 0 { lines.append("… \(more) more") }
            return lines.joined(separator: "\n")
        }
    }

    /// Line formats, each with a `name` group and an `outcome` group whose text says pass or fail.
    static let formats: [(pattern: String, passes: Set<String>)] = [
        // swift-testing: ✔ Test name() passed after …; ✘ Test name() failed after …
        (#"^(?<outcome>✔|✘) Test (?<name>.+?) (passed|failed) after"#, ["✔"]),
        // XCTest: Test Case '-[Suite test]' passed (0.001 seconds).
        (#"^Test Case '(?<name>[^']+)' (?<outcome>passed|failed)"#, ["passed"]),
        // cargo test: test path::name ... ok | FAILED
        (#"^test (?<name>\S+) \.\.\. (?<outcome>ok|FAILED)$"#, ["ok"]),
        // pytest -rA: PASSED tests/x.py::t, FAILED tests/x.py::t - …; -v: tests/x.py::t PASSED
        (#"^(?<outcome>PASSED|FAILED|ERROR) (?<name>\S+::\S+)"#, ["PASSED"]),
        (#"^(?<name>\S+::\S+) (?<outcome>PASSED|FAILED|ERROR)\b"#, ["PASSED"]),
        // go test -v: --- PASS: TestName (0.00s)
        (#"^\s*--- (?<outcome>PASS|FAIL): (?<name>\S+)"#, ["PASS"]),
    ]

    /// Tests to list at most across both lists.
    public var maxTests: Int

    /// Creates a comparison that lists at most `maxTests`.
    public init(maxTests: Int = 40) {
        self.maxTests = maxTests
    }

    /// Each test's outcome in one run's output; a test reported twice keeps its last outcome.
    public static func outcomes(in text: String) -> [String: Outcome] {
        var found: [String: Outcome] = [:]
        for raw in text.split(separator: "\n") {
            let line = String(raw)
            for (pattern, passes) in formats {
                guard let groups = KnownFailures.groups(pattern, in: line, names: ["name", "outcome"]),
                    let name = groups["name"], let outcome = groups["outcome"]
                else { continue }
                found[name] = passes.contains(outcome) ? .pass : .fail
                break
            }
        }
        return found
    }

    /// Compares the runs.
    ///
    /// - Parameter runs: Each run's output, in order.
    /// - Returns: The flaky and always-failing tests.
    /// - Throws: `Failure`.
    public func run(_ runs: [String]) throws -> Report {
        guard runs.count >= 2 else { throw Failure.tooFewRuns(runs.count) }
        let perRun = runs.map(Self.outcomes(in:))
        if let empty = perRun.firstIndex(where: \.isEmpty) { throw Failure.unreadable(run: empty + 1) }
        let names = Set(perRun.flatMap(\.keys)).sorted()
        let tests = names.map { name in Test(name: name, outcomes: perRun.map { $0[name] }) }
        let flaky = tests.filter { $0.passes > 0 && $0.failures > 0 }
            .sorted { ($1.failures, $0.name) < ($0.failures, $1.name) }
        let failing = tests.filter { $0.passes == 0 && $0.failures > 0 }
        let keptFlaky = Array(flaky.prefix(maxTests))
        let keptFailing = Array(failing.prefix(max(0, maxTests - keptFlaky.count)))
        return Report(
            runs: runs.count, tests: tests.count, flaky: keptFlaky, alwaysFailing: keptFailing,
            more: flaky.count + failing.count - keptFlaky.count - keptFailing.count)
    }
}
