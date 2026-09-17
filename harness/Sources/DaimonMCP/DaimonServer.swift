import DaimonCore
import Foundation
import FoundationModels
import MCP

/// Serves daimon's capabilities to MCP clients over stdio.
///
/// Each `respond` call gets a fresh `Agent`, so calls are independent and the
/// server holds no conversation state. Stdout is the protocol channel; nothing
/// else in the process may write to it while the server runs.
public struct DaimonServer: Sendable {
    /// Server name reported during the MCP handshake.
    public static let name = "daimon"
    /// Server version reported during the MCP handshake.
    public static let version = "0.1.0"

    private let defaultInstructions: String
    private let runner: CommandRunner

    /// Creates a server.
    ///
    /// - Parameters:
    ///   - defaultInstructions: Instructions used by `respond` when the caller supplies none.
    ///   - runner: Limits applied to `run_command` and to the model's own `run_command` tool.
    public init(defaultInstructions: String, runner: CommandRunner = CommandRunner()) {
        self.defaultInstructions = defaultInstructions
        self.runner = runner
    }

    /// Starts serving on stdin/stdout and returns when the client disconnects.
    ///
    /// - Throws: Transport errors from the MCP SDK.
    public func run() async throws {
        let server = Server(
            name: Self.name,
            version: Self.version,
            capabilities: .init(tools: .init(listChanged: false))
        )
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: ToolCatalog.all) }
        await server.withMethodHandler(CallTool.self) { params in try await self.call(params) }
        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }

    /// Dispatches one `tools/call`. Argument errors surface as MCP protocol
    /// errors; execution failures come back as tool results with `isError`.
    func call(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        switch params.name {
        case ToolCatalog.respond.name:
            let request = try RespondRequest(arguments: params.arguments)
            return await respond(request)
        case ToolCatalog.runCommand.name:
            let request = try RunCommandRequest(arguments: params.arguments)
            return await runCommand(request)
        default:
            throw MCPError.methodNotFound("Unknown tool: \(params.name)")
        }
    }

    private func respond(_ request: RespondRequest) async -> CallTool.Result {
        let tools: [any FoundationModels.Tool]
        if request.toolNames.isEmpty {
            tools = ToolRegistry.all
        } else {
            let selection = ToolRegistry.select(request.toolNames)
            guard selection.unknown.isEmpty else {
                return failure("Unknown tool(s): \(selection.unknown.joined(separator: ", "))")
            }
            tools = selection.tools
        }
        do {
            let agent = try Agent(instructions: request.instructions ?? defaultInstructions, tools: tools)
            return success(try await agent.respond(to: request.prompt))
        } catch {
            return failure(String(describing: error))
        }
    }

    private func runCommand(_ request: RunCommandRequest) async -> CallTool.Result {
        var runner = runner
        if let directory = request.workingDirectory {
            runner.options.workingDirectory = directory
        }
        do {
            return success(try await runner.run(request.command).rendered)
        } catch {
            return failure(String(describing: error))
        }
    }

    private func success(_ text: String) -> CallTool.Result {
        .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
    }

    private func failure(_ message: String) -> CallTool.Result {
        .init(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
    }
}
