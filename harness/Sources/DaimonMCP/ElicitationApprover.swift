import DaimonCore
import Foundation
import MCP
import Synchronization

/// What the connected client advertised at initialize, shared between the server and its approver.
final class ClientCapabilityFlags: Sendable {
    /// Whether the client supports form elicitation.
    let elicitation = Mutex(false)
}

/// Asks the MCP client's user through elicitation.
///
/// When the client did not advertise elicitation support, denies with a
/// message that tells the calling harness how to proceed, so an unattended
/// caller never runs a risky command by accident.
struct ElicitationApprover: Approver {
    /// The running server, which owns the connection to the client.
    let server: Server
    /// What the client advertised during initialize.
    let client: ClientCapabilityFlags

    /// Creates an approver over `server`; support is learned from the initialize hook.
    init(server: Server, client: ClientCapabilityFlags) {
        self.server = server
        self.client = client
    }

    /// Sends an elicitation with the command and reasons; accept with `approve: true` runs it.
    func decide(_ request: ApprovalRequest) async -> ApprovalDecision {
        guard client.elicitation.withLock({ $0 }) else {
            return .denied(
                "approval required (\(request.assessment.level.rawValue): "
                    + "\(request.assessment.reasons.joined(separator: "; "))) and this client does not support "
                    + "elicitation; run the command from the calling harness, or start daimon mcp with --yes to "
                    + "auto-approve, or lower approval.threshold in config.json")
        }
        // Accept means run; Decline or Cancel means do not. The only field is optional, so a client
        // that submits an empty form on Accept still approves. Clients render different parts of an
        // elicitation (title, message, field titles, descriptions), so the command appears in all of them.
        let level = request.assessment.level.rawValue
        let reasons = request.assessment.reasons.map { "- \($0)" }.joined(separator: "\n")
        let summary = "Run `\(request.command)` in \(request.workingDirectory)?"
        let text = "\(summary)\nRisk: \(level)\n\(reasons)\nAccept to run it, Decline to refuse."
        let schema = Elicitation.RequestSchema(
            title: "daimon (\(level) risk): \(request.command)",
            description: text,
            properties: [
                "always": .object([
                    "type": .string("boolean"),
                    "title": .string("Always this session"),
                    "description": .string("Also approve `\(request.command)` for the rest of this session"),
                    "default": .bool(false),
                ])
            ],
            required: []
        )
        do {
            let result = try await server.requestElicitation(message: text, requestedSchema: schema)
            switch result.action {
            case .accept:
                return Self.wantsAlways(result.content?["always"]) ? .approvedForSession : .approved
            case .decline:
                return .denied("declined by the user")
            case .cancel:
                return .denied("cancelled by the user")
            }
        } catch {
            Diagnostics.mcp.error("elicitation failed: \(error)")
            return .denied("approval request failed: \(error)")
        }
    }

    /// Reads the optional `always` field leniently: booleans, or the strings clients tend to send.
    static func wantsAlways(_ value: Value?) -> Bool {
        if let flag = value?.boolValue { return flag }
        if let text = value?.stringValue { return ["true", "yes", "y", "1", "on"].contains(text.lowercased()) }
        return false
    }
}
