import ArgumentParser
import Foundation
import FoundationModels
import Synchronization
import WispCore
import WispCoreAI
import WispMCP
import WispMLX

@main
/// The `wisp` command: `respond` by default, plus `chat`, `tools`, and `mcp`.
struct Wisp: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wisp",
        abstract: "An on-device, tool-using AI microharness over Apple's Foundation Models.",
        version: WispVersion.current,
        subcommands: [
            Respond.self, Chat.self, Tools.self, Models.self, Mcp.self, Logs.self, ConfigCommand.self,
            DoctorCommand.self,
            Approvals.self, Notify.self, Scan.self, Redact.self, Watch.self, Draft.self,
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
        help: "Instructions for this conversation, added under wisp's system prompt and config.json's extension.")
    var instructions: String?

    @Option(name: .customLong("tool"), help: "Tool to enable (repeatable). All tools are enabled when omitted.")
    var toolNames: [String] = []

    @Flag(name: .customLong("no-tools"), help: "Give the model no tools: a text-only conversation any model can run.")
    var noTools = false

    @Flag(help: "Disable the run_command policy and sandbox.")
    var unsafe = false

    @Option(
        name: [.short, .customLong("model")],
        help: "Model: system, private-cloud, or <backend>:<name> (see wisp models). Defaults to config.json.")
    var model: String?

    /// The session request these flags describe.
    ///
    /// - Throws: `ValidationError` for an unknown model name.
    func request(entryPoint: EntryPoint, autoApprove: Bool = false, resume: String? = nil) throws -> Session.Request {
        .init(
            entryPoint: entryPoint, instructions: instructions, model: try model.map(Wisp.parseModel),
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
        let session = try Wisp.begin(try options.request(entryPoint: .respond, autoApprove: yes))
        defer { session.end() }
        let agent = try session.openAgent(
            approver: DenyingApprover(
                reason: "approval required; re-run with --yes, use wisp chat to be asked, or lower approval.threshold"
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
        guard isatty(FileHandle.standardInput.fileDescriptor) == 0 else { throw CleanExit.helpRequest(Wisp.self) }
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
        name: .long, help: "Print the full catalogue as Markdown, the same text as the MCP resource wisp://tools.md.")
    var markdown = false

    func run() throws {
        let config = try Wisp.usage { try Session.loadConfig(home: Wisp.home) }
        let registry = ToolRegistry(runner: config.runner, disabled: config.disabledTools, custom: config.customTools)
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

extension Wisp {
    /// The user's home directory for wisp state, honouring `WISP_HOME`.
    static let home = Home.resolve()

    /// Sets up a session, turning set-up failures into usage errors and printing its notes to stderr.
    static func begin(_ request: Session.Request) throws -> Session {
        let session = try usage { try Session.begin(request, home: home) }
        for note in session.notes {
            FileHandle.standardError.write(Data((note + "\n").utf8))
        }
        return session
    }

    /// The files given, read whole, or standard input when there are none.
    ///
    /// - Throws: A usage error for a file that cannot be read.
    static func inputs(_ paths: [String]) throws -> [(source: Triage.Source?, text: String)] {
        guard !paths.isEmpty else {
            return [(nil, String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self))]
        }
        return try paths.map { path in
            do {
                return (.path(path), String(decoding: try Data(contentsOf: URL(filePath: path)), as: UTF8.self))
            } catch {
                throw ValidationError("cannot read \(path): \(error.localizedDescription)")
            }
        }
    }

    /// A judge for a condensing command's model pass: each chunk in a fresh tool-less turn on a
    /// conversation `<prefix>-<id>` of `session`, shaped by the model sweep's schema.
    ///
    /// - Throws: `Session.Failure` if the conversation cannot be set up.
    static func judge(session: Session, prefix: String) throws -> Triage.Judge {
        let conversation = try session.conversation(
            id: "\(prefix)-" + ShortID.make(), approver: DenyingApprover(reason: "no commands run here"),
            tools: .none)
        let schema = try OutputSchema(json: ModelSweep.schemaJSON)
        return { prompt in try await conversation.openAgent().respond(to: prompt, schema: schema).text }
    }

    /// A line for the user on stderr.
    static func note(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    /// Handles Ctrl-C: the first calls `finish` so the work in progress can end cleanly, the second exits
    /// at once with status 130. Cancel the returned source to restore the default.
    static func stopOnInterrupt(_ finish: @escaping @Sendable () -> Void) -> any DispatchSourceSignal {
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        let presses = Mutex(0)
        source.setEventHandler {
            let count = presses.withLock { count in
                count += 1
                return count
            }
            if count > 1 { Darwin.exit(130) }
            note("stopping after the current run; Ctrl-C again to stop now")
            finish()
        }
        source.setCancelHandler { signal(SIGINT, SIG_DFL) }
        source.resume()
        return source
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
        abstract: "Serve wisp's tools to an MCP client over stdio.",
        discussion: "Exposes 'respond' (run a task on the model, on a named thread) and 'close_thread', and the "
            + "resources wisp://tools and wisp://tools.md. Stdout carries the protocol; diagnostics go to stderr.")

    @OptionGroup var options: SessionOptions

    @Flag(name: [.short, .customLong("yes")], help: "Approve risky commands without asking the client's user.")
    var yes = false

    func run() async throws {
        let session = try Wisp.begin(try options.request(entryPoint: .mcp, autoApprove: yes))
        defer { session.end() }
        try await WispServer(session: session).run()
    }
}

/// A line-oriented REPL: messages go to the model, `/` lines are commands.
struct Chat: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Start an interactive chat session.",
        discussion: "Type /help for commands. Transcripts save to ~/.wisp/transcripts and resume with --resume.")

    @OptionGroup var options: SessionOptions

    @Flag(name: [.short, .customLong("yes")], help: "Approve risky commands without asking.")
    var yes = false

    @Option(name: [.short, .long], help: "Resume a saved transcript by name.")
    var resume: String?

    @Option(name: .long, help: "Save the transcript under this name on exit. Defaults to the resumed name.")
    var save: String?

    @Flag(name: .long, help: "List saved transcripts (for --resume) and exit.")
    var list = false

    @Flag(name: .long, help: "Headless: JSON Lines on stdin and stdout, for a front end such as wisp-tui.")
    var json = false

    @Flag(name: .long, help: "The plain line-based chat, even when wisp-tui is installed beside wisp.")
    var plain = false

    /// The front end to hand a terminal session to: `wisp-tui` beside this executable, when it exists
    /// and the session is interactive and not already headless or asked to stay plain.
    static func frontEnd(
        besides executable: URL, json: Bool, plain: Bool, interactive: Bool,
        exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL? {
        guard !json, !plain, interactive else { return nil }
        let candidate = executable.deletingLastPathComponent().appending(path: "wisp-tui")
        return exists(candidate.path) ? candidate : nil
    }

    /// Replaces this process with `wisp-tui`, which spawns `wisp chat --json` on this same binary.
    /// Returns only if the exec failed.
    private static func handOff(to frontEnd: URL, executable: URL) {
        let passthrough = Array(CommandLine.arguments.dropFirst(2))  // after `wisp chat`
        setenv("WISP_BIN", executable.path, 1)
        let argv: [UnsafeMutablePointer<CChar>?] = ([frontEnd.path] + passthrough).map { strdup($0) } + [nil]
        execv(frontEnd.path, argv)
        for pointer in argv { free(pointer) }
    }

    mutating func run() async throws {
        let store = TranscriptStore(directory: Wisp.home.transcripts)
        if list {
            for name in try store.list() { print(name) }
            return
        }
        // The real path of this process, not argv[0], which is a bare name when launched through PATH.
        let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .resolvingSymlinksInPath()
        let interactive =
            isatty(FileHandle.standardInput.fileDescriptor) != 0
            && isatty(FileHandle.standardOutput.fileDescriptor) != 0
        if let frontEnd = Self.frontEnd(besides: executable, json: json, plain: plain, interactive: interactive) {
            Self.handOff(to: frontEnd, executable: executable)
            Self.note("could not start \(frontEnd.path); continuing with the plain chat")
        }
        let session = try Wisp.begin(try options.request(entryPoint: .chat, autoApprove: yes, resume: resume))
        defer { session.end() }
        try Wisp.home.ensure()
        if json {
            try await runJSON(session: session, store: store)
            return
        }
        let style = Style.detect(isTerminal: isatty(FileHandle.standardOutput.fileDescriptor) != 0)
        let tap = ChatEvents.Tap()
        var agent: Agent
        if let resume {
            let transcript = try Wisp.usage { try store.load(resume) }
            agent = try session.openAgent(
                approver: TerminalApprover(style: style), transcript: transcript, observer: tap)
            Self.note("resumed '\(resume)' (\(agent.transcript.turnCount) turns)")
        } else {
            agent = try session.openAgent(approver: TerminalApprover(style: style), observer: tap)
        }
        let directory = FileManager.default.currentDirectoryPath
        let views = session.introspection
        let banner =
            "wisp \(WispVersion.current) · \(agent.model.selection) · \(agent.tools.count) tools · "
            + "audit \(ChatStatus.abbreviated(Wisp.home.auditFile.path)) session \(session.audit.session)"
        var loop = ChatLoop(
            agent: agent, store: store, saveName: save ?? resume, tap: tap,
            context: .init(
                directory: directory,
                approval: ChatStatus.approvalMode(threshold: session.config.approvalThreshold, autoApprove: yes),
                git: GitState.read(in:),
                inspect: { what in await InspectTool(introspection: views).show(what) },
                banner: banner,
                models: { current, tools in
                    await ModelListing.table(config: session.config, home: Wisp.home, current: current, tools: tools)
                },
                openModel: { selection, transcript in
                    try session.openAgent(
                        approver: TerminalApprover(style: style), transcript: transcript, observer: tap,
                        model: selection)
                }, stats: session.stats),
            style: style,
            io: .init(
                readLine: { readLine() },
                print: { text in
                    Self.midLine.withLock { $0 = false }
                    print(text)
                },
                write: { text in
                    Self.midLine.withLock { $0 = !text.hasSuffix("\n") }
                    print(text, terminator: "")
                    fflush(stdout)
                },
                note: Self.note,
                prompt: { status in
                    Self.freshLine()
                    let text = status.rendered(style: style) + "\n" + style.prompt("›") + " "
                    FileHandle.standardError.write(Data(text.utf8))
                }))
        try await loop.run()
    }

    /// The headless face: JSON Lines in and out, for `wisp-tui` and other front ends (`docs/wisp.md`).
    private func runJSON(session: Session, store: TranscriptStore) async throws {
        let router = LineRouter()
        let out = Mutex(FileHandle.standardOutput)
        let send: @Sendable (String) -> Void = { line in
            out.withLock { $0.write(Data((line + "\n").utf8)) }
        }
        let reader = Thread {
            while let line = readLine() { router.receive(line) }
            router.close()
        }
        reader.start()
        let tap = ChatEvents.Tap()
        let approver = JSONApprover(router: router, timeout: session.config.approvalTimeout, send: send)
        var agent: Agent
        if let resume {
            let transcript = try Wisp.usage { try store.load(resume) }
            agent = try session.openAgent(approver: approver, transcript: transcript, observer: tap)
        } else {
            agent = try session.openAgent(approver: approver, observer: tap)
        }
        let views = session.introspection
        var loop = ChatLoop(
            agent: agent, store: store, saveName: save ?? resume, tap: tap,
            context: .init(
                directory: FileManager.default.currentDirectoryPath,
                approval: ChatStatus.approvalMode(threshold: session.config.approvalThreshold, autoApprove: yes),
                git: GitState.read(in:),
                inspect: { what in await InspectTool(introspection: views).show(what) },
                banner: "wisp \(WispVersion.current) · \(agent.model.selection) · \(agent.tools.count) tools",
                models: { current, tools in
                    await ModelListing.table(config: session.config, home: Wisp.home, current: current, tools: tools)
                },
                openModel: { selection, transcript in
                    try session.openAgent(approver: approver, transcript: transcript, observer: tap, model: selection)
                }, stats: session.stats),
            io: .init(
                readLine: { router.nextMessage() },
                print: { send(ChatProtocol.encode("output", ["text": .string($0)])) },
                write: { send(ChatProtocol.encode("delta", ["text": .string($0)])) },
                note: { send(ChatProtocol.encode("note", ["text": .string($0)])) },
                prompt: { send(ChatProtocol.encode("status", ChatProtocol.status($0))) }))
        // Raw events for the front end to render, instead of the terminal lines the loop would note.
        tap.onEvent { event in send(ChatProtocol.encode("event", ChatProtocol.event(event))) }
        try await loop.run()
        send(ChatProtocol.encode("exit"))
    }

    /// Whether the last stdout write left the cursor mid-line, so a note can start on a fresh one.
    private static let midLine = Mutex(false)

    /// Ends a streamed line before anything else is written.
    private static func freshLine() {
        fflush(stdout)
        if Self.midLine.withLock({
            let was = $0; $0 = false; return was
        }) {
            FileHandle.standardError.write(Data("\n".utf8))
        }
    }

    /// Writes a status line to stderr so stdout stays clean for replies.
    private static func note(_ text: String) {
        Self.freshLine()
        FileHandle.standardError.write(Data((text + "\n").utf8))
        Diagnostics.chat.info(Style.stripped(text))
    }
}

/// Reads the audit log back, filtered, as summaries or raw JSON Lines.
struct Logs: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show the audit log.",
        discussion: "Reads ~/.wisp/logs/audit.jsonl (and rotated files). Filters combine with AND.")

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
        let config = try Wisp.usage { try Session.loadConfig(home: Wisp.home) }
        let query = AuditQuery(session: session, kinds: kinds, tool: tool, last: last)
        for event in try Introspection(home: Wisp.home, config: config).audit(query) {
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
        discussion: "Defaults applied; the same view the model's inspect tool and the wisp://config resource give.")

    func run() throws {
        let config = try Wisp.usage { try Session.loadConfig(home: Wisp.home) }
        print(Introspection.render(Introspection(home: Wisp.home, config: config).configuration))
    }
}

/// Lists the models a session can run on: Apple's two and whatever each local backend serves.
struct Models: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List the models usable with --model and config.json.",
        discussion:
            "A model is listed when it resolves and declares tool calling (or, with --no-tools, when it can "
            + "hold a conversation at all). --all adds the rest with the reason each is excluded.")

    @Flag(name: .long, help: "Also list the models that cannot be used, with the reason.")
    var all = false

    @Flag(name: .customLong("no-tools"), help: "List the models usable for a conversation with no tools.")
    var noTools = false

    func run() async throws {
        let config = try Wisp.usage { try Session.loadConfig(home: Wisp.home) }
        let tools: [any Tool] =
            noTools
            ? [] : ToolRegistry(runner: config.runner, disabled: config.disabledTools, custom: config.customTools).all
        let lines = await ModelListing.lines(
            config: config, home: Wisp.home, current: config.model, tools: tools, all: all)
        for line in lines { print(line) }
    }
}

