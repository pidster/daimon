import Foundation

/// Raised when `withTimeout` gives up waiting.
public struct TimeoutError: Error, Equatable, CustomStringConvertible {
    /// How long was waited.
    public let duration: Duration

    /// Creates the error.
    public init(duration: Duration) {
        self.duration = duration
    }

    /// Human-readable explanation.
    public var description: String { "no answer within \(duration)" }
}

/// Runs `operation` and gives up after `duration`, cancelling it.
///
/// The safe default for anything that asks a human: an unanswered question is
/// not an answer, so callers turn `TimeoutError` into a denial.
///
/// - Throws: `TimeoutError` on timeout, or whatever `operation` throws.
public func withTimeout<T: Sendable>(
    _ duration: Duration, _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw TimeoutError(duration: duration)
        }
        guard let first = try await group.next() else { throw TimeoutError(duration: duration) }
        group.cancelAll()
        return first
    }
}

/// `withTimeout` when `duration` is set; runs `operation` unbounded when it is nil.
public func withOptionalTimeout<T: Sendable>(
    _ duration: Duration?, _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    guard let duration else { return try await operation() }
    return try await withTimeout(duration, operation)
}
