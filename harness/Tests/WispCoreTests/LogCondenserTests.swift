import Foundation
import Testing

@testable import WispCore

@Suite struct LogDigestTests {
    @Test func linesBecomeTemplatesWithoutTimestampsAndVariableParts() {
        let parsed = LogDigest.parse(
            "2026-09-23 22:01:36.725161+0100 0x1243c40  Error  0x0  586  0  locationd: session sess4Kq9zX2mT7pL "
                + "id 3F2504E0-4F89-11D3-9A0C-0305E82C3301 failed after 12 ms at 0xdeadbeef")
        #expect(parsed.timestamp == "2026-09-23 22:01:36.725161+0100")
        #expect(parsed.declared == .error)
        #expect(parsed.template == "locationd: session <id> id <uuid> failed after <n> ms at <hex>", "\(parsed)")
        let compact = LogDigest.parse("2026-09-23 22:01:38.658 E  wifid[75350:1244fbc] [com.apple.wifi:x] link down")
        #expect(compact.declared == .error && compact.template == "wifid[<pid>] [com.apple.wifi:x] link down")
        let syslog = LogDigest.parse("Sep 23 22:01:36 host app[12]: started 3 workers")
        #expect(syslog.timestamp == "Sep 23 22:01:36" && syslog.declared == nil)
        #expect(LogDigest.parse("[2026-09-23T10:00:00Z] build 1.2.3 ok").template == "build <n> ok")
    }

    @Test func severityComesFromTheLogsOwnTypeThenFromItsWords() {
        #expect(LogDigest.severity(of: "Thread 3 crashed") == .fault)
        #expect(LogDigest.severity(of: "connection refused by peer") == .error)
        #expect(LogDigest.severity(of: "deprecated API in use") == .warning)
        #expect(LogDigest.severity(of: "all good") == .info)
        // log show says Default, so the word "critical" in the message does not make it a fault.
        let declared = LogDigest.parse("2026-09-23 22:01:36.7+0100 0x1  Default  0x0  1  0  priority critical: 1")
        #expect(declared.declared == .info)
        #expect(LogDigest.Severity.fault < .info)
    }

    @Test func groupsAreCountedRankedCappedAndTheirExamplesRedacted() {
        let token = "ghp_" + String(repeating: "aB3", count: 12)
        let log = """
            2026-09-23T10:00:01Z info: request 1 served in 3 ms
            2026-09-23T10:00:02Z error: upload 7 failed: disk full
            2026-09-23T10:00:03Z info: request 2 served in 5 ms
            2026-09-23T10:00:04Z warning: cache at 91%
            2026-09-23T10:00:05Z info: using token \(token)

            2026-09-23T10:00:06Z error: upload 9 failed: disk full
            2026-09-23T10:00:07Z panic: out of memory
              at worker.run (critical section)
            2026-09-23T10:00:08Z info: request 3 served in 4 ms
            """
        let report = LogDigest().run(log)
        #expect(report.lines == 9 && report.templates == 6)
        #expect(report.groups.map(\.severity) == [.fault, .fault, .error, .warning, .info, .info])
        let upload = report.groups[2]
        #expect(upload.count == 2 && upload.firstLine == 2 && upload.lastLine == 7)
        #expect(upload.firstSeen == "2026-09-23T10:00:02Z" && upload.lastSeen == "2026-09-23T10:00:06Z")
        #expect(report.groups[4].count == 3 && report.groups[4].template == "info: request <n> served in <n> ms")
        // The continuation line takes the panic's severity, not its own word "critical".
        #expect(report.groups[1].template == "at worker.run (critical section)" && report.groups[1].firstSeen == nil)
        let tokenGroup = report.groups.first { $0.template.hasPrefix("info: using token") }
        #expect(tokenGroup?.example.contains("[REDACTED:github-token#1]") == true)
        #expect(report.severities[.info] == 4 && report.severities[.fault] == 2)
        #expect(report.rendered.hasPrefix("9 lines, 6 distinct (2 fault, 2 error, 1 warning, 4 info)"))
        #expect(report.rendered.contains("COUNT") && report.rendered.contains("2-7"))
        let capped = LogDigest(options: .init(maxGroups: 2, maxLineLength: 10)).run(log)
        #expect(capped.more && capped.groups.count == 2 && capped.groups[0].template.count == 10)
        #expect(capped.rendered.contains("the top 2 shown"))
        #expect(capped.json.objectValue?["kind"] == "log" && capped.json.objectValue?["more"] == true)
    }
}

