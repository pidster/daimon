import Foundation

/// `wisp watch`: runs a command each time a trigger arrives (the start, a file change, an interval) and,
/// when its outcome turns, triages the failure and posts a notification, so a long build or test loop can
/// run in the background and speak up only when something changes
/// ([ADR 0033](../../../../docs/decisions/0033-watch-mode.md)).
///
/// The loop is free of time and the file system: triggers arrive on an `AsyncStream`, and running the
/// command, triaging, notifying, and reporting are closures, so tests drive it with a scripted stream.
public struct Watcher: Sendable {
    /// What set a run off.
    public enum Trigger: String, Sendable {
        /// The first run.
        case start
        /// A file under a watched path changed.
        case change
        /// The interval elapsed.
        case interval
    }

    /// How a run ended.
    public enum State: String, Sendable {
        /// Exit status 0.
        case pass
        /// Anything else, a timeout included.
        case fail
    }

    /// When to post a notification.
    public enum NotifyPolicy: String, Sendable, CaseIterable {
        /// When the state turns, and on a first run that fails: the default.
        case change
        /// On every failing run.
        case failure
        /// On every run.
        case always
        /// Never; the terminal still shows each run.
        case never
    }

    /// Knobs for one watch.
    public struct Options: Equatable, Sendable {
        /// When to notify.
        public var notify: NotifyPolicy
        /// Whether a failing run's output is triaged into findings.
        public var triage: Bool
        /// Runs before the watch ends by itself; nil runs until the triggers end.
        public var maxRuns: Int?

        /// Creates options.
        public init(notify: NotifyPolicy = .change, triage: Bool = true, maxRuns: Int? = nil) {
            self.notify = notify
            self.triage = triage
            self.maxRuns = maxRuns
        }
    }

    /// One run and what came of it.
    public struct Run: Equatable, Sendable {
        /// Which run, from 1.
        public var number: Int
        /// What set it off.
        public var trigger: Trigger
        /// The command's exit status.
        public var exitStatus: Int32?
        /// Whether it timed out.
        public var timedOut: Bool
        /// Pass or fail.
        public var state: State
        /// The state before, or nil for the first run.
        public var previous: State?
        /// How long the command took.
        public var seconds: Double
        /// The failures triage found, or nil when it did not run.
        public var findings: [Triage.Finding]?
        /// Why triage could not run, when it failed.
        public var triageError: String?
        /// Whether a notification was requested.
        public var notified: Bool

        /// Whether the state turned.
        public var changed: Bool { previous.map { $0 != state } ?? false }

        /// One line for the terminal: the time is the caller's to add.
        public var summary: String {
            var line = "run \(number) (\(trigger.rawValue)): \(state == .pass ? "pass" : "FAIL")"
            if let exitStatus { line += ", exit \(exitStatus)" }
            if timedOut { line += ", timed out" }
            line += String(format: ", %.1f s", seconds)
            if let previous, changed { line += "; was \(previous.rawValue)" }
            if let findings { line += "; \(findings.count) finding\(findings.count == 1 ? "" : "s")" }
            if let triageError { line += "; triage failed: \(triageError)" }
            return line
        }
    }

    /// Whether to notify for a run in `state` after one in `previous`.
    public static func shouldNotify(_ policy: NotifyPolicy, previous: State?, current: State) -> Bool {
        switch policy {
        case .never: false
        case .always: true
        case .failure: current == .fail
        case .change: previous.map { $0 != current } ?? (current == .fail)
        }
    }

    /// The notification for a run: the command as the subtitle, the outcome and the first finding as the body.
    public static func message(for run: Run, command: String) -> Notifier.Message {
        var body: String
        switch (run.state, run.previous) {
        case (.pass, .fail?): body = "Passing again"
        case (.pass, _): body = "Passing"
        case (.fail, _):
            body = run.timedOut ? "Timed out" : "Failing (exit \(run.exitStatus.map(String.init) ?? "?"))"
            if let findings = run.findings, let first = findings.first {
                body += ": \(first.location.map { "\($0) " } ?? "")\(first.message)"
                if findings.count > 1 { body += " (+\(findings.count - 1) more)" }
            }
        }
        return Notifier.Message(title: "wisp watch", body: body, subtitle: command, sound: run.state == .fail)
    }

    /// The command line, as reported.
    public let command: String
    /// The options in force.
    public let options: Options
    /// Runs the command once and returns its output.
    private let execute: @Sendable () async throws -> Triage.Captured
    /// Triages a failing run's output.
    private let triage: (@Sendable (Triage.Captured) async throws -> [Triage.Finding])?
    /// Posts a notification.
    private let notify: @Sendable (Notifier.Message) -> Void
    /// Hears about each run as it ends: the terminal line and the audit record.
    private let report: @Sendable (Run) -> Void

    /// Creates a watch.
    ///
    /// - Parameters:
    ///   - command: The command line, for reports and notifications.
    ///   - options: Notification policy, triage, run limit.
    ///   - execute: Runs the command once; a thrown error ends the watch.
    ///   - triage: Turns a failing run's output into findings; nil skips triage.
    ///   - notify: Posts a notification.
    ///   - report: Receives each run as it ends.
    public init(
        command: String, options: Options = Options(), execute: @escaping @Sendable () async throws -> Triage.Captured,
        triage: (@Sendable (Triage.Captured) async throws -> [Triage.Finding])?,
        notify: @escaping @Sendable (Notifier.Message) -> Void, report: @escaping @Sendable (Run) -> Void
    ) {
        self.command = command
        self.options = options
        self.execute = execute
        self.triage = triage
        self.notify = notify
        self.report = report
    }

    /// Runs once per trigger until the triggers end, `maxRuns` is reached, or the task is cancelled.
    ///
    /// - Parameter triggers: What sets each run off; the first element is normally `.start`.
    /// - Returns: The runs, in order.
    /// - Throws: Whatever `execute` throws, such as a refused command.
    @discardableResult
    public func run(_ triggers: AsyncStream<Trigger>) async throws -> [Run] {
        var runs: [Run] = []
        var previous: State?
        for await trigger in triggers {
            if Task.isCancelled { break }
            let started = Date()
            let captured = try await execute()
            let seconds = Date().timeIntervalSince(started)
            let state: State = captured.exitStatus == 0 && !captured.timedOut ? .pass : .fail
            var run = Run(
                number: runs.count + 1, trigger: trigger, exitStatus: captured.exitStatus, timedOut: captured.timedOut,
                state: state, previous: previous, seconds: seconds, findings: nil, triageError: nil, notified: false)
            let notifying = Self.shouldNotify(options.notify, previous: previous, current: state)
            // Triage only what will be shown: a failure that is new or will be notified.
            if state == .fail, options.triage, let triage, notifying || previous != .fail {
                do {
                    run.findings = try await triage(captured)
                } catch {
                    run.triageError = "\(error)"
                }
            }
            if notifying {
                notify(Self.message(for: run, command: command))
                run.notified = true
            }
            report(run)
            runs.append(run)
            previous = state
            if let maxRuns = options.maxRuns, runs.count >= maxRuns { break }
        }
        return runs
    }
}
