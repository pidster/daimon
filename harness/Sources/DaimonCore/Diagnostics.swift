import Foundation
import os

/// Diagnostic logging for debugging, separate from the audit log.
///
/// Every message goes to Apple's unified logging under one subsystem with a
/// category per component (`log stream --predicate 'subsystem == "com.pidster.daimon"'`).
/// When `DAIMON_LOG` is set to `debug`, `info`, or `error`, messages at that
/// level and above are also written to stderr, which is what you want in a
/// terminal and is safe for MCP because stdout stays untouched.
public enum Diagnostics {
    /// The unified-logging subsystem.
    public static let subsystem = "com.pidster.daimon"

    /// Message severity.
    public enum Level: Int, Comparable, Sendable {
        case debug, info, error

        /// Orders by severity.
        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }

        /// Parses a `DAIMON_LOG` value; unknown values are nil.
        public init?(environmentValue: String) {
            switch environmentValue.lowercased() {
            case "debug": self = .debug
            case "info": self = .info
            case "error", "warn", "warning": self = .error
            default: return nil
            }
        }
    }

    /// Level at or above which messages are mirrored to stderr, from `DAIMON_LOG`.
    public static let stderrLevel: Level? = ProcessInfo.processInfo.environment["DAIMON_LOG"].flatMap(
        Level.init(environmentValue:))

    /// One component's logger.
    public struct Category: Sendable {
        /// The unified-logging category.
        public let name: String
        private let logger: Logger

        /// Creates a category under the daimon subsystem.
        public init(_ name: String) {
            self.name = name
            logger = Logger(subsystem: Diagnostics.subsystem, category: name)
        }

        /// Fine-grained detail, off by default in unified logging.
        public func debug(_ message: @autoclosure () -> String) { emit(.debug, message()) }
        /// Notable but expected events.
        public func info(_ message: @autoclosure () -> String) { emit(.info, message()) }
        /// Failures worth a look.
        public func error(_ message: @autoclosure () -> String) { emit(.error, message()) }

        private func emit(_ level: Level, _ message: String) {
            switch level {
            case .debug: logger.debug("\(message, privacy: .public)")
            case .info: logger.info("\(message, privacy: .public)")
            case .error: logger.error("\(message, privacy: .public)")
            }
            if let threshold = Diagnostics.stderrLevel, level >= threshold {
                FileHandle.standardError.write(Data("daimon[\(name)] \(message)\n".utf8))
            }
        }
    }

    /// Model sessions, turns, condensation.
    public static let agent = Category("agent")
    /// Tool calls and results.
    public static let tools = Category("tools")
    /// Command policy and sandbox decisions.
    public static let policy = Category("policy")
    /// The MCP server and SDK.
    public static let mcp = Category("mcp")
    /// The interactive chat loop.
    public static let chat = Category("chat")
    /// The audit log itself (write failures, rotation).
    public static let audit = Category("audit")
}
