/// A JSON value, used for the free-form `details` of an audit event.
public enum JSONValue: Codable, Equatable, Sendable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByFloatLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral,
    ExpressibleByNilLiteral
{
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Creates a string value.
    public init(stringLiteral value: String) { self = .string(value) }
    /// Creates an integer value.
    public init(integerLiteral value: Int) { self = .int(value) }
    /// Creates a boolean value.
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    /// Creates a double value.
    public init(floatLiteral value: Double) { self = .double(value) }
    /// Creates an array value.
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    /// Creates an object value.
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    /// Creates a null value.
    public init(nilLiteral: ()) { self = .null }

    /// The string, if this is one.
    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// The integer, if this is one.
    public var intValue: Int? {
        if case .int(let i) = self { return i }
        return nil
    }

    /// The boolean, if this is one.
    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    /// Decodes from any JSON shape.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else if let double = try? container.decode(Double.self) {
            self = .double(double)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    /// Encodes as the corresponding JSON shape.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
