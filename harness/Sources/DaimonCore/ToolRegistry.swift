import FoundationModels

/// The set of tools `daimon` exposes to the model, keyed by name.
public struct ToolRegistry: Sendable {
    /// All tools available in this build, in registration order.
    public let all: [any Tool]

    /// Builds the registry with the given limits for command execution and file pages.
    /// With an audit log, every tool is wrapped so its calls and results are recorded;
    /// with an approval gate, `run_command` classifies and asks before running.
    public init(
        runner: CommandRunner.Options = CommandRunner.Options(), reader: FileReader = FileReader(),
        audit: AuditLog? = nil, approval: ApprovalGate? = nil
    ) {
        let commandRunner = CommandRunner(options: runner, audit: audit, approval: approval)
        if let audit {
            all = [
                AuditedTool(CurrentDateTool(), audit: audit),
                AuditedTool(RunCommandTool(runner: commandRunner), audit: audit),
                AuditedTool(ReadFileTool(reader: reader), audit: audit),
            ]
        } else {
            all = [
                CurrentDateTool(),
                RunCommandTool(runner: commandRunner),
                ReadFileTool(reader: reader),
            ]
        }
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
