# Quality review, 2026-09-17

Scope: the Swift package under `harness/` as on disk, including the uncommitted model-selection refactor
(`ModelSelection.swift`, `ResolvedModel`, `Agent`, CLI/MCP/doctor wiring). Read-only review plus a build,
the test suite, the coverage report, and a scratch program linked against the built `DaimonCore` to
confirm the four highest-impact defects.

Ground truth at the time of review:

- `swift build -Xswiftc -warnings-as-errors` and `swift test`: pass.
- `scripts/check coverage`: 76.1% lines overall. `Agent.swift` 0% (accepted), `DiagnosticsLogHandler.swift`
  0%, `ElicitationApprover.swift` 17%, `RunCommandTool.swift` 35%, `ReadFileTool.swift` 50%,
  `ModelSelection.swift` 53%, `DaimonServer.swift` 55%.
- Confirmed by running code (not just reading): D1, D2, D3, D11.

## Summary

| Severity | Count |
| --- | --- |
| High | 5 |
| Medium | 12 |
| Low | 33 |
| Total | 50 |

The five high findings: the nested-sandbox fallback can be triggered by a command's own stderr, which is a
sandbox escape (D1); the timeout only kills the shell, so any forked child keeps the pipes open and the
runner blocks until it exits (D2); the model chooses the working directory, and the working directory is
the sandbox's writable root (D3); MCP `run_command` builds a fresh `ApprovalGate` per call, so "approve for
this session" never caches (D4); and the nested-sandbox step of `scripts/check` is a pipeline ending in
`tail`, so its failures cannot fail the gate (Q1).

## Findings

### 1. Defects

#### D1 (high) A command can escape the sandbox by printing the refusal string

`harness/Sources/DaimonCore/CommandRunner.swift:122-133` and `:225-227`.

```swift
let refused =
    sandboxed && status != 0 && fullStdout.isEmpty
    && String(decoding: fullStderr, as: UTF8.self).contains(Self.sandboxApplyRefusal)
```

`refused` is judged on the command's own stderr. The comment at line 123 says the refusal "cannot be
produced from outside one", but the sandboxed command controls stderr. Confirmed with the scratch probe:
`echo run >> launches.txt; echo 'sandbox_apply: Operation not permitted' >&2; exit 1` under the default
policy produced one `policy.decision` with `nested: true` and two launches, the second without
`sandbox-exec`. A prompt-injected or model-generated command such as
`echo 'sandbox_apply: Operation not permitted' >&2; <write outside the sandbox>; exit 1` therefore runs its
payload unsandboxed on the second launch (the first attempt is blocked, the retry is not). Every command
that takes this path also executes twice, duplicating side effects.

`docs/tools/run_command.md` ("The refusal cannot be produced from outside a sandbox, so this cannot be used
to escape one") and ADR 0009 state the false invariant.

Fix: decide nesting once per process, not per command, with a probe that has no attacker-controlled output
(`sandbox-exec -p <daimon profile> /usr/bin/true`, as `scripts/check` and `CommandRunnerPolicyTests.nested`
already do), cache the answer, and never re-run a user command. Effort: M.

#### D2 (high) The timeout does not terminate the process tree; the runner blocks until grandchildren exit

`CommandRunner.swift:193-201` (watchdog sends `kill(pid, SIGTERM)` to the shell only) and `:208-209`
(`readDataToEndOfFile()` waits for every writer to close).

`/bin/sh -c "sleep 5; echo done"` forks `sleep`; SIGTERM to `sh` orphans it holding the pipe's write end.
Confirmed: a 300 ms timeout returned after 5.0 s with `timedOut=true, exit=-15`. With `sleep 3600` or a
server the model started, `run_command` hangs for hours and, under MCP, so does the calling harness. The
existing test (`killsOnTimeout`, `sleep 30`) passes only because the shell `exec`s a single command.

Fix: put the child in its own process group (spawn via `posix_spawn` with `POSIX_SPAWN_SETSID`/`setpgid`
through a small wrapper, or a launcher such as `/usr/bin/script`-free `setsid`) and `kill(-pgid, …)`; or,
at minimum, stop waiting for EOF after the timeout fires (cancel the handlers and return what was
captured). Add a test with `sleep 5; true`. Effort: M.

#### D3 (high) The model-chosen working directory is the sandbox's writable root

`CommandRunner.swift:159-163` builds the profile with `workingDirectory` in the writable set;
`RunCommandTool.swift:45-47` and `DaimonServer.swift:196-197` let the model or MCP caller set it to any
absolute path. Confirmed: `seatbeltProfile(workingDirectory: "/", …)` emits `(subpath "/")`, which allows
every write. `workingDirectory: "/Users/me"` makes the whole home directory writable.

The approval gate is the only remaining barrier, and it is bypassed by `--yes` (which `CLAUDE.md`
recommends for MCP dogfooding when the client lacks elicitation), by `approval.threshold: dangerous`
(`echo x > ~/.zshrc` is rated moderate by the rules), and by `never`. The sandbox's documented promise
("writes outside the working directory … fail") is therefore only as strong as the classifier.

Fix: confine model-chosen directories to descend from the harness's launch directory (or a configured
`commandPolicy.sandbox.root`), or keep the writable root fixed at the launch directory regardless of the
per-call `workingDirectory`. Document the rule in `run_command.md`. Effort: M.

