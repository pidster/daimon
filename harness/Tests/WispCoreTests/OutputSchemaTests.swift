import Foundation
import FoundationModels
import Testing
import WispTestSupport

@testable import WispCore

@Suite struct OutputSchemaTests {
    /// A schema in the accepted subset, with every construct once.
    static let json: JSONValue = [
        "type": "object", "description": "A verdict",
        "properties": [
            "verdict": ["type": "string", "enum": ["pass", "fail"], "description": "The call"],
            "score": ["type": "number"],
            "count": ["type": "integer"],
            "ok": ["type": "boolean"],
            "notes": ["type": "array", "items": ["type": "string"], "minItems": 0, "maxItems": 3],
            "detail": ["type": "object", "properties": ["reason": ["type": "string"]]],
        ],
        "required": ["verdict", "ok"],
    ]

    @Test func convertsTheSubsetAndKeepsTheSource() throws {
        let schema = try OutputSchema(json: Self.json)
        #expect(schema.source == Self.json)
        let encoded = String(decoding: try JSONEncoder().encode(schema.schema), as: UTF8.self)
        for name in ["verdict", "score", "count", "ok", "notes", "detail", "reason", "pass", "fail", "A verdict"] {
            #expect(encoded.contains(name), "\(name)")
        }
    }

    @Test func refusesWhatTheSubsetDoesNotCoverByPath() {
        func failure(_ json: JSONValue) -> OutputSchema.Failure? {
            do {
                _ = try OutputSchema(json: json)
                return nil
            } catch let failure as OutputSchema.Failure {
                return failure
            } catch {
                return nil
            }
        }
        #expect(failure(["type": "string"]) == .unsupported(path: "/", problem: "the root must be an object schema"))
        #expect(
            failure(["type": "object", "properties": ["a": ["$ref": "#/x"]]])
                == .unsupported(path: "/a/", problem: "'$ref' is not supported"))
        #expect(
            failure(["type": "object", "properties": ["a": ["type": ["string", "null"]]]])
                == .unsupported(path: "/a/", problem: "'type' must be a single type name"))
        #expect(
            failure(["type": "object", "properties": ["a": ["type": "null"]]])
                == .unsupported(path: "/a/", problem: "type 'null' is not supported"))
        #expect(
            failure(["type": "object", "properties": ["a": ["type": "array"]]])
                == .unsupported(path: "/a/", problem: "'items' is required for an array"))
        #expect(
            failure(["type": "object", "properties": ["a": ["type": "array", "items": ["type": "object"]]]])
                == .unsupported(path: "/a/items/", problem: "an object needs at least one property"))
        #expect(
            failure(["type": "object", "properties": ["a": ["type": "string", "enum": [1]]]])
                == .unsupported(path: "/a/", problem: "'enum' must be a non-empty list of strings"))
        #expect(
            failure(["type": "object", "properties": ["a": "string"]])
                == .unsupported(path: "/a/", problem: "expected a schema object"))
        #expect(failure(["type": "object", "properties": [:]])?.description.contains("at least one property") == true)
        #expect(OutputSchema.Failure.invalid("x").description == "schema is invalid: x")
    }

    @Test func agentReturnsJSONThroughGuidedGenerationAndAuditsTheSchema() async throws {
        let schema = try OutputSchema(json: ["type": "object", "properties": ["answer": ["type": "integer"]]])
        let sink = MemoryAuditSink()
        let agent = Agent(
            instructions: "x", tools: [],
            model: ResolvedModel(selection: .system, custom: ScriptedModel(steps: [.say(#"{"answer":42}"#)])),
            audit: AuditLog(session: "s", sink: sink))
        let reply = try await agent.respond(to: "how many?", schema: schema)
        #expect(reply.text.contains("42"))
        let data = Data(reply.text.utf8)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data).objectValue?["answer"] == 42)
        #expect(sink.events.first { $0.kind == .prompt }?.details["schema"] == schema.source)
        // The executor was asked with the schema attached.
        let model = ScriptedModel(steps: [.say(#"{"answer":1}"#)])
        _ = try await Agent(instructions: "x", tools: [], model: ResolvedModel(selection: .system, custom: model))
            .respond(to: "n", schema: schema)
        #expect(model.script.requests.withLock { $0.first?.schema != nil })
        #expect(model.script.requests.withLock { $0.first?.generationOptions.maximumResponseTokens } == 1024)
        // A model that does not declare guided generation is refused before the turn.
        let textOnly = Agent(
            instructions: "x", tools: [],
            model: ResolvedModel(selection: .system, custom: ScriptedModel(steps: [], capabilities: [.toolCalling])))
        await #expect(throws: ModelSelection.Failure.self) { try await textOnly.respond(to: "n", schema: schema) }
        for source in [CapabilitySource.framework, .runtime, .configuration, .undeclared] {
            let resolved = ResolvedModel(
                selection: .system, custom: ScriptedModel(steps: [], capabilities: []), capabilitySource: source)
            #expect(throws: ModelSelection.Failure.self) { try resolved.checkGuidedGeneration() }
        }
    }
}
