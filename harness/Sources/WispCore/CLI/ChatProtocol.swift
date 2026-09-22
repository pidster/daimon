import Foundation
import Synchronization

/// The headless chat: `wisp chat --json` speaks JSON Lines on stdin and stdout so another program can
/// be the face (the `wisp-tui` terminal front end, an editor, a GUI), while the session, tools, gate,
/// and audit stay in this process. One object per line; unknown types are ignored, and a line that is
/// not JSON is taken as a typed message so the protocol can be driven by hand.
///
/// Outbound (to the front end): `banner`, `status`, `output` (a whole line, as `/help` prints), `delta`
/// (streamed reply text), `turn` (`start`/`end`), `event` (an audit event of the conversation: tool
/// calls, results, command outcomes, file writes, condensation, errors), `note`, `approval` (a request
/// the front end must answer), `exit`. Inbound: `message` (a chat line, slash commands included) and
/// `answer` (to an approval, by id). Spike; the shape may change.
public enum ChatProtocol {
    /// What the front end sends.
    public enum Inbound: Equatable, Sendable {
        /// A chat input line.
        case message(String)
        /// An answer to an approval request: `once`, `session`, `project`, `always`, or `no`.
        case answer(id: String, decision: String)

        /// Parses one line; text that is not a typed JSON object is a message.
        public init(line: String) {
            guard let data = line.data(using: .utf8),
                let object = (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue,
                let type = object["type"]?.stringValue
            else {
                self = .message(line)
                return
            }
            switch type {
            case "answer":
                self = .answer(id: object["id"]?.stringValue ?? "", decision: object["decision"]?.stringValue ?? "no")
            default:
                self = .message(object["text"]?.stringValue ?? "")
            }
        }
    }

    /// One line to the front end.
    public static func encode(_ type: String, _ fields: [String: JSONValue] = [:]) -> String {
        var object = fields
        object["type"] = .string(type)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(JSONValue.object(object))) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// The `status` line's fields.
    public static func status(_ status: ChatStatus) -> [String: JSONValue] {
        [
            "model": .string(status.model), "directory": .string(status.directory),
            "branch": status.branch.map { .string($0) } ?? .null, "dirty": status.dirty.map { .bool($0) } ?? .null,
            "approval": .string(status.approval), "contextUsed": status.contextUsed.map { .double($0) } ?? .null,
        ]
    }

    /// The `event` line's fields: the audit event's kind, call, and details.
    public static func event(_ event: AuditEvent) -> [String: JSONValue] {
        [
            "kind": .string(event.kind.rawValue), "call": event.call.map { .string($0) } ?? .null,
            "turn": event.turn.map { .int($0) } ?? .null, "details": .object(event.details),
        ]
    }

    /// The `approval` line's fields.
    public static func approval(id: String, _ request: ApprovalRequest) -> [String: JSONValue] {
        [
            "id": .string(id), "command": .string(request.command), "line": .string(request.line),
            "pattern": .string(request.pattern), "directory": .string(request.workingDirectory),
            "level": .string(request.assessment.level.rawValue),
            "reasons": .array(request.assessment.reasons.map { .string($0) }),
        ]
    }
}

/// Routes the front end's lines: messages queue for the chat loop, answers resume whoever is waiting
/// for that approval. Fed from a reader thread; read by the loop and by `JSONApprover`.
public final class LineRouter: Sendable {
    private struct State {
        var messages: [String] = []
        var closed = false
        var waiting: [String: CheckedContinuation<String, Never>] = [:]
        var early: [String: String] = [:]
    }
    private let state = Mutex(State())
    private let available = DispatchSemaphore(value: 0)

    /// Creates an empty router.
    public init() {}

    /// Takes one line from the front end.
    public func receive(_ line: String) {
        switch ChatProtocol.Inbound(line: line) {
        case .message(let text):
            state.withLock { $0.messages.append(text) }
            available.signal()
        case .answer(let id, let decision):
            let waiter = state.withLock { state -> CheckedContinuation<String, Never>? in
                if let waiter = state.waiting.removeValue(forKey: id) { return waiter }
                state.early[id] = decision
                return nil
            }
            waiter?.resume(returning: decision)
        }
    }

    /// Marks the input closed; `nextMessage` returns nil once the queue drains.
    public func close() {
        state.withLock { $0.closed = true }
        available.signal()
    }

    /// The next message, blocking until one arrives; nil after `close` when none are queued.
    public func nextMessage() -> String? {
        while true {
            available.wait()
            let next: String?? = state.withLock { state in
                if !state.messages.isEmpty { return .some(state.messages.removeFirst()) }
                return state.closed ? .some(nil) : nil
            }
            if let next { return next }
        }
    }

    /// The decision for approval `id`, waiting for the front end's answer.
    public func answer(for id: String) async -> String {
        await withCheckedContinuation { continuation in
            let early = state.withLock { state -> String? in
                if let decision = state.early.removeValue(forKey: id) { return decision }
                state.waiting[id] = continuation
                return nil
            }
            if let early { continuation.resume(returning: early) }
        }
    }
}

/// Asks the front end through the protocol and waits for its answer, bounded by `timeout`.
public struct JSONApprover: Approver {
    private let router: LineRouter
    private let send: @Sendable (String) -> Void
    private let timeout: Duration?

    /// Creates an approver.
    ///
    /// - Parameters:
    ///   - router: Where answers arrive.
    ///   - timeout: How long to wait; nil waits forever.
    ///   - send: Writes one protocol line to the front end.
    public init(router: LineRouter, timeout: Duration?, send: @escaping @Sendable (String) -> Void) {
        self.router = router
        self.timeout = timeout
        self.send = send
    }

    /// Sends the request and maps the answer; silence within the timeout is unanswered.
    public func decide(_ request: ApprovalRequest) async -> ApprovalDecision {
        let id = ShortID.make()
        send(ChatProtocol.encode("approval", ChatProtocol.approval(id: id, request)))
        let router = router
        do {
            let decision = try await Timeout.run(timeout) { await router.answer(for: id) }
            return TerminalApprover.parse(decision)
        } catch Timeout.Failure.elapsed(let waited) {
            return .unanswered(waited)
        } catch {
            return .denied("approval request failed: \(error)")
        }
    }
}
