import Foundation
import FoundationModels

/// Errors raised by the harness before the model is involved.
public enum AgentError: Error, CustomStringConvertible {
    /// The on-device model cannot be used, with the framework's reason (not enabled, not ready, unsupported device).
    case modelUnavailable(SystemLanguageModel.Availability.UnavailableReason)

    /// Human-readable explanation suitable for printing to stderr.
    public var description: String {
        switch self {
        case .modelUnavailable(let reason):
            return "The on-device model is unavailable: \(reason)"
        }
    }
}

/// A tool-using agent over the on-device Apple Foundation Model.
///
/// `Agent` owns a `LanguageModelSession`, which keeps the transcript and
/// runs the tool-call loop: the model requests a tool, the framework invokes
/// the matching `Tool`, and the result is fed back until the model replies.
/// When the context window overflows, `contextPolicy` decides whether the
/// session is rebuilt from a condensed transcript and the prompt retried.
public final class Agent {
    /// The model every session is created on; kept so sessions can be rebuilt.
    private let model: SystemLanguageModel
    /// Tools bound to every session, in registration order.
    private let tools: [any Tool]
    /// The live session. Replaced, never mutated, when the conversation is condensed or reset.
    private var session: LanguageModelSession

    /// What happens when a prompt no longer fits the context window.
    public let contextPolicy: ContextPolicy
    /// How many times the transcript has been condensed to recover from overflow.
    public private(set) var condensations = 0
    /// Where turns, responses, condensations, and errors are recorded.
    public let audit: AuditLog?

    /// Creates an agent bound to the default system model.
    ///
    /// - Parameters:
    ///   - instructions: System-level guidance the model follows for the whole session.
    ///   - tools: Tools the model may call; each must have a unique `name`.
    ///   - contextPolicy: Overflow handling; defaults to condensing to the last four turns.
    ///   - audit: Where to record turns; nil records nothing.
    /// - Throws: `AgentError.modelUnavailable` if the on-device model cannot be used.
    public init(
        instructions: String, tools: [any Tool], contextPolicy: ContextPolicy = .default, audit: AuditLog? = nil
    )
        throws
    {
        model = try Self.availableModel()
        self.tools = tools
        self.contextPolicy = contextPolicy
        self.audit = audit
        session = LanguageModelSession(model: model, tools: tools, instructions: instructions)
    }

    /// Creates an agent that continues a saved conversation.
    ///
    /// - Parameters:
    ///   - transcript: A transcript previously read from `Agent.transcript`.
    ///   - tools: Tools the model may call; they must match the names the transcript refers to.
    ///   - contextPolicy: Overflow handling; defaults to condensing to the last four turns.
    ///   - audit: Where to record turns; nil records nothing.
    /// - Throws: `AgentError.modelUnavailable` if the on-device model cannot be used.
    public init(
        transcript: Transcript, tools: [any Tool], contextPolicy: ContextPolicy = .default, audit: AuditLog? = nil
    )
        throws
    {
        model = try Self.availableModel()
        self.tools = tools
        self.contextPolicy = contextPolicy
        self.audit = audit
        session = LanguageModelSession(model: model, tools: tools, transcript: transcript)
    }

    /// The conversation so far, suitable for saving and resuming.
    public var transcript: Transcript { session.transcript }

    /// Tokens the current transcript occupies, as counted by the model.
    ///
    /// - Throws: Framework errors if counting fails.
    nonisolated(nonsending) public func contextTokens() async throws -> Int {
        try await model.tokenCount(for: session.transcript)
    }

    /// Starts a fresh session with the same instructions and tools, discarding the conversation.
    public func reset() {
        session = LanguageModelSession(
            model: model, tools: tools, transcript: session.transcript.condensed(keepTurns: 0))
    }

    /// Runs `operation`; on context overflow under a `.condense` policy, rebuilds the
    /// session from the pre-call transcript condensed to the policy's turn count and retries once.
    nonisolated(nonsending) private func withOverflowRecovery<T>(_ operation: () async throws -> T) async throws -> T {
        let before = session.transcript
        do {
            return try await operation()
        } catch LanguageModelError.contextSizeExceeded(let details) {
            guard case .condense(let keepTurns) = contextPolicy else {
                throw LanguageModelError.contextSizeExceeded(details)
            }
            session = LanguageModelSession(
                model: model, tools: tools, transcript: before.condensed(keepTurns: keepTurns))
            condensations += 1
            return try await operation()
        }
    }

    /// The default system model, or `AgentError.modelUnavailable` if it cannot serve requests.
    private static func availableModel() throws -> SystemLanguageModel {
        let model = SystemLanguageModel.default
        if case .unavailable(let reason) = model.availability {
            throw AgentError.modelUnavailable(reason)
        }
        return model
    }

    /// Sends one user turn and returns the final assistant text.
    nonisolated(nonsending) public func respond(to prompt: String) async throws -> String {
        try await turn(prompt) { try await session.respond(to: prompt).content }
    }

    /// Sends one user turn, calling `onDelta` with each new fragment of the
    /// assistant text as it streams, and returns the final text.
    @discardableResult
    nonisolated(nonsending) public func stream(_ prompt: String, onDelta: (String) -> Void) async throws -> String {
        try await turn(prompt) {
            var emitted = ""
            for try await snapshot in session.streamResponse(to: prompt) {
                let full = snapshot.content
                onDelta(full.hasPrefix(emitted) ? String(full.dropFirst(emitted.count)) : full)
                emitted = full
            }
            return emitted
        }
    }

    /// Records the prompt, runs `operation` with overflow recovery, and records the response or error.
    nonisolated(nonsending) private func turn(
        _ prompt: String, _ operation: () async throws -> String
    ) async throws -> String {
        audit?.beginTurn()
        audit?.record(.prompt, details: ["text": .string(prompt)])
        let started = Date()
        let before = condensations
        do {
            let text = try await withOverflowRecovery(operation)
            audit?.record(
                .response,
                details: [
                    "text": .string(text), "condensed": .bool(condensations > before),
                    "seconds": .double(Date().timeIntervalSince(started)),
                ])
            return text
        } catch {
            audit?.error(error, context: "turn")
            Diagnostics.agent.error("turn failed: \(error)")
            throw error
        }
    }
}
