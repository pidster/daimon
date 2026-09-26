import Foundation

/// `/config`: the effective configuration, the settings that can change, and changes to `config.json`
/// made by the person at the prompt, never by the model ([ADR 0040](../../../../docs/decisions/0040-config-from-chat.md)).
extension ChatLoop {
    /// Handles one `/config` request.
    mutating func config(_ request: ConfigRequest) async {
        switch request {
        case .show:
            guard let inspect = context.inspect else {
                io.note("the configuration is not shown here")
                return
            }
            io.print(await inspect("config"))
        case .list:
            for line in configList() { io.print(line) }
        case .set(let path?, let value?):
            change(path) { try ConfigEdit.set(path, to: value, in: $0) }
        case .unset(let path?):
            change(path) { try ConfigEdit.unset(path, in: $0) }
        case .set, .unset:
            for line in configList() { io.print(line) }
            io.note(style.muted("give the setting and the value: /config set approval.classifier coreml"))
        case .unknown(let word):
            io.note("unknown /config \(word); use /config, /config list, /config set KEY VALUE, or /config unset KEY")
        }
    }

    /// The settings as a table: each path, its value in the file or `(default)`, and what it does.
    func configList() -> [String] {
        let data = context.configFile.flatMap { try? Data(contentsOf: $0) }
        let rows = ConfigSettings.all.map { setting -> [String] in
            let current: JSONValue? = (try? ConfigEdit.current(setting.path, in: data)) ?? nil
            return [setting.path, current.map(Self.shown) ?? "(default)", setting.summary]
        }
        return TextTable.render(header: ["setting", "value", "what it does"], rows: rows)
    }

    /// A value as the table and the confirmation show it: strings bare, everything else as JSON.
    public static func shown(_ value: JSONValue) -> String {
        if let text = value.stringValue { return text }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "\(value)"
    }

    /// Applies an edit to the config file, audits it, and says what changed and when it takes effect.
    mutating func change(_ path: String, _ edit: (Data?) throws -> ConfigEdit.Outcome) {
        guard let url = context.configFile else {
            io.note("the configuration cannot be changed here")
            return
        }
        do {
            let outcome = try edit(try? Data(contentsOf: url))
            try ConfigEdit.write(outcome, to: url)
            agent.audit?.record(.configChange, details: AuditEvent.Details.configChange(outcome, source: "chat"))
            let old = outcome.old.map(Self.shown) ?? "(default)"
            let new = outcome.new.map(Self.shown) ?? "(default)"
            io.note("\(path): \(old) → \(new); saved to \(url.path), and used from the next session on")
            if let warning = outcome.warning { io.note(style.amber("note: \(warning)")) }
        } catch {
            io.note(style.ember("error: \(error)"))
        }
    }
}
