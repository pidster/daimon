import Foundation
import FoundationModels

/// A caller's JSON Schema turned into the framework's guided-generation schema, so a reply can be
/// validated JSON instead of prose ([ADR 0022](../../../../docs/decisions/0022-structured-output.md)).
///
/// The subset accepted is what a small model can fill and the framework can constrain: objects with
/// typed properties (`required` marks the rest optional), strings (with `enum`), integers, numbers,
/// booleans, arrays of one item type (`minItems`, `maxItems`), and nesting of those. `description`
/// is passed through to guide the model. Anything else (`$ref`, `anyOf` of types, `additionalProperties`,
/// patterns, formats) is refused by name, at its path, before generation.
public struct OutputSchema: Sendable {
    /// Why a schema was refused.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// The schema, or a part of it, is not one the subset accepts.
        case unsupported(path: String, problem: String)
        /// The framework could not build the schema (duplicate names and the like).
        case invalid(String)

        /// Human-readable explanation.
        public var description: String {
            switch self {
            case .unsupported(let path, let problem): "schema at \(path): \(problem)"
            case .invalid(let detail): "schema is invalid: \(detail)"
            }
        }
    }

    /// The schema the framework constrains generation with.
    public let schema: GenerationSchema
    /// The caller's schema, verbatim, for the audit.
    public let source: JSONValue

    /// Converts `json`, which must describe an object at the root.
    ///
    /// - Parameter json: A JSON Schema in the accepted subset.
    /// - Throws: `Failure` naming the first unsupported construct and where it is.
    public init(json: JSONValue) throws {
        source = json
        guard json.objectValue?["type"] == "object" else {
            throw Failure.unsupported(path: "/", problem: "the root must be an object schema")
        }
        let root = try Self.dynamic(json, name: "Output", path: "/")
        do {
            schema = try GenerationSchema(root: root, dependencies: [])
        } catch {
            throw Failure.invalid(String(describing: error))
        }
    }

    /// Builds the dynamic schema for one node.
    private static func dynamic(_ node: JSONValue, name: String, path: String) throws -> DynamicGenerationSchema {
        guard let object = node.objectValue else {
            throw Failure.unsupported(path: path, problem: "expected a schema object")
        }
        for key in ["$ref", "anyOf", "oneOf", "allOf", "not", "pattern", "format", "additionalProperties"]
        where object[key] != nil {
            throw Failure.unsupported(path: path, problem: "'\(key)' is not supported")
        }
        let description = object["description"]?.stringValue
        guard let type = object["type"]?.stringValue else {
            throw Failure.unsupported(path: path, problem: "'type' must be a single type name")
        }
        switch type {
        case "string":
            if let choices = object["enum"] {
                guard let names = choices.arrayValue?.compactMap(\.stringValue), !names.isEmpty,
                    names.count == choices.arrayValue?.count
                else { throw Failure.unsupported(path: path, problem: "'enum' must be a non-empty list of strings") }
                return DynamicGenerationSchema(name: name, description: description, anyOf: names)
            }
            return DynamicGenerationSchema(type: String.self)
        case "integer": return DynamicGenerationSchema(type: Int.self)
        case "number": return DynamicGenerationSchema(type: Double.self)
        case "boolean": return DynamicGenerationSchema(type: Bool.self)
        case "array":
            guard let items = object["items"] else {
                throw Failure.unsupported(path: path, problem: "'items' is required for an array")
            }
            return DynamicGenerationSchema(
                arrayOf: try dynamic(items, name: name + "Item", path: path + "items/"),
                minimumElements: object["minItems"]?.intValue, maximumElements: object["maxItems"]?.intValue)
        case "object":
            guard let properties = object["properties"]?.objectValue, !properties.isEmpty else {
                throw Failure.unsupported(path: path, problem: "an object needs at least one property")
            }
            let required = Set(object["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            let members = try properties.keys.sorted().map { key in
                DynamicGenerationSchema.Property(
                    name: key, description: properties[key]?.objectValue?["description"]?.stringValue,
                    schema: try dynamic(properties[key] ?? .null, name: name + key.capitalized, path: path + key + "/"),
                    isOptional: !required.contains(key))
            }
            return DynamicGenerationSchema(name: name, description: description, properties: members)
        default:
            throw Failure.unsupported(path: path, problem: "type '\(type)' is not supported")
        }
    }
}
