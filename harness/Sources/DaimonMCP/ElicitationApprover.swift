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
        // The title is short because clients trim it; the full command leads the description, which
        // renders before the options, and the message repeats it for clients that show only that.
        let text = """
            Command:
            \(request.command)

            Directory: \(request.workingDirectory)
            Risk: \(level)
            \(reasons)

            Accept runs it (once, or for this session). Decline refuses.
            """
        let schema = Elicitation.RequestSchema(
            title: "daimon: approve command? (\(level) risk)",
            description: text,
            properties: [
                "scope": .object([
                    "type": .string("string"),
                    "title": .string("Approve"),
                    "description": .string("Once, or for the rest of this session"),
                    "enum": .array([.string("once"), .string("session")]),
                    "enumNames": .array([.string("Approve once"), .string("Approve for this session")]),
                    "default": .string("once"),
                ])
            ],
            required: []
        )
        do {
            let result = try await server.requestElicitation(message: text, requestedSchema: schema)
            switch result.action {
            case .accept:
                return Self.wantsSession(result.content?["scope"]) ? .approvedForSession : .approved
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

    /// Reads the optional `scope` field leniently; anything other than a session choice means once.
    static func wantsSession(_ value: Value?) -> Bool {
        if let flag = value?.boolValue { return flag }
        if let text = value?.stringValue {
            return ["session", "always", "approve for this session", "true", "yes"].contains(text.lowercased())
        }
        return false
    }
}
