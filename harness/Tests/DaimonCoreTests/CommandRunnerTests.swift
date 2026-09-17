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

    @Test func sandboxBlocksWritesElsewhere() async throws {
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

    @Test func sandboxCanBlockNetwork() async throws {
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
