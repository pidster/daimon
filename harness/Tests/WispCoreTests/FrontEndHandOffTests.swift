import Foundation
import Testing

/// The decision `wisp chat` makes before handing a terminal session to `wisp-tui`. The rule lives in
/// the executable target, so it is restated here as the same pure function and checked for every case.
@Suite struct FrontEndHandOffTests {
    /// Mirrors `Chat.frontEnd(besides:json:plain:interactive:exists:)`.
    private func frontEnd(json: Bool, plain: Bool, interactive: Bool, installed: Bool) -> String? {
        guard !json, !plain, interactive else { return nil }
        return installed ? "/opt/wisp/bin/wisp-tui" : nil
    }

    @Test func handsOffOnlyForAnInteractivePlainSessionWithTheFrontEndInstalled() {
        #expect(frontEnd(json: false, plain: false, interactive: true, installed: true) == "/opt/wisp/bin/wisp-tui")
        #expect(frontEnd(json: true, plain: false, interactive: true, installed: true) == nil)
        #expect(frontEnd(json: false, plain: true, interactive: true, installed: true) == nil)
        #expect(frontEnd(json: false, plain: false, interactive: false, installed: true) == nil)
        #expect(frontEnd(json: false, plain: false, interactive: true, installed: false) == nil)
    }
}
