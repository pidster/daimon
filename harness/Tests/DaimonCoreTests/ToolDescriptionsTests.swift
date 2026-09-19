import Testing

@testable import DaimonCore

@Suite struct ToolDescriptionsTests {
    @Test func everyRegisteredToolIsDescribedWithGuidance() {
        let registry = ToolRegistry()
        let descriptions = registry.descriptions
        #expect(descriptions.map(\.name) == registry.all.map(\.name))
        for tool in descriptions {
            #expect(!tool.description.isEmpty, "\(tool.name)")
            #expect(!tool.limits.isEmpty, "\(tool.name) has no limits text")
            #expect(tool.examplePrompt.contains(tool.name), "\(tool.name) example does not name the tool")
            guard case .object(let schema) = tool.parameters else { Issue.record("\(tool.name) schema"); return }
            #expect(schema["type"] == "object")
            #expect(schema["properties"] != nil)
        }
    }

    @Test func readFileSchemaCarriesGuideText() {
        let readFile = ToolRegistry().descriptions.first { $0.name == "read_file" }
        guard case .object(let schema)? = readFile?.parameters, case .object(let properties)? = schema["properties"],
            case .object(let path)? = properties["path"]
        else { Issue.record("schema shape"); return }
        #expect(path["type"] == "string")
        #expect(path["description"]?.stringValue?.contains("Path") == true)
        #expect(schema["required"] == .array(["path"]))
    }

    @Test func rendersJSONAndMarkdown() {
        let registry = ToolRegistry()
        #expect(registry.descriptionsJSON.contains("\"name\" : \"run_command\""))
        let markdown = registry.descriptionsMarkdown
        #expect(markdown.hasPrefix("# daimon tools"))
        for tool in registry.all {
            #expect(markdown.contains("## \(tool.name)"))
        }
        #expect(markdown.contains("- `path` (string, required)"))
        #expect(markdown.contains("Example prompt: Use read_file"))
    }
}
