import Foundation

/// What `run_command` may execute and how it is confined.
///
/// Two layers, both configurable from `config.json`:
///
/// 1. **Patterns.** `deny` regexes reject a command line outright; if `allow` is
///    non-empty, the command must also match at least one of them. Deny wins.
///    Patterns are cheap and auditable but only see the command text.
/// 2. **Sandbox.** When enabled, the command runs under `sandbox-exec` with a
///    Seatbelt profile that denies file writes outside a set of directories and,
///    optionally, all network access. This is enforced by the kernel regardless
///    of what the command line says.
public struct CommandPolicy: Codable, Equatable, Sendable {
    /// Seatbelt confinement settings.
    public struct Sandbox: Codable, Equatable, Sendable {
        /// Whether to run commands under `sandbox-exec` at all.
        public var enabled: Bool
        /// Whether the sandboxed command may use the network.
        public var allowNetwork: Bool
        /// Directories writable in addition to the working directory and the temporary directory.
        /// `~` is expanded; symlinks are resolved because Seatbelt matches canonical paths.
        public var writablePaths: [String]

        /// Creates sandbox settings.
        public init(
            enabled: Bool = true, allowNetwork: Bool = true, writablePaths: [String] = Sandbox.defaultWritablePaths
        ) {
            self.enabled = enabled
            self.allowNetwork = allowNetwork
            self.writablePaths = writablePaths
        }

        /// Caches that build tools expect to write: SwiftPM and Cargo registries.
        public static let defaultWritablePaths = ["~/Library/Caches", "~/.cargo/registry", "~/.cargo/git"]
    }

    /// The outcome of checking a command line against the patterns.
    public enum Verdict: Equatable, Sendable {
        /// The command may run.
        case allowed
        /// The command must not run, with the reason to report.
        case denied(String)
    }

    /// Regexes; a match rejects the command. Checked before `allow`.
    public var deny: [String]
    /// Regexes; when non-empty, the command must match one of them.
    public var allow: [String]
    /// Confinement settings.
    public var sandbox: Sandbox

    /// Creates a policy.
    public init(deny: [String] = CommandPolicy.defaultDeny, allow: [String] = [], sandbox: Sandbox = Sandbox()) {
        self.deny = deny
        self.allow = allow
        self.sandbox = sandbox
    }

    /// The default: sandbox on with network allowed, no allow list, and a deny list of
    /// obviously destructive or privilege-escalating shapes.
    public static let `default` = CommandPolicy()

    /// No patterns and no sandbox. What `--unsafe` selects.
    public static let unrestricted = CommandPolicy(deny: [], allow: [], sandbox: Sandbox(enabled: false))

    /// Shapes rejected by default. Illustrative, not exhaustive; the sandbox is the real barrier.
    public static let defaultDeny: [String] = [
        #"(^|[\s;&|(])sudo(\s|$)"#,
        #"(^|[\s;&|(])rm\s+(-[A-Za-z]*r[A-Za-z]*f|-[A-Za-z]*f[A-Za-z]*r)\S*\s+/+(\s|$)"#,
        #"\|\s*(ba|z|da)?sh(\s|$)"#,
        #"(^|[\s;&|(])(mkfs|diskutil\s+erase|newfs_)"#,
        #"(^|[\s;&|(])dd\s.*\bof=/dev/"#,
    ]

    /// Checks that every pattern compiles.
    ///
    /// - Throws: `Failure.invalidPattern` naming the first bad pattern.
    public func validate() throws {
        for pattern in deny + allow {
            do { _ = try Regex(pattern) } catch { throw Failure.invalidPattern(pattern) }
        }
    }

    /// Applies the deny and allow patterns to a command line.
    public func check(_ command: String) -> Verdict {
        for pattern in deny where Self.matches(pattern, command) {
            return .denied("command matches deny pattern \(pattern)")
        }
        if !allow.isEmpty, !allow.contains(where: { Self.matches($0, command) }) {
            return .denied("command matches no allow pattern")
        }
        return .allowed
    }

    /// The Seatbelt profile for a command run in `workingDirectory`.
    ///
    /// Everything is allowed except writes outside the writable set and,
    /// when `allowNetwork` is false, all networking. Paths are canonicalised.
    public func seatbeltProfile(workingDirectory: String, temporaryDirectory: String, home: String) -> String {
        var writable = [workingDirectory, temporaryDirectory, "/private/tmp"]
        writable += sandbox.writablePaths.map { $0.hasPrefix("~") ? home + $0.dropFirst() : $0 }
        let subpaths = writable.map { Self.canonical($0) }.map { "(subpath \(Self.quote($0)))" }
        var lines = [
            "(version 1)",
            "(allow default)",
            "(deny file-write*)",
            "(allow file-write* \(subpaths.joined(separator: " ")) (literal \"/dev/null\") (regex #\"^/dev/(tty|fd/)\"))",
        ]
        if !sandbox.allowNetwork {
            lines.append("(deny network*)")
        }
        return lines.joined(separator: "\n")
    }

    /// Why a policy is unusable.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// A deny or allow pattern is not a valid regular expression.
        case invalidPattern(String)

        /// Human-readable explanation.
        public var description: String {
            switch self {
            case .invalidPattern(let pattern): "invalid command policy pattern: \(pattern)"
            }
        }
    }

    private static func matches(_ pattern: String, _ command: String) -> Bool {
        guard let regex = try? Regex(pattern) else { return false }
        return command.contains(regex)
    }

    /// Resolves symlinks with `realpath(3)` (for example `/var` to `/private/var`) and strips a
    /// trailing slash. For a path that does not exist yet, the longest existing prefix is resolved
    /// and the remainder appended unchanged.
    static func canonical(_ path: String) -> String {
        var existing = path
        var remainder: [String] = []
        while existing.count > 1, realpath(existing, nil) == nil {
            let url = URL(fileURLWithPath: existing)
            remainder.insert(url.lastPathComponent, at: 0)
            existing = url.deletingLastPathComponent().path
        }
        var resolved = existing
        if let real = realpath(existing, nil) {
            resolved = String(cString: real)
            free(real)
        }
        for component in remainder {
            resolved += resolved.hasSuffix("/") ? component : "/" + component
        }
        while resolved.count > 1, resolved.hasSuffix("/") { resolved.removeLast() }
        return resolved
    }

    /// Quotes a path for a Seatbelt string literal.
    static func quote(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
