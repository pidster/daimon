import Synchronization
import Testing

@testable import WispCore

@Suite struct KnownSafeCommandsTests {
    /// Counts the commands it is asked about, and calls each moderate.
    final class CountingClassifier: RiskClassifier {
        let asked = Mutex(0)

        func classify(command: String, workingDirectory: String) async -> RiskAssessment {
            asked.withLock { $0 += 1 }
            return RiskAssessment(level: .moderate, reasons: ["model"], sources: ["model"])
        }
    }

    @Test func everyPatternCompiles() {
        #expect(KnownSafeCommands.patternsCompile)
    }

    @Test func readOnlyCommandsAreKnownSafe() {
        for command in [
            "ls -la", "pwd", "cd /Users/me/src/app", "cd \"$HOME/src/my app\"", "git status", "git status 2>&1",
            "git --no-pager log --oneline -20", "git diff --stat HEAD~1", "git branch -a", "git branch --show-current",
            "git config --get user.name", "NO_COLOR=1 git log -5 2>/dev/null", "grep -rn 'func ' Sources",
            "rg -l Config Sources", "find . -type f -name '*.rs'", "head -40 CHANGELOG.md", "tail -n 100 build.log",
            "wc -l Sources/App.swift", "du -sh node_modules", "jq '.dependencies' package.json", "echo \"---\"",
            "printf '%s\\n' done", "set -o pipefail", "set -euo pipefail", "swift --version", "cargo --version",
            "xcrun --find swift", "xcode-select -p", "brew list", "pip list", "ps aux", "top -l 1 -n 5",
            "sysctl hw.memsize", "pmset -g batt", "diskutil list", "defaults read com.apple.dock",
            "plutil -p Info.plist", "codesign -dv /Applications/Safari.app", "sort names.txt", "uniq -c",
            "awk '{print $1}' access.log", "date +%Y-%m-%d", "sleep 2", "command -v python3", "[ -f Package.swift ]",
            "cat /etc/hosts", "ls ~/Downloads >/dev/null",
        ] {
            #expect(KnownSafeCommands.contains(command), "\(command)")
        }
    }

    @Test func commandsThatWriteRunOrReadSecretsAreNot() {
        for command in [
            // Writes a file, or runs a program.
            "ls > files.txt", "git log >> notes.txt", "find . -name '*.o' -delete", "find . -exec rm {} +",
            "find . -name x -fprint out", "sort -o sorted.txt names.txt", "tree -o out.txt", "rg --pre ./x foo",
            "git diff --output=patch.diff", "git diff --ext-diff", "git grep -O foo", "less '+!rm x' file",
            "man -P ./pager ls", "awk '{ system(\"rm \" $1) }' list", "awk '{ print | \"sh\" }' list",
            "codesign -dv -s me App.app", "file -C -m magic", "awk -f script.awk data",
            // Runs something else inside it.
            "echo $(rm -rf x)", "echo `whoami`", "diff <(ls a) <(ls b)",
            // Changes state, even if the verb reads elsewhere.
            "git branch feature", "git -c core.pager=./x log", "hostname newname", "date 0101000026",
            "sysctl -w kern.maxfiles=1", "sysctl kern.maxfiles=1", "ifconfig en0 down", "plutil -convert xml1 x",
            "PATH=/tmp/evil:$PATH ls", "DYLD_INSERT_LIBRARIES=x.dylib ls", "PAGER=./x git log",
            // Names something sensitive: its output reaches the model.
            "cat .env", "cat .env.local", "grep -r password config", "cat ~/.zsh_history", "ls ~/Library/Messages",
            "head server.pem", "cat secrets.json", "printenv GITHUB_TOKEN", "sqlite3 --version app.db",
            // Not on the list at all.
            "rm file", "swift build", "make", "npm install", "curl https://example.com", "python3 script.py",
            "sed -n 1p file", "xxd a b",
        ] {
            #expect(!KnownSafeCommands.contains(command), "\(command)")
        }
    }

    @Test func theRulesMarkKnownSafeCommandsAndNeverOverrideARiskyRule() async {
        let known = await RuleRiskClassifier.standard.classify(command: "git status 2>&1", workingDirectory: "/tmp")
        #expect(known.isKnownSafe && known.reasons == [RuleRiskClassifier.knownSafe])
        let unknown = await RuleRiskClassifier.standard.classify(command: "frobnicate", workingDirectory: "/tmp")
        #expect(!unknown.isKnownSafe && unknown.reasons == [RuleRiskClassifier.noSignals])
        // `cat` is on the list, but the credentials rule matches first.
        let secret = await RuleRiskClassifier.standard.classify(command: "cat ~/.ssh/id_rsa", workingDirectory: "/tmp")
        #expect(secret.level == .dangerous && !secret.isKnownSafe)
    }

    @Test func redirectingToDevNullNoLongerCountsAsWritingAFile() async {
        for command in ["ls 2>/dev/null", "git status &>/dev/null", "make >/dev/null 2>&1"] {
            let verdict = await RuleRiskClassifier.standard.classify(command: command, workingDirectory: "/tmp")
            #expect(!verdict.reasons.contains("writes to a file"), "\(command)")
        }
        let write = await RuleRiskClassifier.standard.classify(command: "ls > /dev/nullx", workingDirectory: "/tmp")
        #expect(write.reasons.contains("writes to a file"))
    }

    @Test func aCompositeAsksNoModelAboutAKnownSafeCommand() async {
        let model = CountingClassifier()
        let composite = CompositeRiskClassifier([RuleRiskClassifier.standard, model])
        let known = await composite.classify(command: "git log --oneline", workingDirectory: "/tmp")
        #expect(known.level == .safe && known.sources == ["rules"] && model.asked.withLock { $0 } == 0)
        let unknown = await composite.classify(command: "frobnicate --all", workingDirectory: "/tmp")
        #expect(
            unknown.level == .moderate && unknown.sources == ["rules", "model"] && model.asked.withLock { $0 } == 1)
    }

    @Test func aKnownSafeCommandIsNotTimedAsAModelCall() async {
        let stats = CallStats()
        let timed = TimedRiskClassifier(
            CompositeRiskClassifier([RuleRiskClassifier.standard, CountingClassifier()]), name: "coreml", stats: stats)
        _ = await timed.classify(command: "git status", workingDirectory: "/tmp")
        #expect(stats.total == 0)
        _ = await timed.classify(command: "frobnicate", workingDirectory: "/tmp")
        #expect(stats.total == 1)
    }
}
