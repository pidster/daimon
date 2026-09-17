import Foundation

/// Cheap, deterministic risk signals from the command text.
///
/// Covers the model classifier's weak spot (it under-rates ordinary
/// modifications as safe) and the shapes that must never slip through. Each
/// rule is a regex, a level, and the reason shown to the approver.
public struct RuleRiskClassifier: RiskClassifier {
    /// One signal.
    public struct Rule: Sendable, Equatable {
        /// Regex over the whole command line.
        public var pattern: String
        /// Level when it matches.
        public var level: RiskLevel
        /// Shown to the approver.
        public var reason: String

        /// Creates a rule.
        public init(_ pattern: String, _ level: RiskLevel, _ reason: String) {
            self.pattern = pattern
            self.level = level
            self.reason = reason
        }
    }

    /// The rules in use.
    public let rules: [Rule]

    /// Creates a classifier over `rules` (default: `defaultRules`).
    public init(rules: [Rule] = RuleRiskClassifier.defaultRules) {
        self.rules = rules
    }

    /// A word boundary at the start of a simple command in a pipeline or list.
    private static let start = #"(^|[\s;&|(`]|\$\()"#

    /// Built-in signals. Order does not matter; the highest matching level wins.
    public static let defaultRules: [Rule] = [
        // Dangerous
        Rule(start + #"sudo(\s|$)"#, .dangerous, "runs as root"),
        Rule(start + #"rm\s+(-[A-Za-z]*r[A-Za-z]*f|-[A-Za-z]*f[A-Za-z]*r|-r|-R)\b"#, .dangerous, "recursive deletion"),
        Rule(start + #"rm\s+.*(~|\$HOME|/Users/|/etc|/usr|/var|/System)"#, .dangerous, "deletes outside the project"),
        Rule(#"\|\s*(ba|z|da)?sh(\s|$)"#, .dangerous, "pipes downloaded or generated content into a shell"),
        Rule(start + #"git\s+push\b.*(--force|-f\b|\+)"#, .dangerous, "force push rewrites remote history"),
        Rule(
            start + #"git\s+(reset\s+--hard|clean\s+-[a-z]*f|checkout\s+--\s|restore\s)"#, .dangerous,
            "discards local changes"),
        Rule(start + #"git\s+branch\s+-D\b"#, .dangerous, "deletes a branch without merge check"),
        Rule(start + #"(chmod|chown)\s+(-R|--recursive)"#, .dangerous, "recursive permission change"),
        Rule(
            start + #"(mkfs|diskutil\s+(erase|partition)|newfs_|dd\s.*\bof=/dev/)"#, .dangerous,
            "destroys a disk or volume"),
        Rule(
            #"(\.ssh/|id_rsa|id_ed25519|\.aws/credentials|\.netrc|\.gnupg|keychain)"#, .dangerous, "touches credentials"
        ),
        Rule(start + #"(kill\s+-9\s+-1|killall|pkill\s+-9)\b"#, .dangerous, "kills processes broadly"),
        Rule(start + #"(launchctl|systemsetup|nvram|csrutil|spctl)\b"#, .dangerous, "changes system configuration"),
        Rule(
            #"(curl|wget)\b.*(-X\s*POST|--data|-d\s|--upload-file|-T\s|@-)"#, .dangerous,
            "uploads data over the network"),
        // Moderate
        Rule(start + #"(curl|wget|ssh|scp|sftp|rsync|nc|telnet)\b"#, .moderate, "uses the network"),
        Rule(
            #"(-m\s+http\.server|\bhttp-server\b|\bserve\b|\bnc\s+-l|\bngrok\b|\bssh\s+-[LRD]\b|--listen\b|\blisten\s+\d)"#,
            .moderate, "starts a network service"),
        Rule(
            start + #"git\s+(push|pull|fetch|clone|remote|commit|merge|rebase|stash|tag|cherry-pick|revert)\b"#,
            .moderate, "changes repository state"),
        Rule(
            start
                + #"(npm|npx|yarn|pnpm|pip3?|pipx|gem|cargo|brew|swift\s+package)\s+(install|add|update|upgrade|remove|uninstall|publish)\b"#,
            .moderate, "installs or publishes packages"),
        Rule(
            start + #"(rm|mv|cp|touch|mkdir|rmdir|ln|truncate|tee|sed\s+-i|perl\s+-i)\b"#, .moderate, "modifies files"),
        Rule(#"(^|[^>])>{1,2}\s*[^&\s]"#, .moderate, "writes to a file"),
        Rule(
            start
                + #"(swift\s+build|swift\s+test|cargo\s+(build|test|run)|make|xcodebuild|npm\s+(run|test)|pytest|go\s+(build|test))\b"#,
            .moderate, "runs a build or tests"),
        Rule(
            start + #"(open|osascript|defaults\s+write|crontab|at)\b"#, .moderate, "affects the desktop or scheduling"),
        Rule(start + #"(kill|pkill)\b"#, .moderate, "signals a process"),
    ]

    /// Applies every rule and returns the highest level with all matching reasons.
    public func classify(command: String, workingDirectory: String) async -> RiskAssessment {
        var level = RiskLevel.safe
        var reasons: [String] = []
        for rule in rules {
            guard let regex = try? Regex(rule.pattern), command.contains(regex) else { continue }
            level = max(level, rule.level)
            if !reasons.contains(rule.reason) { reasons.append(rule.reason) }
        }
        if reasons.isEmpty { reasons = ["no risk signals in the command text"] }
        return RiskAssessment(level: level, reasons: reasons, sources: ["rules"])
    }
}
