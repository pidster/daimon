import Foundation
import Synchronization

/// Runs a shell command with a timeout, bounded output capture, and a `CommandPolicy`.
///
/// The policy's patterns are checked before launch and its sandbox, when
/// enabled, wraps the shell in `sandbox-exec`. Output is captured separately
/// for stdout and stderr, then truncated to the last `maxOutputBytes` of each
/// so that a chatty command cannot exhaust the model's small context window.
public struct CommandRunner: Sendable {
    /// Limits applied to every command this runner executes.
    public struct Options: Sendable, Equatable {
        /// Directory the command runs in; nil means the process's current directory.
        public var workingDirectory: String?
        /// Wall-clock limit after which the command is sent SIGTERM, then SIGKILL.
        public var timeout: Duration
        /// Maximum bytes kept from each of stdout and stderr; earlier output is discarded.
        public var maxOutputBytes: Int
        /// What may run and how it is confined.
        public var policy: CommandPolicy

        /// Creates options. Defaults are a 60-second timeout, 4 KiB per stream, and the default policy.
        public init(
            workingDirectory: String? = nil, timeout: Duration = .seconds(60), maxOutputBytes: Int = 4096,
            policy: CommandPolicy = .default
        ) {
            self.workingDirectory = workingDirectory
            self.timeout = timeout
            self.maxOutputBytes = maxOutputBytes
            self.policy = policy
        }
    }

    /// What a finished command produced.
    public struct Outcome: Sendable, Equatable {
        /// The process exit status, or the terminating signal negated if it was killed.
        public var exitStatus: Int32
        /// Captured standard output, possibly truncated to its tail.
        public var stdout: String
        /// Captured standard error, possibly truncated to its tail.
        public var stderr: String
        /// Whether the command hit the timeout and was killed.
        public var timedOut: Bool
        /// Whether either stream lost leading bytes to the output limit.
        public var truncated: Bool

        /// A compact, model-facing rendering of the outcome.
        public var rendered: String {
            var lines = ["exit status: \(exitStatus)"]
            if timedOut { lines.append("timed out: the command was killed") }
            if truncated { lines.append("output truncated: only the tail of each stream is shown") }
            if !stdout.isEmpty { lines.append("stdout:\n\(stdout)") }
            if !stderr.isEmpty { lines.append("stderr:\n\(stderr)") }
            return lines.joined(separator: "\n")
        }
    }

    /// Reasons a command could not be started.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// The requested working directory does not exist or is not a directory.
        case invalidWorkingDirectory(String)
        /// The shell could not be launched.
        case launchFailed(String)
        /// The policy's patterns rejected the command.
        case denied(String)

        /// Human-readable explanation suitable for printing to stderr.
        public var description: String {
            switch self {
            case .invalidWorkingDirectory(let path): "working directory does not exist: \(path)"
            case .launchFailed(let reason): "could not launch /bin/sh: \(reason)"
            case .denied(let reason): "command denied by policy: \(reason)"
            }
        }
    }

    /// Limits applied to every command.
    public var options: Options

    /// Creates a runner with the given limits.
    public init(options: Options = Options()) {
        self.options = options
    }

    /// Runs `command` through `/bin/sh -c` and waits for it to finish or time out.
    ///
    /// - Parameter command: A POSIX shell command line.
    /// - Returns: The exit status and bounded output.
    /// - Throws: `Failure` if the policy rejects the command or it cannot be started.
    public func run(_ command: String) async throws -> Outcome {
        if case .denied(let reason) = options.policy.check(command) {
            throw Failure.denied(reason)
        }
        let workingDirectory = options.workingDirectory ?? FileManager.default.currentDirectoryPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &isDirectory), isDirectory.boolValue
        else { throw Failure.invalidWorkingDirectory(workingDirectory) }

        let process = Process()
        if options.policy.sandbox.enabled {
            let profile = options.policy.seatbeltProfile(
                workingDirectory: workingDirectory,
                temporaryDirectory: FileManager.default.temporaryDirectory.path,
                home: FileManager.default.homeDirectoryForCurrentUser.path
            )
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            process.arguments = ["-p", profile, "/bin/sh", "-c", command]
        } else {
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
        }
        process.currentDirectoryURL = options.workingDirectory.map { URL(fileURLWithPath: $0) }
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let stdoutBuffer = OutputBuffer()
        let stderrBuffer = OutputBuffer()
        stdoutBuffer.capture(stdoutPipe.fileHandleForReading)
        stderrBuffer.capture(stderrPipe.fileHandleForReading)

        let timedOut = Mutex(false)
        let watchdog = Mutex<Task<Void, Never>?>(nil)
        let timeout = options.timeout

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: Failure.launchFailed(error.localizedDescription))
                return
            }
            let pid = process.processIdentifier
            watchdog.withLock {
                $0 = Task {
                    guard (try? await Task.sleep(for: timeout)) != nil else { return }
                    timedOut.withLock { $0 = true }
                    kill(pid, SIGTERM)
                    guard (try? await Task.sleep(for: .seconds(2))) != nil else { return }
                    kill(pid, SIGKILL)
                }
            }
        }
        watchdog.withLock { $0?.cancel() }

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        stdoutBuffer.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
        stderrBuffer.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())

        let out = Self.tail(stdoutBuffer.contents, maxBytes: options.maxOutputBytes)
        let err = Self.tail(stderrBuffer.contents, maxBytes: options.maxOutputBytes)
        let status: Int32 =
            process.terminationReason == .uncaughtSignal ? -process.terminationStatus : process.terminationStatus
        return Outcome(
            exitStatus: status,
            stdout: out.text,
            stderr: err.text,
            timedOut: timedOut.withLock { $0 },
            truncated: out.truncated || err.truncated
        )
    }

    /// Keeps at most `maxBytes` from the end of `data`, decoded as UTF-8 with replacement.
    static func tail(_ data: Data, maxBytes: Int) -> (text: String, truncated: Bool) {
        guard data.count > maxBytes else { return (String(decoding: data, as: UTF8.self), false) }
        return (String(decoding: data.suffix(maxBytes), as: UTF8.self), true)
    }

}

/// A thread-safe byte accumulator fed by a pipe's readability handler.
private final class OutputBuffer: Sendable {
    private let storage = Mutex(Data())

    /// A snapshot of everything captured so far.
    var contents: Data { storage.withLock { $0 } }

    /// Appends bytes; safe to call from the pipe's handler queue and the caller concurrently.
    func append(_ data: Data) {
        storage.withLock { $0.append(data) }
    }

    /// Installs a readability handler that appends every chunk until end of file.
    func capture(_ handle: FileHandle) {
        handle.readabilityHandler = { [self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                append(chunk)
            }
        }
    }
}
