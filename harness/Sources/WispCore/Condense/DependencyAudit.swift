import Foundation

/// A dependency audit reduced to what needs action: `npm audit --json`, `cargo audit --json`, or
/// `pip-audit -f json`, read without the model into one line per advisory, the most severe and the
/// fixable first ([ADR 0039](../../../../docs/decisions/0039-exact-condensers.md)).
public struct DependencyAudit: Sendable {
    /// One advisory against one package.
    public struct Advisory: Equatable, Sendable {
        /// The package the advisory is against.
        public var package: String
        /// The installed version, or the vulnerable range when the tool gives no version.
        public var version: String
        /// `critical`, `high`, `moderate`, `low`, `info`, or `unknown`.
        public var severity: String
        /// The advisory's id: a GHSA, RUSTSEC, PYSEC, or CVE identifier, or a URL.
        public var id: String
        /// What it is, in one line.
        public var title: String
        /// What to do: `upgrade to …`, `npm audit fix`, `none available`, and whether it breaks semver.
        public var fix: String
        /// Whether the package is a direct dependency, when the tool says.
        public var direct: Bool?

        /// Whether a fix exists.
        public var fixable: Bool { !fix.hasPrefix("none") }
    }

    /// Why the input could not be read.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// Not JSON, or JSON in none of the three shapes.
        case unrecognised(String)

