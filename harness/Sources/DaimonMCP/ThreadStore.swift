import DaimonCore
import Foundation
import FoundationModels

/// One conversation with the on-device model, addressable by id across MCP calls.
///
/// An actor so that calls on the same thread serialise (a session cannot answer
/// two prompts at once) while different threads run concurrently.
public actor ConversationThread {
    /// The identifier clients pass as `thread_id`.
    public nonisolated let id: String
    /// The conversation; isolated to this actor because it is not `Sendable`.
    private let agent: Agent

    /// Creates a thread with its own model session.
    ///
    /// - Throws: `AgentError.modelUnavailable` if the on-device model cannot be used.
    init(id: String, instructions: String, tools: [any Tool]) throws {
        self.id = id
        agent = try Agent(instructions: instructions, tools: tools)
    }

    /// Sends one user turn on this thread's session.
    ///
    /// - Returns: The reply and whether older turns were dropped to fit the context window.
    public func respond(to prompt: String) async throws -> (text: String, condensed: Bool) {
        let before = agent.condensations
        let text = try await agent.respond(to: prompt)
        return (text, agent.condensations > before)
    }
}

/// Keeps live threads by id with a bounded, least-recently-used capacity.
///
/// Generic over the thread type so the eviction policy is testable without a model.
public actor ThreadStore<Thread: Sendable> {
    /// Why a thread could not be opened or found.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// A thread with this id already exists.
        case alreadyExists(String)
        /// No thread has this id.
        case notFound(String)

        /// Human-readable explanation.
        public var description: String {
            switch self {
            case .alreadyExists(let id): "thread already exists: \(id)"
            case .notFound(let id): "no such thread: \(id)"
            }
        }
    }

    /// Maximum live threads before eviction.
    private let capacity: Int
    /// Live threads by id.
    private var threads: [String: Thread] = [:]
    /// Ids ordered least recently used first.
    private var recency: [String] = []

    /// Creates a store that keeps at most `capacity` threads, evicting the least recently used.
    public init(capacity: Int = 32) {
        precondition(capacity > 0, "capacity must be positive")
        self.capacity = capacity
    }

    /// Ids of live threads, most recently used first.
    public var ids: [String] { recency.reversed() }

    /// Creates and stores a thread, evicting the least recently used one if at capacity.
    ///
    /// - Throws: `Failure.alreadyExists`, or whatever `make` throws.
    public func create(id: String, _ make: () throws -> Thread) throws -> Thread {
        guard threads[id] == nil else { throw Failure.alreadyExists(id) }
        let thread = try make()
        if threads.count >= capacity, let oldest = recency.first {
            threads[oldest] = nil
            recency.removeFirst()
        }
        threads[id] = thread
        recency.append(id)
        return thread
    }

    /// Returns the thread with `id`, marking it most recently used, or nil.
    public func find(_ id: String) -> Thread? {
        guard let thread = threads[id] else { return nil }
        recency.removeAll { $0 == id }
        recency.append(id)
        return thread
    }

    /// Removes the thread with `id`.
    ///
    /// - Throws: `Failure.notFound` if there is none.
    public func close(_ id: String) throws {
        guard threads.removeValue(forKey: id) != nil else { throw Failure.notFound(id) }
        recency.removeAll { $0 == id }
    }
}
