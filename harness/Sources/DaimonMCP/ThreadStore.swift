import DaimonCore
import Foundation
import FoundationModels

/// What `DaimonServer.respond` needs from a thread, so tests can substitute one without a model.
public protocol RespondingThread: Sendable {
    /// Sends one user turn and returns the reply and whether older turns were dropped to fit.
    func respond(to prompt: String) async throws -> (text: String, condensed: Bool)
}

/// One conversation with the on-device model, addressable by id across MCP calls.
///
/// An actor so that calls on the same thread serialise (a session cannot answer
/// two prompts at once) while different threads run concurrently.
public actor ConversationThread: RespondingThread {
    /// The identifier clients pass as `thread_id`.
    public nonisolated let id: String
    /// The conversation; isolated to this actor because it is not `Sendable`.
    private let agent: Agent

    /// Wraps an agent opened by `Session.openConversation`.
    public init(id: String, agent: Agent) {
        self.id = id
        self.agent = agent
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

    /// The outcome of `findOrCreate`.
    public struct Opened: Sendable {
        /// The thread, found or new.
        public let thread: Thread
        /// Whether it was created by this call.
        public let created: Bool
        /// The id evicted to make room, if any.
        public let evicted: String?
    }

    /// Creates and stores a thread, evicting the least recently used one if at capacity.
    ///
    /// - Returns: The thread and the evicted id, if any.
    /// - Throws: `Failure.alreadyExists`, or whatever `make` throws.
    public func create(id: String, _ make: () throws -> Thread) throws -> (thread: Thread, evicted: String?) {
        guard threads[id] == nil else { throw Failure.alreadyExists(id) }
        let thread = try make()
        var evicted: String?
        if threads.count >= capacity, let oldest = recency.first {
            threads[oldest] = nil
            recency.removeFirst()
            evicted = oldest
        }
        threads[id] = thread
        recency.append(id)
        return (thread, evicted)
    }

    /// Finds the thread with `id`, marking it used, or creates it in one actor step so concurrent
    /// callers naming the same new id cannot race each other into `alreadyExists`.
    ///
    /// - Throws: Whatever `make` throws.
    public func findOrCreate(id: String, _ make: () throws -> Thread) throws -> Opened {
        if let existing = find(id) { return Opened(thread: existing, created: false, evicted: nil) }
        let made = try create(id: id, make)
        return Opened(thread: made.thread, created: true, evicted: made.evicted)
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