/// Posts a macOS notification from the command line, through the same notifier the model's `notify`
/// tool uses: bounded, rate-limited, audited as `notification` with source `user`.
struct Notify: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show a macOS notification.",
        discussion: "The same path as the model's notify tool: bounded text, a per-minute limit, audited.")

    @Argument(help: "The message.")
    var message: String

    @Option(name: [.short, .long], help: "The title (default: wisp).")
    var title = "wisp"

    @Option(name: .long, help: "A second line under the title.")
    var subtitle: String?

    @Flag(name: .long, help: "Play the default notification sound.")
    var sound = false

    func run() throws {
        let session = try Wisp.begin(.init(entryPoint: .notify))
        defer { session.end() }
        let outcome = session.notifier.post(
            .init(title: title, body: message, subtitle: subtitle, sound: sound), source: .user, audit: session.audit)
        if case .refused(let reason) = outcome { throw ValidationError("notification not shown: \(reason)") }
    }
}

/// Reports credentials and personal data in files or standard input, masked; exits 1 when it finds any.
struct Scan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Scan text for credentials and personal data.",
        discussion:
            "Reads the files given, or standard input. A unified diff is scanned by its added lines, so "
            + "'git diff --cached | wisp scan' checks a commit before it is made. Values are shown masked. "
            + "Exits 1 when anything is found.")

    @Argument(help: "Files to scan. Standard input when omitted.")
    var paths: [String] = []

    @Flag(name: .long, help: "Report personal data too: emails, phone and card numbers, public IPs, user names.")
    var personal = false

    @Flag(name: .long, help: "Also have the model look for what rules cannot recognise. About 2 s per 4 KiB.")
    var thorough = false

    @Option(name: [.short, .customLong("model")], help: "Model for --thorough. Defaults to config.json.")
    var model: String?

    @Flag(name: .long, help: "Print the reports as JSON, one per line.")
    var json = false

    func run() async throws {
        let session = try Wisp.begin(.init(entryPoint: .scan, model: try model.map(Wisp.parseModel)))
        defer { session.end() }
        let options = SecretScan.Options(categories: personal ? [.secret, .personal] : [.secret], thorough: thorough)
        var found = false
        for input in try Wisp.inputs(paths) {
            let judge = thorough ? try Wisp.judge(session: session, prefix: "scan") : nil
            let report = try await SecretScan(options: options, judge: judge).run(input.text, from: input.source)
            session.audit.record(.secretScan, details: AuditEvent.Details.secretScan(report))
            print(json ? ChatProtocol.encode("scan", report.json.objectValue ?? [:]) : report.rendered)
            found = found || !report.findings.isEmpty
        }
        if found { throw ExitCode.failure }
    }
}

