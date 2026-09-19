import Foundation
import FoundationModels

/// Which language model a session runs on.
///
/// Parsed from `config.json`'s `model` or `--model`: `system` (default) or
/// `private-cloud`. (Custom adapters exist in the framework but are unavailable on macOS.)
public enum ModelSelection: Equatable, Sendable, CustomStringConvertible, Codable {
    /// Apple's on-device model. Nothing leaves the machine.
    case system
    /// Apple's Private Cloud Compute model. Requests leave the machine under Apple's privacy guarantees.
    case privateCloud

    /// The default.
    public static let `default` = ModelSelection.system

    /// Parses `system` or `private-cloud`.
    ///
    /// - Throws: `Failure.unknownModel` for anything else.
    public init(parsing text: String) throws {
        switch text.trimmingCharacters(in: .whitespaces) {
        case "system", "": self = .system
        case "private-cloud", "pcc": self = .privateCloud
        case let other: throw Failure.unknownModel(other)
        }
    }

    /// The canonical spelling, as accepted by `init(parsing:)`.
    public var description: String {
        switch self {
        case .system: "system"
        case .privateCloud: "private-cloud"
        }
    }

    /// Decodes from the canonical spelling.
    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        do {
            try self.init(parsing: text)
        } catch {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "\(error)"))
        }
    }

    /// Encodes as the canonical spelling.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    /// Whether prompts and transcripts are sent off the machine.
    public var leavesDevice: Bool {
        if case .privateCloud = self { return true }
        return false
    }

    /// Why a selection could not be used.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// Not one of the known spellings.
        case unknownModel(String)
        /// The model exists but cannot serve requests right now.
        case unavailable(model: String, reason: String)

        /// Human-readable explanation.
        public var description: String {
            switch self {
            case .unknownModel(let text): "unknown model '\(text)': use system or private-cloud"
            case .unavailable(let model, let reason): "model '\(model)' is unavailable: \(reason)"
            }
        }
    }

    /// Checks availability and returns a session maker for this model.
    ///
    /// - Throws: `Failure.unavailable`.
    public func resolve() throws -> ResolvedModel {
        switch self {
        case .system:
            let model = SystemLanguageModel.default
            if case .unavailable(let reason) = model.availability {
                throw Failure.unavailable(model: description, reason: "\(reason)")
            }
            return ResolvedModel(selection: self, system: model)
        case .privateCloud:
            let model = PrivateCloudComputeLanguageModel()
            if case .unavailable(let reason) = model.availability {
                throw Failure.unavailable(model: description, reason: "\(reason)")
            }
            return ResolvedModel(selection: self, privateCloud: model)
        }
    }
}

/// A checked model that can make sessions. Erases the concrete `LanguageModel` type
/// so `Agent` need not be generic.
public struct ResolvedModel: Sendable {
    /// What was selected.
    public let selection: ModelSelection
    private let makeFromInstructions: @Sendable ([any Tool], String) -> LanguageModelSession
    private let makeFromTranscript: @Sendable ([any Tool], Transcript) -> LanguageModelSession
    private let countTokens: (@Sendable (Transcript) async throws -> Int)?

    /// Wraps the on-device model.
    init(selection: ModelSelection, system model: SystemLanguageModel) {
        self.selection = selection
        makeFromInstructions = { tools, instructions in
            LanguageModelSession(model: model, tools: tools, instructions: instructions)
        }
        makeFromTranscript = { tools, transcript in
            LanguageModelSession(model: model, tools: tools, transcript: transcript)
        }
        countTokens = { transcript in try await model.tokenCount(for: transcript) }
    }

    /// Wraps Private Cloud Compute, which offers no token counting.
    init(selection: ModelSelection, privateCloud model: PrivateCloudComputeLanguageModel) {
        self.selection = selection
        makeFromInstructions = { tools, instructions in
            LanguageModelSession(model: model, tools: tools, instructions: instructions)
        }
        makeFromTranscript = { tools, transcript in
            LanguageModelSession(model: model, tools: tools, transcript: transcript)
        }
        countTokens = nil
    }

    /// A new session with instructions.
    public func session(tools: [any Tool], instructions: String) -> LanguageModelSession {
        makeFromInstructions(tools, instructions)
    }

    /// A session continuing a transcript.
    public func session(tools: [any Tool], transcript: Transcript) -> LanguageModelSession {
        makeFromTranscript(tools, transcript)
    }

    /// Tokens a transcript occupies, or nil when this model cannot count.
    ///
    /// - Throws: Framework errors if counting fails.
    public func tokenCount(for transcript: Transcript) async throws -> Int? {
        try await countTokens?(transcript)
    }
}
