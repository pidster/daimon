import Foundation
import FoundationModels

/// A tool-using agent over the on-device Apple Foundation Model.
///
/// `Agent` owns a `LanguageModelSession`, which keeps the transcript and
/// runs the tool-call loop: the model requests a tool, the framework invokes
/// the matching `Tool`, and the result is fed back until the model replies.
/// When the context window overflows, `contextPolicy` decides whether the
/// session is rebuilt from a condensed transcript and the prompt retried.
public final class Agent {
    /// The model every session is created on; kept so sessions can be rebuilt.
    public let model: ResolvedModel
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

    /// Creates an agent on a model.
    ///
    /// - Parameters:
    ///   - instructions: System-level guidance the model follows for the whole session.
    ///   - tools: Tools the model may call; each must have a unique `name`.
    ///   - model: Which model; defaults to the on-device system model.
    ///   - contextPolicy: Overflow handling; defaults to condensing to the last four turns.
    ///   - audit: Where to record turns; nil records nothing.
    /// - Throws: `ModelSelection.Failure` if the model cannot be used.
    public init(
        instructions: String, tools: [any Tool], model: ModelSelection = .default,
        contextPolicy: ContextPolicy = .default, audit: AuditLog? = nil
    ) throws {
        self.model = try model.resolve()
        self.tools = tools
        self.contextPolicy = contextPolicy
        self.audit = audit
        session = self.model.session(tools: tools, instructions: instructions)
    }

    /// Creates an agent that continues a saved conversation.
    ///
    /// - Parameters:
    ///   - transcript: A transcript previously read from `Agent.transcript`.
    ///   - tools: Tools the model may call; they must match the names the transcript refers to.
    ///   - model: Which model; defaults to the on-device system model.
    ///   - contextPolicy: Overflow handling; defaults to condensing to the last four turns.
    ///   - audit: Where to record turns; nil records nothing.
    /// - Throws: `ModelSelection.Failure` if the model cannot be used.
    public init(
        transcript: Transcript, tools: [any Tool], model: ModelSelection = .default,
        contextPolicy: ContextPolicy = .default, audit: AuditLog? = nil
    ) throws {
        self.model = try model.resolve()
        self.tools = tools
        self.contextPolicy = contextPolicy
        self.audit = audit
        session = self.model.session(tools: tools, transcript: transcript)
    }

    /// The conversation so far, suitable for saving and resuming.
    public var transcript: Transcript { session.transcript }

    /// Tokens the current transcript occupies, as counted by the model, or nil if it cannot count.
    ///
    /// - Throws: Framework errors if counting fails.
    nonisolated(nonsending) public func contextTokens() async throws -> Int? {
        try await model.tokenCount(for: session.transcript)
    }

    /// Starts a fresh session with the same instructions and tools, discarding the conversation.
    public func reset() {
        session = model.session(tools: tools, transcript: session.transcript.condensed(keepTurns: 0))
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
            let condensed = before.condensed(keepTurns: keepTurns)
            session = model.session(tools: tools, transcript: condensed)
            condensations += 1
            audit?.record(
                .condensation,
                details: [
                    "turnsBefore": .int(before.turnCount), "turnsAfter": .int(condensed.turnCount),
                    "contextSize": .int(details.contextSize), "tokenCount": .int(details.tokenCount),
                ])
            Diagnostics.agent.info("condensed \(before.turnCount) -> \(condensed.turnCount) turns")
            return try await operation()
        }
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
