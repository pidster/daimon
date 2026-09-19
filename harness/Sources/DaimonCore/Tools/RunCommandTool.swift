import Foundation
import FoundationModels

/// Lets the model run a shell command on this machine.
///
/// The command passes the `CommandPolicy`, the approval gate, and runs under
/// the Seatbelt sandbox rooted at the harness's launch directory; a
/// model-chosen working directory changes where it runs, never what it may write.
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

    /// Supplies the timeout, output cap, and default working directory.
    private let runner: CommandRunner

    /// Creates the tool over a runner that supplies timeout and output limits.
    public init(runner: CommandRunner = CommandRunner()) {
        self.runner = runner
    }

    /// Runs the command and returns a compact rendering of its outcome.
    ///
    /// A policy denial or a bad working directory is returned as text rather
    /// than thrown, so the model sees why and can choose another approach
    /// instead of the whole response failing.
    ///
    /// - Parameter arguments: The command and optional working directory.
    /// - Returns: Exit status and bounded stdout/stderr, formatted for the model.
    public func call(arguments: Arguments) async -> String {
        var runner = runner
        if let directory = arguments.workingDirectory {
            runner.options.workingDirectory = directory
        }
        do {
            return try await runner.run(arguments.command).rendered
        } catch {
            return "error: \(error)"
        }
    }
}
