import Foundation
import Testing

@testable import DaimonCore

@Suite struct PromptingTests {
    @Test func rendersTheLayersInOrderUnderHeadings() {
        let all = Prompting(systemPromptExtension: " Prefer British spelling. ", instructions: "Answer in French.")
        let expected =
            Prompting.systemPrompt
            + "\n\nGuidance for this Mac:\nPrefer British spelling.\n\nInstructions for this conversation:\nAnswer in French."
        #expect(all.rendered == expected)
    }

    @Test func aConversationWithoutToolsIsToldSo() {
        let text = Prompting(instructions: "x").rendered(toolsAvailable: false)
        #expect(text.contains("This conversation has no tools"))
        #expect(text.hasSuffix("Instructions for this conversation:\nx"))
        #expect(!Prompting().rendered.contains("no tools"))
    }

    @Test func emptyLayersAreOmittedAndTheSystemPromptCannotBe() {
        #expect(Prompting().rendered == Prompting.systemPrompt)
        #expect(Prompting(systemPromptExtension: "  \n", instructions: "").rendered == Prompting.systemPrompt)
        #expect(
            Prompting(instructions: "x").rendered == Prompting.systemPrompt
                + "\n\nInstructions for this conversation:\nx")
        #expect(Prompting.systemPrompt.contains("daimon"))
        #expect(Prompting.systemPrompt.utf8.count < 600, "keep layer 1 small for a 4k window")
    }

    /// The embedded text is the resource file, so editing the file is editing the prompt.
    @Test func systemPromptIsTheResourceFile() throws {
        let file = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/DaimonCore/Resources/system-prompt.md")
        let onDisk = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(Prompting.systemPrompt == onDisk)
    }
}
