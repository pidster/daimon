import Foundation

/// Writes text to a file inside the writable set, the same directories the sandbox lets commands
/// write under, so `edit_file` can change no more than `run_command` could.
///
/// Three edits: write the whole file (created if absent), append, or replace one exact occurrence of
/// a piece of text. Replacement demands exactly one match so the model cannot change more than it
/// showed it meant to. Nothing here creates directories or follows the model outside the set.
public struct FileWriter: Sendable {
    /// What to do to the file.
    public enum Edit: Equatable, Sendable {
        /// Replace the whole file with `content`, creating it if absent.
        case write(String)
        /// Add `content` to the end, creating the file if absent.
        case append(String)
        /// Replace the one occurrence of `find` with `replacement`.
        case replace(find: String, replacement: String)

        /// The spelling the model uses and the audit records.
        public var mode: String {
            switch self {
            case .write: "write"
            case .append: "append"
            case .replace: "replace"
            }
        }
    }

    /// What an edit did.
    public struct Result: Equatable, Sendable {
        /// The path as given.
        public var path: String
        /// The edit's mode.
        public var mode: String
        /// Whether the file did not exist before.
        public var created: Bool
        /// Size before the edit; 0 when created.
        public var bytesBefore: Int
        /// Size after the edit.
        public var bytesAfter: Int
        /// For a replacement, the 1-based line where it started.
        public var line: Int?

        /// Model-facing rendering.
        public var rendered: String {
            switch mode {
            case "replace": "replaced at line \(line ?? 0) of \(path); now \(bytesAfter) bytes"
            case "append": "appended to \(path); now \(bytesAfter) bytes"
            default: "\(created ? "created" : "wrote") \(path); now \(bytesAfter) bytes"
            }
        }
    }

    /// Why an edit was not made.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// The path is outside every writable directory.
        case outsideWritableSet(path: String, roots: [String])
        /// The parent directory does not exist.
        case noParent(String)
        /// The path is a directory.
        case isDirectory(String)
        /// The file contains NUL bytes.
        case binary(String)
        /// The file is larger than the writer will load for a replacement.
        case tooLarge(path: String, bytes: Int, limit: Int)
        /// The text to replace was not found.
        case notFound(find: String)
        /// The text to replace occurs more than once.
        case ambiguous(find: String, count: Int)
        /// The approval gate refused the edit.
        case notApproved(String)

        /// Human-readable explanation.
        public var description: String {
            switch self {
            case .outsideWritableSet(let path, let roots):
                "cannot write \(path): outside the writable directories (\(roots.joined(separator: ", ")))"
            case .noParent(let path): "cannot write \(path): its directory does not exist"
            case .isDirectory(let path): "path is a directory: \(path)"
            case .binary(let path): "file appears to be binary: \(path)"
            case .tooLarge(let path, let bytes, let limit):
                "file too large to edit in place: \(path) is \(bytes) bytes, limit \(limit)"
            case .notFound(let find): "text to replace not found: \(Self.excerpt(find))"
            case .ambiguous(let find, let count):
                "text to replace occurs \(count) times, include more surrounding text: \(Self.excerpt(find))"
            case .notApproved(let reason): "edit not approved: \(reason)"
            }
        }

        /// The first line of `text`, shortened.
        private static func excerpt(_ text: String) -> String {
            let first = text.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
            return first.count > 60 ? String(first.prefix(60)) + "…" : first
        }
    }

    /// Canonical directories writes may land under; nil means anywhere (the sandbox is off).
    public let roots: [String]?
    /// Largest file loaded for a replacement.
    public let maxBytes: Int

    /// Creates a writer confined to `roots`.
    ///
    /// - Parameters:
    ///   - roots: Canonical directories, as `CommandPolicy.writableRoots` gives them; nil confines nothing.
    ///   - maxBytes: Largest file a replacement will load (default 1 MiB).
    public init(roots: [String]?, maxBytes: Int = 1 << 20) {
        self.roots = roots
        self.maxBytes = maxBytes
    }

    /// A writer confined exactly as `options` confines commands: the same roots the Seatbelt profile
    /// is built from, or nothing when the sandbox is off.
    public init(options: CommandRunner.Options) {
        guard options.policy.sandbox.enabled else {
            self.init(roots: nil)
            return
        }
        self.init(
            roots: options.policy.writableRoots(
                writableRoot: options.writableRoot, temporaryDirectory: FileManager.default.temporaryDirectory.path,
                userCacheDirectory: CommandRunner.userCacheDirectory,
                home: FileManager.default.homeDirectoryForCurrentUser.path))
    }

    /// Whether `path` (canonicalised) lies under one of the roots.
    public func permits(_ path: String) -> Bool {
        guard let roots else { return true }
        let canonical = CommandPolicy.canonical(path)
        return roots.contains { root in
            canonical == root || canonical.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
    }

    /// Applies `edit` to the file at `path`.
    ///
    /// - Parameters:
    ///   - edit: What to do.
    ///   - path: The file; created by `write` and `append` when absent, its directory must exist.
    /// - Returns: What happened.
    /// - Throws: `Failure`, or a file-system error from the write.
    public func apply(_ edit: Edit, to path: String) throws -> Result {
        guard permits(path) else { throw Failure.outsideWritableSet(path: path, roots: roots ?? []) }
        let url = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        if exists, isDirectory.boolValue { throw Failure.isDirectory(path) }
        guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { throw Failure.noParent(path) }
        let before = exists ? try Data(contentsOf: url) : Data()
        var line: Int?
        let after: Data
        switch edit {
        case .write(let content):
            after = Data(content.utf8)
        case .append(let content):
            after = before + Data(content.utf8)
        case .replace(let find, let replacement):
            guard before.count <= maxBytes else {
                throw Failure.tooLarge(path: path, bytes: before.count, limit: maxBytes)
            }
            guard !before.contains(0) else { throw Failure.binary(path) }
            let text = String(decoding: before, as: UTF8.self)
            let ranges = text.ranges(of: find)
            guard let range = ranges.first, !find.isEmpty else { throw Failure.notFound(find: find) }
            guard ranges.count == 1 else { throw Failure.ambiguous(find: find, count: ranges.count) }
            line = text[..<range.lowerBound].count(where: { $0 == "\n" }) + 1
            after = Data(text.replacingCharacters(in: range, with: replacement).utf8)
        }
        try after.write(to: url)
        return Result(
            path: path, mode: edit.mode, created: !exists, bytesBefore: before.count, bytesAfter: after.count,
            line: line)
    }
}
