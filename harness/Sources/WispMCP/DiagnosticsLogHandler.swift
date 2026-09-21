import Logging
import WispCore

/// Routes the MCP SDK's swift-log output into wisp's diagnostics (`mcp` category).
struct DiagnosticsLogHandler: LogHandler {
    /// Per-logger metadata, unused beyond conformance.
    var metadata: Logging.Logger.Metadata = [:]
    /// Minimum level forwarded; the SDK is chatty at trace and debug.
    var logLevel: Logging.Logger.Level = .info

    /// Metadata access required by the protocol.
    subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    /// Forwards one event at the matching diagnostics level.
    func log(event: LogEvent) {
        var text = "\(event.message)"
        if let metadata = event.metadata, !metadata.isEmpty { text += " \(metadata)" }
        if let error = event.error { text += " error=\(error)" }
        switch event.level {
        case .trace, .debug: Diagnostics.mcp.debug(text)
        case .info, .notice: Diagnostics.mcp.info(text)
        case .warning, .error, .critical: Diagnostics.mcp.error(text)
        }
    }

    /// Legacy entry point; newer swift-log calls `log(event:)`.
    func log(
        level: Logging.Logger.Level, message: Logging.Logger.Message, metadata: Logging.Logger.Metadata?,
        source: String, file: String, function: String, line: UInt
    ) {
        log(
            event: LogEvent(
                level: level, message: message, metadata: metadata, source: source, file: file, function: function,
                line: line))
    }

    /// A swift-log logger backed by this handler.
    static func logger() -> Logging.Logger {
        Logging.Logger(label: "wisp.mcp") { _ in DiagnosticsLogHandler() }
    }
}
