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
    /// How long to wait for an answer before treating silence as a denial.
    let timeout: Duration

    /// Creates an approver over `server`; support is learned from the initialize hook.
    init(server: Server, client: ClientCapabilityFlags, timeout: Duration) {
        self.server = server
        self.client = client
        self.timeout = timeout
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
        // No form fields: Accept runs the command once, Decline refuses. A fieldless dialog is the
        // shape clients render most reliably. The title is short because clients trim it; the full
        // command leads the description, which renders before the buttons.
        let text = """
            Command:
            \(request.command)

            Directory: \(request.workingDirectory)
            Risk: \(level)
            \(reasons)

            Accept runs it once. Decline refuses. No answer within \(timeout) counts as Decline.
            """
        let schema = Elicitation.RequestSchema(
            title: "daimon: approve command? (\(level) risk)", description: text, properties: [:], required: [])
        let server = server
        do {
            let result = try await withTimeout(timeout) {
                try await server.requestElicitation(message: text, requestedSchema: schema)
            }
            switch result.action {
            case .accept: return .approved
            case .decline: return .denied("declined by the user")
            case .cancel: return .denied("cancelled by the user")
            }
        } catch let timeout as TimeoutError {
            Diagnostics.mcp.info("approval unanswered: \(timeout)")
            return .unanswered(timeout.duration)
        } catch {
            Diagnostics.mcp.error("elicitation failed: \(error)")
            return .denied("approval request failed: \(error)")
        }
    }
}
