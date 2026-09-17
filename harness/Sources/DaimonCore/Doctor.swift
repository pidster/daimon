import Foundation
import FoundationModels

/// Checks what a fresh install needs to work, for `daimon doctor`.
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

    /// Where daimon keeps its state.
    public var home: Home

    /// Creates a doctor for `home`.
    public init(home: Home) {
        self.home = home
    }

    /// Runs every check. Never throws: problems are findings.
    public func run() -> [Finding] {
        [macOSVersion(), modelAvailability(), sandboxExec(), config(), homeWritable()]
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
            detail: version.majorVersion >= 27 ? text : "\(text); daimon needs macOS 27 or later")
    }

    private func modelAvailability() -> Finding {
        switch SystemLanguageModel.default.availability {
        case .available:
            return Finding(name: "model", ok: true, detail: "on-device model available")
        case .unavailable(let reason):
            return Finding(
                name: "model", ok: false,
                detail:
                    "unavailable (\(reason)); enable Apple Intelligence in System Settings and wait for the model to download"
            )
        }
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
