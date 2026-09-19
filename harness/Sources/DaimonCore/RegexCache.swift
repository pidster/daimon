import Foundation
import Synchronization

/// Compiles each pattern once per process; policy and rule patterns are matched on every command.
///
/// `NSRegularExpression` rather than `Regex` because it is `Sendable`, so compiled patterns can live in
/// `Sendable` classifiers and in this cache.
enum RegexCache {
    private static let cache = Mutex<[String: NSRegularExpression]>([:])

    /// The compiled expression for `pattern`, compiling on first use.
    ///
    /// - Throws: `NSRegularExpression`'s error for an invalid pattern.
    static func regex(_ pattern: String) throws -> NSRegularExpression {
        if let cached = cache.withLock({ $0[pattern] }) { return cached }
        let compiled = try NSRegularExpression(pattern: pattern)
        cache.withLock { $0[pattern] = compiled }
        return compiled
    }
}

extension NSRegularExpression {
    /// Whether the expression matches anywhere in `text`.
    func matches(anywhereIn text: String) -> Bool {
        firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