#### D4 (high) MCP `run_command` constructs a new `ApprovalGate` per call, so session approvals never cache

`harness/Sources/DaimonMCP/DaimonServer.swift:53-57` (`gate(audit:)` returns a fresh actor) and `:195`
(`CommandRunner(options: config.runner, audit: audit, approval: gate(audit: audit))` inside `runCommand`).
`ApprovalGate.sessionApprovals` lives in the actor instance, so "Approve for this session" on the
elicitation form is honoured for exactly one command. `docs/mcp.md` ("caching that exact command for the
rest of the session") and `CLAUDE.md` ("choose Approve for this session for repeated shapes") promise
otherwise. `respond` threads are unaffected (one gate per thread, `:135`).

Fix: create one gate for direct `run_command` calls in `init` and reuse it. Effort: S.

#### D5 (medium) `FileAuditSink` opens without `O_APPEND`; concurrent daimons overwrite each other

`harness/Sources/DaimonCore/Audit/AuditLog.swift:186` (`FileHandle(forWritingTo:)`) and `:123`
(`seekToEnd()` once at open). Two processes (an MCP server plus a CLI run, the documented dogfooding setup)
each seek to the end once and then write at their own advancing offsets, so later lines clobber the other
process's lines. `docs/logging.md` says `pid` exists "to separate concurrent daimons sharing a file",
which presumes appends interleave. Rotation by one process also leaves the other writing to the renamed
file with a stale byte count. Fix: open with `open(2)` and `O_WRONLY|O_APPEND|O_CREAT`, wrap in
`FileHandle(fileDescriptor:closeOnDealloc:)`. Effort: S.

#### D6 (medium) Watchdog task can outlive the process and signal a reused pid

`CommandRunner.swift:185-205`. The continuation is resumed from `terminationHandler` on another thread;
the awaiting task can reach line 205 (`watchdog.withLock { $0?.cancel() }`) before the closure body has
stored the task at lines 194-202, in which case the watchdog is never cancelled and, after `timeout`, sends
SIGTERM then SIGKILL to a pid that may by then belong to another process. Narrow window, but real.
Related: lines 206-209 clear the readability handlers and then `readDataToEndOfFile()` while a handler
invocation may still be appending, so a trailing chunk can land out of order. Fix: store the watchdog
before `process.run()` (start it, then run) or start it outside the continuation; drain the pipe on one
side only. Effort: S.

#### D7 (medium) Session approvals are keyed on the command text only, not the directory

`harness/Sources/DaimonCore/Approval/Approval.swift:129, 141`. `rm -rf build` approved "for this session"
in project A is then run without asking in any other `workingDirectory` the model picks. Combine with D3.
Fix: key on `(command, workingDirectory)`. Effort: S.

#### D8 (medium) Streaming retry after mid-stream overflow re-emits already-printed text

`Agent.swift:113-122` and `:101`. `stream` emits deltas as they arrive; if `contextSizeExceeded` fires
after some deltas (tool output pushed the transcript over), `withOverflowRecovery` re-runs the closure with
a fresh `emitted = ""`, so the caller prints the partial reply and then the full retry. Also line 118 emits
`full` again whenever the snapshot is not a prefix extension. Fix: track emitted text across the retry
(pass it through the closure) or print a separator on retry. Effort: S.

#### D9 (medium) `read_file` is outside the classifier and approval entirely

`harness/Sources/DaimonCore/Tools/ReadFileTool.swift:46-48`. The rules rate `cat ~/.ssh/id_rsa` dangerous
and ask; `read_file` with `/Users/me/.ssh/id_rsa` asks nobody, and the content lands in the transcript, the
audit log, and, with `--model private-cloud`, off the machine. `docs/approval.md` scopes approval to
`run_command`, so this is a design gap rather than a regression, but it is the obvious route around the
gate. Fix: route `read_file` paths through the same `ApprovalGate` (a path classifier is a few rules), or
document the gap loudly. Effort: M.

#### D10 (low) `realpath` result leaked in the loop condition

`harness/Sources/DaimonCore/CommandPolicy.swift:140`: `while existing.count > 1, realpath(existing, nil)
== nil` allocates on success and never frees; the loop exits on exactly that success. One small leak per
command. Fix: call once, keep the pointer, free it. Effort: S.

#### D11 (low) `FileReader` reports `hasMore` when the page ends exactly at end of file

`harness/Sources/DaimonCore/FileReader.swift:100-101, 110-112`. Confirmed: a three-line file read with
`limit: 3` returns `hasMore=true, nextOffset=4`; the model then makes a wasted call that returns
`(no lines in range)`. Fix: after the early `break chunks`, peek whether any bytes remain (`scanner`
pending or another non-empty read) before setting `hasMore`. Effort: S.

#### D12 (low) Over-long lines are cut at a byte boundary

`FileReader.swift:98`: `line.prefix(maxBytes)` can split a UTF-8 sequence, yielding U+FFFD at the end of
the line. Fix: trim to the last complete scalar. Effort: S.

#### D13 (low) An invalid rule regex is silently ignored

`harness/Sources/DaimonCore/Approval/RuleRiskClassifier.swift:90`: `guard let regex = try?
Regex(rule.pattern) … else { continue }`. A typo in `defaultRules` would remove a signal without any test
noticing; `CommandPolicy` validates its patterns but the classifier does not. Fix: compile once in `init`
(throwing, or a `precondition` for the built-in list) and add a test that every default rule compiles.
Effort: S.

#### D14 (low) Thread eviction is silent

`harness/Sources/DaimonMCP/ThreadStore.swift:79-82`. Evicting the least-recently-used thread writes no
`session.end` event, so an audit reader sees a thread that never ended, and the caller learns only through
"no such thread" or, worse, a silently new thread under a reused id. Fix: return the evicted id from
`create` and audit it in `DaimonServer.respond`. Effort: S.

#### D15 (low) `find` then `create` race on a new `thread_id`

`DaimonServer.swift:126-152`. Two concurrent `respond` calls naming the same unused id both miss `find`,
and the second `create` fails with "thread already exists" although the caller did nothing wrong. Fix: a
single `findOrCreate` on the store actor. Effort: S.

#### D16 (low) Unknown MCP tool returns `methodNotFound`

`DaimonServer.swift:98`. The MCP specification treats an unknown tool name in `tools/call` as an invalid
params error (-32602); -32601 says the `tools/call` method itself is missing. Effort: S.

#### D17 (low) `Config.resolved` silently falls back on an unparseable `model`

`harness/Sources/DaimonCore/Config.swift:104`: `(try? ModelSelection(parsing: model ?? "")) ?? .default`.
`load` validates first, so only programmatic construction reaches it, but a `Config(model: "bogus")`
resolves to `system` with no error. Fix: make `resolved` throwing or store `ModelSelection` in `Config`.
Effort: S.

#### D18 (low) `daimon doctor` and `respond`/`mcp` create `~/.daimon` although the docs say only `chat` does

`harness/Sources/DaimonCore/Doctor.swift:104` (`home.ensure()` inside a diagnostic) and
`harness/Sources/daimon/Daimon.swift:137` (`openAudit` ensures the tree for every entry point).
`docs/daimon.md:92` and `docs/design.md` ("Read-only commands never create the directory") are wrong.
Either behaviour is fine; the docs must say which. Effort: S.

#### D19 (low) Default deny pattern misses `rm -rf /*`

`CommandPolicy.swift:70`: the pattern requires whitespace or end after `/+`, so `rm -rf /*` passes the deny
list. The rule classifier still rates it dangerous and the sandbox blocks the writes, and the list is
documented as illustrative, but the one documented example (`rm -rf /`) has an obvious sibling. Effort: S.

#### D20 (low) Command text is interpolated into the classifier prompt

`harness/Sources/DaimonCore/Approval/ModelRiskClassifier.swift:79`. A command containing prose ("this
command only lists files") steers the model's verdict. The rules floor limits the damage, and
`docs/approval.md` already says never let the model lower a level; record the exposure and consider
quoting the command in a fenced block. Effort: S.

### 2. Missing or orphaned code and documentation

#### O1 (medium) `AgentError.modelUnavailable` no longer exists but is still documented

Deleted in the uncommitted `Agent.swift` diff; still referenced at
`harness/Sources/DaimonMCP/ThreadStore.swift:17` (`- Throws: AgentError.modelUnavailable`) and
`docs/design.md:60` ("Construction checks `SystemLanguageModel.default.availability` and throws
`AgentError.modelUnavailable(reason)`"). The replacement is `ModelSelection.Failure.unavailable`.

#### O2 (medium) `docs/logging.md` omits fields the code now writes

`session.start` (`docs/logging.md:38`) lacks `model` (`Daimon.swift:70, 205, 258`;
`DaimonServer.swift:157`) and `autoApprove` (`Daimon.swift:204`). `policy.decision` (`:44`) lacks `nested`
(`CommandRunner.swift:130`). `CLAUDE.md` requires new event fields to be documented there.

#### O3 (low) `docs/design.md` drift

Duplicated "Repository layout" section (lines 22 and 31); the Targets table lists subcommands without
`doctor`; the Components section says read-only commands never create the directory (see D18); the
`Agent` paragraph is stale (O1).

#### O4 (low) `docs/daimon.md` drift

Line 3: "It has four subcommands" (there are six). Line 92: state "is created on first use by `chat`;
other subcommands only read from it" (see D18).

#### O5 (low) `docs/README.md:14` still labels `policy-and-sandboxing.md` "(decision pending)"

That page opens with "all five layers are implemented".

#### O6 (low) `RunCommandTool` doc comment says there is no sandbox

`harness/Sources/DaimonCore/Tools/RunCommandTool.swift:6-7`: "There is no sandbox: the command runs with
the harness's own privileges." False since ADR 0009.

#### O7 (low) `daimon mcp --help` omits `close_thread`

`harness/Sources/daimon/Daimon.swift:176`: "Exposes 'respond' … and 'run_command'."

#### O8 (low) `DaimonServer.version` duplicates `DaimonVersion.current`

`DaimonServer.swift:16` hard-codes `"0.1.0"`; `scripts/release:31` and `docs/release.md` treat
`DaimonVersion.current` as the single source, so the MCP handshake version will drift on the first bump.
Fix: `public static let version = DaimonVersion.current`.

#### O9 (low) `Diagnostics.chat` is never used

`harness/Sources/DaimonCore/Diagnostics.swift:77`; `Chat` writes status through its own `note` and logs
nothing. `docs/logging.md` lists `chat` as a live category.

#### O10 (low) `TranscriptStore.list()` has no caller outside tests

`TranscriptStore.swift:57`. There is no `/list` chat command or CLI flag to discover saved names for
`--resume`. Either add one or drop the method.

#### O11 (low) Undocumented `pcc` alias

`ModelSelection.swift:23` accepts `pcc`; the error message (`:52`), `docs/daimon.md`, `docs/mcp.md`, and
ADR 0013 list only `system` and `private-cloud`.

#### O12 (low) `JSONValue.boolValue` is unused

`harness/Sources/DaimonCore/Audit/JSONValue.swift:44`. Harmless public surface; keep or remove
deliberately.

#### O13 (low) Classifier timing claims disagree

`ModelRiskClassifier.swift:7` says "under a second per call"; `docs/approval.md:34` says "about 1.5 s".

Verified as consistent: every `AuditEvent.Kind` case is emitted somewhere; every `config.json` field in
`docs/daimon.md` is honoured by `Config.resolved`; the three MCP tools in `ToolCatalog` match
`DaimonServer.call`; the CLI flags in `docs/daimon.md` match `Daimon.swift`.

### 3. Untested code and weak tests

#### Q1 / T1 (high) The nested-sandbox gate step cannot fail

`scripts/check:49`:

```sh
(cd harness && sandbox-exec -p '(version 1) (allow default)' swift test --disable-sandbox --filter 'CommandRunner|NestedSandbox' 2>&1 | grep -E 'Test run with|✘' | tail -3)
```

Under `/bin/sh` with `set -e` and no `pipefail`, the pipeline's status is `tail`'s, so a failing nested run
prints a ✘ line and the gate continues. This is the only place the fallback path (`CommandRunner.swift:
122-133`) is exercised at all: `NestedSandboxTests.fallsBackWhenAlreadySandboxed`
(`harness/Tests/DaimonCoreTests/CommandRunnerTests.swift:146-162`) asserts that manual nesting prints the
refusal string and that a normal run works; it never drives the runner's own fallback. Fix: assert on the
exit status of `swift test` (capture to a file, check `$?`), and add a unit test that feeds a fake refused
launch through the fallback (which also pins D1's fix). Effort: S.

#### T2 (medium) Timeout coverage only exercises a direct-exec child

`CommandRunnerTests.killsOnTimeout` uses `sleep 30`, which the shell `exec`s. Add `sleep 5; true` with a
short timeout and assert the elapsed time; it fails today (D2).

#### T3 (medium) No test that command output cannot trigger the nested fallback

Add a test that a sandboxed command printing `sandbox_apply: Operation not permitted` and exiting non-zero
is launched once and is not audited as `nested`; it fails today (D1).

#### T4 (medium) `ElicitationApprover.decide` is untested (17% file coverage)

The no-elicitation branch (`ElicitationApprover.swift:31-37`) is pure and its message is a documented
contract in `docs/mcp.md`; the `.accept`/`.decline`/`.cancel` mapping could be tested with a fake
`Server` transport. `DiagnosticsLogHandler` is 0%.

#### T5 (medium) `sandboxCanBlockNetwork` passes when offline

`CommandRunnerTests.swift:121-129` asserts only `exitStatus != 0`, which `curl -m 3` also returns with no
network, DNS failure, or a captive portal. Assert the Seatbelt denial text on stderr, or run the same
command with `allowNetwork: true` first and skip when that fails.

#### T6 (medium) No test that every default rule compiles

See D13. `CommandPolicyTests.validatesPatterns` covers the deny list; nothing covers
`RuleRiskClassifier.defaultRules`.

#### T7 (low) Model-facing wrappers untested

`RunCommandTool.call` (35%) and `ReadFileTool.call` (50%): the `error: …` rendering that the model reacts
to, the `workingDirectory` override, and the default `limit` are all untested although they are pure and
need no model.

#### T8 (low) `AuditEvent.summary` and concurrent sink writers

The `.policyDecision` and `.commandOutcome` summary branches (`AuditEvent.swift:83-86`) and two
`FileAuditSink`s writing interleaved (D5) have no tests; `fileSinkReopensExistingFileAtEnd` writes
sequentially and so passes regardless of `O_APPEND`.

#### T9 (low) `DaimonServer.respond` guards need the model

The "instructions, tools, and model apply only when a thread is created" guard and the
`contextSizeExceeded` mapping (`DaimonServer.swift:126-129, 174-176`) are untestable because
`ConversationThread` constructs an `Agent`. Make `respond` generic over a thread protocol (as `ThreadStore`
already is) so a fake thread can drive them.

#### T10 (low) The CLI target has no tests

`Daimon.swift` (412 lines) holds real logic: `--model` and `--instructions` overriding config, `--unsafe`
swapping the policy, the chat loop's save-on-exit rules, log file ordering in `Logs.run`. `docs/engineering.md`
says the executable holds "argument parsing and I/O only"; moving `loadConfig`/`openAudit`/the REPL step
function into `DaimonCore` would make them testable and honour the layering rule.

#### T11 (low) `DoctorTests` touches the model framework

`DoctorTests.checksConfigAndHomeWithoutTheModel` calls `Doctor.run()`, which queries
`SystemLanguageModel.default.availability` and, for `.privateCloud`, `PrivateCloudComputeLanguageModel()`.
The rule is "tests never need the model"; inject the availability probes or test the private checks
individually.

### 4. Other quality defects

#### Q2 (low) `Chat.run` exits the loop through a fall-through `break`

`Daimon.swift:278-279` (`case .quit: break` only leaves the `switch`) and `:335` (an unconditional `break`
after the `switch` that every other case skips with `continue`). Correct today, fragile on the next edit;
`case .quit: return`-style or a labelled loop reads as intended.

#### Q3 (low) Session set-up is duplicated across `Respond`, `Chat`, and `Mcp`

`Daimon.swift:51-74, 241-261, 196-207`: load config, override model, open audit, build gate and registry,
record `session.start`, warn about egress. Three copies drift (the `Mcp` `session.start` omits
`instructions` and `tools`; `Respond` and `Chat` omit `autoApprove`). A `Session.begin(...)` in `DaimonCore`
would also fix T10.

#### Q4 (low) `policy.decision: allowed` is recorded before approval and before the directory check

`CommandRunner.swift:113-118`. The audit shows "allowed" for commands that are then refused by the gate or
fail on a missing directory, and a human is asked to approve a command that cannot run. Reorder: validate
the directory, then policy, then approval, then one decision event.

#### Q5 (low) Regexes are recompiled for every command

`CommandPolicy.swift:129-131` and `RuleRiskClassifier.swift:90` compile each pattern on every call
(about thirty compilations per `run_command`). Compile once at construction (which also gives D13's
validation for free).

#### Q6 (low) `ModelSelection.Failure.unavailable` prints the raw enum case

`ModelSelection.swift:66, 72`: `"\(reason)"` yields `appleIntelligenceNotEnabled`; `Doctor` already has a
human sentence for the same condition ("enable Apple Intelligence in System Settings and wait for the
model to download"). Share it.

#### Q7 (low) Stale wording after the refactor

`Agent.swift:4` ("over the on-device Apple Foundation Model") and `Agent.swift:31, 51` ("defaults to the
on-device system model") are fine, but `ToolCatalog.respond` still says "Run a task on this Mac's on-device
Apple Foundation Model" while accepting `model: private-cloud` two fields later.

## Todo

Ordered by severity; effort S (under an hour), M (half a day), L (a day or more).

- [ ] D1 Decide sandbox nesting once per process with a fixed probe; never re-run a command on a refusal judged from its own stderr; fix `run_command.md` and ADR 0009 (M)
- [ ] D2 Kill the whole process group on timeout, or stop waiting for pipe EOF after the kill; add the `sleep 5; true` test (M)
- [ ] D3 Confine model- and MCP-chosen `workingDirectory` to the launch directory (or a configured root) so it cannot widen the writable set; document (M)
- [ ] D4 Create one `ApprovalGate` for MCP `run_command` in `DaimonServer.init` and reuse it (S)
- [ ] Q1 Make the nested-sandbox step of `scripts/check` fail on test failure (check `swift test`'s status, not `tail`'s); add a unit test for the fallback path (S)
- [ ] D5 Open the audit file with `O_APPEND`; add a two-writer test (S)
- [ ] D6 Start the watchdog before `process.run()` so it is always cancellable; drain pipes on one side only (S)
- [ ] D7 Key session approvals on command plus working directory (S)
- [ ] D8 Carry emitted text across the overflow retry in `Agent.stream` (S)
- [ ] D9 Put `read_file` paths through the approval gate, or document the gap in `approval.md` (M)
- [ ] O1 Replace `AgentError.modelUnavailable` references in `ThreadStore.swift:17` and `design.md:60` with `ModelSelection.Failure` (S)
- [ ] O2 Add `model`, `autoApprove`, and `nested` to `docs/logging.md` (S)
- [ ] T2 Add a timeout test whose child forks (S)
- [ ] T3 Add a test that a printed refusal string is not treated as nesting (S)
- [ ] T4 Test `ElicitationApprover.decide`'s denial branch and result mapping (M)
- [ ] T5 Make `sandboxCanBlockNetwork` assert the Seatbelt denial, not any failure (S)
- [ ] T6 Test that every `RuleRiskClassifier.defaultRules` pattern compiles (S)
- [ ] D10 Free the `realpath` result in `canonical`'s loop (S)
- [ ] D11 Fix `hasMore` at an exact-limit end of file; add a test (S)
- [ ] D12 Trim over-long lines at a scalar boundary (S)
- [ ] D13 Compile rule regexes once and fail loudly on a bad one (S)
- [ ] D14 Audit `session.end` on thread eviction (S)
- [ ] D15 Add `ThreadStore.findOrCreate` to remove the find/create race (S)
- [ ] D16 Return `invalidParams` for an unknown MCP tool name (S)
- [ ] D17 Make `Config.resolved` unable to swallow an invalid `model` (S)
- [ ] D18 Decide whether read-only commands may create `~/.daimon` and fix `daimon.md` and `design.md` accordingly (S)
- [ ] D19 Extend the `rm -rf /` deny pattern to `/*` (S)
- [ ] D20 Fence the command in the classifier prompt and note the injection exposure in `approval.md` (S)
- [ ] O3 Remove the duplicated "Repository layout" section, add `doctor` to the Targets table in `design.md` (S)
- [ ] O4 Fix "four subcommands" and the home-directory sentence in `daimon.md` (S)
- [ ] O5 Drop "(decision pending)" from `docs/README.md` (S)
- [ ] O6 Correct the `RunCommandTool` doc comment about the sandbox (S)
- [ ] O7 Mention `close_thread` in `daimon mcp --help` (S)
- [ ] O8 Derive `DaimonServer.version` from `DaimonVersion.current` (S)
- [ ] O9 Use `Diagnostics.chat` or remove it and its entry in `logging.md` (S)
- [ ] O10 Add a way to list saved transcripts, or remove `TranscriptStore.list()` (S)
- [ ] O11 Document or remove the `pcc` alias (S)
- [ ] O12 Remove unused `JSONValue.boolValue` or keep deliberately (S)
- [ ] O13 Reconcile the classifier timing claims (S)
- [ ] T7 Test `RunCommandTool.call` and `ReadFileTool.call` rendering and defaults (S)
- [ ] T8 Test the remaining `AuditEvent.summary` branches (S)
- [ ] T9 Make `DaimonServer.respond` generic over a thread protocol so its guards are testable (M)
- [ ] T10 Move `loadConfig`, `openAudit`, and the REPL step into `DaimonCore` and test them (M)
- [ ] T11 Inject availability probes into `Doctor` so its tests never touch the model (S)
- [ ] Q2 Rewrite the chat loop's exit path without the fall-through `break` (S)
- [ ] Q3 Factor the three session set-ups into one helper and align their `session.start` fields (M)
- [ ] Q4 Order `run` as directory check, policy, approval, then one `policy.decision` event (S)
- [ ] Q5 Precompile policy and rule regexes (S)
- [ ] Q6 Share the human-readable unavailability message between `ModelSelection.Failure` and `Doctor` (S)
- [ ] Q7 Update `ToolCatalog.respond`'s description now that the model is selectable (S)


## Status

2026-09-19: D1, D2, D3, D5, D6, D7, D8, D9, T1, T2, T3, O1, O2, O6 addressed (commit "Close the
high-severity review findings"). D4 is moot: the direct MCP `run_command` tool was removed on 2026-09-18.
Remaining items stand as listed in the Todo.
