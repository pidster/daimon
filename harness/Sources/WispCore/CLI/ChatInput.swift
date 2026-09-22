/// One line typed into `wisp chat`, parsed into a command or a message.
public enum ChatInput: Equatable, Sendable {
    /// End the session.
    case quit
    /// Show the command list.
    case help
    /// List the tools the model can call.
    case tools
    /// Save the transcript, under the given name or the session's default.
    case save(String?)
    /// Start a fresh session with the same instructions and tools.
    case new
    /// Report how many tokens the transcript occupies.
    case tokens
    /// Show wisp's own state (`config`, `status`, `approvals`, `audit`), as the model's `inspect` tool would.
    case inspect(String)
    /// Show the last tool result in full.
    case last
    /// List the models the session could switch to.
    case models
    /// Switch the conversation to a model, or show the current one when nil.
    case model(String?)
    /// A message for the model.
    case message(String)
    /// A slash command that does not exist.
    case unknown(String)

    /// Parses a raw line. Leading and trailing whitespace is ignored; a line
    /// starting with `/` is a command, a bare `exit`, `quit`, or `q` ends the
    /// session, and anything else is a message.
    public init(line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["exit", "quit", "q"].contains(trimmed.lowercased()) {
            self = .quit
            return
        }
        if ["help", "?"].contains(trimmed.lowercased()) {
            self = .help
            return
        }
        guard trimmed.hasPrefix("/") else {
            self = .message(trimmed)
            return
        }
        let parts = trimmed.dropFirst().split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let command = parts.first.map(String.init) ?? ""
        let argument = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : nil
        switch command {
        case "quit", "exit", "q": self = .quit
        case "help", "?": self = .help
        case "tools": self = .tools
        case "save": self = .save(argument)
        case "new": self = .new
        case "tokens": self = .tokens
        case "inspect", "status": self = .inspect(argument ?? (command == "status" ? "status" : "status"))
        case "last": self = .last
        case "models": self = .models
        case "model": self = .model(argument)
        default: self = .unknown(command)
        }
    }

    /// The text shown for `/help`.
    public static let helpText = """
        /help          show this list
        /tools         list the tools the model can call
        /tokens        show how much of the context window the conversation uses
        /inspect [what] show wisp's own config, status (default), approvals, or audit
        /last          show the last tool result in full
        /models        list the models this Mac can run
        /model [name]  switch the conversation to a model, keeping the transcript; no name shows the current one
        /save [name]   save the transcript to ~/.wisp/transcripts
        /new           start a fresh conversation with the same instructions and tools
        /quit          exit (also /exit, a bare exit or quit, Ctrl-D)
        """
}
