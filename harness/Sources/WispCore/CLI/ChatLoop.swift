import Foundation

/// The `wisp chat` read-eval-print loop over an agent, with its input and output injected so the
/// whole loop runs in tests over a scripted model. The CLI supplies the terminal; tests supply lines.
///
/// Messages go to the model and stream to `io.write`; `/` lines are `ChatInput` commands. Replies
/// print to stdout, everything else is a note on stderr, so stdout stays clean for the replies. Tool
/// activity arrives through a `ChatEvents.Tap` attached to the conversation and is shown as it happens;
/// a `ChatStatus` line is drawn above each prompt.
public struct ChatLoop {
    /// Where the loop reads and writes.
    public struct IO {
        /// The next line, or nil at end of input.
        public var readLine: () -> String?
        /// A whole line of reply text to stdout.
        public var print: (String) -> Void
        /// A fragment of streamed reply text, no newline, flushed.
        public var write: (String) -> Void
        /// A status line for the user, kept off stdout. Sendable: tool events arrive from the tool loop.
        public var note: @Sendable (String) -> Void
        /// The prompt, on a fresh line, with the status line above it when there is one.
        public var prompt: (String?) -> Void

        /// Creates an IO.
        public init(
            readLine: @escaping () -> String?, print: @escaping (String) -> Void, write: @escaping (String) -> Void,
            note: @escaping @Sendable (String) -> Void, prompt: @escaping (String?) -> Void
        ) {
            self.readLine = readLine
            self.print = print
            self.write = write
            self.note = note
            self.prompt = prompt
        }
    }

    /// What the loop can find out beyond the agent: the status line's facts and the inspect views.
    public struct Context: Sendable {
        /// The working directory shown in the status line.
        public var directory: String
        /// The approval mode, from `ChatStatus.approvalMode`.
        public var approval: String
        /// Reads the git branch and dirty state of a directory; the CLI passes `GitState.read`.
        public var git: @Sendable (String) -> (branch: String?, dirty: Bool?)
        /// Answers `/inspect <what>`; nil makes the command unavailable.
        public var inspect: (@Sendable (String) async -> String)?
        /// A banner line for the start of the session.
        public var banner: String?

        /// Creates a context.
        public init(
            directory: String, approval: String,
            git: @escaping @Sendable (String) -> (branch: String?, dirty: Bool?) = { _ in (nil, nil) },
            inspect: (@Sendable (String) async -> String)? = nil, banner: String? = nil
        ) {
            self.directory = directory
            self.approval = approval
            self.git = git
            self.inspect = inspect
            self.banner = banner
        }
    }

    /// The conversation.
    public let agent: Agent
    /// Where `/save` and the exit save go.
    public let store: TranscriptStore
    /// The name the transcript saves under on exit and for a bare `/save`; nil saves nothing on exit.
    public private(set) var saveName: String?
    /// The tap the conversation was opened with; its events are rendered as they arrive.
    public let tap: ChatEvents.Tap
    /// The styling in force.
    public let style: Style
    private let context: Context
    private let io: IO

    /// Creates a loop over `agent`.
    ///
    /// - Parameters:
    ///   - agent: The conversation, already resumed if it should be, opened with `tap` observing.
    ///   - store: Where transcripts are saved.
    ///   - saveName: The default name for `/save` and the save on exit; nil for none.
    ///   - tap: The sink the conversation's events reach; the loop sets its handler.
    ///   - context: Directory, approval mode, git reader, inspect views, banner.
    ///   - style: Styling; `.plain` when piped.
    ///   - io: Input and output.
    public init(
        agent: Agent, store: TranscriptStore, saveName: String?, tap: ChatEvents.Tap = ChatEvents.Tap(),
        context: Context, style: Style = .plain, io: IO
    ) {
        self.agent = agent
        self.store = store
        self.saveName = saveName
        self.tap = tap
        self.context = context
        self.style = style
        self.io = io
        let note = io.note
        tap.onEvent { event in
            if let line = ChatEvents.render(event, style: style) { note(line) }
        }
    }

    /// The status line for the next prompt.
    public func status() async -> ChatStatus {
        let git = context.git(context.directory)
        var used: Double?
        if let size = agent.contextSize, size > 0, let tokens = try? await agent.contextTokens() {
            used = min(1, Double(tokens) / Double(size))
        }
        return ChatStatus(
            model: agent.model.selection.description, directory: ChatStatus.abbreviated(context.directory),
            branch: git.branch, dirty: git.dirty, approval: context.approval, contextUsed: used)
    }

    /// Runs until `/quit` or end of input, then saves the transcript under `saveName` if there is one.
    ///
    /// - Throws: Only the exit save can throw; everything inside the loop is reported as a note.
    public mutating func run() async throws {
        if let banner = context.banner { io.note(style.bold(banner)) }
        io.note(style.dim("/help for commands, /quit or Ctrl-D to exit."))
        loop: while true {
            io.prompt(await status().rendered(style: style))
            guard let line = io.readLine() else { break loop }
            switch ChatInput(line: line) {
            case .quit:
                break loop
            case .help:
                io.print(ChatInput.helpText)
            case .tools:
                let width = agent.tools.map(\.name.count).max() ?? 0
                for tool in agent.tools {
                    let name = tool.name.padding(toLength: width, withPad: " ", startingAt: 0)
                    io.print("\(style.bold(name))  \(ChatEvents.firstSentence(of: tool.description))")
                }
            case .inspect(let what):
                guard let inspect = context.inspect else {
                    io.note("inspect is not available here")
                    continue
                }
                io.print(await inspect(what))
            case .last:
                io.print(tap.lastToolOutput ?? "no tool has run yet")
            case .tokens:
                do {
                    let tokens = try await agent.contextTokens().map(String.init) ?? "unknown"
                    io.print(
                        "\(tokens) tokens in \(agent.transcript.turnCount) turns; condensed \(agent.condensations) times"
                    )
                } catch {
                    io.note("error: \(error)")
                }
            case .save(let name):
                guard let name = name ?? saveName else {
                    io.note("usage: /save <name>")
                    continue
                }
                do {
                    try store.save(agent.transcript, as: name)
                    saveName = name
                    io.note("saved '\(name)'")
                } catch {
                    io.note("error: \(error)")
                }
            case .new:
                agent.reset()
                io.note("new conversation")
            case .unknown(let command):
                io.note("unknown command /\(command); /help lists commands")
            case .message(let text):
                guard !text.isEmpty else { continue }
                do {
                    _ = try await agent.stream(text) { io.write($0) }
                    io.print("")
                } catch {
                    io.print("")
                    io.note(style.red("error: \(error)"))
                }
            }
        }
        if let saveName {
            try store.save(agent.transcript, as: saveName)
            io.note("saved '\(saveName)'")
        }
    }
}
