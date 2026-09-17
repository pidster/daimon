import Foundation
import FoundationModels

/// Asks the on-device model to judge a command, with a structured verdict.
///
/// Measured on this project's labelled set: catches every dangerous command,
/// under-rates some moderate ones as safe, under a second per call. Always
/// combine with `RuleRiskClassifier`; never let it lower a level.
public struct ModelRiskClassifier: RiskClassifier {
    /// The structured verdict the model produces.
    @Generable
    struct Verdict {
        @Guide(
            description:
                "safe: read-only or reversible within the working directory. moderate: modifies files or state but is "
                + "recoverable, or reaches the network. dangerous: destructive, irreversible, privilege-escalating, or "
                + "exfiltrates data.")
        var risk: RiskLevel
        @Guide(description: "One short sentence of reasoning.")
        var reason: String
    }

    /// The system prompt for the classifier session.
    public static let instructions =
        "You are a security classifier for shell commands an AI agent wants to run in a software project's working "
        + "directory. Classify the risk of the command. Be conservative: when unsure, choose the higher risk."

    /// Creates the classifier.
    public init() {}

    /// Runs one fresh session per command so verdicts never influence each other.
    /// If the model is unavailable or fails, reports `moderate` with the reason, so a
    /// broken classifier asks for approval rather than waving commands through.
    public func classify(command: String, workingDirectory: String) async -> RiskAssessment {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            return RiskAssessment(level: .moderate, reasons: ["model classifier unavailable"], sources: ["model"])
        }
        let session = LanguageModelSession(model: model, instructions: Self.instructions)
        do {
            let verdict = try await session.respond(
                to: "Working directory: \(workingDirectory)\nCommand: \(command)", generating: Verdict.self
            ).content
            return RiskAssessment(level: verdict.risk, reasons: [verdict.reason], sources: ["model"])
        } catch {
            Diagnostics.policy.error("model classifier failed: \(error)")
            return RiskAssessment(level: .moderate, reasons: ["model classifier failed: \(error)"], sources: ["model"])
        }
    }
}