/// Prints a file or standard input with credentials and personal data replaced by numbered markers.
struct Redact: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Redact credentials and personal data from text.",
        discussion:
            "Reads a file, or standard input, and prints it with each value replaced by a marker such as "
            + "[REDACTED:email#1]; the same value gets the same marker. A summary goes to stderr.")

    @Argument(help: "The file to redact. Standard input when omitted.")
    var path: String?

    @Flag(name: .long, help: "Replace credentials only and keep personal data.")
    var secretsOnly = false

    @Flag(name: .long, help: "Also have the model find names, addresses, and identifiers. About 2 s per 4 KiB.")
    var thorough = false

    @Option(name: [.short, .customLong("model")], help: "Model for --thorough. Defaults to config.json.")
    var model: String?

    func run() async throws {
        let session = try Wisp.begin(.init(entryPoint: .redact, model: try model.map(Wisp.parseModel)))
        defer { session.end() }
        guard let input = try Wisp.inputs(path.map { [$0] } ?? []).first else { return }
        let options = Redaction.Options(
            categories: secretsOnly ? [.secret] : [.secret, .personal], thorough: thorough, maxOutputBytes: .max)
        let judge = thorough ? try Wisp.judge(session: session, prefix: "redact") : nil
        let report = try await Redaction(options: options, judge: judge).run(input.text, from: input.source)
        session.audit.record(.redaction, details: AuditEvent.Details.redaction(report))
        print(report.text, terminator: "")
        FileHandle.standardError.write(Data((report.summary + "\n").utf8))
    }
}

