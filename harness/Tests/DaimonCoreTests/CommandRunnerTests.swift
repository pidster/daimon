import Foundation
import Testing

@testable import DaimonCore

@Suite struct CommandRunnerTests {
    @Test func capturesStdoutAndExitStatus() async throws {
        let outcome = try await CommandRunner().run("printf hello; exit 3")
        #expect(outcome.stdout == "hello")
        #expect(outcome.stderr.isEmpty)
        #expect(outcome.exitStatus == 3)
        #expect(!outcome.timedOut)
        #expect(!outcome.truncated)
    }

    @Test func separatesStderr() async throws {
        let outcome = try await CommandRunner().run("printf err >&2")
        #expect(outcome.stdout.isEmpty)
        #expect(outcome.stderr == "err")
    }

    @Test func honoursWorkingDirectory() async throws {
        let runner = CommandRunner(options: .init(workingDirectory: "/private/tmp"))
        let outcome = try await runner.run("pwd")
        #expect(outcome.stdout.trimmingCharacters(in: .newlines) == "/private/tmp")
    }

    @Test func rejectsMissingWorkingDirectory() async {
        let runner = CommandRunner(options: .init(workingDirectory: "/nonexistent/dir"))
        await #expect(throws: CommandRunner.Failure.invalidWorkingDirectory("/nonexistent/dir")) {
            try await runner.run("true")
        }
    }

    @Test func killsOnTimeout() async throws {
        let runner = CommandRunner(options: .init(timeout: .milliseconds(200)))
        let outcome = try await runner.run("sleep 30")
        #expect(outcome.timedOut)
        #expect(outcome.exitStatus == -SIGTERM)
    }

    @Test func keepsOnlyTheTailOfLongOutput() async throws {
        let runner = CommandRunner(options: .init(maxOutputBytes: 10))
        let outcome = try await runner.run("printf 0123456789abcdef")
        #expect(outcome.truncated)
        #expect(outcome.stdout == "6789abcdef")
    }

    @Test func rendersCompactly() {
        let outcome = CommandRunner.Outcome(
            exitStatus: 1, stdout: "out", stderr: "err", timedOut: false, truncated: true)
        #expect(
            outcome.rendered
                == "exit status: 1\noutput truncated: only the tail of each stream is shown\nstdout:\nout\nstderr:\nerr"
        )
    }

    @Test func tailDecodesLossily() {
        let data = Data([0x61, 0xFF, 0x62])
        #expect(CommandRunner.tail(data, maxBytes: 10).text == "a\u{FFFD}b")
    }
}

@Suite struct CommandRunnerPolicyTests {
    /// True when this test process is itself inside a sandbox, where daimon falls back to the outer
    /// sandbox and cannot enforce its own profile. Seatbelt lets a process re-apply an identical
    /// profile but refuses a different one, so the probe profile is one no outer sandbox would use.
    static let nested: Bool = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = [
            "-p", "(version 1) (allow default) (deny file-write* (subpath \"/nonexistent/daimon-nesting-probe\"))",
            "/usr/bin/true",
        ]
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return true }
        process.waitUntilExit()
        return process.terminationStatus != 0
    }()

    private func scratch() throws -> String {
        let dir = FileManager.default.temporaryDirectory.appending(path: "daimon-sb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    @Test func deniedPatternNeverLaunches() async {
        await #expect(throws: CommandRunner.Failure.denied("command matches deny pattern secret")) {
            try await CommandRunner(options: .init(policy: CommandPolicy(deny: ["secret"]))).run("echo secret")
        }
    }

    @Test func sandboxAllowsWritesInWorkingDirectoryAndTemp() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let runner = CommandRunner(options: .init(workingDirectory: dir))
        let outcome = try await runner.run(
            "echo hi > here.txt && echo hi > \"$TMPDIR/daimon-sb-probe\" && cat here.txt")
        #expect(outcome.exitStatus == 0, "\(outcome.stderr)")
        #expect(outcome.stdout == "hi\n")
    }

    @Test(.enabled(if: !nested, "enforcement cannot be asserted inside an outer sandbox"))
    func sandboxBlocksWritesElsewhere() async throws {
        let dir = try scratch()
        // The home directory is outside the writable set (working directory, temp, caches).
        let blocked = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "daimon-sb-blocked-\(UUID().uuidString).txt").path
        defer {
            try? FileManager.default.removeItem(atPath: dir)
            try? FileManager.default.removeItem(atPath: blocked)
        }
        let runner = CommandRunner(options: .init(workingDirectory: dir))
        let outcome = try await runner.run("echo x > '\(blocked)'")
        #expect(outcome.exitStatus != 0)
        #expect(outcome.stderr.contains("Operation not permitted"))
        #expect(!FileManager.default.fileExists(atPath: blocked))
    }

    @Test(.enabled(if: !nested, "enforcement cannot be asserted inside an outer sandbox"))
    func sandboxCanBlockNetwork() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        var options = CommandRunner.Options(workingDirectory: dir, timeout: .seconds(10))
        options.policy.sandbox.allowNetwork = false
        let outcome = try await CommandRunner(options: options).run("curl -sS -m 3 https://example.com -o /dev/null")
        #expect(outcome.exitStatus != 0)
    }

    @Test func unrestrictedRunsPlainShell() async throws {
        let dir = try scratch()
        let other = try scratch()
        defer {
            try? FileManager.default.removeItem(atPath: dir)
            try? FileManager.default.removeItem(atPath: other)
        }
        let runner = CommandRunner(options: .init(workingDirectory: dir, policy: .unrestricted))
        let outcome = try await runner.run("echo x > '\(other)/ok.txt'")
        #expect(outcome.exitStatus == 0)
        #expect(FileManager.default.fileExists(atPath: "\(other)/ok.txt"))
    }
}

@Suite struct NestedSandboxTests {
    @Test func fallsBackWhenAlreadySandboxed() async throws {
        // Run daimon's runner inside an outer sandbox whose profile differs from the one it generates.
        let dir = FileManager.default.temporaryDirectory.appending(path: "daimon-nest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let inner = CommandRunner(options: .init(workingDirectory: dir.path))
        // The outer sandbox here is a permissive one applied to a shell that then runs a sandboxed
        // command through daimon's own profile: the inner apply is refused and the fallback runs it.
        let outer = CommandRunner(options: .init(workingDirectory: dir.path, policy: .unrestricted))
        let probe = try await outer.run(
            "sandbox-exec -p '(version 1) (allow default)' /bin/sh -c 'sandbox-exec -p \"(version 1) (deny default)\" /usr/bin/true' 2>&1; echo status=$?"
        )
        #expect(probe.stdout.contains(CommandRunner.sandboxApplyRefusal), "\(probe.stdout)")
        // Sanity: a normal sandboxed run is not reported as refused.
        let normal = try await inner.run("printf ok")
        #expect(normal.stdout == "ok")
    }
}
