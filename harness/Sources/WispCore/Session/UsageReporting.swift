/// A model whose executor remembers the token usage of the last request it served.
///
/// `LanguageModelSession.usage` accumulates across every request of a session (probed on 2026-09-20:
/// two one-request turns of 40 input tokens each read 80), so it cannot say how full the window is.
/// The executor knows the last request's figure; a model that keeps it lets `Agent` condense ahead
/// of a runtime that truncates silently ([ADR 0025](../../../../docs/decisions/0025-context-estimation.md)).
public protocol UsageReporting: Sendable {
    /// Input tokens of the most recent request, as the runtime reported them; nil before the first.
    var lastInputTokens: Int? { get }
}
