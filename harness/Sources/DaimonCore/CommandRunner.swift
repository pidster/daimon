import Darwin
import Foundation
import Synchronization

/// Runs a shell command with a timeout, bounded output capture, and a `CommandPolicy`.
///
/// The policy's patterns are checked before launch and its sandbox, when
/// enabled, wraps the shell in `sandbox-exec`. The command is spawned in its
/// own process group so a timeout can stop the whole tree. Output is captured
/// separately for stdout and stderr, then truncated to the last
/// `maxOutputBytes` of each so that a chatty command cannot exhaust the
/// model's small context window.
public struct CommandRunner: Sendable {
    /// Limits applied to every command this runner executes.
    public struct Options: Sendable, Equatable {
        /// Directory the command runs in; nil means the process's current directory.
        public var workingDirectory: String?
        /// Root of the sandbox's writable set. Fixed at the launch directory by default and never taken
        /// from a per-command `workingDirectory`, so a caller cannot widen the sandbox by choosing where
        /// to run.
        public var writableRoot: String
        /// Wall-clock limit after which the command's process group is sent SIGTERM, then SIGKILL.
        public var timeout: Duration
        /// Maximum bytes kept from each of stdout and stderr; earlier output is discarded.
        public var maxOutputBytes: Int
        /// What may run and how it is confined.
        public var policy: CommandPolicy

        /// Creates options. Defaults are a 60-second timeout, 4 KiB per stream, the default policy, and
        /// the current directory as the writable root.
        public init(
            workingDirectory: String? = nil, writableRoot: String? = nil, timeout: Duration = .seconds(60),
            maxOutputBytes: Int = 4096, policy: CommandPolicy = .default
        ) {
            self.workingDirectory = workingDirectory
            self.writableRoot = writableRoot ?? FileManager.default.currentDirectoryPath
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

    /// Reasons a command could not be started or was refused.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// The requested working directory does not exist or is not a directory.
        case invalidWorkingDirectory(String)
        /// The shell could not be launched.
        case launchFailed(String)
        /// The policy's patterns rejected the command.
        case denied(String)
        /// The command needed approval and did not get it.
        case disapproved(String)

        /// Human-readable explanation suitable for printing to stderr.
        public var description: String {
            switch self {
            case .invalidWorkingDirectory(let path): "working directory does not exist: \(path)"
            case .launchFailed(let reason): "could not launch /bin/sh: \(reason)"
            case .denied(let reason): "command denied by policy: \(reason)"
            case .disapproved(let reason): "command not approved: \(reason)"
            }
        }
    }

    /// Limits applied to every command.
    public var options: Options
    /// Where policy decisions and outcomes are recorded, if anywhere.
    public var audit: AuditLog?
    /// Classifies commands and asks for approval when they are risky; nil never asks.
    public var approval: ApprovalGate?

    /// Creates a runner with the given limits.
    public init(options: Options = Options(), audit: AuditLog? = nil, approval: ApprovalGate? = nil) {
        self.options = options
        self.audit = audit
        self.approval = approval
    }

    /// True when this process is already inside a Seatbelt sandbox whose profile differs from ours.
    ///
    /// Seatbelt lets a process re-apply an identical profile but refuses a different one, so the probe
    /// applies a profile no outer sandbox would use. Decided once per process from a fixed command whose
    /// output nobody else controls; a user command can never influence it.
    public static let isNestedSandbox: Bool = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = [
            "-p", "(version 1) (allow default) (deny file-write* (subpath \"/nonexistent/daimon-nesting-probe\"))",
            "/usr/bin/true",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return true }
        process.waitUntilExit()
        return process.terminationStatus != 0
    }()

    /// Runs `command` through `/bin/sh -c` and waits for it to finish or time out.
    ///
    /// - Parameter command: A POSIX shell command line.
    /// - Returns: The exit status and bounded output.
    /// - Throws: `Failure` if the policy rejects the command or it cannot be started.
    public func run(_ command: String) async throws -> Outcome {
        let workingDirectory = options.workingDirectory ?? FileManager.default.currentDirectoryPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &isDirectory), isDirectory.boolValue
        else { throw Failure.invalidWorkingDirectory(workingDirectory) }
        let sandboxed = options.policy.sandbox.enabled && !Self.isNestedSandbox
        var decision: [String: JSONValue] = [
            "command": .string(command), "workingDirectory": .string(workingDirectory),
            "sandbox": .bool(sandboxed), "network": .bool(options.policy.sandbox.allowNetwork),
            "nested": .bool(options.policy.sandbox.enabled && Self.isNestedSandbox),
        ]
        if case .denied(let reason) = options.policy.check(command) {
            decision["verdict"] = "denied"
            decision["reason"] = .string(reason)
            audit?.record(.policyDecision, details: decision)
            Diagnostics.policy.info("denied: \(reason): \(command)")
            throw Failure.denied(reason)
        }
        do {
            try await approval?.clear(command: command, workingDirectory: workingDirectory)
        } catch let failure as Failure {
            if case .disapproved(let reason) = failure {
                decision["verdict"] = "disapproved"
                decision["reason"] = .string(reason)
                audit?.record(.policyDecision, details: decision)
            }
            throw failure
        }
        decision["verdict"] = "allowed"
        audit?.record(.policyDecision, details: decision)

