import FoundationModels

/// A tool of daimon's, as opposed to any `FoundationModels.Tool`: besides what the model sees, it
/// describes its limits and how to ask for it, so the client-facing catalogue is generated from the
/// tool itself and cannot go stale when a default changes.
public protocol DaimonTool: Tool where Arguments: Generable, Output == String {
    /// Limits that bound its output or effect, rendered from the live options.
    var limits: String { get }
    /// A `respond` prompt that reliably makes the model use it.
    var examplePrompt: String { get }
}
