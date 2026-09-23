import Foundation
import Testing

@testable import WispCore

@Suite struct CallStatsTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func call(
        _ kind: CallStats.Kind = .turn, _ model: String = "system", at offset: Double = 0,
        seconds: Double = 1, failure: String? = nil, tokens: Int? = nil
    ) -> CallStats.Call {
        CallStats.Call(
            kind: kind, model: model, started: start.addingTimeInterval(offset), seconds: seconds, failure: failure,
            inputTokens: tokens)
    }

    @Test func theRingKeepsTheLatestCallsOldestFirst() {
        let stats = CallStats(capacity: 3)
        for index in 0..<5 { stats.record(call(at: Double(index), seconds: Double(index))) }
        #expect(stats.calls.map(\.seconds) == [2, 3, 4])
        #expect(stats.total == 5)
        #expect(CallStats(capacity: 0).capacity == 1)
        let partial = CallStats(capacity: 3)
        partial.record(call(seconds: 7))
        #expect(partial.calls.map(\.seconds) == [7])
    }

    @Test func aLongFailureIsCut() {
        let stats = CallStats()
        stats.record(call(failure: String(repeating: "x", count: 500)))
        let kept = stats.calls.first?.failure ?? ""
        #expect(kept.count == CallStats.failureLimit && kept.hasSuffix("…"))
    }

    @Test func theReportSummarisesPerKindAndModelThenListsRecentCallsByStart() {
        #expect(CallStats().report() == ["no model or classifier calls yet"])
        let stats = CallStats()
        // Recorded as they finish: the classification inside the first turn finishes before it.
        stats.record(call(.classifier, "system-model", at: 1, seconds: 1.5))
        stats.record(call(at: 0, seconds: 4, tokens: 1000))
        stats.record(call(at: 10, seconds: 2, failure: "boom", tokens: 2000))
        stats.record(call(.turn, "ollama:granite4.1:8b", at: 20, seconds: 3))
        let utc = TimeZone(identifier: "UTC") ?? .current
        let lines = stats.report(recent: 3, timeZone: utc)
        #expect(lines[0] == "4 calls this session (the store keeps the last 256)")
        #expect(
            Array(lines[2...5]) == [
                "KIND        MODEL                 CALLS  FAILED  MEAN   P50   P95   MAX  TOKENS IN",
                "classifier  system-model              1       0  1.5s  1.5s  1.5s  1.5s",
                "turn        system                    2       1  3.0s  2.0s  4.0s  4.0s       1500",
                "turn        ollama:granite4.1:8b      1       0  3.0s  3.0s  3.0s  3.0s",
            ])
        #expect(lines[7] == "recent, by start time")
        let clock = Date.FormatStyle(date: .omitted, time: .standard, timeZone: utc)
        #expect(lines[8].hasPrefix("TIME"))
        #expect(lines.count == 12)
        #expect(lines[9].hasPrefix(start.addingTimeInterval(0).formatted(clock)) && lines[9].hasSuffix("  ok"))
        #expect(lines[10].contains("2.0s  failed: boom"))
        #expect(lines[11].contains("ollama:granite4.1:8b"))
        let small = CallStats(capacity: 2)
        for index in 0..<3 { small.record(call(at: Double(index))) }
        #expect(small.report()[0] == "3 calls this session; the last 2 are kept and summarised")
    }

    @Test func percentilesAreNearestRank() {
        #expect(CallStats.percentile(0.5, of: []) == 0)
        #expect(CallStats.percentile(0.5, of: [1, 2, 3, 4]) == 2)
        #expect(CallStats.percentile(0.95, of: [1, 2, 3, 4]) == 4)
        #expect(CallStats.percentile(0, of: [5, 6]) == 5)
    }

    @Test func aTimedClassifierRecordsEachVerdictAndCountsFallbacksAsFailures() async {
        struct Fixed: RiskClassifier {
            let assessment: RiskAssessment
            func classify(command: String, workingDirectory: String) async -> RiskAssessment { assessment }
        }
        let stats = CallStats()
        let judged = RiskAssessment(level: .safe, reasons: ["reads"], sources: ["model"])
        let fallback = RiskAssessment(
            level: .moderate, reasons: ["model classifier unavailable"], sources: ["model"],
            metadata: [RiskAssessment.failureKey: .string("unavailable")])
        let timed = TimedRiskClassifier(Fixed(assessment: judged), name: "system-model", stats: stats)
        #expect(await timed.classify(command: "ls", workingDirectory: "/") == judged)
        _ = await TimedRiskClassifier(Fixed(assessment: fallback), name: "system-model", stats: stats)
            .classify(command: "ls", workingDirectory: "/")
        #expect(stats.calls.map(\.kind) == [.classifier, .classifier])
        #expect(stats.calls.map(\.failure) == [nil, "unavailable"])
        #expect(stats.calls.allSatisfy { $0.model == "system-model" })
    }
}
