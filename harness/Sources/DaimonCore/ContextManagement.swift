import FoundationModels

/// How an `Agent` reacts when a prompt no longer fits the model's context window.
public enum ContextPolicy: Sendable, Equatable {
    /// Surface `LanguageModelError.contextSizeExceeded` to the caller.
    case failFast
    /// Rebuild the session keeping the instructions and the last `keepTurns` turns, then retry once.
    case condense(keepTurns: Int)

    /// Keep the last four turns.
    public static let `default` = ContextPolicy.condense(keepTurns: 4)
}

extension Transcript {
    /// A copy that keeps the leading instructions entry, if any, and only the last `keepTurns` turns.
    ///
    /// A turn starts at a `.prompt` entry and runs to the next prompt, so tool
    /// calls and outputs stay with the prompt that caused them. Entries before
    /// the first prompt other than instructions are dropped.
    public func condensed(keepTurns: Int) -> Transcript {
        precondition(keepTurns >= 0, "keepTurns must not be negative")
        var kept: [Entry] = []
        if let first = self.first, case .instructions = first {
            kept.append(first)
        }
        var turns: [[Entry]] = []
        for entry in self {
            switch entry {
            case .instructions:
                continue
            case .prompt:
                turns.append([entry])
            default:
                if turns.isEmpty { continue }
                turns[turns.count - 1].append(entry)
            }
        }
        kept.append(contentsOf: turns.suffix(keepTurns).flatMap { $0 })
        return Transcript(entries: kept)
    }

    /// Number of turns, counted as prompt entries.
    public var turnCount: Int {
        reduce(0) { count, entry in
            if case .prompt = entry { return count + 1 }
            return count
        }
    }
}