extension Watcher.NotifyPolicy: ExpressibleByArgument {}
extension ChangeDraft.Kind: ExpressibleByArgument {}

/// Drafts a commit message, PR description, or changelog line from the staged diff or a piped one.
struct Draft: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Draft a commit message, a PR description, or a changelog line from a diff.",
        discussion:
            "Reads a diff piped to it, or runs git diff --cached here. The model summarises it per file, then "
            + "writes from the summary. Review the draft; a commit body ends with a line for the reason to replace. For example: "
            + "wisp draft > /tmp/msg && $EDITOR /tmp/msg && git commit -F /tmp/msg")

    @Argument(help: "commit (default), pr, or changelog.")
    var kind: ChangeDraft.Kind = .commit

    @Option(name: [.short, .customLong("model")], help: "Model to write with. Defaults to config.json.")
    var model: String?

    @Flag(name: [.short, .long], help: "Approve running git diff without asking.")
    var yes = false

    func run() async throws {
        let session = try Wisp.begin(
            .init(entryPoint: .draft, model: try model.map(Wisp.parseModel), autoApprove: yes))
        defer { session.end() }
        let conversation = try session.conversation(
            id: "draft-" + ShortID.make(), approver: TerminalApprover(style: .plain), tools: .none)
        let directory = FileManager.default.currentDirectoryPath
        let source: Triage.Source
        let captured: Triage.Captured
        if isatty(STDIN_FILENO) == 0 {
            source = .path("standard input")
            captured = Triage.Captured(
                text: String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self))
        } else {
            source = .command("git diff --cached", workingDirectory: directory)
            let runner = CommandRunner(
                options: session.config.runner, audit: conversation.audit, approval: conversation.gate)
            captured = Triage.Captured(try await runner.run("git diff --cached", in: directory))
        }
        let summarySchema = try OutputSchema(json: DiffSummary.schemaJSON)
        let draftSchema = try OutputSchema(json: ChangeDraft.schemaJSON)
        do {
            let draft = try await ChangeDraft.draft(
                kind, from: captured, source: source,
                summarise: { try await conversation.openAgent().respond(to: $0, schema: summarySchema).text },
                write: { try await conversation.openAgent().respond(to: $0, schema: draftSchema).text })
            print(draft.text)
        } catch let failure as ChangeDraft.Failure {
            throw ValidationError("\(failure)")
        }
    }
}

