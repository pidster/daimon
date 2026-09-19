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
    /// The tools the model may call.
    public let tools: [any Tool]
    /// The live session. Replaced, never mutated, when the conversation is condensed or reset.
    private var session: LanguageModelSession

    /// What happens when a prompt no longer fits the context window.
    public let contextPolicy: ContextPolicy
    /// How many times the transcript has been condensed to recover from overflow.
    public private(set) var condensations = 0
    /// Where turns, responses, condensations, and errors are recorded.
    public let audit: AuditLog?
    /// The conversation's turn counter, advanced once per prompt; the approval gate reads it.
    public let turns: TurnClock

    /// Creates an agent on a model.
    ///
    /// - Parameters:
    ///   - instructions: System-level guidance the model follows for the whole session.
    ///   - tools: Tools the model may call; each must have a unique `name`.
    ///   - model: Which model; defaults to the on-device system model.
    ///   - contextPolicy: Overflow handling; defaults to condensing to the last four turns.
    ///   - audit: Where to record turns; nil records nothing.
    ///   - turns: The conversation's clock; defaults to the audit log's, or a fresh one.
    /// - Throws: `ModelSelection.Failure` if the model cannot be used.
    public init(
        instructions: String, tools: [any Tool], model: ModelSelection = .default,
        contextPolicy: ContextPolicy = .default, audit: AuditLog? = nil, turns: TurnClock? = nil
    ) throws {
        self.model = try model.resolve()
        self.tools = tools
        self.contextPolicy = contextPolicy
        self.audit = audit
        self.turns = turns ?? audit?.turns ?? TurnClock()
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
    ///   - turns: The conversation's clock; defaults to the audit log's, or a fresh one.
    /// - Throws: `ModelSelection.Failure` if the model cannot be used.
    public init(
        transcript: Transcript, tools: [any Tool], model: ModelSelection = .default,
        contextPolicy: ContextPolicy = .default, audit: AuditLog? = nil, turns: TurnClock? = nil
    ) throws {
        self.model = try model.resolve()
        self.tools = tools
        self.contextPolicy = contextPolicy
        self.audit = audit
        self.turns = turns ?? audit?.turns ?? TurnClock()
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

    /// Starts a fresh session with the same instructions and tools, discarding the conversation,
    /// and records it as a `session.start` with reason `new`.
    public func reset() {
        session = model.session(tools: tools, transcript: session.transcript.condensed(keepTurns: 0))
        audit?.record(
            .sessionStart, details: AuditEvent.Details.sessionRestart(tools: tools.map(\.name), model: model.selection))
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
                details: AuditEvent.Details.condensation(
                    turnsBefore: before.turnCount, turnsAfter: condensed.turnCount, contextSize: details.contextSize,
                    tokenCount: details.tokenCount))
            Diagnostics.agent.info("condensed \(before.turnCount) -> \(condensed.turnCount) turns")
            return try await operation()
        }
    }

    /// What one turn produced.
    public struct Reply: Sendable, Equatable {
        /// The final assistant text.
        public var text: String
        /// Whether older turns were dropped to fit the context window during this turn.
        public var condensed: Bool

        /// Creates a reply.
        public init(text: String, condensed: Bool) {
            self.text = text
            self.condensed = condensed
        }
    }

    /// Sends one user turn and returns the reply.
    nonisolated(nonsending) public func respond(to prompt: String) async throws -> Reply {
        try await turn(prompt) { try await session.respond(to: prompt).content }
    }

    /// Sends one user turn, calling `onDelta` with each new fragment of the assistant text as it
    /// streams, and returns the reply.
    ///
    /// Snapshots are cumulative. If a retry after mid-stream overflow starts a new answer that does
    /// not continue the text already shown, a newline separates the two so the caller's output stays
    /// readable rather than splicing an unrelated suffix onto it.
    @discardableResult
    nonisolated(nonsending) public func stream(_ prompt: String, onDelta: (String) -> Void) async throws -> Reply {
        // `emitted` lives outside the retried closure so a retry after mid-stream overflow continues
        // from what the caller has already seen instead of repeating it.
        var emitted = ""
        return try await turn(prompt) {
            for try await snapshot in session.streamResponse(to: prompt) {
                let full = snapshot.content
                guard full != emitted else { continue }
                if full.hasPrefix(emitted) {
                    onDelta(String(full.dropFirst(emitted.count)))
                } else {
                    onDelta("\n" + full)
                }
                emitted = full
            }
            return emitted
        }
    }

    /// Records the prompt, runs `operation` with overflow recovery, and records the response or error.
    nonisolated(nonsending) private func turn(
        _ prompt: String, _ operation: () async throws -> String
    ) async throws -> Reply {
        turns.advance()
        audit?.record(.prompt, details: AuditEvent.Details.prompt(text: prompt))
        let started = Date()
        let before = condensations
        do {
            let text = try await withOverflowRecovery(operation)
            let reply = Reply(text: text, condensed: condensations > before)
            audit?.record(
                .response,
                details: AuditEvent.Details.response(
                    text: text, condensed: reply.condensed, seconds: Date().timeIntervalSince(started)))
            return reply
        } catch {
            audit?.error(error, context: "turn")
            Diagnostics.agent.error("turn failed: \(error)")
            throw error
        }
    }
}
