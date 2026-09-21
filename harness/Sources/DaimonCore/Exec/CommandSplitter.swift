import Foundation

/// One simple command inside a shell line, with the key its approval is stored under.
public struct SimpleCommand: Equatable, Sendable {
    /// The segment as written, trimmed.
    public var text: String
    /// The program that actually runs, after unwrapping prefixes such as `sudo`, `env`, `time`, or
    /// `VAR=value`, and without its directory.
    public var executable: String
    /// The verb, for a program in `Multiplexers` (`commit` in `git commit -q`); nil otherwise.
    public var subcommand: String?
    /// The approval key: the executable, its verb when it has one, and ` *`, so arguments never
    /// matter to remembering but `git commit *` and `git push *` are remembered apart.
    public var pattern: String { "\(executable)\(subcommand.map { " " + $0 } ?? "") *" }
    /// The pattern before verbs were part of it (`git *`); a standing approval stored under it is
    /// still honoured so an existing approvals file keeps working.
    public var legacyPattern: String? { subcommand == nil ? nil : "\(executable) *" }

    /// Creates a simple command.
    public init(text: String, executable: String, subcommand: String? = nil) {
        self.text = text
        self.executable = executable
        self.subcommand = subcommand
    }
}

/// Splits a shell line into the simple commands it would run.
///
/// Understands single and double quotes, backslash escapes, the operators `;`, `&&`, `||`, `|`, `&`
/// and newlines, and looks inside `$(…)`, backticks, and `(…)` subshells so a command hidden there is
/// checked too. It is a policy pre-pass, not a shell: anything it cannot parse stays in the enclosing
/// segment's text, where the deny patterns and classifier still see it.
public enum CommandSplitter {
    /// Wrapper options that take a separate value, whose value must be skipped too.
    static let valueOptions: Set<String> = [
        "-n", "-u", "-g", "-s", "-k", "-C", "-i", "-p", "-P", "-I", "-L", "-a", "-c",
    ]

    /// Prefixes that run another command; the real executable follows them.
    static let wrappers: Set<String> = [
        "sudo", "doas", "env", "nice", "nohup", "time", "timeout", "xargs", "command", "exec", "builtin", "caffeinate",
        "stdbuf", "ionice", "chronic",
    ]

    /// The simple commands in `line`, in order, including those nested in substitutions.
    public static func split(_ line: String) -> [SimpleCommand] {
        var commands: [SimpleCommand] = []
        for segment in segments(of: line) {
            let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            for nested in substitutions(in: trimmed) {
                commands += split(nested)
            }
            if let essential = essential(of: trimmed) {
                commands.append(
                    SimpleCommand(text: trimmed, executable: essential.executable, subcommand: essential.subcommand))
            }
        }
        return commands
    }

    /// Top-level segments split on control operators outside quotes and parentheses.
    static func segments(of line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var chars = Array(line)
        var index = 0
        var inSingle = false
        var inDouble = false
        var depth = 0
        var inBacktick = false
        while index < chars.count {
            let char = chars[index]
            let next: Character? = index + 1 < chars.count ? chars[index + 1] : nil
            if inSingle {
                current.append(char)
                if char == "'" { inSingle = false }
            } else if inDouble {
                current.append(char)
                if char == "\\", let next { current.append(next); index += 1 } else if char == "\"" { inDouble = false }
            } else if inBacktick {
                current.append(char)
                if char == "`" { inBacktick = false }
            } else {
                switch char {
                case "\\":
                    current.append(char)
                    if let next { current.append(next); index += 1 }
                case "'": inSingle = true; current.append(char)
                case "\"": inDouble = true; current.append(char)
                case "`": inBacktick = true; current.append(char)
                case "(": depth += 1; current.append(char)
                case ")": depth = max(0, depth - 1); current.append(char)
                case ";",
                    "\n" where depth == 0:
                    result.append(current); current = ""
                case "|" where depth == 0:
                    if next == "|" { index += 1 }
                    result.append(current); current = ""
                case "&" where depth == 0:
                    if next == "&" {
                        index += 1
                        result.append(current); current = ""
                    } else if next == ">" || (current.last == ">") {
                        current.append(char)  // redirection such as `2>&1` or `&>`
                    } else {
                        result.append(current); current = ""  // background job
                    }
                default: current.append(char)
                }
            }
            index += 1
        }
        result.append(current)
        chars.removeAll()
        return result
    }

