import Foundation

extension AuditEvent {
    /// Builds the `details` of each event kind, so every field name is spelled in exactly one place
    /// and `docs/logging.md` has one Swift file to agree with. `fields(for:)` is the documented set;
    /// a test checks every constructor against it.
    public enum Details {
        /// `session.start` for a session or an MCP thread.
        public static func sessionStart(
            entryPoint: EntryPoint, instructions: String, tools: [String], model: ModelSelection, unsafe: Bool,
            autoApprove: Bool, resume: String?, parent: String? = nil
        ) -> [String: JSONValue] {
            var details: [String: JSONValue] = [
                "entryPoint": .string(entryPoint.rawValue), "instructions": .string(instructions),
                "tools": .array(tools.map { .string($0) }), "model": .string(model.description),
                "unsafe": .bool(unsafe), "autoApprove": .bool(autoApprove),
                "resume": resume.map { .string($0) } ?? .null,
            ]
            if let parent { details["parent"] = .string(parent) }
            return details
        }

        /// `session.start` with reason `new`: a chat `/new` on the same session.
        public static func sessionRestart(tools: [String], model: ModelSelection) -> [String: JSONValue] {
            ["reason": "new", "tools": .array(tools.map { .string($0) }), "model": .string(model.description)]
        }

        /// `session.end`, with why for MCP threads.
        public static func sessionEnd(reason: String? = nil) -> [String: JSONValue] {
            reason.map { ["reason": .string($0)] } ?? [:]
        }

        /// `prompt`.
        public static func prompt(text: String) -> [String: JSONValue] { ["text": .string(text)] }

        /// `response`.
        public static func response(text: String, condensed: Bool, seconds: TimeInterval) -> [String: JSONValue] {
            ["text": .string(text), "condensed": .bool(condensed), "seconds": .double(seconds)]
        }

        /// `tool.call`; `arguments` is the JSON the model produced.
        public static func toolCall(tool: String, arguments: String) -> [String: JSONValue] {
            ["tool": .string(tool), "arguments": .string(arguments)]
        }

        /// `tool.result`.
        public static func toolResult(tool: String, output: String, seconds: TimeInterval) -> [String: JSONValue] {
            [
                "tool": .string(tool), "output": .string(output), "bytes": .int(output.utf8.count),
                "seconds": .double(seconds),
            ]
        }

        /// How `policy.decision` came out.
        public enum PolicyVerdict: String, Sendable {
            /// Passed the patterns and the gate.
            case allowed
            /// Matched a deny pattern or no allow pattern.
            case denied
            /// The approval gate refused it.
            case disapproved
        }

        /// `policy.decision`.
        public static func policyDecision(
            command: String, workingDirectory: String, verdict: PolicyVerdict, reason: String?, sandbox: Bool,
            network: Bool, nested: Bool
        ) -> [String: JSONValue] {
            var details: [String: JSONValue] = [
                "command": .string(command), "workingDirectory": .string(workingDirectory),
                "verdict": .string(verdict.rawValue), "sandbox": .bool(sandbox), "network": .bool(network),
                "nested": .bool(nested),
            ]
            if let reason { details["reason"] = .string(reason) }
            return details
        }

        /// `command.outcome`.
        public static func commandOutcome(
            command: String, outcome: CommandRunner.Outcome, seconds: TimeInterval
        )
            -> [String: JSONValue]
        {
            [
                "command": .string(command), "exitStatus": .int(Int(outcome.exitStatus)),
                "timedOut": .bool(outcome.timedOut), "truncated": .bool(outcome.truncated),
                "stdout": .string(outcome.stdout), "stderr": .string(outcome.stderr), "seconds": .double(seconds),
            ]
        }

        /// `context.condensation`.
        public static func condensation(
            turnsBefore: Int, turnsAfter: Int, contextSize: Int, tokenCount: Int
        )
            -> [String: JSONValue]
        {
            [
                "turnsBefore": .int(turnsBefore), "turnsAfter": .int(turnsAfter), "contextSize": .int(contextSize),
                "tokenCount": .int(tokenCount),
            ]
        }

        /// `mcp.request`; `arguments` is the call's JSON.
        public static func mcpRequest(tool: String, arguments: String) -> [String: JSONValue] {
            ["tool": .string(tool), "arguments": .string(arguments)]
        }