        let started = Date()
        let outcome = try await launch(command, in: workingDirectory, sandboxed: sandboxed)
        audit?.record(
            .commandOutcome,
            details: [
                "command": .string(command), "exitStatus": .int(Int(outcome.exitStatus)),
                "timedOut": .bool(outcome.timedOut),
                "truncated": .bool(outcome.truncated), "stdout": .string(outcome.stdout),
                "stderr": .string(outcome.stderr),
                "seconds": .double(Date().timeIntervalSince(started)),
            ])
        Diagnostics.policy.debug("exit \(outcome.exitStatus) after \(Date().timeIntervalSince(started))s: \(command)")
        return outcome
    }

    /// Spawns `/bin/sh -c command` in its own process group, under `sandbox-exec` when `sandboxed`,
    /// and captures its outcome. Exactly one launch per call.
    private func launch(_ command: String, in workingDirectory: String, sandboxed: Bool) async throws -> Outcome {
        var argv = ["/bin/sh", "-c", command]
        if sandboxed {
            let profile = options.policy.seatbeltProfile(
                writableRoot: options.writableRoot,
                temporaryDirectory: FileManager.default.temporaryDirectory.path,
                home: FileManager.default.homeDirectoryForCurrentUser.path
            )
            argv = ["/usr/bin/sandbox-exec", "-p", profile] + argv
        }
        let stdoutBuffer = OutputBuffer()
        let stderrBuffer = OutputBuffer()
        let pid = try Spawn.spawn(argv, workingDirectory: workingDirectory, stdout: stdoutBuffer, stderr: stderrBuffer)

        let timedOut = Mutex(false)
        let timeout = options.timeout
        let watchdog = Task {
            guard (try? await Task.sleep(for: timeout)) != nil else { return }
            timedOut.withLock { $0 = true }
            kill(-pid, SIGTERM)
            guard (try? await Task.sleep(for: .seconds(2))) != nil else { return }
            kill(-pid, SIGKILL)
        }
        let status = await Spawn.wait(for: pid)
        watchdog.cancel()
        // The group is dead, so writers close and EOF arrives; a descendant that escaped the group
        // could hold the pipe, so the drain is bounded rather than blocking.
        await stdoutBuffer.drain(deadline: .seconds(1))
        await stderrBuffer.drain(deadline: .seconds(1))

        let out = Self.tail(stdoutBuffer.contents, maxBytes: options.maxOutputBytes)
        let err = Self.tail(stderrBuffer.contents, maxBytes: options.maxOutputBytes)
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
final class OutputBuffer: Sendable {
    private let storage = Mutex(Data())
    private let finished = Mutex(false)
    /// The pipe's read end; owned here so its readability handler stays installed.
    private let handle = Mutex<FileHandle?>(nil)

    /// A snapshot of everything captured so far.
    var contents: Data { storage.withLock { $0 } }

    /// Whether the writer has closed the pipe.
    var isFinished: Bool { finished.withLock { $0 } }

    /// Appends bytes; safe to call from the pipe's handler queue and the caller concurrently.
    func append(_ data: Data) {
        storage.withLock { $0.append(data) }
    }

    /// Takes ownership of a pipe's read end and appends every chunk until end of file.
    func capture(_ handle: FileHandle) {
        self.handle.withLock { $0 = handle }
        handle.readabilityHandler = { [self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                finished.withLock { $0 = true }
                try? handle.close()
            } else {
                append(chunk)
            }
        }
    }

    /// Waits for end of file, but no longer than `deadline`.
    func drain(deadline: Duration) async {
        let stop = ContinuousClock.now + deadline
        while !isFinished, ContinuousClock.now < stop {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// Minimal `posix_spawn` wrapper: new process group, working directory, stdin from `/dev/null`,
/// stdout and stderr into `OutputBuffer`s.
enum Spawn {
    /// Spawns `argv[0]` with `argv`, returning the child's pid, which is also its process group id.
    ///
    /// - Throws: `CommandRunner.Failure.launchFailed`.
    static func spawn(
        _ argv: [String], workingDirectory: String, stdout: OutputBuffer, stderr: OutputBuffer
    ) throws
        -> pid_t
    {
        var outPipe: [Int32] = [-1, -1]
        var errPipe: [Int32] = [-1, -1]
        guard pipe(&outPipe) == 0, pipe(&errPipe) == 0 else {
            throw CommandRunner.Failure.launchFailed("pipe: \(String(cString: strerror(errno)))")
        }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        for descriptor in [outPipe[0], outPipe[1], errPipe[0], errPipe[1]] {
            posix_spawn_file_actions_addclose(&actions, descriptor)
        }
        posix_spawn_file_actions_addchdir(&actions, workingDirectory)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)

        var cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cArgs.append(nil)
        defer { cArgs.forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, argv[0], &actions, &attributes, cArgs, environ)
        close(outPipe[1])
        close(errPipe[1])
        guard result == 0 else {
            close(outPipe[0])
            close(errPipe[0])
            throw CommandRunner.Failure.launchFailed("\(argv[0]): \(String(cString: strerror(result)))")
        }
        stdout.capture(FileHandle(fileDescriptor: outPipe[0], closeOnDealloc: true))
        stderr.capture(FileHandle(fileDescriptor: errPipe[0], closeOnDealloc: true))
        return pid
    }

    /// Waits for `pid` off the cooperative pool and returns its status: the exit code, or the signal negated.
    static func wait(for pid: pid_t) async -> Int32 {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var status: Int32 = 0
                while waitpid(pid, &status, 0) < 0, errno == EINTR {}
                let signal = status & 0x7f
                continuation.resume(returning: signal == 0 ? (status >> 8) & 0xff : -signal)
            }
        }
    }
}