    /// The bodies of `$(…)`, backtick, and top-level `(…)` groups in `segment`, outermost only.
    static func substitutions(in segment: String) -> [String] {
        var bodies: [String] = []
        let chars = Array(segment)
        var index = 0
        var inSingle = false
        while index < chars.count {
            let char = chars[index]
            if inSingle {
                if char == "'" { inSingle = false }
                index += 1
                continue
            }
            if char == "'" {
                inSingle = true
                index += 1
                continue
            }
            if char == "\\" { index += 2; continue }
            if char == "`" {
                if let close = chars[(index + 1)...].firstIndex(of: "`") {
                    bodies.append(String(chars[(index + 1)..<close]))
                    index = close + 1
                    continue
                }
            }
            let isDollarParen = char == "$" && index + 1 < chars.count && chars[index + 1] == "("
            if isDollarParen || char == "(" {
                let open = isDollarParen ? index + 1 : index
                var depth = 0
                var cursor = open
                while cursor < chars.count {
                    if chars[cursor] == "(" {
                        depth += 1
                    } else if chars[cursor] == ")" {
                        depth -= 1
                        if depth == 0 { break }
                    }
                    cursor += 1
                }
                if cursor < chars.count {
                    bodies.append(String(chars[(open + 1)..<cursor]))
                    index = cursor + 1
                    continue
                }
            }
            index += 1
        }
        return bodies
    }

    /// The program a segment runs, or nil for a bare subshell or assignment-only segment.
    static func executable(of segment: String) -> String? { essential(of: segment)?.executable }

    /// The program and, for a multiplexer, its verb: the first word after the program that is not an
    /// option, an option's value, or a toolchain selector such as `+nightly`. `git -C dir status`
    /// gives `status`; `git --version` gives no verb.
    static func essential(of segment: String) -> (executable: String, subcommand: String?)? {
        guard let (name, rest) = program(of: segment) else { return nil }
        guard Multiplexers.programs.contains(name) else { return (name, nil) }
        var words = rest
        while let word = words.first {
            words.removeFirst()
            if word.hasPrefix("-") {
                if valueOptions.contains(word), !words.isEmpty { words.removeFirst() }
                continue
            }
            if word.hasPrefix("+") { continue }
            let isVerb =
                word.first?.isLetter == true && word.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            return (name, isVerb ? word : nil)
        }
        return (name, nil)
    }

    /// The program name and the words after it, with wrappers and assignments unwrapped.
    private static func program(of segment: String) -> (String, [String])? {
        var words = words(of: segment)
        while let first = words.first {
            if first.hasPrefix("(") || first.hasPrefix("$(") || first.hasPrefix("`") { return nil }
            let isAssignment =
                first.contains("=") && !first.hasPrefix("=")
                && first.split(separator: "=", maxSplits: 1)[0].allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
            if isAssignment {
                words.removeFirst()
                continue
            }
            let name = String(first.split(separator: "/").last ?? Substring(first))
            if wrappers.contains(name) {
                words.removeFirst()
                // Skip a wrapper's own options such as `sudo -u root`, `nice -n 10`, or `timeout 5`.
                while let option = words.first, option.hasPrefix("-") || (name == "timeout" && Double(option) != nil) {
                    words.removeFirst()
                    if Self.valueOptions.contains(option), !words.isEmpty { words.removeFirst() }
                }
                continue
            }
            words.removeFirst()
            return (name, words)
        }
        return nil
    }

    /// Whitespace-separated words, honouring quotes so an argument with spaces stays one word.
    static func words(of segment: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        var previousWasEscape = false
        for char in segment {
            if previousWasEscape {
                current.append(char)
                previousWasEscape = false
            } else if char == "\\" {
                previousWasEscape = true
            } else if inSingle {
                if char == "'" { inSingle = false } else { current.append(char) }
            } else if inDouble {
                if char == "\"" { inDouble = false } else { current.append(char) }
            } else if char == "'" {
                inSingle = true
            } else if char == "\"" {
                inDouble = true
            } else if char.isWhitespace {
                if !current.isEmpty { result.append(current); current = "" }
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
