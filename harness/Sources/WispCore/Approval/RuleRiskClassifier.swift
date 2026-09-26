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
    private let compiled: [(regex: NSRegularExpression, rule: Rule)]

    /// Why the rules could not be compiled.
    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// A rule's pattern does not compile as a regular expression.
        case invalidRule(pattern: String)

        /// Human-readable explanation.
        public var description: String {
            switch self {
            case .invalidRule(let pattern): "invalid risk rule pattern: \(pattern)"
            }
        }
    }

    /// Creates a classifier over `rules`, compiling every pattern once.
    ///
    /// - Throws: `Failure.invalidRule` naming the first pattern that does not compile.
    public init(rules: [Rule]) throws {
        self.rules = rules
        compiled = try rules.map { rule in
            do {
                return (try RegexCache.regex(rule.pattern), rule)
            } catch {
                throw Failure.invalidRule(pattern: rule.pattern)
            }
        }
    }

    /// The built-in rules. A test compiles every default pattern, so this cannot fail in practice; a
    /// pattern that somehow did would be dropped with an error in diagnostics rather than crash.
    public static let standard: RuleRiskClassifier = {
        if let classifier = try? RuleRiskClassifier(rules: defaultRules) { return classifier }
        let usable = defaultRules.filter { (try? RegexCache.regex($0.pattern)) != nil }
        Diagnostics.policy.error(
            "dropping \(defaultRules.count - usable.count) default risk rule(s) that do not compile")
        return (try? RuleRiskClassifier(rules: usable)) ?? RuleRiskClassifier(compiled: [])
    }()

    private init(compiled: [(regex: NSRegularExpression, rule: Rule)]) {
        rules = compiled.map(\.rule)
        self.compiled = compiled
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
        Rule(
            start + #"find\b.*\s(-delete\b|-exec(dir)?\s+rm\b)"#, .dangerous,
            "deletes every file the search matches"),
        Rule(start + #"xargs\s+(-\S+\s+)*rm\b"#, .dangerous, "deletes every path given to it"),
        Rule(
            start + #"find\s+(/|~|\$HOME)\S*\s.*-exec(dir)?\s+(cat|cp|tar|zip|base64|curl|scp|rsync|xxd|strings)\b"#,
            .dangerous, "reads or copies every file a search of the home folder or the disk matches"),
        Rule(
            start + #"security\s+(find-(generic|internet)-password\b.*\s-w\b|dump-keychain\b|export\b)"#,
            .dangerous, "prints stored passwords or keys"),
        Rule(start + #"(chmod|chown)\s+(-R|--recursive)"#, .dangerous, "recursive permission change"),
        Rule(
            start + #"(mkfs|diskutil\s+(erase|partition)|newfs_|dd\s.*\bof=/dev/)"#, .dangerous,
            "destroys a disk or volume"),
        Rule(
            #"(\.ssh/|id_rsa|id_ed25519|\.aws/credentials|\.netrc|\.gnupg|keychain|\.config/gh/hosts\.yml|\.git-credentials|\.npmrc|\.pypirc|\.docker/config\.json|\.kube/config)"#,
            .dangerous, "touches credentials"
        ),
        Rule(start + #"(kill\s+-9\s+-1|killall|pkill\s+-9)\b"#, .dangerous, "kills processes broadly"),
        Rule(start + #"(launchctl|systemsetup|nvram|csrutil|spctl)\b"#, .dangerous, "changes system configuration"),
        Rule(
            #"(curl|wget)\b.*(-X\s*POST|--data|-d\s|--upload-file|-T\s|@-)"#, .dangerous,
            "uploads data over the network"),
        Rule(
            #"-m\s+http\.server\b(?!.*(--bind|-b)\s+(127\.0\.0\.1|localhost|::1)\b)"#, .dangerous,
            "serves a directory on every network interface"),
        // Moderate
        Rule(start + #"(curl|wget|ssh|scp|sftp|rsync|nc|telnet)\b"#, .moderate, "uses the network"),
        Rule(
            #"(-m\s+http\.server|\bhttp-server\b|\bserve\b|\bnc\s+-l|\bngrok\b|\bssh\s+-[LRD]\b|--listen\b|\blisten\s+\d)"#,
            .moderate, "starts a network service"),
        Rule(
            start
                + #"git\s+(push|pull|fetch|clone|remote|commit|merge|rebase|stash|tag(?!\s+(-l|--list)\b)|cherry-pick|revert)(?![\w-])"#,
            .moderate, "changes repository state"),
        Rule(
            start
                + #"(npm|npx|yarn|pnpm|pip3?|pipx|gem|cargo|brew|swift\s+package)\s+(install|add|update|upgrade|remove|uninstall|publish)\b"#,
            .moderate, "installs or publishes packages"),
        Rule(
            start + #"(rm|mv|cp|touch|mkdir|rmdir|ln|truncate|tee|sed\s+-i|perl\s+-i)\b"#, .moderate, "modifies files"),
        Rule(#"(^|[^>])>{1,2}\s*(?!/dev/null\b)[^&\s]"#, .moderate, "writes to a file"),
        Rule(start + #"edit_file\b"#, .moderate, "edits a file"),
        // Building and testing the project are safe, as the labels have them (training/risk/labels.md); only
        // what writes outside the project or throws build output away is moderate.
        Rule(
            start + #"xcodebuild(?!\s+(-showsdks|-version|-list)\b)(?=\s|$)"#, .moderate,
            "writes build products outside the project"),
        Rule(
            start
                + #"(make\s+(\S+\s+)*(clean|distclean|install|uninstall)\b|cargo\s+clean\b|swift\s+package\s+(clean|reset|purge-cache)\b|go\s+clean\b)"#,
            .moderate, "cleans or installs build output"),
        Rule(
            start + #"(open|osascript|defaults\s+write|crontab|at)(?=\s|$)"#, .moderate,
            "affects the desktop or scheduling"),
        Rule(start + #"(kill|pkill)\b"#, .moderate, "signals a process"),
    ]

    /// The one reason given when no rule matches, so a caller can tell "safe by a rule" from "no rule
    /// knew the command".
    public static let noSignals = "no risk signals in the command text"

    /// The reason given for a command on the read-only list (`KnownSafeCommands`).
    public static let knownSafe = "a known read-only command"

    /// Applies every rule and returns the highest level with all matching reasons. A command no rule
    /// matches that is on the read-only list is marked `RiskAssessment.knownSafeKey`, so a composite asks
    /// no other classifier about it.
    public func classify(command: String, workingDirectory: String) async -> RiskAssessment {
        var level = RiskLevel.safe
        var reasons: [String] = []
        for (regex, rule) in compiled where regex.matches(anywhereIn: command) {
            level = max(level, rule.level)
            if !reasons.contains(rule.reason) { reasons.append(rule.reason) }
        }
        if reasons.isEmpty, KnownSafeCommands.contains(command) {
            return RiskAssessment(
                level: .safe, reasons: [Self.knownSafe], sources: ["rules"],
                metadata: [RiskAssessment.knownSafeKey: true])
        }
        if reasons.isEmpty { reasons = [Self.noSignals] }
        return RiskAssessment(level: level, reasons: reasons, sources: ["rules"])
    }
}
