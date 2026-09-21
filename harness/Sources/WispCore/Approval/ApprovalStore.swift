import Foundation

/// How long an approval lasts.
public enum ApprovalScope: String, Codable, Equatable, Sendable, CaseIterable {
    /// The rest of this turn: the current prompt's tool loop, however many calls it makes.
    case once
    /// Until the process exits.
    case session
    /// Until it expires, for this exact command in this exact directory; persisted.
    case project
    /// Until it expires, for this exact command in any directory; persisted.
    case always

    /// Whether the scope outlives the process.
    public var isPersistent: Bool {
        self == .project || self == .always
    }
}

/// Approvals that outlive the process, kept in `~/.wisp/approvals.json`.
///
/// A persisted approval is a standing permission, so it is bound to a pattern
/// (`head *`: the program, any arguments; and the directory for `project`),
/// expires, is never used for a dangerous verdict, and can be listed and revoked
/// with `wisp approvals`.
/// Deny patterns and the sandbox still apply to every use.
public actor ApprovalStore {
    /// One standing approval.
    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        /// Short random id, for `wisp approvals revoke`.
        public var id: String
        /// The approval key, such as `head *`.
        public var pattern: String
        /// The directory, for `project` scope; nil for `always`.
        public var workingDirectory: String?
        /// `project` or `always`.
        public var scope: ApprovalScope
        /// The classifier level when granted.
        public var level: RiskLevel
        /// When it was granted.
        public var grantedAt: Date
        /// When it stops applying.
        public var expiresAt: Date
        /// Which entry point granted it.
        public var source: String

        /// Whether `pattern` in `directory` is covered at `now`.
        func covers(pattern: String, directory: String, now: Date) -> Bool {
            guard now < expiresAt, self.pattern == pattern else { return false }
            return scope == .always || workingDirectory == directory
        }
    }

    /// Where entries are written; nil keeps them in memory only (tests).
    public let url: URL?
    private let lifetime: Duration
    private var entries: [Entry]

    /// Loads entries from `url` (missing or unreadable means empty) and drops expired ones.
    ///
    /// - Parameters:
    ///   - url: The JSON file, or nil for an in-memory store.
    ///   - lifetime: How long a new grant lasts.
    public init(url: URL?, lifetime: Duration = .seconds(30 * 24 * 3600)) {
        self.url = url
        self.lifetime = lifetime
        var loaded: [Entry] = []
        if let url, let data = try? Data(contentsOf: url),
            let decoded = try? Self.decoder.decode([Entry].self, from: data)
        {
            loaded = decoded
        }
        entries = loaded.filter { $0.expiresAt > Date() }
    }

    /// Live entries, newest first.
    public var all: [Entry] {
        entries.filter { $0.expiresAt > Date() }.sorted { $0.grantedAt > $1.grantedAt }
    }

    /// The entry covering `pattern` in `directory`, if any.
    public func find(pattern: String, directory: String) -> Entry? {
        entries.first { $0.covers(pattern: pattern, directory: directory, now: Date()) }
    }

    /// Records a standing approval and writes the file.
    ///
    /// - Returns: The new entry.
    /// - Throws: File-system errors from writing.
    @discardableResult
    public func grant(
        pattern: String, directory: String, scope: ApprovalScope, level: RiskLevel, source: String
    ) throws -> Entry {
        precondition(scope.isPersistent, "only project and always are persisted")
        let now = Date()
        let entry = Entry(
            id: ShortID.make(), pattern: pattern,
            workingDirectory: scope == .project ? directory : nil, scope: scope, level: level, grantedAt: now,
            expiresAt: now.addingTimeInterval(TimeInterval(lifetime.components.seconds)), source: source)
        entries.append(entry)
        try save()
        return entry
    }

    /// Removes the entry with `id`.
    ///
    /// - Returns: Whether anything was removed.
    /// - Throws: File-system errors from writing.
    public func revoke(id: String) throws -> Bool {
        let before = entries.count
        entries.removeAll { $0.id == id }
        try save()
        return entries.count < before
    }

    /// Removes every entry.
    ///
    /// - Throws: File-system errors from writing.
    public func clear() throws {
        entries.removeAll()
        try save()
    }

    private func save() throws {
        guard let url else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try Self.encoder.encode(entries)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
