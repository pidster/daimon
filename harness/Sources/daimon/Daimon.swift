import ArgumentParser
import DaimonCore
import DaimonCoreAI
import DaimonMCP
import DaimonMLX
import Foundation
import FoundationModels

@main
/// The `daimon` command: `respond` by default, plus `chat`, `tools`, and `mcp`.
struct Daimon: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daimon",
        abstract: "An on-device, tool-using AI microharness over Apple's Foundation Models.",
        version: DaimonVersion.current,
        subcommands: [
            Respond.self, Chat.self, Tools.self, Models.self, Mcp.self, Logs.self, ConfigCommand.self,
            DoctorCommand.self,
            Approvals.self,
        ],
        defaultSubcommand: Respond.self
    )

    /// Registers the model backends this build carries, then parses and runs.
    static func main() async {
        ModelBackends.register(CoreAIBackend())
        ModelBackends.register(MLXBackend())
        await main(nil)
    }
}

/// The flags every session-starting subcommand shares, declared once.
struct SessionOptions: ParsableArguments {
    @Option(
        name: [.short, .customLong("instructions")],
        help: "Instructions for this conversation, added under daimon's system prompt and config.json's extension.")
    var instructions: String?

    @Option(name: .customLong("tool"), help: "Tool to enable (repeatable). All tools are enabled when omitted.")
    var toolNames: [String] = []

    @Flag(name: .customLong("no-tools"), help: "Give the model no tools: a text-only conversation any model can run.")
    var noTools = false

    @Flag(help: "Disable the run_command policy and sandbox.")
    var unsafe = false

    @Option(
        name: [.short, .customLong("model")],
        help: "Model: system (on device) or private-cloud. Defaults to config.json.")
    var model: String?

    /// The session request these flags describe.
    ///
    /// - Throws: `ValidationError` for an unknown model name.
    func request(entryPoint: EntryPoint, autoApprove: Bool = false, resume: String? = nil) throws -> Session.Request {
        .init(
            entryPoint: entryPoint, instructions: instructions, model: try model.map(Daimon.parseModel),
            tools: noTools ? .none : ToolSelection(toolNames), unsafe: unsafe, autoApprove: autoApprove,
            resume: resume)
    }
}

/// One prompt in, one reply out, in the shape of `fm respond`.
struct Respond: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Generate a response to a prompt, calling tools as needed.")

    @Argument(help: "Prompt for the model. Read from stdin when omitted and stdin is a pipe.")
    var prompt: String?

    @OptionGroup var options: SessionOptions

    @Flag(inversion: .prefixedNo, help: "Stream the output as it is generated.")
    var stream = true

    @Flag(name: [.short, .customLong("yes")], help: "Approve risky commands without asking (non-interactive).")
    var yes = false

    @Option(
        name: .customLong("schema"),
        help: "Path to a JSON Schema; the reply is JSON of that shape (not streamed).")
    var schemaPath: String?

    mutating func run() async throws {
        let text = try prompt ?? Self.readStdin()
        let schema = try schemaPath.map { path in
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                return try OutputSchema(json: try JSONDecoder().decode(JSONValue.self, from: data))
            } catch let failure as OutputSchema.Failure {
                throw ValidationError("\(failure)")
            } catch {
                throw ValidationError("cannot read the schema at \(path): \(error.localizedDescription)")
            }
        }
        let session = try Daimon.begin(try options.request(entryPoint: .respond, autoApprove: yes))
        defer { session.end() }
        let agent = try session.openAgent(
            approver: DenyingApprover(
                reason: "approval required; re-run with --yes, use daimon chat to be asked, or lower approval.threshold"
            ))
        if let schema {
            print(try await agent.respond(to: text, schema: schema).text)
        } else if stream {
            try await agent.stream(text) { delta in
                print(delta, terminator: "")
                fflush(stdout)
            }
            print()
        } else {
            print(try await agent.respond(to: text).text)
        }
    }

    /// The whole of piped stdin, trimmed; a usage error if empty. When stdin is a terminal there is
    /// nothing to read and waiting would look like a hang, so the help is shown instead.
    private static func readStdin() throws -> String {
        guard isatty(FileHandle.standardInput.fileDescriptor) == 0 else { throw CleanExit.helpRequest(Daimon.self) }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ValidationError("No prompt given and stdin is empty.") }
        return text
    }
}