        /// Human-readable explanation.
        public var description: String {
            switch self {
            case .unrecognised(let detail):
                "not npm audit --json, cargo audit --json, or pip-audit -f json output: \(detail)"
            }
        }
    }

    /// The audit, condensed.
    public struct Report: Equatable, Sendable {
        /// `npm`, `cargo`, or `pip-audit`.
        public var tool: String
        /// The advisories kept, most severe and fixable first.
        public var advisories: [Advisory]
        /// Advisories per severity, before the cap.
        public var counts: [String: Int]
        /// Warnings the tool raised that are not vulnerabilities (`cargo audit`'s unmaintained and yanked
        /// crates), one line each.
        public var warnings: [String]
        /// Advisories dropped by the cap.
        public var more: Int

        /// The report as JSON, the shape the MCP tool returns.
        public var json: JSONValue {
            .object([
                "tool": .string(tool), "counts": .object(counts.mapValues { .int($0) }), "more": .int(more),
                "warnings": .array(warnings.map { .string($0) }),
                "advisories": .array(
                    advisories.map {
                        .object([
                            "package": .string($0.package), "version": .string($0.version),
                            "severity": .string($0.severity), "id": .string($0.id), "title": .string($0.title),
                            "fix": .string($0.fix), "direct": $0.direct.map { .bool($0) } ?? .null,
                        ])
                    }),
            ])
        }

        /// The report as lines: a headline with the counts, then one advisory per line.
        public var rendered: String {
            let total = counts.values.reduce(0, +)
            let tally = DependencyAudit.severities.compactMap { level in counts[level].map { "\($0) \(level)" } }
            var lines = [
                "\(tool) audit: \(total) advisor\(total == 1 ? "y" : "ies")"
                    + (tally.isEmpty ? "" : " (\(tally.joined(separator: ", ")))")
                    + ", \(advisories.filter(\.fixable).count) with a fix"
            ]
            for advisory in advisories {
                let direct = advisory.direct == true ? " (direct)" : ""
                lines.append(
                    "\(advisory.severity)\t\(advisory.package) \(advisory.version)\(direct)\t\(advisory.id)\t"
                        + "\(advisory.title)\t\(advisory.fix)")
            }
            if more > 0 { lines.append("… \(more) more, less severe") }
            lines += warnings.map { "warning\t\($0)" }
            return lines.joined(separator: "\n")
        }
    }

    /// Severities from most to least severe.
    static let severities = ["critical", "high", "moderate", "low", "info", "unknown"]

    /// Advisories to keep at most.
    public var maxAdvisories: Int

    /// Creates a condenser that keeps at most `maxAdvisories`.
    public init(maxAdvisories: Int = 40) {
        self.maxAdvisories = maxAdvisories
    }

    /// Reads an audit's JSON output.
    ///
    /// - Throws: `Failure.unrecognised`.
    public func run(_ text: String) throws -> Report {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else {
            throw Failure.unrecognised("not JSON")
        }
        let (tool, advisories, warnings): (String, [Advisory], [String])
        if let object = value.objectValue,
            object["auditReportVersion"] != nil
                || (object["vulnerabilities"] != nil && object["vulnerabilities"]?.objectValue?["list"] == nil)
        {
            (tool, advisories, warnings) = ("npm", Self.npm(object), [])
        } else if let object = value.objectValue, let list = object["vulnerabilities"]?.objectValue?["list"] {
            (tool, advisories, warnings) = ("cargo", Self.cargo(list), Self.cargoWarnings(object["warnings"]))
        } else if let dependencies = value.objectValue?["dependencies"]?.arrayValue ?? value.arrayValue {
            (tool, advisories, warnings) = ("pip-audit", Self.pip(dependencies), [])
        } else {
            throw Failure.unrecognised("no vulnerabilities, list, or dependencies")
        }
        let rank = { (severity: String) in Self.severities.firstIndex(of: severity) ?? Self.severities.count }
        let sorted = advisories.sorted {
            (rank($0.severity), $0.fixable ? 0 : 1, $0.package, $0.id) < (
                rank($1.severity), $1.fixable ? 0 : 1, $1.package, $1.id
            )
        }
        var counts: [String: Int] = [:]
        for advisory in advisories { counts[advisory.severity, default: 0] += 1 }
        return Report(
            tool: tool, advisories: Array(sorted.prefix(maxAdvisories)), counts: counts, warnings: warnings,
            more: max(0, sorted.count - maxAdvisories))
    }

    /// `npm audit --json`, version 2: one entry per vulnerable package, whose `via` holds the advisories
    /// (objects) or the names of the vulnerable packages it depends on (strings, skipped here, since
    /// those packages have entries of their own).
    static func npm(_ object: [String: JSONValue]) -> [Advisory] {
        guard let vulnerabilities = object["vulnerabilities"]?.objectValue else { return [] }
        return vulnerabilities.sorted { $0.key < $1.key }.flatMap { name, entry -> [Advisory] in
            let fields = entry.objectValue ?? [:]
            let fix: String
            switch fields["fixAvailable"] {
            case .bool(true): fix = "npm audit fix"
            case .object(let target):
                let breaking = target["isSemVerMajor"]?.boolValue == true ? " (breaking)" : ""
                fix =
                    "upgrade \(target["name"]?.stringValue ?? name) to \(target["version"]?.stringValue ?? "?")"
                    + breaking
            default: fix = "none available"
            }
            return (fields["via"]?.arrayValue ?? []).compactMap { via in
                guard let advisory = via.objectValue else { return nil }
                return Advisory(
                    package: name, version: fields["range"]?.stringValue ?? advisory["range"]?.stringValue ?? "?",
                    severity: advisory["severity"]?.stringValue ?? fields["severity"]?.stringValue ?? "unknown",
                    id: advisory["url"]?.stringValue.map(Self.idFromURL) ?? advisory["source"]?.intValue.map(
                        String.init)
                        ?? "?",
                    title: advisory["title"]?.stringValue ?? "", fix: fix, direct: fields["isDirect"]?.boolValue)
            }
        }
    }

    /// The last path component of an advisory URL, `GHSA-…` for GitHub's.
    static func idFromURL(_ url: String) -> String {
        url.split(separator: "/").last.map(String.init) ?? url
    }

    /// `cargo audit --json`'s `vulnerabilities.list`.
    static func cargo(_ list: JSONValue) -> [Advisory] {
        (list.arrayValue ?? []).map { item in
            let fields = item.objectValue ?? [:]
            let advisory = fields["advisory"]?.objectValue ?? [:]
            let package = fields["package"]?.objectValue ?? [:]
            let patched = (fields["versions"]?.objectValue?["patched"]?.arrayValue ?? []).compactMap(\.stringValue)
            return Advisory(
                package: package["name"]?.stringValue ?? advisory["package"]?.stringValue ?? "?",
                version: package["version"]?.stringValue ?? "?",
                severity: Self.cvssSeverity(advisory["cvss"]?.stringValue),
                id: advisory["id"]?.stringValue ?? "?", title: advisory["title"]?.stringValue ?? "",
                fix: patched.isEmpty ? "none available" : "upgrade to \(patched.joined(separator: " or "))", direct: nil
            )
        }
    }

    /// `cargo audit`'s warnings: unmaintained, yanked, and unsound crates.
    static func cargoWarnings(_ warnings: JSONValue?) -> [String] {
        guard let groups = warnings?.objectValue else { return [] }
        return groups.sorted { $0.key < $1.key }.flatMap { kind, items in
            (items.arrayValue ?? []).map { item in
                let fields = item.objectValue ?? [:]
                let package = fields["package"]?.objectValue ?? [:]
                let title = fields["advisory"]?.objectValue?["title"]?.stringValue.map { ": \($0)" } ?? ""
                return "\(kind) \(package["name"]?.stringValue ?? "?") \(package["version"]?.stringValue ?? "")\(title)"
            }
        }
    }

    /// A CVSS v3 vector's severity from its base metrics, roughly: `cargo audit` gives the vector, not
    /// a score. Network reach with high impact is `high`, adding no privileges or interaction is
    /// `critical`, and anything else with impact is `moderate`; no vector is `unknown`.
    static func cvssSeverity(_ vector: String?) -> String {
        guard let vector, vector.hasPrefix("CVSS:") else { return "unknown" }
        let metrics = Dictionary(
            vector.split(separator: "/").dropFirst().compactMap { part -> (String, String)? in
                let pieces = part.split(separator: ":")
                return pieces.count == 2 ? (String(pieces[0]), String(pieces[1])) : nil
            }, uniquingKeysWith: { first, _ in first })
        let impact = ["C", "I", "A"].filter { metrics[$0] == "H" }.count
        let anyImpact = ["C", "I", "A"].contains { metrics[$0] == "H" || metrics[$0] == "L" }
        if metrics["AV"] == "N", impact > 0 {
            return metrics["PR"] == "N" && metrics["UI"] == "N" && impact >= 2 ? "critical" : "high"
        }
        return anyImpact ? "moderate" : "low"
    }

    /// `pip-audit -f json`: packages, each with its `vulns`.
    static func pip(_ dependencies: [JSONValue]) -> [Advisory] {
        dependencies.flatMap { dependency -> [Advisory] in
            let fields = dependency.objectValue ?? [:]
            return (fields["vulns"]?.arrayValue ?? []).map { vuln in
                let v = vuln.objectValue ?? [:]
                let fixes = (v["fix_versions"]?.arrayValue ?? []).compactMap(\.stringValue)
                let description = v["description"]?.stringValue ?? ""
                return Advisory(
                    package: fields["name"]?.stringValue ?? "?", version: fields["version"]?.stringValue ?? "?",
                    severity: "unknown", id: v["id"]?.stringValue ?? "?",
                    title: description.split(separator: "\n").first.map { String($0.prefix(120)) } ?? "",
                    fix: fixes.isEmpty ? "none available" : "upgrade to \(fixes.joined(separator: " or "))", direct: nil
                )
            }
        }
    }
}
