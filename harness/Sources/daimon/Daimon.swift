import ArgumentParser
import DaimonCore
import DaimonMCP
import Foundation
import FoundationModels

@main
/// The `daimon` command: `respond` by default, plus `chat`, `tools`, and `mcp`.
struct Daimon: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daimon",
        abstract: "An on-device, tool-using AI microharness over Apple's Foundation Models.",
        version: DaimonVersion.current,
        subcommands: [Respond.self, Chat.self, Tools.self, Mcp.self, Logs.self, DoctorCommand.self],
        defaultSubcommand: Respond.self
    )
}

/// One prompt in, one reply out, in the shape of `fm respond`.
struct Respond: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Generate a response to a prompt, calling tools as needed.")

    @Argument(help: "Prompt for the model. Read from stdin when omitted.")
    var prompt: String?

    @Option(
        name: [.short, .customLong("instructions")],
        help: "Instructions for the model to follow. Defaults to config.json's instructions.")
    var instructions: String?

    @Option(name: .customLong("tool"), help: "Tool to enable (repeatable). All tools are enabled when omitted.")
    var toolNames: [String] = []

    @Flag(inversion: .prefixedNo, help: "Stream the output as it is generated.")
    var stream = true

    @Flag(help: "Disable the run_command policy and sandbox.")
    var unsafe = false

    @Flag(name: [.short, .customLong("yes")], help: "Approve risky commands without asking (non-interactive).")
    var yes = false

    @Option(
        name: [.short, .customLong("model")],
        help: "Model: system (on device) or private-cloud. Defaults to config.json.")
    var model: String?

    mutating func run() async throws {
        let text = try prompt ?? Self.readStdin()
        var config = try Daimon.loadConfig(unsafe: unsafe)
        if let model { config.model = try Daimon.parseModel(model) }
        let audit = try Daimon.openAudit(config: config, entryPoint: "respond", unsafe: unsafe)
        let approver: any Approver =
            yes
            ? AutoApprover()
            : DenyingApprover(
                reason: "approval required; re-run with --yes, use daimon chat to be asked, or lower approval.threshold"
            )
        let gate = ApprovalGate(
            classifier: config.classifier, approver: approver, threshold: config.approvalThreshold, audit: audit)
        let tools = try Daimon.selectTools(
            toolNames, from: ToolRegistry(runner: config.runner, audit: audit, approval: gate))
        let instructions = instructions ?? config.instructions
        audit.record(
            .sessionStart,
            details: [
                "entryPoint": "respond", "instructions": .string(instructions),
                "tools": .array(tools.map { .string($0.name) }),
                "unsafe": .bool(unsafe), "model": .string(config.model.description),
            ])
        defer { audit.record(.sessionEnd) }
        Daimon.warnIfLeavingDevice(config.model)
        let agent = try Agent(instructions: instructions, tools: tools, model: config.model, audit: audit)
        if stream {
            try await agent.stream(text) { delta in
                print(delta, terminator: "")
                fflush(stdout)
            }
            print()
        } else {
            print(try await agent.respond(to: text))
        }
    }

    /// The whole of stdin, trimmed; a usage error if empty.
    private static func readStdin() throws -> String {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ValidationError("No prompt given and stdin is empty.") }
        return text
    }
}

/// Prints the registered tools as `name<TAB>description`.
struct Tools: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List the tools available to the model.")

    func run() throws {
        for tool in ToolRegistry().all {
            print("\(tool.name)\t\(tool.description)")
        }
    }
}

extension Daimon {
    /// The user's home directory for daimon state, honouring `DAIMON_HOME`.
    static let home = Home.resolve()

    /// Reads `config.json` from the home directory, tolerating its absence.
    /// With `unsafe`, the run_command policy and sandbox are switched off.
    static func loadConfig(unsafe: Bool = false) throws -> Config.Resolved {
        var resolved: Config.Resolved
        do {
            resolved = try Config.load(from: home.configFile).resolved
        } catch let error as DecodingError {
            throw ValidationError("Malformed \(home.configFile.path): \(error)")
        } catch let error as CommandPolicy.Failure {
            throw ValidationError("\(home.configFile.path): \(error)")
        } catch let error as Config.Failure {
            throw ValidationError("\(home.configFile.path): \(error)")
        } catch let error as ModelSelection.Failure {
            throw ValidationError("\(home.configFile.path): \(error)")
        }
        if unsafe {
            resolved.runner.policy = .unrestricted
            FileHandle.standardError.write(Data("warning: --unsafe: run_command policy and sandbox are off\n".utf8))
        }
        return resolved
    }

