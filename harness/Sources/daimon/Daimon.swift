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
        subcommands: [Respond.self, Chat.self, Tools.self, Mcp.self, Logs.self, DoctorCommand.self, Approvals.self],
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
        let session = try Daimon.begin(
            .init(
                entryPoint: "respond", instructions: instructions, model: try model.map(Daimon.parseModel),
                toolNames: toolNames, unsafe: unsafe, autoApprove: yes),
            approver: DenyingApprover(
                reason: "approval required; re-run with --yes, use daimon chat to be asked, or lower approval.threshold"
            ))
        defer { session.end() }
        let agent = try Agent(
            instructions: session.instructions, tools: session.tools, model: session.config.model, audit: session.audit)
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

    /// Sets up a session, turning set-up failures into usage errors and printing the egress note.
    static func begin(_ request: Session.Request, approver: any Approver) throws -> Session {
        let session: Session
        do {
            session = try Session.begin(request, home: home, approver: approver)
        } catch let failure as Session.Failure {
            throw ValidationError("\(failure)")
        }
        if let note = session.egressNote {
            FileHandle.standardError.write(Data((note + "\n").utf8))
        }
        return session
    }

    /// Parses a `--model` value into a usage error on failure.
    static func parseModel(_ text: String) throws -> ModelSelection {
        do {
            return try ModelSelection(parsing: text)
        } catch {
            throw ValidationError("\(error)")
        }
    }
}

/// Serves MCP over stdio until the client closes the pipe.
struct Mcp: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Serve daimon's tools to an MCP client over stdio.",
        discussion: "Exposes 'respond' (run a task on the model, on a named thread) and 'close_thread', and the "
            + "resources daimon://tools and daimon://tools.md. Stdout carries the protocol; diagnostics go to stderr.")

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
        let session = try Daimon.begin(
            .init(
                entryPoint: "mcp", instructions: instructions, model: try model.map(Daimon.parseModel), unsafe: unsafe,
                autoApprove: yes),
            approver: DenyingApprover(reason: "unused: the MCP server elicits approval itself"))
        defer { session.end() }
        try await DaimonServer(config: session.config, audit: session.audit, autoApprove: yes, store: session.store)
            .run()
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

    @Flag(name: .long, help: "List saved transcripts (for --resume) and exit.")
    var list = false

    mutating func run() async throws {
        let store = TranscriptStore(directory: Daimon.home.transcripts)
        if list {
            for name in try store.list() { print(name) }
            return
        }
        let session = try Daimon.begin(
            .init(
                entryPoint: "chat", instructions: instructions, model: try model.map(Daimon.parseModel),
                toolNames: toolNames, unsafe: unsafe, resume: resume),
            approver: TerminalApprover())
        defer { session.end() }
        try Daimon.home.ensure()
        var agent: Agent
        if let resume {
            agent = try Agent(
                transcript: try store.load(resume), tools: session.tools, model: session.config.model,
                audit: session.audit)
            Self.note("resumed '\(resume)' (\(agent.transcript.turnCount) turns)")
        } else {
            agent = try Agent(
                instructions: session.instructions, tools: session.tools, model: session.config.model,
                audit: session.audit)
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
                for tool in session.tools { print("\(tool.name)\t\(tool.description)") }
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
                session.audit.record(.sessionStart, details: ["entryPoint": "chat", "reason": "new"])
                Self.note("new conversation")
            case .unknown(let command):
                Self.note("unknown command /\(command); /help lists commands")
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
        let config: Config.Resolved
        do {
            config = try Session.loadConfig(home: Daimon.home)
        } catch let failure as Session.Failure {
            throw ValidationError("\(failure)")
        }
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
        let model = (try? Session.loadConfig(home: Daimon.home).model) ?? .default
        let findings = Doctor(home: Daimon.home, model: model).run()
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
