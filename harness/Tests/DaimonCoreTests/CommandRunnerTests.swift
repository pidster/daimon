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
