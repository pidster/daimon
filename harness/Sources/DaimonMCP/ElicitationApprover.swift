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
        let schema = Elicitation.RequestSchema(
            title: "daimon: approve command?",
            description: request.assessment.reasons.joined(separator: "\n"),
            properties: [
                "approve": .object(["type": .string("boolean"), "description": .string("Run this command")]),
                "always": .object([
                    "type": .string("boolean"),
                    "description": .string("Also approve this exact command for the rest of the session"),
                ]),
            ],
            required: ["approve"]
        )
        let message =
            "Run `\(request.command)` in \(request.workingDirectory)? Risk: \(request.assessment.level.rawValue)."
        do {
            let result = try await server.requestElicitation(message: message, requestedSchema: schema)
            switch result.action {
            case .accept:
                guard result.content?["approve"]?.boolValue == true else { return .denied("not approved by the user") }
                return result.content?["always"]?.boolValue == true ? .approvedForSession : .approved
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
}
