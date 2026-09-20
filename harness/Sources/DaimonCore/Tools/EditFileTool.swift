import Foundation
import FoundationModels

/// Lets the model write a text file: the whole file, an addition at the end, or one exact
/// replacement. Confined to the directories the sandbox lets commands write under, cleared by the
/// approval gate as `edit_file <mode> <path>`, and recorded as `file.write`
/// ([ADR 0024](../../../../docs/decisions/0024-edit-file.md)).
public struct EditFileTool: DaimonTool {
    /// The identifier the model uses to request this tool.
    public let name = "edit_file"
    /// What the model is told this tool does.
    public let description =
        "Writes a text file: mode write replaces the whole file (creating it), append adds content at the end, "
        + "replace swaps the one exact occurrence of find with content, and nothing else changes. "
        + "Read the file first for replace."

    /// Arguments the model may supply when calling the tool.
    @Generable
    public struct Arguments {
        /// Absolute or working-directory-relative path.
        @Guide(description: "Path of the file to write.")
        public var path: String
        /// `write`, `append`, or `replace`.
        @Guide(description: "One of: write, append, replace.")
        public var mode: String
        /// The text to write, append, or put in place of `find`.
        @Guide(description: "The text to write or append, or the replacement text for replace.")
        public var content: String
        /// For `replace`, the exact text to replace; must occur once.
        @Guide(description: "For replace only: the exact existing text to replace; it must occur exactly once.")
        public var find: String?
    }

    /// Applies edits within the writable set.
    private let writer: FileWriter
    /// Asks before writing; nil never asks.
    private let approval: ApprovalGate?
    /// Where `file.write` is recorded.
    private let audit: AuditLog

    /// Confinement and approval, from the live writer.
    public var limits: String {
        let confinement =
            writer.roots.map { "Writes only under \($0.joined(separator: ", ")); elsewhere fails" }
            ?? "No write confinement (the sandbox is off)"
        return
            "\(confinement). replace loads files up to \(writer.maxBytes) bytes and needs exactly one match. "
            + "Every edit passes the risk classifier and needs the user's approval at moderate and above."
    }
    /// How to ask for it.
    public let examplePrompt =
        "Use edit_file with mode replace on /path/to/file.swift to replace exactly `let x = 1` with `let x = 2`."

    /// Creates the tool over a writer, a gate, and an audit log.
    ///
    /// - Parameters:
    ///   - writer: Applies edits within the writable set.
    ///   - approval: The gate to clear each edit with; nil never asks.
    ///   - audit: Where `file.write` events go; nil records nothing.
    public init(writer: FileWriter, approval: ApprovalGate? = nil, audit: AuditLog? = nil) {
        self.writer = writer
        self.approval = approval
        self.audit = audit ?? .disabled(session: "unaudited")
    }

    /// Clears the edit with the gate, applies it, records it, and renders what happened.
    ///
    /// Refusals and errors are returned as text so the model can react.
    ///
    /// - Parameter arguments: Path, mode, content, and for replace the text to find.
    /// - Returns: One line saying what changed, or `error: …`.
    public func call(arguments: Arguments) async -> String {
        let edit: FileWriter.Edit
        switch arguments.mode.trimmingCharacters(in: .whitespaces).lowercased() {
        case "write": edit = .write(arguments.content)
        case "append": edit = .append(arguments.content)
        case "replace":
            guard let find = arguments.find, !find.isEmpty else {
                return "error: replace needs find, the exact text to replace"
            }
            edit = .replace(find: find, replacement: arguments.content)
        default: return "error: mode must be write, append, or replace"
        }
        do {
            try await approval?.clear(
                editingFile: arguments.path, mode: edit.mode, workingDirectory: FileManager.default.currentDirectoryPath
            )
            let result = try writer.apply(edit, to: arguments.path)
            audit.record(
                .fileWrite,
                details: AuditEvent.Details.fileWrite(
                    path: result.path, mode: result.mode, created: result.created, bytesBefore: result.bytesBefore,
                    bytesAfter: result.bytesAfter))
            return result.rendered
        } catch ApprovalGate.Failure.refused(let reason) {
            return ToolOutput.error(FileWriter.Failure.notApproved(reason))
        } catch {
            return ToolOutput.error(error)
        }
    }
}
