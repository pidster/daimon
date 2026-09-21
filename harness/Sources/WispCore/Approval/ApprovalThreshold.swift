/// From which risk level a human is asked before a command runs.
///
/// Decoded once from `approval.threshold` in `config.json`, where it is a level name or `never`.
public enum ApprovalThreshold: Sendable, Equatable, Codable {
    /// Ask at this level and above.
    case level(RiskLevel)
    /// Never ask; verdicts are still audited.
    case never

    /// The default: ask at `moderate` and above.
    public static let `default` = ApprovalThreshold.level(.moderate)

    /// Whether a command assessed at `level` needs approval.
    public func requiresApproval(at level: RiskLevel) -> Bool {
        switch self {
        case .level(let minimum): level >= minimum
        case .never: false
        }
    }

    /// The name used in `config.json`.
    public var rawValue: String {
        switch self {
        case .level(let level): level.rawValue
        case .never: "never"
        }
    }

    /// Parses a config value; nil for anything but a level name or `never`.
    public init?(rawValue: String) {
        if rawValue == "never" {
            self = .never
        } else if let level = RiskLevel(rawValue: rawValue) {
            self = .level(level)
        } else {
            return nil
        }
    }

    /// Decodes from the config string, with a message that lists the accepted values.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let threshold = ApprovalThreshold(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "invalid approval.threshold '\(raw)': use safe, moderate, dangerous, or never")
        }
        self = threshold
    }

    /// Encodes as the config string.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
