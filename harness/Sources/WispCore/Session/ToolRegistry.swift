import FoundationModels

/// The set of tools `wisp` exposes to the model, keyed by name.
public struct ToolRegistry: Sendable {
    /// All tools available in this build, in registration order, each wrapped by `AuditedTool`.
    public let all: [any WispTool]

    /// Builds the registry with the given limits for command execution and file pages.
    ///
    /// Every tool is wrapped so its calls and results are recorded; without an audit log the wrapper
    /// records to a log that discards everything, so there is one list and one code path. With an
    /// approval gate, `run_command`, `read_file`, and `edit_file` classify and ask before acting.
    ///
    /// - Parameters:
    ///   - runner: Limits and policy for `run_command`, whose writable set also confines `edit_file`.
    ///   - reader: Page limits for `read_file`.
    ///   - audit: Where tool calls are recorded; nil records nothing.
    ///   - approval: The gate risky tools consult; nil never asks.
    ///   - introspection: What `inspect` shows; the default sees the default home and config.
    ///   - notifier: Posts `notify`'s notifications; the session shares one across conversations.
    public init(
        runner: CommandRunner.Options = CommandRunner.Options(), reader: FileReader = FileReader(),
        audit: AuditLog? = nil, approval: ApprovalGate? = nil,
        introspection: Introspection = Introspection(home: Home.resolve(), config: Config().resolved),
        notifier: Notifier = Notifier()
    ) {
        let audit = audit ?? .disabled(session: "unaudited")
        let commandRunner = CommandRunner(options: runner, audit: audit, approval: approval)
        all = [
            AuditedTool(CurrentDateTool(), audit: audit),
            AuditedTool(RunCommandTool(runner: commandRunner), audit: audit),
            AuditedTool(ReadFileTool(reader: reader, approval: approval), audit: audit),
            AuditedTool(
                EditFileTool(writer: FileWriter(options: runner), approval: approval, audit: audit), audit: audit),
            AuditedTool(InspectTool(introspection: introspection), audit: audit),
            AuditedTool(NotifyTool(notifier: notifier, audit: audit), audit: audit),
        ]
    }

    /// Tools whose names appear in `names`; unknown names are reported back.
    public func select(_ names: [String]) -> (tools: [any WispTool], unknown: [String]) {
        let byName = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })
        var tools: [any WispTool] = []
        var unknown: [String] = []
        for name in names {
            if let tool = byName[name] { tools.append(tool) } else { unknown.append(name) }
        }
        return (tools, unknown)
    }
}
