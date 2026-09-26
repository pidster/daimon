import Foundation

/// The line shown above each chat prompt: model, directory, git branch and state, approval mode, and
/// how much of the context window the conversation has used. Facts only; each part is omitted when
/// unknown.
public struct ChatStatus: Equatable, Sendable {
    /// The model selection, as spelled for `--model`.
    public var model: String
    /// The working directory, with the home directory as `~`.
    public var directory: String
    /// The git branch, or nil outside a repository.
    public var branch: String?
    /// Whether tracked files have uncommitted changes; nil when unknown.
    public var dirty: Bool?
    /// How approvals are decided: `approve at moderate`, `approve at dangerous`, `never asks`, or `--yes`.
    public var approval: String
    /// Fraction of the context window used, 0 to 1, or nil when neither side is known.
    public var contextUsed: Double?

    /// Creates a status.
    public init(
        model: String, directory: String, branch: String? = nil, dirty: Bool? = nil, approval: String,
        contextUsed: Double? = nil
    ) {
        self.model = model
        self.directory = directory
        self.branch = branch
        self.dirty = dirty
        self.approval = approval
        self.contextUsed = contextUsed
    }

    /// The line, parts separated by ` · `: facts in the main tone, the approval mode and a modest
    /// context use muted, a context past 80% in amber.
    public func rendered(style: Style) -> String {
        var parts = [style.wisp(model), style.wisp(directory)]
        if let branch { parts.append(style.wisp(branch)) }
        if let dirty { parts.append(style.wisp(dirty ? "changes" : "clean")) }
        parts.append(style.muted(approval))
        if let contextUsed {
            let text = "context \(Int((contextUsed * 100).rounded()))% used"
            parts.append(contextUsed >= 0.8 ? style.amber(text) : style.muted(text))
        }
        return parts.joined(separator: style.muted(" · "))
    }

    /// `path` with the current user's home replaced by `~`.
    public static func abbreviated(
        _ path: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path
    )
        -> String
    {
        path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// The approval mode in words.
    public static func approvalMode(threshold: ApprovalThreshold, autoApprove: Bool) -> String {
        if autoApprove { return "--yes" }
        switch threshold {
        case .never: return "never asks"
        case .level(let level): return "approve at \(level.rawValue)"
        }
    }
}

/// What git says about a directory, read cheaply: the branch from `.git/HEAD`, the dirty state from
/// `git status --porcelain` with a short timeout. Both nil outside a repository or without git.
public enum GitState {
    /// The branch and dirty state of `directory`.
    public static func read(in directory: String) -> (branch: String?, dirty: Bool?) {
        guard let root = repositoryRoot(of: directory) else { return (nil, nil) }
        let head = (try? String(contentsOfFile: gitDirectory(of: root) + "/HEAD", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let branch: String?
        if let head, head.hasPrefix("ref: refs/heads/") {
            branch = String(head.dropFirst("ref: refs/heads/".count))
        } else {
            branch = head.map { String($0.prefix(8)) }
        }
        return (branch, isDirty(root))
    }

    /// Where a repository's own git files are: `.git` itself, or, in a worktree or a submodule, where
    /// the `.git` file's `gitdir:` line points, relative to the root when it is not absolute.
    static func gitDirectory(of root: String) -> String {
        let dotGit = root + "/.git"
        guard let text = try? String(contentsOfFile: dotGit, encoding: .utf8),
            let line = text.split(separator: "\n").first, line.hasPrefix("gitdir: ")
        else { return dotGit }
        let target = line.dropFirst("gitdir: ".count).trimmingCharacters(in: .whitespaces)
        return target.hasPrefix("/") ? target : URL(fileURLWithPath: root).appending(path: target).standardized.path
    }

    /// The nearest ancestor of `directory` (itself included) holding a `.git` entry.
    static func repositoryRoot(of directory: String) -> String? {
        var url = URL(fileURLWithPath: directory)
        while true {
            if FileManager.default.fileExists(atPath: url.appending(path: ".git").path) { return url.path }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return nil }
            url = parent
        }
    }

    /// Whether `git status --porcelain` prints anything within two seconds; nil when git cannot run.
    static func isDirty(_ root: String) -> Bool? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", root, "status", "--porcelain", "--untracked-files=no"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return !data.isEmpty
    }
}
