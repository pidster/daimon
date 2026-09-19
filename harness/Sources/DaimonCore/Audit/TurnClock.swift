import Synchronization

/// Counts the turns of one conversation so everything that reasons about "this turn" (the audit
/// log's turn numbers, the approval gate's once-approvals and refusals) agrees on what a turn is.
///
/// One clock per conversation: the agent advances it when a prompt arrives, and the gate and the
/// audit log read it. Turn 0 is "before the first prompt".
public final class TurnClock: Sendable {
    private let turn = Mutex(0)

    /// Creates a clock at turn 0.
    public init() {}

    /// The current turn number.
    public var current: Int { turn.withLock { $0 } }

    /// Advances to the next turn and returns its number.
    @discardableResult
    public func advance() -> Int {
        turn.withLock {
            $0 += 1
            return $0
        }
    }
}
