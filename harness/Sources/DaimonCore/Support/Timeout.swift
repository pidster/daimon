import Foundation

/// Bounded waits. The safe default for anything that asks a human: an unanswered question is
/// not an answer, so callers turn `Failure.elapsed` into a denial.
public enum Timeout {
    /// Why a bounded wait ended without a result.
    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// Nothing arrived within the duration.
        case elapsed(Duration)

        /// Human-readable explanation.
        public var description: String {
            switch self {
            case .elapsed(let duration): "no answer within \(duration)"
            }
        }
    }

    /// Runs `operation` and gives up after `duration`, cancelling it.
    ///
    /// - Throws: `Failure.elapsed` on timeout, or whatever `operation` throws.
    public static func run<T: Sendable>(
        _ duration: Duration, _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: duration)
                throw Failure.elapsed(duration)
            }
            guard let first = try await group.next() else { throw Failure.elapsed(duration) }
            group.cancelAll()
            return first
        }
    }

    /// `run` when `duration` is set; runs `operation` unbounded when it is nil.
    public static func run<T: Sendable>(
        _ duration: Duration?, _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard let duration else { return try await operation() }
        return try await run(duration, operation)
    }
}
