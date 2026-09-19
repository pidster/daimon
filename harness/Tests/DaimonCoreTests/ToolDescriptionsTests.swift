import Testing

@testable import DaimonCore

@Suite struct ToolDescriptionsTests {
    @Test func everyRegisteredToolIsDescribed() {
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

    @Test func limitsComeFromTheLiveOptions() {
        let registry = ToolRegistry(
            runner: .init(timeout: .seconds(5), maxOutputBytes: 999), reader: FileReader(maxBytes: 777))
        let limits = Dictionary(uniqueKeysWithValues: registry.descriptions.map { ($0.name, $0.limits) })
        #expect(limits["run_command"]?.contains("Timeout 5 s") == true)
        #expect(limits["run_command"]?.contains("999 bytes") == true)
        #expect(limits["read_file"]?.contains("777 bytes") == true)
        var unsandboxed = CommandRunner.Options()
        unsandboxed.policy.sandbox.enabled = false
        #expect(
            ToolRegistry(runner: unsandboxed).descriptions.first { $0.name == "run_command" }?.limits.contains(
                "no sandbox") == true)
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
