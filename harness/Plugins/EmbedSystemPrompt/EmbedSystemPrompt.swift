import Foundation
import PackagePlugin

/// Embeds `Resources/system-prompt.md` into `DaimonCore` as a Swift string constant at build time, so
/// the prompt is a plain text file in the source tree and the product stays one binary with nothing to
/// ship beside it. The text goes into a raw multi-line literal, so it needs no escaping; the one
/// sequence that would end the literal early is refused.
@main
struct EmbedSystemPrompt: BuildToolPlugin {
    /// The shell that turns the text file into Swift; `$1` is the input, `$2` the output.
    static let script = """
        set -eu
        if grep -q '\"\"\"#' "$1"; then echo "system-prompt.md must not contain \\"\\"\\"#" >&2; exit 1; fi
        {
            printf '// Generated from Resources/system-prompt.md by the EmbedSystemPrompt plugin. Do not edit.\\n'
            printf 'enum SystemPromptText {\\n    static let text = #\"\"\"\\n'
            cat "$1"
            printf '\"\"\"#\\n}\\n'
        } > "$2"
        """

    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        guard let target = target as? SourceModuleTarget else { return [] }
        let input = target.directoryURL.appending(path: "Resources/system-prompt.md")
        let output = context.pluginWorkDirectoryURL.appending(path: "SystemPromptText.swift")
        return [
            .buildCommand(
                displayName: "Embed system-prompt.md",
                executable: URL(filePath: "/bin/sh"),
                arguments: ["-c", Self.script, "embed-system-prompt", input.path(), output.path()],
                inputFiles: [input],
                outputFiles: [output]
            )
        ]
    }
}
