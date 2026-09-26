import Testing

@testable import WispCore

/// `/config`'s YAML view of the configuration.
@Suite struct YAMLTextTests {
    @Test func nestingListsAndScalarsReadAsYAML() {
        let value: JSONValue = [
            "model": "system", "maxThreads": 32, "enabled": true, "ratio": .double(0.6), "nothing": .null,
            "routing": ["ladder": ["system", "ollama:qwen3.8:27b"]],
            "tools": ["custom": [["name": "deploy", "arguments": [:]], ["name": "lint"]]],
            "empty": .array([]),
        ]
        #expect(
            YAMLText.render(value) == """
                empty: []
                enabled: true
                maxThreads: 32
                model: system
                nothing: null
                ratio: 0.6
                routing:
                  ladder:
                    - system
                    - ollama:qwen3.8:27b
                tools:
                  custom:
                    - arguments: {}
                      name: deploy
                    - name: lint
                """)
        #expect(YAMLText.render(["a": ["b": [["c", "d"]]]]) == "a:\n  b:\n    -\n      - c\n      - d")
        #expect(YAMLText.render(.object([:])) == "{}" && YAMLText.render(.double(2)) == "2.0")
    }

    @Test func stringsYAMLWouldMisreadAreQuoted() {
        for text in [
            "", "yes", "No", "null", "42", "1.5", "key: value", "note #1 later", "trailing:", " padded", "-dash",
            "*star", "say \"hi\"", "two\nlines", "{brace",
        ] {
            #expect(YAMLText.quotedIfNeeded(text).hasPrefix("\""), "\(text)")
        }
        for text in [
            "system", "ollama:qwen3.8:27b", "http://127.0.0.1:11434", "/Users/me/.wisp", "approve at moderate",
        ] {
            #expect(YAMLText.quotedIfNeeded(text) == text, "\(text)")
        }
        #expect(YAMLText.quotedIfNeeded("say \"hi\"\n") == #""say \"hi\"\n""#)
    }
}
