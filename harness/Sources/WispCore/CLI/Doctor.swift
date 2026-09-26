import Foundation
import FoundationModels

/// Checks what a fresh install needs to work, for `wisp doctor`.
public struct Doctor: Sendable {
    /// One check's outcome.
    public struct Finding: Equatable, Sendable {
        /// Short name of the check.
        public var name: String
        /// Whether it passed.
        public var ok: Bool
        /// What was found, or what to do about it.
        public var detail: String

        /// Creates a finding.
        public init(name: String, ok: Bool, detail: String) {
            self.name = name
            self.ok = ok
            self.detail = detail
        }
    }

    /// How the doctor asks about models, so tests can answer without the framework.
    public struct Probes: Sendable {
        /// Nil when the system model is available, else the reason it is not.
        public var systemModel: @Sendable () -> String?
        /// Nil when the given model resolves under this configuration and home, else the failure text.
        public var configuredModel: @Sendable (ModelSelection, Config.Resolved, Home) -> String?
        /// For a `coreml` classifier: nil when its model prepares, else the failure text.
        public var coremlClassifier: @Sendable (Config.Resolved, Home) -> String?

        /// Probes that ask the framework.
        public static let live = Probes(
            systemModel: {
                if case .unavailable(let reason) = SystemLanguageModel.default.availability {
                    return ModelSelection.explain(reason)
                }
                return nil
            },
            configuredModel: { model, config, home in
                do {
                    _ = try model.resolve(config: config, home: home)
                    return nil
                } catch {
                    return "\(error)"
                }
            },
            coremlClassifier: { config, home in
                do {
                    _ = try CoreMLRiskClassifier.prepare(Session.coremlModelURL(config: config, home: home))
                    return nil
                } catch {
                    return "\(error)"
                }
            })

        /// Creates probes.
        public init(
            systemModel: @escaping @Sendable () -> String?,
            configuredModel: @escaping @Sendable (ModelSelection, Config.Resolved, Home) -> String?,
            coremlClassifier: @escaping @Sendable (Config.Resolved, Home) -> String? = { _, _ in nil }
        ) {
            self.systemModel = systemModel
            self.configuredModel = configuredModel
            self.coremlClassifier = coremlClassifier
        }
    }

    /// Where wisp keeps its state.
    public var home: Home
    /// The configured model, checked in addition to the system model.
    public var model: ModelSelection
    /// The configuration local backends read their settings from.
    public var resolvedConfig: Config.Resolved
    private let probes: Probes

    /// Creates a doctor for `home` and the configured `model`.
    public init(
        home: Home, model: ModelSelection = .default, config: Config.Resolved = Config().resolved,
        probes: Probes = .live
    ) {
        self.home = home
        self.model = model
        resolvedConfig = config
        self.probes = probes
    }

    /// Runs every check. Never throws: problems are findings.
    public func run() -> [Finding] {
        var findings = [macOSVersion(), modelAvailability(), sandboxExec(), config(), homeWritable()]
        if model != .system { findings.insert(configuredModel(), at: 2) }
        if resolvedConfig.approvalClassifier == .coreml { findings.insert(classifier(), at: 2) }
        return findings
    }

    private func classifier() -> Finding {
        if let problem = probes.coremlClassifier(resolvedConfig, home) {
            return Finding(name: "classifier", ok: false, detail: problem)
        }
        return Finding(
            name: "classifier", ok: true,
            detail:
                "coreml model \(resolvedConfig.coremlModel ?? ClassifierStore.reference(ClassifierStore.defaultVersion()) + " (shipped)") prepares"
        )
    }

    private func configuredModel() -> Finding {
        if let problem = probes.configuredModel(model, resolvedConfig, home) {
            return Finding(name: "configured model", ok: false, detail: problem)
        }
        return Finding(name: "configured model", ok: true, detail: "\(model) available")
    }

    /// True when every finding passed.
    public static func allPassed(_ findings: [Finding]) -> Bool {
        findings.allSatisfy(\.ok)
    }

    /// Renders findings one per line with a pass or fail mark.
    public static func render(_ findings: [Finding]) -> String {
        findings.map { "\($0.ok ? "ok  " : "FAIL") \($0.name): \($0.detail)" }.joined(separator: "\n")
    }

    private func macOSVersion() -> Finding {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let text = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        return Finding(
            name: "macOS", ok: version.majorVersion >= 27,
            detail: version.majorVersion >= 27 ? text : "\(text); wisp needs macOS 27 or later")
    }

    private func modelAvailability() -> Finding {
        if let problem = probes.systemModel() {
            return Finding(name: "model", ok: false, detail: problem)
        }
        return Finding(name: "model", ok: true, detail: "on-device model available")
    }

    private func sandboxExec() -> Finding {
        let path = "/usr/bin/sandbox-exec"
        let present = FileManager.default.isExecutableFile(atPath: path)
        return Finding(
            name: "sandbox", ok: present,
            detail: present ? "\(path) present" : "\(path) missing; run_command cannot be sandboxed")
    }

    private func config() -> Finding {
        let file = home.configFile
        guard FileManager.default.fileExists(atPath: file.path) else {
            return Finding(name: "config", ok: true, detail: "no \(file.path); defaults apply")
        }
        do {
            _ = try Config.load(from: file)
            return Finding(name: "config", ok: true, detail: "\(file.path) parses")
        } catch {
            return Finding(name: "config", ok: false, detail: "\(file.path): \(error)")
        }
    }

    private func homeWritable() -> Finding {
        do {
            try home.ensure()
            let probe = home.root.appending(path: ".doctor-\(UUID().uuidString)")
            try Data().write(to: probe)
            try FileManager.default.removeItem(at: probe)
            return Finding(name: "home", ok: true, detail: "\(home.root.path) writable")
        } catch {
            return Finding(name: "home", ok: false, detail: "\(home.root.path) not writable: \(error)")
        }
    }
}
