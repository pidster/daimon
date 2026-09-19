import Foundation
import Testing

@testable import DaimonCore

@Suite struct ToolWrapperTests {
    @Test func runCommandRendersOutcomeAndHonoursWorkingDirectory() async throws {
        let tool = RunCommandTool(runner: CommandRunner(options: .init(policy: .unrestricted)))
        let plain = await tool.call(
            arguments: .init(command: "printf hi; printf err >&2; exit 2", workingDirectory: nil))
        #expect(plain == "exit status: 2\nstdout:\nhi\nstderr:\nerr")
        let elsewhere = await tool.call(arguments: .init(command: "pwd", workingDirectory: "/private/tmp"))
        #expect(elsewhere == "exit status: 0\nstdout:\n/private/tmp\n")
        let missing = await tool.call(arguments: .init(command: "true", workingDirectory: "/nonexistent/dir"))
        #expect(missing == "error: working directory does not exist: /nonexistent/dir")
        let denied = RunCommandTool(runner: CommandRunner(options: .init(policy: CommandPolicy(deny: ["nope"]))))
        #expect(
            await denied.call(arguments: .init(command: "echo nope", workingDirectory: nil)).hasPrefix(
                "error: command denied by policy"))
    }

    @Test func readFileDefaultsAndErrorsRenderForTheModel() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "daimon-wrap-\(UUID().uuidString).txt")
        try Data((1...150).map(String.init).joined(separator: "\n").utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let tool = ReadFileTool()
        let page = await tool.call(arguments: .init(path: url.path, offset: nil, limit: nil))
        #expect(page.hasPrefix("1\t1\n"))
        #expect(page.contains("100\t100\n[more: call again with offset 101]"))
        let tail = await tool.call(arguments: .init(path: url.path, offset: 149, limit: 5))
        #expect(tail == "149\t149\n150\t150\n[end of file]")
        #expect(
            await tool.call(arguments: .init(path: "/nonexistent/x", offset: nil, limit: nil))
                == "error: file not found: /nonexistent/x")
    }
}
