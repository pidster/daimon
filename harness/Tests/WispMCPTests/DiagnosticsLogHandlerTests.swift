import Logging
import Testing

@testable import WispMCP

@Suite struct DiagnosticsLogHandlerTests {
    @Test func forwardsEveryLevelAndCarriesMetadata() {
        var handler = DiagnosticsLogHandler()
        handler[metadataKey: "k"] = "v"
        #expect(handler[metadataKey: "k"] == "v")
        #expect(handler.logLevel == .info)
        // Forwarding goes to unified logging, which cannot be read back here; the assertion is that no
        // level traps and both entry points accept an event.
        for level in Logger.Level.allCases {
            handler.log(
                level: level, message: "m", metadata: ["a": "b"], source: "s", file: "f", function: "fn", line: 1)
        }
        handler.log(
            event: LogEvent(
                level: .error, message: "boom", metadata: nil, source: "s", file: "f", function: "fn", line: 2))
        let logger = DiagnosticsLogHandler.logger()
        #expect(logger.label == "wisp.mcp")
        logger.info("through the logger")
    }
}
