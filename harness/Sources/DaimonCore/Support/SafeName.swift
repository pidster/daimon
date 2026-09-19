import Foundation

/// A name safe to use as a file name or an id: 1 to 64 characters from `[A-Za-z0-9._-]`.
/// Transcript names and MCP thread ids share this rule.
public enum SafeName {
    /// The rule in words, for error messages.
    public static let rule = "1-64 characters from [A-Za-z0-9._-]"

    /// Whether `name` follows the rule.
    public static func isValid(_ name: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return !name.isEmpty && name.count <= 64 && name.unicodeScalars.allSatisfy(allowed.contains)
    }
}
