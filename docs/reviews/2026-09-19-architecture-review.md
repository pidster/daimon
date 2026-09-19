# Architecture review, 2026-09-19

Scope: the Swift package under `harness/` at commit `994cd89` ("Make Session and Conversation the common
core under every face"), read in full (`DaimonCore`, `DaimonMCP`, `daimon`, and the test targets) against
`CLAUDE.md`, `docs/design.md`, and ADRs 0001 to 0015. Read-only: a `swift build` and one targeted
`swift test` run to confirm A1; nothing was modified. The earlier reviews
([quality](2026-09-17-quality-review.md), [docs](2026-09-19-docs-review.md)) are closed; this one looks
only for duplication, inconsistency, and structural choices a reviewer would push back on.

Ground truth at the time of review:

- `swift build`: passes.
- `swift test --filter DaimonServerTests/threadsShareTheSessionsStoreAndSessionApprovals`: passes in
  2.45 s, which is the time two on-device classifier calls take (A1).

## Summary

| Severity | Count |
| --- | --- |
| High | 2 |
| Medium | 9 |
| Low | 12 |
| Total | 23 |

The shape is right: one `Session.begin`, one `Conversation.setUp`, tools wrapped once by `AuditedTool`,
the framework owning the tool loop, an actor per MCP thread, and typed `Failure` enums throughout. The
two high findings are both about hidden coupling that undermines a stated rule. A unit test builds a
real session with the default config and so runs the on-device risk classifier, breaking "tests never
need the model" (A1). And the `once` approval scope only works when an `AuditLog` is attached, because
the gate borrows the audit log's turn counter as its notion of "this turn" (A2). Below those, the same
few facts are still assembled in more than one place: `session.start` is built three ways (A4), the
MCP server keeps a thread, its gate, and its audit log in two containers stitched together by a
closure-captured variable (A3), and `Session` demands an approver from the one face that immediately
replaces it (A5). Everything else is small and mostly mechanical.

## Findings

### 1. Poor architecture choices

#### A1 (high) A unit test runs the on-device model through the default classifier

`harness/Tests/DaimonMCPTests/DaimonServerTests.swift:15-23` (`scratchSession` writes no
`config.json`) and `:52-60` (`gate.clear(command: "touch a", …)` twice).
`harness/Sources/DaimonCore/Config.swift:167-170` makes the default classifier
`CompositeRiskClassifier([RuleRiskClassifier.standard, ModelRiskClassifier()])`, and
`harness/Sources/DaimonCore/Approval/ModelRiskClassifier.swift:71-75` opens a `LanguageModelSession`
whenever `SystemLanguageModel.default.availability` is `.available`.

Confirmed: the test passes in 2.45 s on this machine (the rest of the suite's tests take milliseconds),
and on a Mac without Apple Intelligence it would still pass because the classifier falls back to
`moderate`. So the test is green either way, slow when the model is present, and exercises different
code depending on the machine. `CLAUDE.md` says tests never need the model; `Session.begin` gives a test
no way to say so other than writing a config file with `"approval":{"useModel":false}`.

The root cause is structural: `Config.Resolved.classifier` (a *configuration* value) constructs
*behaviour* (`ModelRiskClassifier()`) and `Conversation.setUp` (`Session.swift:228-229`) takes it from
there. There is no seam between "what the config asked for" and "what runs".

Fix: give `Session.begin` a `Dependencies` (or `Environment`) value with a `makeClassifier:
(Config.Resolved) -> any RiskClassifier` and `makeSink:` in it (replacing the bare `makeSink` closure
parameter), default to the live one, and have the MCP and session tests pass rules-only. Then remove
`Config.Resolved.classifier`. Add a guard test: with the default dependencies a `Session` must not be
constructible in the test target without the model probe stubbed (the same trick as `Doctor.Probes`).
Effort: M.

#### A2 (high) The `once` approval scope depends on the audit log being attached

`harness/Sources/DaimonCore/Approval/Approval.swift:141-148` (`currentTurnApprovals()` returns `[]`
when `audit` is nil), `:263-265` (`if audit != nil { turnApprovals.keys.insert(…) }`), and
`AuditLog.swift:38-47` (the turn counter lives on the log; `Agent.turn` advances it at
`Agent.swift:136`).

An approval "for this turn" is defined as "for the audit log's current turn number". A gate without an
audit log (every unit test that constructs `ApprovalGate` directly, and any future caller that passes
`nil`) silently degrades `once` to "this call": the second `run_command` in the same prompt asks again.
`ADR 0014` defines `once` as "the rest of the current turn"; the implementation ties that to a logging
concern. The `Refusal` list is likewise cleared only by `takeRefusals()` (`:180-183`), which only the MCP
server calls, so in `respond` and `chat` refusals accumulate for the life of the gate.

Related layering inversion: the gate throws `CommandRunner.Failure.disapproved`
(`Approval.swift:191, 286, 292`), so the approval layer depends on the exec layer's error type, and a
refused `read_file` renders as "command not approved" (`ReadFileTool.swift:58` via `:51`).

Fix: introduce a small `TurnClock` (a `Sendable` counter) owned by `Conversation` and advanced by
`Agent.turn`, passed to both the gate and the audit log; the gate keys once-approvals and refusals on
it and clears both when the turn changes. Give `ApprovalGate` its own `Refused` error and map it in
`CommandRunner` and `ReadFileTool`. Add a test that two commands in one turn ask once with no audit.
Effort: M.

#### A3 (medium) The MCP server stores one thread's parts in two containers, joined by a captured `var`

`harness/Sources/DaimonMCP/DaimonServer.swift:23-26` (`ThreadStore<any RespondingThread>` plus a
separate `GateRegistry`), `:149-158` (`var openedGate` mutated inside the `findOrCreate` closure),
`:163-168` (caller removes the evicted id from `gates` by hand), and `:203-205` (`close` does the same).
`ThreadStore` is generic over `Thread: Sendable` (`ThreadStore.swift:40`) and already supports any value.

The thread, its gate, and its audit log are created together by the factory (`:31-35`) and must die
together, but only the thread is owned by the store; the gate lives in a second map with its own
lifetime, and the audit log for the thread is re-derived on every call (`:148`,
`audit.log(forSession: id)`). Eviction is correct today only because two call sites remember to update
both maps. The optional `gate` in the factory's tuple exists solely so the test fake can return `nil`.

Fix: store a value type, `OpenThread { thread: any RespondingThread; gate: ApprovalGate; audit:
AuditLog }`, as the `ThreadStore` element; delete `GateRegistry`; have the factory return that struct;
let the test fake build a real gate (rules only, no model). Effort: S.

#### A4 (medium) `session.start` is assembled in three places with three field sets

`Session.swift:130-137` (seven fields, via `Session.begin`), `DaimonServer.swift:170-177`
(`entryPoint: "mcp-thread"`, three fields, recomputing `instructions` and `model` defaults at `:146-147`
that `Session.openConversation` computes again at `:203`), and `Daimon.swift:255` (`/new` in chat
records `session.start` with `reason: new` by hand from the executable). `docs/logging.md:38` claims
"all entry points record the same fields via `Session.begin`"; the thread record omits `unsafe`,
`autoApprove`, and `resume`.

Fix: `Session.conversation(id:…)` records the thread's `session.start` (it has every input), and an
`Agent.reset()` or `Conversation.restart` records the `/new` one, so the executable never builds an audit
event. Effort: S.

#### A5 (medium) `Session` demands an approver from the face that discards it, and builds a conversation MCP never uses

`Daimon.swift:161` passes `DenyingApprover(reason: "unused: the MCP server elicits approval itself")`;
`DaimonServer.swift:57-59` immediately calls `session.with(approver:)`, which rebuilds `main`
(`Session.swift:149-157`) and is documented as throwing an error "which cannot happen". The `main`
conversation built by `begin` for the `mcp` entry point is used only to list tool names for the audit
record (`DaimonServer.swift:175`, `session.tools`).

The approver is a per-face channel, not a per-session fact, so it should not be a `Session` field that
needs a placeholder. `Session.with(approver:)` exists only to work around the field.

Fix: drop `approver` from `Session` and `Session.begin`; take it in `openAgent(approver:)` and
`conversation(id:approver:)` (with `request.autoApprove` still forcing `AutoApprover` inside `Session`).
`Session.begin` then records `session.start` from `request.toolNames` resolved through the registry
without building a gate. Remove `with(approver:)`. Effort: M.

#### A6 (medium) Tool selection is represented four ways

`Session.Request.toolNames: [String]` where empty means all (`Session.swift:16`);
`Session.conversation(toolNames: [String]?)` where nil means "the session's" (`:178`);
`RespondRequest.toolNames: [String]` where empty means all (`ToolCatalog.swift:112`), converted at
`DaimonServer.swift:155` with `request.toolNames.isEmpty ? nil : request.toolNames`; and
`ThreadFactory` taking `[String]?` (`:34`). The same optional-versus-empty ambiguity appears in
`approvalThreshold: RiskLevel?` (nil means never, `Config.swift:158`) next to `approvalTimeout:
Duration?` (nil means forever, `:162`) which is spelled `0` in the file (`:124`).

Fix: a `ToolSelection` enum (`.all`, `.named([String])`) carried from the CLI and MCP request through
`Session` to `ToolRegistry.select`, and a `Threshold` enum (`.level(RiskLevel)`, `.never`) decoded once
(see A13). Effort: S.

#### A7 (medium) Audit details are hand-built dictionaries at every site

`CommandRunner.swift:133-160` (three branches mutate one `decision` dictionary),
`Approval.swift:222-292` (eight `base.merging([...]) { $1 }` calls), `Agent.swift:94-99, 137, 142-147`,
`AuditedTool.swift:39-50`, `DaimonServer.swift:94, 115-121, 165-177`, `Session.swift:130-137`,
`Daimon.swift:255`. Field names are string literals in fourteen places; `docs/logging.md` is the only
schema. The docs review found drift there once already (its O2); nothing prevents the next one.

Fix: one static constructor per `AuditEvent.Kind` (for example
`AuditEvent.Details.policyDecision(command:workingDirectory:verdict:reason:sandbox:network:nested:)`)
in `Audit/`, returning `[String: JSONValue]`, so a field is named in exactly one Swift file and a test
can assert the documented field set per kind. Effort: M.

#### A8 (medium) `ToolRegistry.init` keeps two parallel tool lists

`ToolRegistry.swift:16-28`: the audited and unaudited registries are written out twice; adding a tool
means editing both, and `docs/tools/README.md` step 4 says "append it to `ToolRegistry.init`" as if it
were one line. Every real entry point passes an audit log, so the second list exists for the `tools`
subcommand and the MCP resource reader (`DaimonServer.swift:127`, `Daimon.swift:92`), which only want
descriptions and build a live `CommandRunner` to get them.

Fix: always wrap, with `AuditLog.disabled(session:)` when none is given (a `NullAuditSink` costs
nothing); make `descriptions` obtainable without a runner (a static list of tool instances built with
defaults, or `ToolRegistry.describe()`), and fold the `guidance` dictionary into each tool (A15).
Effort: S.

#### A9 (medium) `RunCommandTool` smuggles the per-call directory through `Options`

`RunCommandTool.swift:45-48` copies the runner and mutates `runner.options.workingDirectory`;
`CommandRunner.Options.workingDirectory` (`CommandRunner.swift:17-18`) is never set by `Config.resolved`
and exists only for this trick. `CommandRunner.run` then reads it back at `:129`. A per-call argument is
modelled as configuration, which is why the quality review's D3 (working directory widening the
sandbox) was possible in the first place: the two concepts shared a struct.

Fix: `run(_ command: String, in workingDirectory: String? = nil)`; delete `Options.workingDirectory`.
Effort: S.

#### A10 (medium) Library code writes to stderr, and `Session` carries copies of its request

`Session.swift:119` prints the `--unsafe` warning from `DaimonCore`, while the egress note for the same
situation is returned as a value (`egressNote`, `:80-83`) for the CLI to print. `docs/design.md`
("Library code never prints"). `Session` also stores `entryPoint`, `toolNames`, and `instructions`
(`:66-71`) that duplicate `Request` and `config.instructions` (`:115, 140`).

Fix: `Session.notes: [String]` (or `warnings`) returned for the face to print; store `request` and
derive the three fields. Effort: S.

#### A11 (medium) `Agent`'s "was this turn condensed" is recomputed by every caller

`Agent.swift:139-145` computes `condensed` for the audit event; `ThreadStore.swift:31-33`
(`ConversationThread.respond`) and `Daimon.swift:261-268` (chat) each re-derive it from
`agent.condensations` before and after. `RespondingThread.respond` returns an unnamed tuple
(`ThreadStore.swift:8`). Also `Agent.stream` (`Agent.swift:120-126`) has an `else if` branch identical
to its `if` branch, so a non-prefix snapshot emits `full.dropFirst(emitted.count)`, which is the wrong
suffix; the branch is dead weight that hides a bug.

Fix: `Agent.respond`/`stream` return a `Reply { text, condensed }`; `RespondingThread` returns the same
type; delete the duplicate branch and decide what a non-prefix snapshot should do (emit a separator and
`full`, per the quality review's D8). Effort: S.

### 2. Duplication

#### A12 (low) Short-id generation is copied four times

`String(UUID().uuidString.prefix(8)).lowercased()` at `Session.swift:121`, `AuditedTool.swift:37`,
`DaimonServer.swift:92`, `ApprovalStore.swift:97`. Fix: `ShortID.make()` in `Audit/`. Effort: S.

#### A13 (low) `approval.threshold` is parsed twice with different failure behaviour

`Config.swift:91-94` validates the string in `load`; `:121-122` parses it again in `resolved` with a
silent `?? .moderate`. The quality review's D17 fixed the same pattern for `model` by making
`ModelSelection` `Codable`. Fix: the `Threshold` enum from A6, `Codable`, decoded once. Effort: S.

#### A14 (low) Name validation `[A-Za-z0-9._-]{1,64}` exists twice

`TranscriptStore.swift:70-75` and `ToolCatalog.swift:98-103` (`validateThreadID`), with different error
types. Fix: one `SafeName.validate(_:)` in `DaimonCore`; both callers map to their own error. Effort: S.

#### A15 (low) A tool's model-facing text lives in three places

The `Tool` struct (`description`, `@Guide`), the `ToolRegistry.guidance` dictionary keyed by string
(`ToolDescriptions.swift:27-45`), and `docs/tools/<name>.md`. The dictionary is kept complete by a test,
but its `limits` text repeats defaults that live in code (`60 s`, `4 KiB`, `100 lines`) and will drift
when a default changes. Fix: a `DaimonTool: Tool` refinement with `static var limits` and
`examplePrompt`, so the registry reads them off the instance; render numbers from the live options.
Effort: S.

#### A16 (low) CLI option groups and error mapping are copied per subcommand

`Daimon.swift:27-47, 140-154, 173-196` declare `--instructions`, `--model`, `--unsafe`, `--tool`, and
`--yes` three times with slightly different help text; `Mcp` has no `--tool` although
`Session.Request.toolNames` supports it and `mcp` threads inherit the session's selection
(`Session.swift:185`). `catch let failure as Session.Failure { throw ValidationError("\(failure)") }` and
the `parseModel` wrapper repeat at `:107-129` and `:322-326`. Fix: an `@OptionGroup struct
SessionOptions` that builds the `Session.Request`, and one `usage(_:)` helper. Effort: S.

#### A17 (low) Model-facing error rendering is duplicated and worded for commands

`RunCommandTool.swift:51-53` and `ReadFileTool.swift:57-59` both `return "error: \(error)"`; the
read tool's refusal says "command not approved" (A2). Fix: one `ToolError.render(_:)` and the gate's own
error type. Effort: S.

#### A18 (low) `CommandSplitter.split` runs two or three times per command

`CommandRunner.swift:139` (policy over each part), `Approval.swift:207` (gate splits again), and
`ApprovalRequest.init` (`Approval.swift:25`) splits a third time when `pattern` is not supplied (only
tests take that path). Fix: split once in `CommandRunner.run` and pass `[SimpleCommand]` to
`ApprovalGate.clear(parts:line:…)`; make `pattern` a required argument of `ApprovalRequest`. Effort: S.

### 3. Inconsistency

#### A19 (low) Entry points are free-form strings

`Session.Request.entryPoint: String` (`Session.swift:10`), `ApprovalGate.source: String` defaulting to
`"unknown"` (`Approval.swift:168`), `ApprovalStore.Entry.source: String`, and the literals `"respond"`,
`"chat"`, `"mcp"`, `"mcp-thread"` in `Daimon.swift` and `DaimonServer.swift:173`. `docs/logging.md`
enumerates exactly four values. Fix: `enum EntryPoint: String, Codable { respond, chat, mcp, mcpThread }`.
Effort: S.

#### A20 (low) Actor versus `Mutex` class is chosen per file without a stated rule

Actors: `ApprovalGate`, `ApprovalStore`, `ThreadStore`, `ConversationThread`. `final class … Sendable`
with `Mutex`: `SessionApprovals`, `AuditLog`, `OutputBuffer`, `GateRegistry`, `ClientCapabilityFlags`,
`MemoryAuditSink`, `FileAuditSink`. The split is defensible (actors where a call awaits a human or the
model; `Mutex` for synchronous state) but is not written down, and `ApprovalStore` does synchronous
file writes from an actor while `FileAuditSink` does the same from a `Mutex`. Fix: a paragraph in
`docs/design.md` "Concurrency" stating the rule; convert `ApprovalStore` to a `Mutex` class if the rule
is "actors only when awaiting". Effort: S.

#### A21 (low) Public surface is wider than the API

`SessionApprovals` is `public` with only `internal` methods (`Approval.swift:105-115`); `Conversation`
is `public` but only constructible through `internal` `setUp` (`Session.swift:215-241`);
`Doctor`, `ChatInput`, `Spawn`, `OutputBuffer`, `RegexCache`, and `withTimeout` mix `public` and
`internal` without a pattern. `DaimonCore` is exported as a library product (`Package.swift:9`) but
nothing outside this package consumes it. Fix: decide whether `DaimonCore` is an API or an
implementation detail; if the latter, default to `internal` and use `@testable import` (already used by
every test), keeping `public` for what `DaimonMCP` and `daimon` call. Effort: M.

#### A22 (low) Errors are named and flattened inconsistently

Nested `Failure` enums in eight types, plus `RuleRiskClassifier.InvalidRule` and `TimeoutError` as
structs. `Session.loadConfig` (`Session.swift:89-94`) flattens `DecodingError`, `Config.Failure`, and
`CommandPolicy.Failure` into a string `reason`, so a caller cannot tell a JSON syntax error from a bad
pattern. `TranscriptStore.Failure.notFound` for `--resume` exits 1 while the other user-input errors exit
64 (`docs/daimon.md:151`). Fix: name them all `Failure`; keep the underlying error as an associated
value; map `--resume` failures to `ValidationError`. Effort: S.

#### A23 (low) File placement does not follow the module's own folders

`Approval/Timeout.swift` is a general utility; `Approval/CommandSplitter.swift` is shared by the policy
layer; `CommandRunner.swift`, `CommandPolicy.swift`, and `FileReader.swift` sit at the root beside
`Tools/`; `Doctor.swift` and `ChatInput.swift` are CLI concerns inside `DaimonCore` (necessary for
testing, but a `CLI/` folder would say so). Fix: `Exec/` (runner, policy, splitter), `Approval/`,
`Audit/`, `Tools/`, `Session/` (session, conversation, agent, model selection, context), `CLI/`
(doctor, chat input), `Support/` (timeout, regex cache, short id). Effort: S.

Verified as sound: the framework-owned tool loop with `Agent` as a thin non-`Sendable` class under
`nonisolated(nonsending)` (ADR 0003, 0007); `posix_spawn` with a process group and bounded drains in
`CommandRunner.launch`; `Home` as the single owner of paths; `ContextPolicy` and
`Transcript.condensed` as a pure function; `AuditSink` injection; `Doctor.Probes`; `RespondRequest` and
`CloseThreadRequest` as pure decoders; `RegexCache` and precompiled rules; the `CommandSplitter` as a
policy pre-pass with the enclosing segment as fallback.

## Todo

Ordered by recommended sequence: the two structural fixes first because later items land on them,
then the mechanical de-duplications. Effort S (under an hour), M (half a day), L (a day or more).

- [x] A1 Inject the classifier (and sink) through a `Session.Dependencies` value; remove `Config.Resolved.classifier`; make the MCP and session tests rules-only; add a guard against model use in tests (M)
- [x] A2 Add a `TurnClock` owned by `Conversation`, shared by gate and audit log; key once-approvals and refusals on it; give `ApprovalGate` its own error type (M)
- [x] A5 Move the approver from `Session` to `openAgent`/`conversation`; delete `with(approver:)` and the placeholder `DenyingApprover` in `Mcp` (M)
- [x] A3 Store `OpenThread { thread, gate, audit }` in `ThreadStore`; delete `GateRegistry` and the captured `openedGate` (S)
- [x] A4 Record thread and `/new` `session.start` events inside `DaimonCore`; align field sets with `logging.md` (S)
- [x] A6 Introduce `ToolSelection` and `Threshold` enums end to end (S)
- [x] A13 Decode `approval.threshold` once via the `Threshold` enum (S)
- [x] A7 Typed detail constructors per `AuditEvent.Kind`, with a test that pins the documented field set (M)
- [x] A9 `CommandRunner.run(_:in:)`; drop `Options.workingDirectory` (S)
- [x] A11 `Agent` returns `Reply { text, condensed }`; remove the duplicate stream branch (S)
- [x] A8 Always wrap tools in `AuditedTool`; descriptions without a runner (S)
- [x] A15 Move `limits` and `examplePrompt` onto each tool type (S)
- [x] A10 Return session warnings as values; store `Request` on `Session` (S)
- [x] A18 Split a command line once and pass the parts to the gate; make `pattern` required on `ApprovalRequest` (S)
- [x] A17 One `ToolError.render`; reword the read refusal (S)
- [x] A12 `ShortID.make()` (S)
- [x] A14 One `SafeName.validate` (S)
- [x] A16 `@OptionGroup SessionOptions`; add `--tool` to `mcp`; one usage-error helper (S)
- [x] A19 `EntryPoint` enum (S)
- [x] A22 Consistent `Failure` naming; keep underlying errors; `--resume` failures as usage errors (S)
- [x] A20 Write down the actor-versus-`Mutex` rule in `design.md` (S)
- [x] A21 Decide `DaimonCore`'s public surface and trim (M)
- [x] A23 Regroup `DaimonCore` sources into folders (S)

## Status

Closed on 2026-09-19. All 23 items landed in the commits after `543de9d`, one or a few findings per
commit, in the todo order; each commit message names its findings. Departures from the proposed fixes:
A17 keeps the two wordings ("command not approved", "read not approved") behind one `ToolOutput.error`
renderer, with the read refusal typed as `FileReader.Failure.notApproved`; A20 converts nothing, because
every existing type already fits the rule once it was written down; A21 trims only `ToolOutput`, because
the survey found the rest of the public surface is either called by `DaimonMCP` or `daimon` or is an
extension point, and keeps the `DaimonCore` product export.
