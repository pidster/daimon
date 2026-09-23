import Foundation
import Synchronization

/// A session's recent model turns and classifier calls, kept in memory for `/stats`. The store is a
/// fixed-size ring, so a long session costs no more memory than a short one: once it is full, each new
/// call replaces the oldest. Nothing here reaches the disk; the audit log is the durable record, and
/// this is a quick view of how fast and how reliably the models are answering right now.
///
/// Every conversation of a session records into the session's store, so the MCP server's threads and
/// the chat's model switches all count.
public final class CallStats: Sendable {
    /// What was called.
    public enum Kind: String, Sendable, CaseIterable {
        /// One prompt through the conversation's model, until the reply: the framework's tool loop runs
        /// inside it, so its time includes the tools the model called and any approval it waited for.
        case turn
        /// One risk classification of a command, by the classifier `approval.classifier` names.
        case classifier
    }

    /// One call.
    public struct Call: Equatable, Sendable {
        /// What was called.
        public var kind: Kind
        /// The model for a turn (`ollama:granite4.1:8b`), the classifier for a classification (`system-model`).
        public var model: String
        /// When it started.
        public var started: Date
        /// How long it took.
        public var seconds: Double
        /// Why it failed, or nil when it succeeded.
        public var failure: String?
        /// Prompt tokens of the last request, for runtimes that report them.
        public var inputTokens: Int?

        /// Creates a call.
        public init(
            kind: Kind, model: String, started: Date, seconds: Double, failure: String? = nil, inputTokens: Int? = nil
        ) {
            self.kind = kind
            self.model = model
            self.started = started
            self.seconds = seconds
            self.failure = failure
            self.inputTokens = inputTokens
        }
    }

    /// Calls kept unless a caller asks otherwise: a few hours of busy chat, a few tens of kilobytes.
    public static let defaultCapacity = 256
    /// Longest failure text kept per call.
    static let failureLimit = 120

    /// How many calls the ring holds.
    public let capacity: Int
    private struct State {
        var ring: [Call] = []
        var next = 0
        var total = 0
    }
    private let state = Mutex(State())

    /// Creates an empty store.
    ///
    /// - Parameter capacity: Calls kept; at least one.
    public init(capacity: Int = defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    /// Records a call, replacing the oldest when the ring is full. A long failure is cut to
    /// `failureLimit` characters.
    public func record(_ call: Call) {
        var call = call
        if let failure = call.failure, failure.count > Self.failureLimit {
            call.failure = String(failure.prefix(Self.failureLimit - 1)) + "…"
        }
        let capacity = capacity
        state.withLock { state in
            if state.ring.count < capacity {
                state.ring.append(call)
            } else {
                state.ring[state.next] = call
            }
            state.next = (state.next + 1) % capacity
            state.total += 1
        }
    }

    /// The calls kept, oldest first.
    public var calls: [Call] {
        state.withLock { state in
            state.ring.count < capacity
                ? state.ring : Array(state.ring[state.next...] + state.ring[..<state.next])
        }
    }

    /// Every call recorded since the store was created, including those the ring has dropped.
    public var total: Int { state.withLock { $0.total } }

    /// The `/stats` text: a summary per kind and model over the calls kept, then the latest calls in
    /// the order they started.
    ///
    /// - Parameters:
    ///   - recent: How many of the latest calls to list.
    ///   - timeZone: The zone call times are shown in.
    /// - Returns: Lines ready to print.
    public func report(recent: Int = 8, timeZone: TimeZone = .current) -> [String] {
        let calls = calls
        let total = total
        guard !calls.isEmpty else { return ["no model or classifier calls yet"] }
        var lines = [
            total == calls.count
                ? "\(total) calls this session (the store keeps the last \(capacity))"
                : "\(total) calls this session; the last \(calls.count) are kept and summarised"
        ]
        lines.append("")
        lines += TextTable.render(
            header: ["KIND", "MODEL", "CALLS", "FAILED", "MEAN", "P50", "P95", "MAX", "TOKENS IN"],
            rows: Self.groups(calls).map { group in
                let seconds = group.calls.map(\.seconds).sorted()
                let tokens = group.calls.compactMap(\.inputTokens)
                return [
                    group.kind.rawValue, group.model, "\(group.calls.count)",
                    "\(group.calls.filter { $0.failure != nil }.count)",
                    Self.format(seconds.reduce(0, +) / Double(seconds.count)),
                    Self.format(Self.percentile(0.5, of: seconds)), Self.format(Self.percentile(0.95, of: seconds)),
                    Self.format(seconds.last ?? 0), tokens.isEmpty ? "" : "\(tokens.reduce(0, +) / tokens.count)",
                ]
            }, rightAligned: [2, 3, 4, 5, 6, 7, 8])
        lines.append("")
        lines.append("recent, by start time")
        let clock = Date.FormatStyle(date: .omitted, time: .standard, timeZone: timeZone)
        lines += TextTable.render(
            header: ["TIME", "KIND", "MODEL", "SECONDS", "RESULT"],
            // Calls are recorded as they finish, and a classification finishes inside its turn, so the
            // latest calls are put back in the order they started.
            rows: calls.suffix(max(0, recent)).sorted { $0.started < $1.started }.map { call in
                [
                    call.started.formatted(clock), call.kind.rawValue, call.model, Self.format(call.seconds),
                    call.failure.map { "failed: \($0)" } ?? "ok",
                ]
            }, rightAligned: [3])
        return lines
    }

    /// The calls grouped by kind, then model, in the order each group first appeared.
    static func groups(_ calls: [Call]) -> [(kind: Kind, model: String, calls: [Call])] {
        var order: [String] = []
        var grouped: [String: (kind: Kind, model: String, calls: [Call])] = [:]
        for call in calls {
            let key = "\(call.kind.rawValue)\u{0}\(call.model)"
            if grouped[key] == nil {
                order.append(key)
                grouped[key] = (call.kind, call.model, [])
            }
            grouped[key]?.calls.append(call)
        }
        return order.compactMap { grouped[$0] }
    }

    /// The nearest-rank percentile of sorted values; 0 for none.
    static func percentile(_ fraction: Double, of sorted: [Double]) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        return sorted[min(sorted.count, max(1, rank)) - 1]
    }

    /// Seconds with one decimal and a unit: `3.1s`.
    static func format(_ seconds: Double) -> String {
        String(format: "%.1fs", seconds)
    }
}
