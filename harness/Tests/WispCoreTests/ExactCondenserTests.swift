import Foundation
import Testing

@testable import WispCore

/// The deterministic condensers of ADR 0039: dependency audits, flaky tests, and hot paths.
@Suite struct ExactCondenserTests {
    // MARK: Dependency audits

    static let npm = """
        {"auditReportVersion": 2, "vulnerabilities": {
          "lodash": {"name": "lodash", "severity": "high", "isDirect": true, "range": "<4.17.21",
            "via": [{"source": 1523, "title": "Prototype Pollution", "url": "https://github.com/advisories/GHSA-p6mc-m468-83gw",
                     "severity": "high", "range": "<4.17.21"}],
            "fixAvailable": {"name": "lodash", "version": "4.17.21", "isSemVerMajor": false}},
          "minimist": {"name": "minimist", "severity": "critical", "isDirect": false, "range": "<1.2.6",
            "via": [{"source": 1179, "title": "Prototype Pollution in minimist", "url": "https://github.com/advisories/GHSA-xvch-5gv4-984h",
                     "severity": "critical"}], "fixAvailable": true},
          "mkdirp": {"name": "mkdirp", "severity": "critical", "isDirect": false, "via": ["minimist"], "fixAvailable": true},
          "request": {"name": "request", "severity": "moderate", "isDirect": true, "range": "*",
            "via": [{"source": 1, "title": "Server-Side Request Forgery", "url": "https://github.com/advisories/GHSA-p8p7-x288-28g6",
                     "severity": "moderate"}], "fixAvailable": false}
        }, "metadata": {"vulnerabilities": {"critical": 2, "high": 1, "moderate": 1, "total": 4}}}
        """