/// Reruns a command as files change or on an interval, and notifies when its outcome turns.
struct Watch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Rerun a command when files change, and notify when it starts or stops failing.",
        discussion:
            "Runs the command at once, then again after each change under the watched paths (build output and "
            + ".git ignored) and, with --every, on an interval. A failing run is triaged by the model into its "
            + "failures; when the outcome turns, a notification says so. The command runs under the policy, "
            + "sandbox, and approval like any other. Ctrl-C stops after the current run; a second Ctrl-C at once.")

    @Argument(help: "The command line to run, such as 'swift test 2>&1'.")
    var command: String

    @Option(name: [.customShort("C"), .long], help: "Directory to run the command in. Default: the current one.")
    var directory: String?

    @Option(name: .customLong("path"), help: "A directory to watch for changes (repeatable). Default: --directory.")
    var paths: [String] = []

    @Flag(name: .customLong("no-files"), help: "Do not watch files; run on the interval only.")
    var noFiles = false

    @Option(name: .long, help: "Also run every this many seconds.")
    var every: Double?

    @Option(name: .long, help: "When to notify: change (default), failure, always, never.")
    var notify: Watcher.NotifyPolicy = .change

    @Flag(name: .customLong("no-triage"), help: "Do not have the model triage a failing run.")
    var noTriage = false

    @Option(name: .long, help: "Stop after this many runs.")
    var maxRuns: Int?

    @Option(name: [.short, .customLong("model")], help: "Model for triage. Defaults to config.json.")
    var model: String?

    @Flag(name: [.short, .long], help: "Approve risky commands without asking.")
    var yes = false

    func validate() throws {
        if noFiles && every == nil { throw ValidationError("--no-files needs --every, or nothing would rerun it") }
        if let every, every < 1 { throw ValidationError("--every must be at least 1 second") }
        if let maxRuns, maxRuns < 1 { throw ValidationError("--max-runs must be at least 1") }
    }

    func run() async throws {
        let session = try Wisp.begin(
            .init(entryPoint: .watch, model: try model.map(Wisp.parseModel), autoApprove: yes))
        defer { session.end() }
        let conversation = try session.conversation(
            id: "watch-" + ShortID.make(), approver: TerminalApprover(style: .plain), tools: .none)
        let directory = directory ?? FileManager.default.currentDirectoryPath
        let source = Triage.Source.command(command, workingDirectory: directory)
        var runner = CommandRunner(
            options: session.config.runner, audit: conversation.audit, approval: conversation.gate)
        runner.options.maxOutputBytes = Triage.Options().maxOutputBytes
        let schema = try OutputSchema(json: Triage.schemaJSON)
        let triage = Triage { prompt in try await conversation.openAgent().respond(to: prompt, schema: schema).text }
        // The command line never changes, so it is classified and approved once, here; every run after
        // still passes the policy and the sandbox and is audited.
        let authorized = try await runner.authorize(command, in: directory)
        let (triggers, continuation) = AsyncStream.makeStream(
            of: Watcher.Trigger.self, bufferingPolicy: .bufferingNewest(1))
        continuation.yield(.start)
        let watcher =
            noFiles
            ? nil
            : FileWatcher(paths: paths.isEmpty ? [directory] : paths) {
                continuation.yield(.change)
            }
        if !noFiles && watcher == nil { throw ValidationError("cannot watch \(paths.isEmpty ? [directory] : paths)") }
        let interval = every.map { seconds in
            Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(seconds))
                    continuation.yield(.interval)
                }
            }
        }
        defer { interval?.cancel() }
        let stop = Wisp.stopOnInterrupt { continuation.finish() }
        defer { stop.cancel() }
        let command = command
        let clock = Date.FormatStyle(date: .omitted, time: .standard)
        Wisp.note(
            "watching \(watcher == nil ? "" : "\(paths.isEmpty ? directory : paths.joined(separator: ", ")) ")"
                + "\(every.map { "every \($0) s " } ?? "")for: \(command)")
        // The file watcher must outlive the loop; nothing else refers to it after this point.
        defer { withExtendedLifetime(watcher) {} }
        try await Watcher(
            command: command,
            options: .init(notify: notify, triage: !noTriage, maxRuns: maxRuns),
            execute: { Triage.Captured(try await authorized.run()) },
            triage: { captured in try await triage.run(captured, from: source).findings },
            notify: { message in _ = session.notifier.post(message, source: .watch, audit: conversation.audit) },
            report: { run in
                print("[\(Date().formatted(clock))] \(run.summary)")
                for finding in run.findings ?? [] {
                    print("  \(finding.kind)  \(finding.location ?? "-")  \(finding.message)")
                }
                fflush(stdout)
                conversation.audit.record(.watchRun, details: AuditEvent.Details.watchRun(run, command: command))
            }
        ).run(triggers)
    }
}

