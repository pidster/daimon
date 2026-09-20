import FoundationModels

/// The spellings of model capabilities in `config.json` and the audit, and their framework values.
public enum CapabilityName: String, CaseIterable, Sendable, Codable {
    /// May call daimon's tools.
    case toolCalling
    /// May produce schema-shaped output.
    case guidedGeneration
    /// Emits a reasoning trace.
    case reasoning
    /// Accepts images.
    case vision

    /// The framework's value.
    public var capability: LanguageModelCapabilities.Capability {
        switch self {
        case .toolCalling: .toolCalling
        case .guidedGeneration: .guidedGeneration
        case .reasoning: .reasoning
        case .vision: .vision
        }
    }

    /// Parses a list of names, refusing any that is not one of the four.
    ///
    /// - Returns: The framework capabilities, in the order given.
    /// - Throws: `ModelSelection.Failure.unavailable` naming the bad entry and the accepted spellings.
    public static func parse(_ names: [String], forModel model: String) throws -> [LanguageModelCapabilities.Capability]
    {
        try names.map { name in
            guard let known = CapabilityName(rawValue: name) else {
                throw ModelSelection.Failure.unavailable(
                    model: model,
                    reason:
                        "unknown capability '\(name)' in config.json; use \(allCases.map(\.rawValue).joined(separator: ", "))"
                )
            }
            return known.capability
        }
    }
}
