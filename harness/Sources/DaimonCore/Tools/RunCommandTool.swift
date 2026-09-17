import Foundation
import FoundationModels

/// Lets the model run a shell command on this machine.
///
/// There is no sandbox: the command runs with the harness's own privileges.
/// Restrict exposure with the CLI's `--tool` selection when that matters.
public struct RunCommandTool: Tool {
    /// The identifier the model uses to request this tool.
    public let name = "run_command"
    /// What the model is told this tool does.
    public let description =
        "Runs a shell command on this Mac and returns its exit status and output. "
        + "Use it to build or test software, list or read files, and inspect the system."

    /// Arguments the model may supply when calling the tool.
    @Generable
    public struct Arguments {
        /// The command line, executed by `/bin/sh -c`.
        @Guide(description: "POSIX shell command line to run with /bin/sh -c.")
        public var command: String
        /// Optional directory to run in; nil means the harness's current directory.
        @Guide(description: "Absolute path of the directory to run in. Omit to use the current directory.")
        public var workingDirectory: String?
    }

    private let runner: CommandRunner

    /// Creates the tool over a runner that supplies timeout and output limits.
    public init(runner: CommandRunner = CommandRunner()) {
        self.runner = runner
    }

    /// Runs the command and returns a compact rendering of its outcome.
    ///
    /// - Parameter arguments: The command and optional working directory.
    /// - Returns: Exit status and bounded stdout/stderr, formatted for the model.
    /// - Throws: `CommandRunner.Failure` if the command cannot be started.
    public func call(arguments: Arguments) async throws -> String {
        var runner = runner
        if let directory = arguments.workingDirectory {
            runner.options.workingDirectory = directory
        }
        return try await runner.run(arguments.command).rendered
    }
}