    @Test func npmAuditKeepsTheAdvisoriesMostSevereAndFixableFirst() throws {
        let report = try DependencyAudit().run(Self.npm)
        #expect(report.tool == "npm")
        #expect(
            report.advisories.map(\.package) == ["minimist", "lodash", "request"], "mkdirp only points at minimist")
        let lodash = try #require(report.advisories.first { $0.package == "lodash" })
        #expect(
            lodash.id == "GHSA-p6mc-m468-83gw" && lodash.fix == "upgrade lodash to 4.17.21" && lodash.direct == true)
        #expect(report.advisories.first { $0.package == "minimist" }?.fix == "npm audit fix")
        #expect(report.advisories.last?.fix == "none available" && report.advisories.last?.fixable == false)
        #expect(report.counts == ["critical": 1, "high": 1, "moderate": 1])
        #expect(report.rendered.hasPrefix("npm audit: 3 advisories (1 critical, 1 high, 1 moderate), 2 with a fix"))
        #expect(report.json.objectValue?["advisories"]?.arrayValue?.count == 3)
    }

    @Test func cargoAuditReadsAdvisoriesPatchesAndWarnings() throws {
        let cargo = """
            {"vulnerabilities": {"found": true, "count": 1, "list": [{
              "advisory": {"id": "RUSTSEC-2024-0001", "package": "time", "title": "Segfault in localtime_r",
                           "cvss": "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H"},
              "versions": {"patched": [">=0.2.23"]}, "package": {"name": "time", "version": "0.1.45"}}]},
             "warnings": {"unmaintained": [{"kind": "unmaintained", "package": {"name": "ansi_term", "version": "0.12.1"},
                                           "advisory": {"title": "ansi_term is Unmaintained"}}]}}
            """
        let report = try DependencyAudit().run(cargo)
        #expect(report.tool == "cargo")
        #expect(
            report.advisories == [
                .init(
                    package: "time", version: "0.1.45", severity: "critical", id: "RUSTSEC-2024-0001",
                    title: "Segfault in localtime_r", fix: "upgrade to >=0.2.23", direct: nil)
            ])
        #expect(report.warnings == ["unmaintained ansi_term 0.12.1: ansi_term is Unmaintained"])
        #expect(DependencyAudit.cvssSeverity("CVSS:3.1/AV:N/AC:L/PR:L/UI:N/S:U/C:H/I:N/A:N") == "high")
        #expect(DependencyAudit.cvssSeverity("CVSS:3.1/AV:L/AC:L/PR:L/UI:N/S:U/C:L/I:N/A:N") == "moderate")
        #expect(DependencyAudit.cvssSeverity("CVSS:3.1/AV:L/AC:L/PR:L/UI:N/S:U/C:N/I:N/A:N") == "low")
        #expect(DependencyAudit.cvssSeverity(nil) == "unknown")
    }

    @Test func pipAuditAndTheCapAndUnreadableInput() throws {
        let pip = """
            {"dependencies": [{"name": "requests", "version": "2.19.0", "vulns": [
              {"id": "PYSEC-2018-28", "fix_versions": ["2.20.0"], "description": "Requests before 2.20.0 sends auth headers\\nmore"}]},
              {"name": "flask", "version": "3.0.0", "vulns": []}]}
            """
        let report = try DependencyAudit().run(pip)
        #expect(report.tool == "pip-audit" && report.advisories.count == 1)
        #expect(report.advisories[0].title == "Requests before 2.20.0 sends auth headers")
        #expect(report.advisories[0].fix == "upgrade to 2.20.0")
        let capped = try DependencyAudit(maxAdvisories: 1).run(Self.npm)
        #expect(capped.advisories.count == 1 && capped.more == 2 && capped.rendered.contains("… 2 more"))
        #expect(throws: DependencyAudit.Failure.unrecognised("not JSON")) { try DependencyAudit().run("not json") }
        #expect(throws: DependencyAudit.Failure.unrecognised("no vulnerabilities, list, or dependencies")) {
            try DependencyAudit().run(#"{"x": 1}"#)
        }
    }

    @Test func sparseAndOlderAuditShapesStillRead() throws {
        // pip-audit before 2.5 printed a bare array; npm entries can lack most fields.
        let old = try DependencyAudit().run(#"[{"name": "urllib3", "version": "1.0", "vulns": [{"id": "CVE-1"}]}]"#)
        #expect(old.tool == "pip-audit" && old.advisories.first?.fix == "none available")
        #expect(old.advisories.first?.title == "" && old.advisories.first?.severity == "unknown")
        let sparse = try DependencyAudit().run(
            #"{"auditReportVersion": 2, "vulnerabilities": {"x": {"via": [{"source": 7}], "fixAvailable": {"version": "2.0.0", "isSemVerMajor": true}}}}"#
        )
        let advisory = try #require(sparse.advisories.first)
        #expect(advisory.id == "7" && advisory.version == "?" && advisory.severity == "unknown")
        #expect(advisory.fix == "upgrade x to 2.0.0 (breaking)" && advisory.direct == nil)
        #expect(sparse.rendered.contains("unknown\tx ?\t7"))
        let cargo = try DependencyAudit().run(
            #"{"vulnerabilities": {"list": [{"advisory": {"package": "a", "cvss": "not a vector"}}]}, "warnings": {"yanked": [{"package": {"name": "b"}}]}}"#
        )
        #expect(cargo.advisories.first?.package == "a" && cargo.advisories.first?.severity == "unknown")
        #expect(cargo.advisories.first?.fix == "none available" && cargo.warnings == ["yanked b "])
        #expect(DependencyAudit.idFromURL("GHSA-x") == "GHSA-x")
        #expect("\(DependencyAudit.Failure.unrecognised("x"))".hasSuffix(": x"))
        let empty = try DependencyAudit().run(#"{"auditReportVersion": 2, "vulnerabilities": {}}"#)
        #expect(empty.rendered == "npm audit: 0 advisories, 0 with a fix")
    }

    // MARK: Flaky tests

    @Test func runsAreComparedByTestName() throws {
        let first = """
            ✔ Test parses() passed after 0.01 seconds.
            ✘ Test times() failed after 1.20 seconds with 1 issue.
            ✘ Test broken() failed after 0.01 seconds with 1 issue.
            """
        let second = """
            ✔ Test parses() passed after 0.01 seconds.
            ✔ Test times() passed after 0.90 seconds.
            ✘ Test broken() failed after 0.01 seconds with 1 issue.
            """
        let report = try FlakyTests().run([first, second, first])
        #expect(report.runs == 3 && report.tests == 3)
        #expect(report.flaky.map(\.name) == ["times()"] && report.flaky[0].failures == 2)
        #expect(report.alwaysFailing.map(\.name) == ["broken()"])
        #expect(report.rendered.contains("flaky\tFPF\ttimes() (failed 2 of 3)"))
        #expect(report.json.objectValue?["flaky"]?.arrayValue?.count == 1)
    }

    @Test func eachRunnersOutcomeLinesAreRead() {
        let outcomes = FlakyTests.outcomes(
            in: """
                Test Case '-[AppTests testLogin]' passed (0.001 seconds).
                Test Case '-[AppTests testLogout]' failed (0.002 seconds).
                test parser::parses ... ok
                test parser::rejects ... FAILED
                PASSED tests/test_a.py::test_one
                tests/test_a.py::test_two FAILED
                --- PASS: TestGo (0.00s)
                --- FAIL: TestGoBad (0.00s)
                """)
        #expect(outcomes["-[AppTests testLogin]"] == .pass && outcomes["-[AppTests testLogout]"] == .fail)
        #expect(outcomes["parser::parses"] == .pass && outcomes["parser::rejects"] == .fail)
        #expect(outcomes["tests/test_a.py::test_one"] == .pass && outcomes["tests/test_a.py::test_two"] == .fail)
        #expect(outcomes["TestGo"] == .pass && outcomes["TestGoBad"] == .fail)
        #expect(throws: FlakyTests.Failure.tooFewRuns(1)) { try FlakyTests().run(["x"]) }
        #expect(throws: FlakyTests.Failure.unreadable(run: 2)) {
            try FlakyTests().run(["test a ... ok", "no tests here"])
        }
    }

    // MARK: Hot paths

    @Test func foldedStacksBecomeSelfTimeAndHeavyPaths() throws {
        let folded = """
            main;run;parse;tokenize 40
            main;run;parse 10
            main;run;render;layout 30
            main;run;render;layout 20
            not a stack line
            main;idle 0
            """
        let report = try HotPaths(maxFrames: 3, maxPaths: 2, pathDepth: 2).run(folded)
        #expect(report.samples == 100 && report.stacks == 3 && report.skipped == 2)
        #expect(report.topSelf.map(\.name) == ["layout", "tokenize", "parse"])
        #expect(report.topSelf.first { $0.name == "parse" }?.totalSamples == 50)
        #expect(report.topPaths.map(\.frames) == [["render", "layout"], ["parse", "tokenize"]])
        #expect(report.rendered.contains("50.0%\t(total 50.0%)\tlayout"))
        #expect(report.json.objectValue?["topPaths"]?.arrayValue?.count == 2)
        #expect(throws: HotPaths.Failure.notFolded) { try HotPaths().run("nothing\nhere") }
        #expect("\(HotPaths.Failure.notFolded)".contains("folded stacks"))
        let bare = try HotPaths().run(" 5\nmain 5")
        #expect(bare.samples == 5 && bare.skipped == 1)
        #expect("\(FlakyTests.Failure.tooFewRuns(1))".contains("at least two"))
        #expect("\(FlakyTests.Failure.unreadable(run: 2))".hasPrefix("run 2 reports no test outcomes"))
        let capped = try FlakyTests(maxTests: 1).run([
            "test a ... FAILED\ntest b ... FAILED", "test a ... ok\ntest b ... FAILED",
        ])
        #expect(capped.flaky.map(\.name) == ["a"] && capped.alwaysFailing.isEmpty && capped.more == 1)
        #expect(capped.rendered.hasSuffix("… 1 more"))
    }
}
