import ArgumentParser
import DaimonCore
import DaimonMCP
import Foundation
import FoundationModels

@main
struct Daimon: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daimon",
        abstract: "An on-device, tool-using AI microharness over Apple's Foundation Models.",
        subcommands: [Respond.self, Tools.self, Mcp.self],
        defaultSubcommand: Respond.self
    )
}

struct Respond: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Generate a response to a prompt, calling tools as needed.")

    @Argument(help: "Prompt for the model. Read from stdin when omitted.")
    var prompt: String?

    @Option(
        name: [.short, .customLong("instructions")],
        help: "Instructions for the model to follow. Defaults to config.json's instructions.")
    var instructions: String?

    @Option(name: .customLong("tool"), help: "Tool to enable (repeatable). All tools are enabled when omitted.")
    var toolNames: [String] = []

    @Flag(inversion: .prefixedNo, help: "Stream the output as it is generated.")
    var stream = true

    mutating func run() async throws {
        let text = try prompt ?? Self.readStdin()
        let config = try Daimon.loadConfig()
        let tools = try Daimon.selectTools(toolNames, from: ToolRegistry(runner: config.runner))
        let agent = try Agent(instructions: instructions ?? config.instructions, tools: tools)
        if stream {
            try await agent.stream(text) { delta in
                print(delta, terminator: "")
                fflush(stdout)
            }
            print()
        } else {
            print(try await agent.respond(to: text))
        }
    }

    private static func readStdin() throws -> String {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ValidationError("No prompt given and stdin is empty.") }
        return text
    }
}

struct Tools: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List the tools available to the model.")

    func run() throws {
        for tool in ToolRegistry().all {
            print("\(tool.name)\t\(tool.description)")
        }
    }
}

extension Daimon {
    /// The user's home directory for daimon state, honouring `DAIMON_HOME`.
    static let home = Home.resolve()

    /// Reads `config.json` from the home directory, tolerating its absence.
    static func loadConfig() throws -> Config.Resolved {
        do {
            return try Config.load(from: home.configFile).resolved
        } catch let error as DecodingError {
            throw ValidationError("Malformed \(home.configFile.path): \(error)")
        }
    }

    /// Resolves `--tool` names against the registry, or all tools when none are given.
    static func selectTools(_ names: [String], from registry: ToolRegistry) throws -> [any Tool] {
        guard !names.isEmpty else { return registry.all }
        let selection = registry.select(names)
        guard selection.unknown.isEmpty else {
            throw ValidationError("Unknown tool(s): \(selection.unknown.joined(separator: ", "))")
        }
        return selection.tools
    }
}

struct Mcp: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Serve daimon's tools to an MCP client over stdio.",
        discussion: "Exposes 'respond' (run a task on the on-device model) and 'run_command'. "
            + "Stdout carries the protocol; diagnostics go to stderr.")

    @Option(
        name: [.short, .customLong("instructions")],
        help: "Default instructions for 'respond' sessions. Defaults to config.json's instructions.")
    var instructions: String?

    func run() async throws {
        var config = try Daimon.loadConfig()
        if let instructions { config.instructions = instructions }
        try await DaimonServer(config: config).run()
    }
}
