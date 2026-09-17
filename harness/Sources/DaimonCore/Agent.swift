import Foundation
import FoundationModels

/// Errors raised by the harness before the model is involved.
public enum AgentError: Error, CustomStringConvertible {
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
public final class Agent {
    private let session: LanguageModelSession

    /// Creates an agent bound to the default system model.
    ///
    /// - Parameters:
    ///   - instructions: System-level guidance the model follows for the whole session.
    ///   - tools: Tools the model may call; each must have a unique `name`.
    /// - Throws: `AgentError.modelUnavailable` if the on-device model cannot be used.
    public init(instructions: String, tools: [any Tool]) throws {
        let model = try Self.availableModel()
        session = LanguageModelSession(model: model, tools: tools, instructions: instructions)
    }

    /// Creates an agent that continues a saved conversation.
    ///
    /// - Parameters:
    ///   - transcript: A transcript previously read from `Agent.transcript`.
    ///   - tools: Tools the model may call; they must match the names the transcript refers to.
    /// - Throws: `AgentError.modelUnavailable` if the on-device model cannot be used.
    public init(transcript: Transcript, tools: [any Tool]) throws {
        let model = try Self.availableModel()
        session = LanguageModelSession(model: model, tools: tools, transcript: transcript)
    }

    /// The conversation so far, suitable for saving and resuming.
    public var transcript: Transcript { session.transcript }

    private static func availableModel() throws -> SystemLanguageModel {
        let model = SystemLanguageModel.default
        if case .unavailable(let reason) = model.availability {
            throw AgentError.modelUnavailable(reason)
        }
        return model
    }

    /// Sends one user turn and returns the final assistant text.
    nonisolated(nonsending) public func respond(to prompt: String) async throws -> String {
        try await session.respond(to: prompt).content
    }

    /// Sends one user turn, calling `onDelta` with each new fragment of the
    /// assistant text as it streams, and returns the final text.
    @discardableResult
    nonisolated(nonsending) public func stream(_ prompt: String, onDelta: (String) -> Void) async throws -> String {
        var emitted = ""
        for try await snapshot in session.streamResponse(to: prompt) {
            let full = snapshot.content
            onDelta(full.hasPrefix(emitted) ? String(full.dropFirst(emitted.count)) : full)
            emitted = full
        }
        return emitted
    }
}
