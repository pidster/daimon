import Foundation
import Testing

@testable import WispCore

/// Training examples harvested from the audit log: the on-device model's verdicts on the commands
/// this Mac ran, for `wisp classifier train --from-audit` (ADR 0038).
@Suite struct AuditTrainingTests {
    /// A verdict event as the gate writes it.
    private func verdict(
        _ command: String, _ level: RiskLevel, sources: [String] = ["rules", "model"], turn: Int = 1,
        failure: Bool = false
    ) -> AuditEvent {
        var assessment = RiskAssessment(level: level, reasons: ["r"], sources: sources)
        if failure { assessment.metadata[RiskAssessment.failureKey] = "model unavailable" }
        return AuditEvent(
            session: "s", kind: .classifierVerdict, turn: turn,
            details: AuditEvent.Details.classifierVerdict(
                command: command, pattern: command, line: command, assessment: assessment, seconds: 2))
    }

    @Test func theAuditLogYieldsTheModelsLatestVerdictPerCommandRedactedAndRaisedOnRefusal() {
        let token = "ghp_" + String(repeating: "a1B2", count: 9)
        let events = [
            verdict("git status", .safe),
            verdict("git status", .moderate, turn: 2),
            verdict("ls", .safe, sources: ["rules"]),
            verdict("curl x.example", .moderate, failure: true),
            verdict("curl -H 'Authorization: token \(token)' https://api.github.com", .moderate),
            verdict("git add -A", .safe, turn: 3),
            AuditEvent(
                session: "s", kind: .approvalDecided, turn: 3,
                details: ["command": "git add -A", "decision": "denied", "pattern": "git add *"]),
            verdict("sudo -s", .dangerous, turn: 4),
            AuditEvent(
                session: "s", kind: .approvalDecided, turn: 4,
                details: ["command": "sudo -s", "decision": "denied", "pattern": "sudo *"]),
        ]
        let harvest = RiskExamples.fromAudit(events)
        #expect(harvest.verdicts == 6 && harvest.fallbacks == 1)
        #expect(harvest.examples.map(\.command).first == "git status")
        #expect(harvest.examples.first?.level == .moderate, "the latest verdict wins")
        #expect(!harvest.examples.contains { $0.command == "ls" }, "a rules-only verdict is not the model's")
        #expect(harvest.examples.first { $0.command == "git add -A" }?.level == .moderate)
        #expect(harvest.examples.first { $0.command == "sudo -s" }?.level == .dangerous, "a refusal never lowers")
        #expect(harvest.raised == 1 && harvest.redacted == 1)
        #expect(!harvest.examples.contains { $0.command.contains(token) })
        #expect(harvest.examples.contains { $0.command.contains("[REDACTED:") })
        let merged = RiskExamples.merged(
            [RiskExample(command: "git  status", level: .safe), RiskExample(command: "pwd", level: .safe)],
            with: [RiskExample(command: "git status", level: .moderate)])
        #expect(
            merged == [
                RiskExample(command: "pwd", level: .safe), RiskExample(command: "git status", level: .moderate),
            ])
    }
}