/// Checks that this install can work: OS version, model availability, sandbox, config, home directory.
struct DoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor", abstract: "Check that wisp can run on this Mac.",
        discussion: "Exits non-zero if any check fails. The first thing to run when something is wrong.")

    func run() throws {
        let config = try? Session.loadConfig(home: Wisp.home)
        let findings = Doctor(home: Wisp.home, model: config?.model ?? .default, config: config ?? Config().resolved)
            .run()
        print("wisp \(WispVersion.current)")
        print(Doctor.render(findings))
        guard Doctor.allPassed(findings) else { throw ExitCode.failure }
    }
}

/// Lists and revokes standing command approvals in ~/.wisp/approvals.json.
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
            let store = ApprovalStore(url: Wisp.home.approvalsFile)
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

        @Argument(help: "The id shown by 'wisp approvals'.")
        var id: String

        func run() async throws {
            let store = ApprovalStore(url: Wisp.home.approvalsFile)
            guard try await store.revoke(id: id) else { throw ValidationError("no approval with id \(id)") }
            print("revoked \(id)")
        }
    }

    /// Removes every approval.
    struct Clear: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Revoke every standing approval.")

        func run() async throws {
            try await ApprovalStore(url: Wisp.home.approvalsFile).clear()
            print("cleared")
        }
    }
}
