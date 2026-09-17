import FoundationModels

/// The set of tools `daimon` exposes to the model, keyed by name.
public enum ToolRegistry {
    /// All tools available in this build.
    public static let all: [any Tool] = [
        CurrentDateTool(),
    ]

    /// Tools whose names appear in `names`; unknown names are reported back.
    public static func select(_ names: [String]) -> (tools: [any Tool], unknown: [String]) {
        let byName = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })
        var tools: [any Tool] = []
        var unknown: [String] = []
        for name in names {
            if let tool = byName[name] { tools.append(tool) } else { unknown.append(name) }
        }
        return (tools, unknown)
    }
}
