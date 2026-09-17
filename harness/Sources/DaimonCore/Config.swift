import Foundation

/// User configuration read from `Home.configFile`.
///
/// Every field is optional in the file; `resolved` fills in defaults. Unknown
/// keys are ignored so older binaries tolerate newer files.
public struct Config: Codable, Equatable, Sendable {
    /// Default instructions for new sessions.
    public var instructions: String?
    /// Wall-clock limit for `run_command`, in seconds.
    public var commandTimeoutSeconds: Int?
    /// Bytes kept from each of stdout and stderr by `run_command`.
    public var commandMaxOutputBytes: Int?
    /// Live MCP conversation threads kept before eviction.
    public var maxThreads: Int?
    /// What `run_command` may execute and how it is confined.
    public var commandPolicy: CommandPolicy?
    /// Audit log settings.
    public var audit: AuditConfig?
    /// Risk classification and approval for `run_command`.
    public var approval: ApprovalConfig?

    /// Approval settings in the file.
    public struct ApprovalConfig: Codable, Equatable, Sendable {
        /// Ask at this level and above: `safe`, `moderate`, `dangerous`, or `never`.
        public var threshold: String?
        /// Whether the on-device model classifies alongside the rules.
        public var useModel: Bool?

        /// Creates settings; nil fields take defaults.
        public init(threshold: String? = nil, useModel: Bool? = nil) {
            self.threshold = threshold
            self.useModel = useModel
        }
    }

    /// Audit log settings in the file.
    public struct AuditConfig: Codable, Equatable, Sendable {
        /// Whether to write the audit log at all.
        public var enabled: Bool?
        /// Rotate when the file would exceed this size.
        public var maxFileBytes: Int?
        /// Rotated files to keep.
        public var keepFiles: Int?

        /// Creates settings; nil fields take defaults.
        public init(enabled: Bool? = nil, maxFileBytes: Int? = nil, keepFiles: Int? = nil) {
            self.enabled = enabled
            self.maxFileBytes = maxFileBytes
            self.keepFiles = keepFiles
        }
    }

    /// Instructions used when the file sets none.
    public static let defaultInstructions =
        "You are daimon, a concise assistant. Use the available tools when they help answer accurately."

    /// Creates a config; nil fields take defaults at resolution.
    public init(
        instructions: String? = nil, commandTimeoutSeconds: Int? = nil, commandMaxOutputBytes: Int? = nil,
        maxThreads: Int? = nil, commandPolicy: CommandPolicy? = nil, audit: AuditConfig? = nil,
        approval: ApprovalConfig? = nil
    ) {
        self.instructions = instructions
        self.commandTimeoutSeconds = commandTimeoutSeconds
        self.commandMaxOutputBytes = commandMaxOutputBytes
        self.maxThreads = maxThreads
        self.commandPolicy = commandPolicy
        self.audit = audit
        self.approval = approval
    }

    /// Reads the file at `url`, or returns an empty config if it does not exist.
    ///
    /// - Throws: `DecodingError` for malformed JSON, `CommandPolicy.Failure` for a bad pattern,
    ///   or file-system errors other than "missing".
    public static func load(from url: URL) throws -> Config {
        guard FileManager.default.fileExists(atPath: url.path) else { return Config() }
        let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
        try config.commandPolicy?.validate()
        if let threshold = config.approval?.threshold, threshold != "never", RiskLevel(rawValue: threshold) == nil {
            throw Failure.invalidApprovalThreshold(threshold)
        }
        return config
    }

    /// Writes this config as pretty-printed JSON.
    ///
    /// - Throws: File-system errors.
    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// The effective values with defaults applied.
    public var resolved: Resolved {
        Resolved(
            instructions: instructions ?? Self.defaultInstructions,
            runner: CommandRunner.Options(
                timeout: .seconds(commandTimeoutSeconds ?? 60),
                maxOutputBytes: commandMaxOutputBytes ?? 4096,
                policy: commandPolicy ?? .default
            ),
            maxThreads: maxThreads ?? 32,
            auditEnabled: audit?.enabled ?? true,
            auditLimits: FileAuditSink.Limits(
                maxFileBytes: audit?.maxFileBytes ?? 10 * 1024 * 1024, keepFiles: audit?.keepFiles ?? 5),
            approvalThreshold: approval?.threshold == "never"
                ? nil : RiskLevel(rawValue: approval?.threshold ?? "") ?? .moderate,
            approvalUsesModel: approval?.useModel ?? true
        )
    }

    /// Why a config file is unusable beyond JSON syntax.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// `approval.threshold` is not a risk level or `never`.
        case invalidApprovalThreshold(String)

        /// Human-readable explanation.
        public var description: String {
            switch self {
            case .invalidApprovalThreshold(let value):
                "invalid approval.threshold '\(value)': use safe, moderate, dangerous, or never"
            }
        }
    }

    /// Configuration with every default filled in.
    public struct Resolved: Equatable, Sendable {
        /// Instructions for new sessions.
        public var instructions: String
        /// Limits for `run_command`.
        public var runner: CommandRunner.Options
        /// Live MCP threads kept before eviction.
        public var maxThreads: Int
        /// Whether the audit log is written.
        public var auditEnabled: Bool
        /// Rotation limits for the audit file.
        public var auditLimits: FileAuditSink.Limits
        /// Ask for approval at this level and above; nil never asks.
        public var approvalThreshold: RiskLevel?
        /// Whether the on-device model classifies alongside the rules.
        public var approvalUsesModel: Bool

        /// The classifier this configuration calls for.
        public var classifier: any RiskClassifier {
            approvalUsesModel
                ? CompositeRiskClassifier([RuleRiskClassifier(), ModelRiskClassifier()]) : RuleRiskClassifier()
        }
    }
}
