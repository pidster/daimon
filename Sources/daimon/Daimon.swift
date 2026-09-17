import ArgumentParser
import DaimonCore
import Foundation
import FoundationModels

@main
struct Daimon: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daimon",
        abstract: "An on-device, tool-using AI microharness over Apple's Foundation Models.",
        subcommands: [Respond.self, Tools.self],
        defaultSubcommand: Respond.self
    )
}

struct Respond: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Generate a response to a prompt, calling tools as needed.")

    @Argument(help: "Prompt for the model. Read from stdin when omitted.")
    var prompt: String?

    @Option(name: [.short, .customLong("instructions")], help: "Instructions for the model to follow.")
    var instructions: String = "You are daimon, a concise assistant. Use the available tools when they help answer accurately."

    @Option(name: .customLong("tool"), help: "Tool to enable (repeatable). All tools are enabled when omitted.")
    var toolNames: [String] = []

    @Flag(inversion: .prefixedNo, help: "Stream the output as it is generated.")
    var stream = true

    mutating func run() async throws {
        let text = try prompt ?? Self.readStdin()
        let tools: [any Tool]
        if toolNames.isEmpty {
            tools = ToolRegistry.all
        } else {
            let selection = ToolRegistry.select(toolNames)
            guard selection.unknown.isEmpty else {
                throw ValidationError("Unknown tool(s): \(selection.unknown.joined(separator: ", "))")
            }
            tools = selection.tools
        }
        let agent = try Agent(instructions: instructions, tools: tools)
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
        for tool in ToolRegistry.all {
            print("\(tool.name)\t\(tool.description)")
        }
    }
}