        /// `mcp.result`.
        public static func mcpResult(
            tool: String, isError: Bool, text: String, seconds: TimeInterval
        )
            -> [String: JSONValue]
        {
            ["tool": .string(tool), "isError": .bool(isError), "text": .string(text), "seconds": .double(seconds)]
        }

        /// `error`.
        public static func error(message: String, context: String?) -> [String: JSONValue] {
            var details: [String: JSONValue] = ["message": .string(message)]
            if let context { details["context"] = .string(context) }
            return details
        }

        /// The fields every approval event shares: the simple command, its pattern, and the whole line
        /// when the command is part of one.
        private static func approvalSubject(command: String, pattern: String, line: String) -> [String: JSONValue] {
            var details: [String: JSONValue] = ["command": .string(command), "pattern": .string(pattern)]
            if line != command { details["line"] = .string(line) }
            return details
        }

        /// `classifier.verdict`.
        public static func classifierVerdict(
            command: String, pattern: String, line: String, assessment: RiskAssessment, seconds: TimeInterval
        ) -> [String: JSONValue] {
            approvalSubject(command: command, pattern: pattern, line: line).merging([
                "level": .string(assessment.level.rawValue),
                "reasons": .array(assessment.reasons.map { .string($0) }),
                "sources": .array(assessment.sources.map { .string($0) }),
                "seconds": .double(seconds),
            ]) { $1 }
        }

        /// `approval.requested`.
        public static func approvalRequested(
            command: String, pattern: String, line: String, level: RiskLevel
        )
            -> [String: JSONValue]
        {
            approvalSubject(command: command, pattern: pattern, line: line).merging(["level": .string(level.rawValue)])
            { $1 }
        }

        /// `approval.decided`. `decision` is `approved`, `denied`, `timed-out`, `cached`, `cached-turn`,
        /// `cached-project`, or `cached-always`; the optionals apply as documented for each.
        public static func approvalDecided(
            command: String, pattern: String, line: String, decision: String, scope: ApprovalScope? = nil,
            reason: String? = nil, approvalID: String? = nil, expiresAt: Date? = nil,
            downgradedFrom: ApprovalScope? = nil, persistError: String? = nil
        ) -> [String: JSONValue] {
            var details = approvalSubject(command: command, pattern: pattern, line: line)
            details["decision"] = .string(decision)
            if let scope { details["scope"] = .string(scope.rawValue) }
            if let reason { details["reason"] = .string(reason) }
            if let approvalID { details["approvalID"] = .string(approvalID) }
            if let expiresAt { details["expiresAt"] = .string(expiresAt.ISO8601Format()) }
            if let downgradedFrom { details["downgradedFrom"] = .string(downgradedFrom.rawValue) }
            if let persistError { details["persistError"] = .string(persistError) }
            return details
        }
    }

    /// The detail fields each kind may carry, exactly as `docs/logging.md` lists them.
    public static func fields(for kind: Kind) -> Set<String> {
        switch kind {
        case .sessionStart:
            ["entryPoint", "instructions", "tools", "model", "unsafe", "autoApprove", "resume", "parent", "reason"]
        case .sessionEnd: ["reason"]
        case .prompt: ["text"]
        case .response: ["text", "condensed", "seconds"]
        case .toolCall: ["tool", "arguments"]
        case .toolResult: ["tool", "output", "bytes", "seconds"]
        case .policyDecision: ["command", "workingDirectory", "verdict", "reason", "sandbox", "network", "nested"]
        case .commandOutcome: ["command", "exitStatus", "timedOut", "truncated", "stdout", "stderr", "seconds"]
        case .condensation: ["turnsBefore", "turnsAfter", "contextSize", "tokenCount"]
        case .mcpRequest: ["tool", "arguments"]
        case .mcpResult: ["tool", "isError", "text", "seconds"]
        case .error: ["message", "context"]
        case .classifierVerdict: ["command", "pattern", "line", "level", "reasons", "sources", "seconds"]
        case .approvalRequested: ["command", "pattern", "line", "level"]
        case .approvalDecided:
            [
                "command", "pattern", "line", "decision", "scope", "reason", "approvalID", "expiresAt",
                "downgradedFrom",
                "persistError",
            ]
        }
    }
}
