import Foundation
import Synchronization
import Testing

@testable import WispCore

/// The exact pre-pass triage runs before the model, over output in each format it reads.
@Suite struct KnownFailuresTests {
    /// Asserts that `text` is explained completely and yields exactly these `(kind, location)` pairs.
    private func check(
        _ text: String, _ expected: [(String, String)], sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let scan = KnownFailures.scan(text)
        #expect(scan.unexplained.isEmpty, "unexplained: \(scan.unexplained)", sourceLocation: sourceLocation)
        #expect(
            scan.findings.map { "\($0.kind) \($0.location ?? "-")" } == expected.map { "\($0.0) \($0.1)" },
            "\(scan.findings)", sourceLocation: sourceLocation)
    }

    @Test func swiftAndClangDiagnosticsAreReadWithTheirLocation() {
        check(
            """
            [5/12] Compiling WispCore Agent.swift
            /src/Sources/Agent.swift:42:13: error: cannot find 'fooBar' in scope
                    let x = fooBar()
            /src/Sources/Agent.swift:58:9: warning: variable 'unused' was never used
            main.c:7: fatal error: 'missing.h' file not found
            error: fatalError
            """,
            [
                ("error", "/src/Sources/Agent.swift:42:13"), ("warning", "/src/Sources/Agent.swift:58:9"),
                ("error", "main.c:7"),
            ])
        let message = KnownFailures.scan("a.swift:1:2: error: boom").findings.first?.message
        #expect(message == "boom")
    }

    @Test func swiftTestingIssuesAreTestFailuresAtTheirAssertion() {
        check(
            """
            ✔ Test capturesOutput() passed after 0.012 seconds.
            ✘ Test respectsTimeout() recorded an issue at CommandRunnerTests.swift:88:9: Expectation failed: false
            ✘ Test respectsTimeout() failed after 1.203 seconds with 1 issue.
            ✘ Suite CommandRunnerTests failed after 1.3 seconds with 1 issue.
            ✘ Test run with 40 tests in 6 suites failed after 2.100 seconds with 1 issue.
            """,
            [("test-failure", "CommandRunnerTests.swift:88:9")])
        #expect(
            KnownFailures.scan("✘ Test a() recorded an issue at A.swift:1:1: boom").findings.first?.message
                == "a(): boom")
    }

    @Test func rustcErrorsTakeTheLocationFromTheArrowLine() {
        check(
            """
               Compiling tools v0.1.0 (/src/tools)
            error[E0425]: cannot find value `undefined_name` in this scope
              --> src/main.rs:14:20
               |
            14 |     let total = undefined_name + 1;
            warning: unused variable: `x`
             --> src/lib.rs:3:9
            error: could not compile `tools` (bin "tools") due to 1 previous error
            """,
            [("error", "src/main.rs:14:20"), ("warning", "src/lib.rs:3:9")])
        #expect(
            KnownFailures.scan("error[E0308]: mismatched\n --> a.rs:1:1").findings.first?.message
                == "[E0308] mismatched")
    }

    @Test func cargoTestFailuresAndPanicsAreRead() {
        check(
            """
            running 2 tests
            test parser::parses ... ok
            test parser::rejects ... FAILED

            failures:

            ---- parser::rejects stdout ----
            thread 'parser::rejects' panicked at src/parser.rs:40:9:
            note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace

            failures:
                parser::rejects

            test result: FAILED. 1 passed; 1 failed; 0 ignored
            """,
            [("test-failure", "parser::rejects"), ("test-failure", "src/parser.rs:40:9")])
    }

    @Test func pytestAndGoTestSummariesAreRead() {
        check(
            """
            =================================== FAILURES ===================================
            =========================== short test summary info ============================
            FAILED tests/test_math.py::test_divide - ZeroDivisionError: division by zero
            ERROR tests/test_db.py::test_connect
            ========================= 1 failed, 1 error, 2 passed in 0.04s =================
            """,
            [("test-failure", "tests/test_math.py::test_divide"), ("error", "tests/test_db.py::test_connect")])
        check(
            """
            --- FAIL: TestParse (0.00s)
            FAIL
            FAIL\texample.com/pkg\t0.012s
            """,
            [("test-failure", "TestParse")])
    }

    @Test func aFailureNoPatternReadsIsLeftForTheModel() {
        let scan = KnownFailures.scan(
            """
            a.swift:1:1: error: known
            Segmentation fault: the process crashed
            """)
        #expect(scan.findings.count == 1 && !scan.explainsEverything)
        #expect(scan.unexplained == ["Segmentation fault: the process crashed"])
        #expect(!KnownFailures.scan("all good\nBuild complete!").explainsEverything)
        // A rustc head with no location nearby is left for the model.
        let bare = KnownFailures.scan("error: linker `cc` not found")
        #expect(bare.findings.isEmpty && bare.unexplained == ["error: linker `cc` not found"])
        #expect(KnownFailures.declaredNames(#"(?<a>x)(?<b2>y)(z)"#) == ["a", "b2"])
        #expect(KnownFailures.groups(#"(?<a>x)"#, in: "x", names: ["a", "missing"]) == ["a": "x"])
    }

    @Test func triageSkipsTheModelForAChunkReadExactlyAndMergesOtherwise() async throws {
        let calls = Mutex(0)
        let triage = Triage(options: .init(chunkBytes: 4096)) { _ in
            calls.withLock { $0 += 1 }
            return
                #"{"failures":[{"kind":"crash","message":"segfault"},{"kind":"error","location":"a.swift:1:1","message":"reworded"}]}"#
        }
        let exact = try await triage.run(.init(text: "a.swift:1:1: error: known"), from: .path("build.log"))
        #expect(calls.withLock { $0 } == 0 && exact.exactChunks == 1 && exact.findings.count == 1)
        #expect(exact.rendered.contains("1 read exactly") && exact.json.objectValue?["exactChunks"] == 1)
        let mixed = try await triage.run(
            .init(text: "a.swift:1:1: error: known\nSegmentation fault: crashed"), from: .path("build.log"))
        #expect(calls.withLock { $0 } == 1 && mixed.exactChunks == 0)
        #expect(mixed.findings.map(\.message) == ["known", "segfault"], "the exact finding wins its location")
    }
}
