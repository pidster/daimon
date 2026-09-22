import Foundation

/// The list `wisp models` prints and `/models` shows in chat: Apple's two models with their
/// availability and declared capabilities, then every model each registered backend serves.
public enum ModelListing {
    /// One line per model, the current selection marked with `*`. A backend that does not answer gets
    /// one line saying so; the others are still listed.
    public static func lines(config: Config.Resolved, home: Home, current: ModelSelection) async -> [String] {
        var lines: [String] = []
        for selection in [ModelSelection.system, .privateCloud] {
            let state: String
            do {
                let resolved = try selection.resolve(config: config, home: home)
                state = "available; \(resolved.capabilityNames.joined(separator: ", "))"
            } catch {
                state = "unavailable: \(error)"
            }
            lines.append("\(selection == current ? "*" : " ") \(selection)\t\(state)")
        }
        for backend in ModelBackends.all {
            do {
                for model in try await backend.installed(config: config, home: home) {
                    lines.append("\(model.selection == current ? "*" : " ") \(model.selection)\t\(model.detail)")
                }
            } catch {
                lines.append("  \(backend.scheme):*\tunavailable: \(error)")
            }
        }
        return lines
    }
}
