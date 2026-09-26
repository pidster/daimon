/// A question with a list of answers for a face to offer: a numbered list in the plain chat, a picker in
/// `wisp-tui` ([ADR 0040](../../../../docs/decisions/0040-config-from-chat.md)). Only chat commands ask;
/// the model never does.
public struct ChatChoice: Equatable, Sendable {
    /// One answer.
    public struct Option: Equatable, Sendable {
        /// What choosing it answers.
        public var value: String
        /// What it is called, often the value itself.
        public var label: String
        /// A line about it, or empty.
        public var detail: String

        /// Creates an option.
        public init(value: String, label: String? = nil, detail: String = "") {
            self.value = value
            self.label = label ?? value
            self.detail = detail
        }
    }

    /// The question.
    public var title: String
    /// The answers on offer; empty when only typed text will do.
    public var options: [Option]
    /// The value in force now, marked in the list.
    public var current: String?
    /// Whether a typed value is taken as well as an option.
    public var acceptsText: Bool

    /// Creates a choice.
    public init(title: String, options: [Option], current: String? = nil, acceptsText: Bool = false) {
        self.title = title
        self.options = options
        self.current = current
        self.acceptsText = acceptsText
    }

    /// Reads an answer typed at a numbered list: a number picks that option, other text is taken as
    /// typed when the choice accepts text, and an empty line, a slash command, or anything else is no
    /// answer.
    public func answer(typed line: String) -> String? {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !text.hasPrefix("/") else { return nil }
        if let number = Int(text), options.indices.contains(number - 1) { return options[number - 1].value }
        if let option = options.first(where: { $0.value == text }) { return option.value }
        return acceptsText ? text : nil
    }

    /// The lines of a numbered list: the title, one line per option with the current one marked, and
    /// what to type.
    public var numbered: [String] {
        let width = String(options.count).count
        var lines = [title]
        for (index, option) in options.enumerated() {
            let number = String(index + 1)
            let mark = option.value == current ? "*" : " "
            let detail = option.detail.isEmpty ? "" : "  \(option.detail)"
            lines.append(
                "\(mark) \(String(repeating: " ", count: width - number.count))\(number)  \(option.label)\(detail)")
        }
        let how =
            options.isEmpty
            ? "type a value, or press Enter to leave it"
            : acceptsText
                ? "type a number or a value, or press Enter to leave it" : "type a number, or press Enter to leave it"
        lines.append(how)
        return lines
    }
}