    /// Opens the audit log for a new session, creating `~/.daimon/logs` if needed.
    /// Disabled by config yields a log that records nothing.
    static func openAudit(config: Config.Resolved, entryPoint: String, unsafe: Bool) throws -> AuditLog {
        let session = String(UUID().uuidString.prefix(8)).lowercased()
        guard config.auditEnabled else { return .disabled(session: session) }
        try home.ensure()
        let sink = try FileAuditSink(url: home.auditFile, limits: config.auditLimits)
        return AuditLog(session: session, sink: sink)
    }

    /// Parses a `--model` value into a usage error on failure.
    static func parseModel(_ text: String) throws -> ModelSelection {
        do {
            return try ModelSelection(parsing: text)
        } catch {
            throw ValidationError("\(error)")
        }
    }

    /// Tells the user on stderr when the chosen model sends data off the machine.
    static func warnIfLeavingDevice(_ model: ModelSelection) {
        if model.leavesDevice {
            FileHandle.standardError.write(
                Data(
                    "note: model \(model) runs on Apple's Private Cloud Compute; prompts and tool output leave this Mac\n"
                        .utf8))
        }
    }

    /// Resolves `--tool` names against the registry, or all tools when none are given.
    static func selectTools(_ names: [String], from registry: ToolRegistry) throws -> [any Tool] {
        guard !names.isEmpty else { return registry.all }
        let selection = registry.select(names)
        guard selection.unknown.isEmpty else {
            throw ValidationError("Unknown tool(s): \(selection.unknown.joined(separator: ", "))")
        }
        return selection.tools
    }
}

/// Serves MCP over stdio until the client closes the pipe.
struct Mcp: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Serve daimon's tools to an MCP client over stdio.",
        discussion: "Exposes 'respond' (run a task on the on-device model) and 'run_command'. "
            + "Stdout carries the protocol; diagnostics go to stderr.")

    @Option(
        name: [.short, .customLong("instructions")],
        help: "Default instructions for 'respond' sessions. Defaults to config.json's instructions.")
    var instructions: String?

    @Flag(help: "Disable the run_command policy and sandbox.")
    var unsafe = false

    @Flag(name: [.short, .customLong("yes")], help: "Approve risky commands without asking the client's user.")
    var yes = false

    @Option(
        name: [.short, .customLong("model")],
        help: "Default model for threads: system (on device) or private-cloud.")
    var model: String?

    func run() async throws {
        var config = try Daimon.loadConfig(unsafe: unsafe)
        if let instructions { config.instructions = instructions }
        if let model { config.model = try Daimon.parseModel(model) }
        Daimon.warnIfLeavingDevice(config.model)
        let audit = try Daimon.openAudit(config: config, entryPoint: "mcp", unsafe: unsafe)
        audit.record(
            .sessionStart,
            details: [
                "entryPoint": "mcp", "unsafe": .bool(unsafe), "autoApprove": .bool(yes),
                "model": .string(config.model.description),
            ])
        defer { audit.record(.sessionEnd) }
        try await DaimonServer(config: config, audit: audit, autoApprove: yes).run()
    }
}

