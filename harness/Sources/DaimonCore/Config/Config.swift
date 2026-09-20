import Foundation

/// User configuration read from `Home.configFile`.
///
/// Every field is optional in the file; `resolved` fills in defaults. Unknown
/// keys are ignored so older binaries tolerate newer files.
public struct Config: Codable, Equatable, Sendable {
    /// Text added to daimon's system prompt for every session on this Mac (layer 2 of `Prompting`).
    public var systemPromptExtension: String?
    /// The pre-0.2 name of `systemPromptExtension`; read when the new key is absent, never written.
    public var instructions: String?
    /// Which model sessions run on; nil means `system`.
    public var model: ModelSelection?
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
    /// Where a local Ollama serves `ollama:<name>` models.
    public var ollama: OllamaConfig?

    /// Ollama settings in the file.
    public struct OllamaConfig: Codable, Equatable, Sendable {
        /// The server's base URL; default `http://127.0.0.1:11434`.
        public var baseURL: String?
        /// Seconds allowed for one generation request; default 120.
        public var timeoutSeconds: Int?

        /// Creates settings; nil fields take defaults.
        public init(baseURL: String? = nil, timeoutSeconds: Int? = nil) {
            self.baseURL = baseURL
            self.timeoutSeconds = timeoutSeconds
        }
    }

    /// Approval settings in the file.
    public struct ApprovalConfig: Codable, Equatable, Sendable {
        /// Ask at this level and above: `safe`, `moderate`, `dangerous`, or `never`.
        public var threshold: ApprovalThreshold?
        /// Whether the on-device model classifies alongside the rules.
        public var useModel: Bool?
        /// Seconds to wait for an approval answer before treating silence as a denial; 0 waits forever.
        public var timeoutSeconds: Int?
        /// Days a persisted (project or always) approval lasts.
        public var persistDays: Int?

        /// Creates settings; nil fields take defaults.
        public init(
            threshold: ApprovalThreshold? = nil, useModel: Bool? = nil, timeoutSeconds: Int? = nil,
            persistDays: Int? = nil
        ) {
            self.threshold = threshold
            self.useModel = useModel
            self.timeoutSeconds = timeoutSeconds
            self.persistDays = persistDays
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

    /// Creates a config; nil fields take defaults at resolution.
    public init(
        systemPromptExtension: String? = nil, instructions: String? = nil, model: ModelSelection? = nil,
        commandTimeoutSeconds: Int? = nil,
        commandMaxOutputBytes: Int? = nil, maxThreads: Int? = nil, commandPolicy: CommandPolicy? = nil,
        audit: AuditConfig? = nil, approval: ApprovalConfig? = nil, ollama: OllamaConfig? = nil
    ) {
        self.systemPromptExtension = systemPromptExtension
        self.instructions = instructions
        self.model = model
        self.commandTimeoutSeconds = commandTimeoutSeconds
        self.commandMaxOutputBytes = commandMaxOutputBytes
        self.maxThreads = maxThreads
        self.commandPolicy = commandPolicy
        self.audit = audit
        self.approval = approval
        self.ollama = ollama
    }

    /// Reads the file at `url`, or returns an empty config if it does not exist.
    ///
    /// - Throws: `DecodingError` for malformed JSON or an unknown `approval.threshold`,
    ///   `CommandPolicy.Failure` for a bad pattern, or file-system errors other than "missing".
    public static func load(from url: URL) throws -> Config {
        guard FileManager.default.fileExists(atPath: url.path) else { return Config() }
        let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
        try config.commandPolicy?.validate()
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
            systemPromptExtension: systemPromptExtension ?? instructions,
            model: model ?? .default,
            runner: CommandRunner.Options(
                timeout: .seconds(commandTimeoutSeconds ?? 60),
                maxOutputBytes: commandMaxOutputBytes ?? 4096,
                policy: commandPolicy ?? .default
            ),
            maxThreads: maxThreads ?? 32,
            auditEnabled: audit?.enabled ?? true,
            auditLimits: FileAuditSink.Limits(
                maxFileBytes: audit?.maxFileBytes ?? 10 * 1024 * 1024, keepFiles: audit?.keepFiles ?? 5),
            approvalThreshold: approval?.threshold ?? .default,
            approvalUsesModel: approval?.useModel ?? true,
            approvalTimeout: (approval?.timeoutSeconds ?? 600) == 0 ? nil : .seconds(approval?.timeoutSeconds ?? 600),
            approvalLifetime: .seconds((approval?.persistDays ?? 30) * 24 * 3600),
            ollama: OllamaSettings(
                baseURL: ollama?.baseURL.flatMap(URL.init(string:)) ?? OllamaSettings.default.baseURL,
                timeout: .seconds(ollama?.timeoutSeconds ?? 120))
        )
    }

    /// Configuration with every default filled in.
    public struct Resolved: Equatable, Sendable {
        /// The operator's addition to daimon's system prompt, if any.
        public var systemPromptExtension: String?
        /// Which model sessions run on.
        public var model: ModelSelection
        /// Limits for `run_command`.
        public var runner: CommandRunner.Options
        /// Live MCP threads kept before eviction.
        public var maxThreads: Int
        /// Whether the audit log is written.
        public var auditEnabled: Bool
        /// Rotation limits for the audit file.
        public var auditLimits: FileAuditSink.Limits
        /// From which level a human is asked.
        public var approvalThreshold: ApprovalThreshold
        /// Whether the on-device model classifies alongside the rules.
        public var approvalUsesModel: Bool
        /// How long an approval request may go unanswered before it counts as a denial; nil waits forever.
        public var approvalTimeout: Duration?
        /// How long a persisted approval lasts.
        public var approvalLifetime: Duration
        /// Where Ollama is for `ollama:<name>` models.
        public var ollama: OllamaSettings
    }
}
