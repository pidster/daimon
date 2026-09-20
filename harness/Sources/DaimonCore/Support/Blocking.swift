import Foundation
import Synchronization

/// Runs a short async operation to completion from synchronous code.
///
/// `ModelSelection.resolve` is synchronous because agents are created synchronously (the MCP thread
/// store builds a thread inside one actor step), while checking a runtime or loading an asset is
/// async. This is the one bridge; use it only for local, bounded work such as a tags request or a
/// tokenizer load, never for generation.
public enum Blocking {
    /// Runs `operation` on a detached task and waits for its result.
    ///
    /// - Throws: Whatever `operation` throws.
    public static func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
        let slot = Slot<T>()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let result: Result<T, any Error>
            do { result = .success(try await operation()) } catch { result = .failure(error) }
            slot.result.withLock { $0 = result }
            done.signal()
        }
        done.wait()
        guard let result = slot.result.withLock({ $0 }) else { throw Failure.noResult }
        return try result.get()
    }

    /// Why a blocking run produced nothing; cannot happen unless the task was lost.
    public enum Failure: Error, CustomStringConvertible {
        /// The task finished without storing a result.
        case noResult

        /// Human-readable explanation.
        public var description: String {
            switch self {
            case .noResult: "blocking operation produced no result"
            }
        }
    }

    /// A one-shot result slot.
    private final class Slot<T: Sendable>: Sendable {
        let result = Mutex<Result<T, any Error>?>(nil)
    }
}