/// A line-oriented REPL: messages go to the model, `/` lines are commands.
struct Chat: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Start an interactive chat session.",
        discussion: "Type /help for commands. Transcripts save to ~/.daimon/transcripts and resume with --resume.")

    @Option(
        name: [.short, .customLong("instructions")],
        help: "Instructions for the model. Defaults to config.json's instructions.")
    var instructions: String?

    @Option(name: .customLong("tool"), help: "Tool to enable (repeatable). All tools are enabled when omitted.")
    var toolNames: [String] = []

    @Option(name: [.short, .long], help: "Resume a saved transcript by name.")
    var resume: String?

    @Option(name: .long, help: "Save the transcript under this name on exit. Defaults to the resumed name.")
    var save: String?

    @Flag(help: "Disable the run_command policy and sandbox.")
    var unsafe = false

    @Option(
        name: [.short, .customLong("model")],
        help: "Model: system (on device) or private-cloud. Defaults to config.json.")
    var model: String?

    mutating func run() async throws {
        var config = try Daimon.loadConfig(unsafe: unsafe)
        if let model { config.model = try Daimon.parseModel(model) }
        try Daimon.home.ensure()
        let store = TranscriptStore(directory: Daimon.home.transcripts)
        let audit = try Daimon.openAudit(config: config, entryPoint: "chat", unsafe: unsafe)
        let gate = ApprovalGate(
            classifier: config.classifier, approver: TerminalApprover(), threshold: config.approvalThreshold,
            audit: audit)
        let tools = try Daimon.selectTools(
            toolNames, from: ToolRegistry(runner: config.runner, audit: audit, approval: gate))
        let instructions = instructions ?? config.instructions
        audit.record(
            .sessionStart,
            details: [
                "entryPoint": "chat", "instructions": .string(instructions),
                "tools": .array(tools.map { .string($0.name) }),
                "resume": resume.map { .string($0) } ?? .null, "unsafe": .bool(unsafe),
                "model": .string(config.model.description),
            ])
        defer { audit.record(.sessionEnd) }
        Daimon.warnIfLeavingDevice(config.model)
        var agent: Agent
        if let resume {
            agent = try Agent(transcript: try store.load(resume), tools: tools, model: config.model, audit: audit)
            Self.note("resumed '\(resume)' (\(agent.transcript.turnCount) turns)")
        } else {
            agent = try Agent(instructions: instructions, tools: tools, model: config.model, audit: audit)
        }
        Self.note("audit log: \(Daimon.home.auditFile.path) session \(audit.session)")
        var saveName = save ?? resume
        Self.note("daimon chat. /help for commands, /quit or Ctrl-D to exit.")

        while true {
            print("> ", terminator: "")
            fflush(stdout)
            guard let line = readLine() else { break }
            switch ChatInput(line: line) {
            case .quit:
                break
            case .help:
                print(ChatInput.helpText)
                continue
            case .tools:
                for tool in tools { print("\(tool.name)\t\(tool.description)") }
                continue
            case .tokens:
                do {
                    let tokens = try await agent.contextTokens().map(String.init) ?? "unknown"
                    print(
                        "\(tokens) tokens in \(agent.transcript.turnCount) turns; condensed \(agent.condensations) times"
                    )
                } catch {
                    Self.note("error: \(error)")
                }
                continue
            case .save(let name):
                guard let name = name ?? saveName else {
                    Self.note("usage: /save <name>")
                    continue
                }
                do {
                    try store.save(agent.transcript, as: name)
                    saveName = name
                    Self.note("saved '\(name)'")
                } catch {
                    Self.note("error: \(error)")
                }
                continue
            case .new:
                agent.reset()
                audit.record(.sessionStart, details: ["entryPoint": "chat", "reason": "new"])
                Self.note("new conversation")
                continue
            case .unknown(let command):
                Self.note("unknown command /\(command); /help lists commands")
                continue
            case .message(let text):
                guard !text.isEmpty else { continue }
                let before = agent.condensations
                do {
                    try await agent.stream(text) { delta in
                        print(delta, terminator: "")
                        fflush(stdout)
                    }
                    print()
                    if agent.condensations > before {
                        Self.note("(context was full; older turns were dropped to continue)")
                    }
                } catch {
                    print()
                    Self.note("error: \(error)")
                }
                continue
            }
            break
        }

        if let saveName {
            try store.save(agent.transcript, as: saveName)
            Self.note("saved '\(saveName)'")
        }
    }

    /// Writes a status line to stderr so stdout stays clean for replies.
    private static func note(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}

/// Reads the audit log back, filtered, as summaries or raw JSON Lines.
struct Logs: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show the audit log.",
        discussion: "Reads ~/.daimon/logs/audit.jsonl (and rotated files). Filters combine with AND.")

    @Option(name: .long, help: "Only this session id.")
    var session: String?

    @Option(name: .long, help: "Only these event kinds (repeatable), e.g. tool.call, policy.decision.")
    var kind: [String] = []

    @Option(name: .long, help: "Only tool events for this tool name.")
    var tool: String?

    @Option(name: .shortAndLong, help: "Only the last N matching events.")
    var last: Int?

    @Flag(name: .long, help: "Print raw JSON Lines instead of one-line summaries.")
    var json = false

    func run() throws {
        var kinds: [AuditEvent.Kind] = []
        for raw in kind {
            guard let parsed = AuditEvent.Kind(rawValue: raw) else {
                throw ValidationError(
                    "Unknown kind '\(raw)'. Kinds: \(AuditEvent.Kind.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            kinds.append(parsed)
        }
        let config = try Daimon.loadConfig()
        var files = Array(
            FileAuditSink.rotatedFiles(for: Daimon.home.auditFile, keep: config.auditLimits.keepFiles).reversed())
        files.append(Daimon.home.auditFile)
        var events: [AuditEvent] = []
        for file in files where FileManager.default.fileExists(atPath: file.path) {
            events += AuditQuery.events(in: try Data(contentsOf: file))
        }
        let query = AuditQuery(session: session, kinds: kinds, tool: tool, last: last)
        for event in query.filter(events) {
            if json {
                print(String(decoding: try AuditEvent.encoder.encode(event), as: UTF8.self))
            } else {
                print(event.summary)
            }
        }
    }
}

/// Checks that this install can work: OS version, model availability, sandbox, config, home directory.
struct DoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor", abstract: "Check that daimon can run on this Mac.",
        discussion: "Exits non-zero if any check fails. The first thing to run when something is wrong.")

    func run() throws {
        let model = (try? Daimon.loadConfig().model) ?? .default
        let findings = Doctor(home: Daimon.home, model: model).run()
        print("daimon \(DaimonVersion.current)")
        print(Doctor.render(findings))
        guard Doctor.allPassed(findings) else { throw ExitCode.failure }
    }
}