/// Prints the registered tools as `name<TAB>description`, or the full catalogue as JSON or Markdown.
struct Tools: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List the tools available to the model.")

    @Flag(name: .long, help: "Print the full catalogue (schemas, limits, example prompts) as JSON.")
    var json = false

    @Flag(
        name: .long, help: "Print the full catalogue as Markdown, the same text as the MCP resource daimon://tools.md.")
    var markdown = false

    func run() throws {
        let registry = ToolRegistry()
        if json {
            print(registry.descriptionsJSON)
        } else if markdown {
            print(registry.descriptionsMarkdown)
        } else {
            for tool in registry.all {
                print("\(tool.name)\t\(tool.description)")
            }
        }
    }
}

extension Daimon {
    /// The user's home directory for daimon state, honouring `DAIMON_HOME`.
    static let home = Home.resolve()

    /// Sets up a session, turning set-up failures into usage errors and printing its notes to stderr.
    static func begin(_ request: Session.Request) throws -> Session {
        let session = try usage { try Session.begin(request, home: home) }
        for note in session.notes {
            FileHandle.standardError.write(Data((note + "\n").utf8))
        }
        return session
    }

    /// Parses a `--model` value into a usage error on failure.
    static func parseModel(_ text: String) throws -> ModelSelection {
        try usage { try ModelSelection(parsing: text) }
    }

    /// Runs `operation`, turning a bad-input failure from the core into a usage error (exit 64) and
    /// letting everything else through.
    static func usage<T>(_ operation: () throws -> T) throws -> T {
        do {
            return try operation()
        } catch let failure as Session.Failure {
            throw ValidationError("\(failure)")
        } catch let failure as ModelSelection.Failure {
            throw ValidationError("\(failure)")
        } catch let failure as TranscriptStore.Failure {
            throw ValidationError("\(failure)")
        }
    }
}

/// Serves MCP over stdio until the client closes the pipe.
struct Mcp: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Serve daimon's tools to an MCP client over stdio.",
        discussion: "Exposes 'respond' (run a task on the model, on a named thread) and 'close_thread', and the "
            + "resources daimon://tools and daimon://tools.md. Stdout carries the protocol; diagnostics go to stderr.")

    @OptionGroup var options: SessionOptions

    @Flag(name: [.short, .customLong("yes")], help: "Approve risky commands without asking the client's user.")
    var yes = false

    func run() async throws {
        let session = try Daimon.begin(try options.request(entryPoint: .mcp, autoApprove: yes))
        defer { session.end() }
        try await DaimonServer(session: session).run()
    }
}

/// A line-oriented REPL: messages go to the model, `/` lines are commands.
struct Chat: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Start an interactive chat session.",
        discussion: "Type /help for commands. Transcripts save to ~/.daimon/transcripts and resume with --resume.")

    @OptionGroup var options: SessionOptions

    @Option(name: [.short, .long], help: "Resume a saved transcript by name.")
    var resume: String?

    @Option(name: .long, help: "Save the transcript under this name on exit. Defaults to the resumed name.")
    var save: String?

    @Flag(name: .long, help: "List saved transcripts (for --resume) and exit.")
    var list = false

    mutating func run() async throws {
        let store = TranscriptStore(directory: Daimon.home.transcripts)
        if list {
            for name in try store.list() { print(name) }
            return
        }
        let session = try Daimon.begin(try options.request(entryPoint: .chat, resume: resume))
        defer { session.end() }
        try Daimon.home.ensure()
        var agent: Agent
        if let resume {
            let transcript = try Daimon.usage { try store.load(resume) }
            agent = try session.openAgent(approver: TerminalApprover(), transcript: transcript)
            Self.note("resumed '\(resume)' (\(agent.transcript.turnCount) turns)")
        } else {
            agent = try session.openAgent(approver: TerminalApprover())
        }
        Self.note("audit log: \(Daimon.home.auditFile.path) session \(session.audit.session)")
        var saveName = save ?? resume
        Self.note("daimon chat. /help for commands, /quit or Ctrl-D to exit.")

        loop: while true {
            FileHandle.standardError.write(Data("> ".utf8))
            guard let line = readLine() else { break loop }
            switch ChatInput(line: line) {
            case .quit:
                break loop
            case .help:
                print(ChatInput.helpText)
            case .tools:
                for tool in agent.tools { print("\(tool.name)\t\(tool.description)") }
            case .tokens:
                do {
                    let tokens = try await agent.contextTokens().map(String.init) ?? "unknown"
                    print(
                        "\(tokens) tokens in \(agent.transcript.turnCount) turns; condensed \(agent.condensations) times"
                    )
                } catch {
                    Self.note("error: \(error)")
                }
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
            case .new:
                agent.reset()
                Self.note("new conversation")
            case .unknown(let command):
                Self.note("unknown command /\(command); /help lists commands")
            case .message(let text):
                guard !text.isEmpty else { continue }
                do {
                    let reply = try await agent.stream(text) { delta in
                        print(delta, terminator: "")
                        fflush(stdout)
                    }
                    print()
                    if reply.condensed {
                        Self.note("(context was full; older turns were dropped to continue)")
                    }
                } catch {
                    print()
                    Self.note("error: \(error)")
                }
            }
        }

        if let saveName {
            try store.save(agent.transcript, as: saveName)
            Self.note("saved '\(saveName)'")
        }
    }

    /// Writes a status line to stderr so stdout stays clean for replies.
    private static func note(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
        Diagnostics.chat.info(text)
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
        let config = try Daimon.usage { try Session.loadConfig(home: Daimon.home) }
        let query = AuditQuery(session: session, kinds: kinds, tool: tool, last: last)
        for event in try Introspection(home: Daimon.home, config: config).audit(query) {
            if json {
                print(String(decoding: try AuditEvent.encoder.encode(event), as: UTF8.self))
            } else {
                print(event.summary)
            }
        }
    }
}

