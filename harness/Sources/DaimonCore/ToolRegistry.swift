import FoundationModels

/// The set of tools `daimon` exposes to the model, keyed by name.
public struct ToolRegistry: Sendable {
    /// All tools available in this build, in registration order.
    public let all: [any Tool]

    /// Builds the registry with the given limits for command execution.
    public init(runner: CommandRunner.Options = CommandRunner.Options()) {
        all = [
            CurrentDateTool(),
            RunCommandTool(runner: CommandRunner(options: runner)),
        ]
    }

    /// Tools whose names appear in `names`; unknown names are reported back.
    public func select(_ names: [String]) -> (tools: [any Tool], unknown: [String]) {
        let byName = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })
        var tools: [any Tool] = []
        var unknown: [String] = []
        for name in names {
            if let tool = byName[name] { tools.append(tool) } else { unknown.append(name) }
        }
        return (tools, unknown)
    }
}
