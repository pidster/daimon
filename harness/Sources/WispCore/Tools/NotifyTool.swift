import Foundation
import FoundationModels

/// Lets the model show the user a macOS notification: to say a long task has finished, or that it needs
/// them. Posted through the session's `Notifier`, bounded, rate-limited, and audited; no approval, since
/// a banner changes nothing on the Mac ([ADR 0030](../../../../docs/decisions/0030-notifications.md)).
public struct NotifyTool: WispTool {
    /// The identifier the model uses to request this tool.
    public let name = "notify"
    /// What the model is told this tool does.
    public let description =
        "Shows the user a macOS notification. Use it when a long task finishes or you need their attention."

    /// Arguments the model may supply when calling the tool.
    @Generable
    public struct Arguments {
        /// The notification's first line.
        @Guide(description: "A short title, a few words.")
        public var title: String
        /// The notification's text.
        @Guide(description: "The message, one or two sentences.")
        public var message: String
    }

    private let notifier: Notifier
    private let audit: AuditLog?

    /// Bounds, from the notifier's limits.
    public var limits: String {
        "Title up to \(Notifier.titleLimit) characters, message up to \(Notifier.bodyLimit); a few per minute at most."
    }
    /// How to ask for it.
    public let examplePrompt = "Use notify with title `Build done` and message `The tests pass.`"

    /// Creates the tool over the session's notifier.
    ///
    /// - Parameters:
    ///   - notifier: Shared across the session so the rate limit covers every conversation.
    ///   - audit: Where `notification` events go.
    public init(notifier: Notifier, audit: AuditLog? = nil) {
        self.notifier = notifier
        self.audit = audit
    }

    /// Posts the notification.
    ///
    /// - Parameter arguments: Title and message.
    /// - Returns: `notification shown`, or `error: …` saying why not.
    public func call(arguments: Arguments) async -> String {
        switch notifier.post(.init(title: arguments.title, body: arguments.message), source: .model, audit: audit) {
        case .posted: "notification shown"
        case .refused(let reason): "error: notification not shown: \(reason)"
        }
    }
}