/// Prints the effective configuration: every default applied, and where the file is.
struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config", abstract: "Print the effective configuration as JSON.",
        discussion: "Defaults applied; the same view the model's inspect tool and the daimon://config resource give.")

    func run() throws {
        let config = try Daimon.usage { try Session.loadConfig(home: Daimon.home) }
        print(Introspection.render(Introspection(home: Daimon.home, config: config).configuration))
    }
}

/// Lists the models a session can run on: Apple's two and whatever each local backend serves.
struct Models: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List the models available to --model and config.json.",
        discussion: "Apple's models are checked with the framework; each local backend lists what it serves.")

    func run() async throws {
        let config = try Daimon.usage { try Session.loadConfig(home: Daimon.home) }
        for selection in [ModelSelection.system, .privateCloud] {
            let state: String
            do {
                let resolved = try selection.resolve(config: config, home: Daimon.home)
                state = "available; \(resolved.capabilityNames.joined(separator: ", "))"
            } catch {
                state = "unavailable: \(error)"
            }
            let mark = selection == config.model ? "*" : " "
            print("\(mark) \(selection)\t\(state)")
        }
        for backend in ModelBackends.all {
            do {
                for model in try await backend.installed(config: config, home: Daimon.home) {
                    let mark = model.selection == config.model ? "*" : " "
                    print("\(mark) \(model.selection)\t\(model.detail)")
                }
            } catch {
                print("  \(backend.scheme):*\tunavailable: \(error)")
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
        let config = try? Session.loadConfig(home: Daimon.home)
        let findings = Doctor(home: Daimon.home, model: config?.model ?? .default, config: config ?? Config().resolved)
            .run()
        print("daimon \(DaimonVersion.current)")
        print(Doctor.render(findings))
        guard Doctor.allPassed(findings) else { throw ExitCode.failure }
    }
}

/// Lists and revokes standing command approvals in ~/.daimon/approvals.json.
struct Approvals: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show or revoke standing command approvals.",
        discussion:
            "Project and always approvals outlive the process. They are exact command lines, expire, and never cover dangerous commands.",
        subcommands: [List.self, Revoke.self, Clear.self], defaultSubcommand: List.self)

    /// Prints live approvals, newest first.
    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List standing approvals.")

        func run() async throws {
            let store = ApprovalStore(url: Daimon.home.approvalsFile)
            let entries = await store.all
            if entries.isEmpty {
                print("no standing approvals")
                return
            }
            for entry in entries {
                let where_ = entry.workingDirectory ?? "any directory"
                print(
                    "\(entry.id)\t\(entry.scope.rawValue)\texpires \(entry.expiresAt.formatted(date: .abbreviated, time: .omitted))\t\(where_)\t\(entry.pattern)"
                )
            }
        }
    }

    /// Removes one approval by id.
    struct Revoke: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Revoke one standing approval by id.")

        @Argument(help: "The id shown by 'daimon approvals'.")
        var id: String

        func run() async throws {
            let store = ApprovalStore(url: Daimon.home.approvalsFile)
            guard try await store.revoke(id: id) else { throw ValidationError("no approval with id \(id)") }
            print("revoked \(id)")
        }
    }

    /// Removes every approval.
    struct Clear: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Revoke every standing approval.")

        func run() async throws {
            try await ApprovalStore(url: Daimon.home.approvalsFile).clear()
            print("cleared")
        }
    }
}
