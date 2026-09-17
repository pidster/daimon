import Foundation
import FoundationModels

/// Saves and loads conversation transcripts as JSON files named by the user.
public struct TranscriptStore: Sendable {
    /// Why a transcript name or file was rejected.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// The name contains characters outside `[A-Za-z0-9._-]` or is too long.
        case invalidName(String)
        /// No transcript has this name.
        case notFound(String)

        /// Human-readable explanation.
        public var description: String {
            switch self {
            case .invalidName(let name): "invalid transcript name '\(name)': use 1-64 of [A-Za-z0-9._-]"
            case .notFound(let name): "no saved transcript named '\(name)'"
            }
        }
    }

    /// The directory holding `<name>.json` files.
    public let directory: URL

    /// Creates a store over `directory`; the directory must already exist to save.
    public init(directory: URL) {
        self.directory = directory
    }

    /// The file a name maps to.
    ///
    /// - Throws: `Failure.invalidName`.
    public func url(for name: String) throws -> URL {
        try Self.validate(name)
        return directory.appending(path: "\(name).json")
    }

    /// Writes `transcript` under `name`, replacing any existing file.
    ///
    /// - Throws: `Failure.invalidName` or file-system errors.
    public func save(_ transcript: Transcript, as name: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(transcript).write(to: try url(for: name), options: .atomic)
    }

    /// Reads the transcript saved under `name`.
    ///
    /// - Throws: `Failure.invalidName`, `Failure.notFound`, or decoding errors.
    public func load(_ name: String) throws -> Transcript {
        let file = try url(for: name)
        guard FileManager.default.fileExists(atPath: file.path) else { throw Failure.notFound(name) }
        return try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: file))
    }

    /// Names of saved transcripts, sorted.
    public func list() throws -> [String] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    /// Validates a name: 1 to 64 characters from `[A-Za-z0-9._-]`.
    ///
    /// - Throws: `Failure.invalidName`.
    public static func validate(_ name: String) throws {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard !name.isEmpty, name.count <= 64, name.unicodeScalars.allSatisfy(allowed.contains) else {
            throw Failure.invalidName(name)
        }
    }
}
