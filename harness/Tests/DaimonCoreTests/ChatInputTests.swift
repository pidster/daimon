import Testing

@testable import DaimonCore

@Suite struct ChatInputTests {
    @Test func parsesCommandsAndMessages() {
        #expect(ChatInput(line: "/quit") == .quit)
        #expect(ChatInput(line: " /exit ") == .quit)
        #expect(ChatInput(line: "exit") == .quit)
        #expect(ChatInput(line: " Quit ") == .quit)
        #expect(ChatInput(line: "q") == .quit)
        #expect(ChatInput(line: "exit now") == .message("exit now"))
        #expect(ChatInput(line: "/help") == .help)
        #expect(ChatInput(line: "/?") == .help)
        #expect(ChatInput(line: "/tools") == .tools)
        #expect(ChatInput(line: "/tokens") == .tokens)
        #expect(ChatInput(line: "/new") == .new)
        #expect(ChatInput(line: "/save") == .save(nil))
        #expect(ChatInput(line: "/save  my-chat ") == .save("my-chat"))
        #expect(ChatInput(line: "/frobnicate now") == .unknown("frobnicate"))
        #expect(ChatInput(line: "  hello there ") == .message("hello there"))
        #expect(ChatInput(line: "") == .message(""))
    }
}
