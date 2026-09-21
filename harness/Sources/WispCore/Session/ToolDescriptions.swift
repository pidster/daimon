import Foundation
import FoundationModels

/// A client-facing description of one of the model's tools: what it does, its
/// argument schema as the model sees it, its limits, and how to ask for it.
public struct ToolDescription: Codable, Equatable, Sendable {
    /// The tool's name, as the model calls it.
    public var name: String
    /// The description the model is given.
    public var description: String
    /// JSON Schema for the arguments, generated from the tool's `@Generable` type.
    public var parameters: JSONValue
    /// Limits that bound its output or effect.
    public var limits: String
    /// A `respond` prompt that reliably makes the model use it.
    public var examplePrompt: String
    /// What the eval harness measured for tasks on this tool; empty when nothing has been measured.
    public var measurements: [Measurement] = []
}

extension ToolRegistry {
    /// Descriptions of every registered tool, in registration order, with the embedded measurements.
    public var descriptions: [ToolDescription] { descriptions(measurements: Measurements.embedded) }

    /// Descriptions with the given measurements attached by tool name.
    public func descriptions(measurements: [Measurement]) -> [ToolDescription] {
        all.map { tool in
            ToolDescription(
                name: tool.name, description: tool.description, parameters: Self.schema(of: tool), limits: tool.limits,
                examplePrompt: tool.examplePrompt, measurements: Measurements.forTool(tool.name, in: measurements))
        }
    }

    /// The descriptions as pretty JSON.
    public var descriptionsJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(descriptions) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    /// The descriptions as Markdown, with the prompting rules a client needs and the embedded measurements.
    public var descriptionsMarkdown: String { descriptionsMarkdown(measurements: Measurements.embedded) }

    /// The Markdown catalogue with the given measurements attached.
    public func descriptionsMarkdown(measurements: [Measurement]) -> String {
        var lines = [
            "# wisp tools",
            "",
            "These tools belong to the on-device model, not to the MCP client. To use one, ask `respond` for it:",
            "name the tool, give it exact arguments, and say how to report the result. The model is small; one",
            "tool per prompt and verbatim reporting work best. Restrict `tools` on a new thread to the ones the",
            "task needs.",
            "",
        ]
        for tool in descriptions(measurements: measurements) {
            lines += ["## \(tool.name)", "", tool.description, "", "Arguments:", ""]
            if case .object(let schema) = tool.parameters, case .object(let properties)? = schema["properties"] {
                var required: [String] = []
                if case .array(let names)? = schema["required"] { required = names.compactMap(\.stringValue) }
                for name in properties.keys.sorted() {
                    guard case .object(let property)? = properties[name] else { continue }
                    let type = property["type"]?.stringValue ?? "any"
                    let flag = required.contains(name) ? "required" : "optional"
                    lines.append("- `\(name)` (\(type), \(flag)): \(property["description"]?.stringValue ?? "")")
                }
            }
            lines += ["", "Limits: \(tool.limits)", "", "Example prompt: \(tool.examplePrompt)", ""]
            for measured in tool.measurements {
                lines.append(
                    "Measured: \(measured.task) \(measured.summary) on \(measured.model), \(measured.date): \(measured.notes)"
                )
            }
            if !tool.measurements.isEmpty { lines.append("") }
        }
        return lines.joined(separator: "\n")
    }

    /// The tool's argument schema, decoded from the framework's JSON Schema encoding.
    private static func schema(of tool: any Tool) -> JSONValue {
        guard let data = try? JSONEncoder().encode(tool.parameters),
            let value = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return .object([:]) }
        return value
    }
}