@Suite struct CrashReportTests {
    /// The shape of a real `.ips` from `~/Library/Logs/DiagnosticReports` on 2026-09-23, abridged.
    static let report = """
        {"app_name":"Demo","timestamp":"2026-09-23 21:41:05.00 +0100","app_version":"1.2","bug_type":"309","os_version":"macOS 27.0 (26A428)","name":"Demo"}
        {
          "procName" : "Demo",
          "exception" : {"type" : "EXC_BAD_ACCESS", "signal" : "SIGSEGV", "subtype" : "KERN_INVALID_ADDRESS at 0x0"},
          "termination" : {"indicator" : "Segmentation fault: 11", "namespace" : "SIGNAL"},
          "faultingThread" : 1,
          "threads" : [
            {"frames" : [{"imageOffset" : 1, "symbol" : "mach_msg", "imageIndex" : 0}]},
            {"triggered" : true, "frames" : [
              {"imageOffset" : 64548, "symbol" : "Parser.next()", "imageIndex" : 1},
              {"imageOffset" : 9120, "imageIndex" : 1},
              {"imageOffset" : 12, "imageIndex" : 9}
            ]}
          ],
          "usedImages" : [{"name" : "libsystem_kernel.dylib"}, {"name" : "Demo"}]
        }
        """

    @Test func aReportIsReducedToWhatExplainsIt() throws {
        let crash = try #require(CrashReport(Self.report))
        #expect(crash.process == "Demo" && crash.version == "1.2" && crash.bugType == "309")
        #expect(crash.exception == "EXC_BAD_ACCESS · SIGSEGV · KERN_INVALID_ADDRESS at 0x0")
        #expect(crash.termination == "Segmentation fault: 11 · SIGNAL")
        #expect(crash.faultingThread == 1)
        #expect(crash.frames.map(\.rendered) == ["Demo  Parser.next()", "Demo + 9120", "? + 12"])
        #expect(crash.rendered.contains("thread 1 faulted:\n  0  Demo  Parser.next()"))
        #expect(crash.json.objectValue?["kind"] == "crash")
    }

    @Test func otherTextIsNotAReportAndATriggeredThreadStandsInForTheIndex() {
        #expect(CrashReport("just a log line\nanother") == nil)
        #expect(CrashReport(#"{"no_bug_type":1}"# + "\n{}") == nil)
        let untagged = Self.report.replacingOccurrences(of: "\"faultingThread\" : 1,", with: "")
        #expect(CrashReport(untagged)?.faultingThread == 1)
        let bare = CrashReport(#"{"bug_type":"288","name":"Hang"}"# + "\n{}")
        #expect(bare?.process == "Hang" && bare?.frames.isEmpty == true && bare?.exception == nil)
    }
}

@Suite struct JSONShapeTests {
    @Test func aDocumentIsOutlinedWithTypesRangesAndOptionalKeys() throws {
        let json = """
            {"items":[{"sku":"A-1","price":0.5,"tags":["new"]},{"sku":"B-2","price":120,"tags":[],"note":null},
             {"sku":"C-3","price":7,"tags":["x","y"],"owner":"jane@acme.co"}],"total":3,"ok":true}
            """
        let report = try JSONShape().run(json)
        #expect(report.format == "json" && report.records == 1 && !report.more)
        #expect(
            report.outline == [
                "(root): object",
                "  ok: boolean",
                "  total: integer 3",
                "  items: array[3] of object",
                "    price: number 0.5…120",
                "    sku: string e.g. \"A-1\"",
                "    note?: null",
                "    owner?: string e.g. \"[REDACTED:email#1]\"",
                "    tags: array[0…2] of string",
            ], "\(report.outline)")
        #expect(report.rendered.hasPrefix("JSON document, "))
    }

    @Test func jsonLinesMergeIntoOneRecordOutline() throws {
        let lines = "{\"kind\":\"a\",\"n\":1}\n{\"kind\":\"b\",\"n\":2,\"extra\":{\"x\":\"multi\\nline\"}}\n"
        let report = try JSONShape().run(lines)
        #expect(report.format == "jsonl" && report.records == 2)
        #expect(
            report.outline.contains("  extra?: object")
                && report.outline.contains("    x: string e.g. \"multi\\nline\""))
        #expect(report.rendered.hasPrefix("2 JSON Lines records"))
        #expect(throws: JSONShape.Failure.self) { try JSONShape().run("{\"a\":1}\nnot json\n") }
        #expect(throws: JSONShape.Failure.notJSON("empty input")) { try JSONShape().run("\n") }
    }

    @Test func depthKeysLinesAndExamplesAreBounded() throws {
        let deep = try JSONShape(options: .init(maxDepth: 1)).run(#"{"a":{"b":{"c":1}}}"#)
        #expect(deep.outline == ["(root): object", "  a: object"])
        let wide = try JSONShape(options: .init(maxKeys: 2)).run(#"{"a":1,"b":2,"c":3,"d":4}"#)
        #expect(wide.outline.last == "  … 2 more keys")
        let long = try JSONShape(options: .init(maxLines: 2)).run(#"{"a":1,"b":2,"c":3}"#)
        #expect(long.more && long.outline.count == 2 && long.rendered.contains("outline cut to 2 lines"))
        let bare = try JSONShape(options: .init(examples: false)).run(#"["x", 1, null]"#)
        #expect(bare.outline == ["(root): array[3] of string | number | null"])
        let nested = try JSONShape().run(#"[[{"a":1}],[{"a":2}]]"#)
        #expect(nested.outline == ["(root): array[2] of array", "  []: array[1] of object", "    a: integer 1…2"])
        #expect(JSONShape.Node.format(2.5) == "2.5" && JSONShape.Node.format(3) == "3")
    }
}
