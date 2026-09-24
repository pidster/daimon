import Foundation

/// Chooses a model for a task by the size of its input, from what the eval measured: the first model on
/// the operator's ladder trusted with an input this large ([ADR 0037](../../../../docs/decisions/0037-routing-by-input-size.md)).
/// The input is measured before anything runs, so routing costs nothing and needs no judgement from the
/// model; the small model is never asked how well it did.
public enum ModelRouting {
    /// The pass rate a band must reach to count.
    public static let passRate = 0.8

    /// A choice and why it was made.
    public struct Decision: Equatable, Sendable {
        /// The model to use.
        public var model: ModelSelection
        /// One sentence for the audit log and the result.
        public var reason: String
    }

    /// How large an input `model` is trusted with on `task`: the largest band in the run of passing bands
    /// that starts at the smallest. A model that fails small inputs is never trusted with larger ones,
    /// however a larger band happened to go, since bands hold few cases and a lucky one proves little. 0
    /// when the smallest band fails or none is measured.
    public static func envelope(task: String, model: ModelSelection, measurements: [Measurement]) -> Int {
        let bands = measurements.filter { $0.task == task && $0.model == model.description && $0.maxInputBytes != nil }
            .sorted { ($0.maxInputBytes ?? 0) < ($1.maxInputBytes ?? 0) }
        var trusted = 0
        for band in bands {
            guard band.total > 0, Double(band.passed) / Double(band.total) >= passRate else { break }
            trusted = band.maxInputBytes ?? trusted
        }
        return trusted
    }

    /// The model for `task` on an input of `inputBytes`, or nil when there is no ladder.
    ///
    /// - Parameters:
    ///   - task: The measured task, such as `draft_change.commit`.
    ///   - inputBytes: The input's size.
    ///   - ladder: Models from least to most capable, as the operator configured them.
    ///   - measurements: What the eval recorded; the embedded set by default.
    /// - Returns: The first ladder model whose envelope covers the input; the last model on the ladder
    ///   when none does; nil for an empty ladder.
    public static func choose(
        task: String, inputBytes: Int, ladder: [ModelSelection], measurements: [Measurement] = Measurements.embedded
    ) -> Decision? {
        guard let most = ladder.last else { return nil }
        for model in ladder {
            let trusted = envelope(task: task, model: model, measurements: measurements)
            if trusted > 0, trusted >= inputBytes {
                return Decision(
                    model: model,
                    reason:
                        "\(model) passed every measured \(task) band up to \(trusted) bytes; this input is \(inputBytes)"
                )
            }
        }
        return Decision(
            model: most,
            reason:
                "no model on the ladder is trusted with \(task) inputs of \(inputBytes) bytes; using the last, \(most)")
    }
}
