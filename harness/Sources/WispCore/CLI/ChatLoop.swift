import Foundation

/// The `wisp chat` read-eval-print loop over an agent, with its input and output injected so the
/// whole loop runs in tests over a scripted model. The CLI supplies the terminal; tests supply lines.
///
/// Messages go to the model and stream to `io.write`; `/` lines are `ChatInput` commands. Replies
/// print to stdout, everything else is a note on stderr, so stdout stays clean for the replies.
public struct ChatLoop {
    /// Where the loop reads and writes.
    public struct IO {
        /// The next line, or nil at end of input.
        public var readLine: () -> String?
        /// A whole line of reply text to stdout.
        public var print: (String) -> Void
        /// A fragment of streamed reply text, no newline, flushed.
        public var write: (String) -> Void
        /// A status line for the user, kept off stdout.
        public var note: (String) -> Void

        /// Creates an IO.
        public init(
            readLine: @escaping () -> String?, print: @escaping (String) -> Void, write: @escaping (String) -> Void,
            note: @escaping (String) -> Void
        ) {
            self.readLine = readLine
            self.print = print
            self.write = write
            self.note = note
        }
    }

    /// The conversation.
    public let agent: Agent
    /// Where `/save` and the exit save go.
    public let store: TranscriptStore
    /// The name the transcript saves under on exit and for a bare `/save`; nil saves nothing on exit.
    public private(set) var saveName: String?
    private let io: IO

    /// Creates a loop over `agent`.
    ///
    /// - Parameters:
    ///   - agent: The conversation, already resumed if it should be.
    ///   - store: Where transcripts are saved.
    ///   - saveName: The default name for `/save` and the save on exit; nil for none.
    ///   - io: Input and output.
    public init(agent: Agent, store: TranscriptStore, saveName: String?, io: IO) {
        self.agent = agent
        self.store = store
        self.saveName = saveName
        self.io = io
    }

    /// Runs until `/quit` or end of input, then saves the transcript under `saveName` if there is one.
    ///
    /// - Throws: Only the exit save can throw; everything inside the loop is reported as a note.
    public mutating func run() async throws {
        io.note("wisp chat. /help for commands, /quit or Ctrl-D to exit.")
        loop: while true {
            io.write("> ")
            guard let line = io.readLine() else { break loop }
            switch ChatInput(line: line) {
            case .quit:
                break loop
            case .help:
                io.print(ChatInput.helpText)
            case .tools:
                for tool in agent.tools { io.print("\(tool.name)\t\(tool.description)") }
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
                    let reply = try await agent.stream(text) { io.write($0) }
                    io.print("")
                    if reply.condensed { io.note("(context was full; older turns were dropped to continue)") }
                } catch {
                    io.print("")
                    io.note("error: \(error)")
                }
            }
        }
        if let saveName {
            try store.save(agent.transcript, as: saveName)
            io.note("saved '\(saveName)'")
        }
    }
}
