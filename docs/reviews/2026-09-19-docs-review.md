# Documentation review, 2026-09-19

An adversarial read of the user-facing documentation from the standpoint of a sceptical new user on
macOS 27 who wants to install daimon, use it from the terminal and from Claude Code over MCP, and trust
it with commands on their Mac. Every claim was checked against `harness/Sources` at commit `0aae5da` and,
where safe, by running the debug build (`harness/.build/debug/daimon`, version 0.1.2) with
`DAIMON_HOME=/tmp/daimon-docs-review`. The scratch home was deleted afterwards; nothing was written to
`~/.daimon` or the repository. Private Cloud Compute was not exercised.

## Summary

| Severity | Count |
| --- | --- |
| High (a user would be misled or blocked) | 5 distinct issues (6 entries; 44 restates 37 for approval.md) |
| Medium (confusing or incomplete) | 21 |
| Low (polish) | 45 |
| Total entries | 72 |

**Verdict.** A new user can install daimon from these docs: the Homebrew tap is live at 0.1.2,
`daimon doctor` does what the README says, and the CLI reference matches `--help` almost flag for flag.
Using it from the command line mostly works, but the README's own second quick-start example is refused
as written (the model's `swift test` needs approval and plain `daimon` cannot ask), a refusal exits 0
with model prose rather than a detectable error, the documented exit code for a bad `config.json` is
wrong, and the one config section a cautious user is most likely to edit (`commandPolicy`) rejects any
partial object although the reference says every field is optional. Using it over MCP is where the docs
diverge most from the binary: `mcp.md` promises a structured `isError` on refusal and four approval
scopes including persisted `project` and `always`; in fact the refusal is ordinary model output with
`isError: false`, and the MCP server builds its approval gate without the approval store, so nothing is
persisted or honoured over MCP and a "session" approval lives only as long as one thread. Trusting daimon
is the weakest part: the mechanisms are sound and honestly described at the component level, but the
front door says "kernel-enforced sandbox" and "nothing leaves your machine" without the qualifications
(only writes are confined, network is on by default, `--yes` removes every human check, reads are
unconfined), and the facts a user needs to answer "what can this do to my Mac and how do I undo it" are
scattered across six pages and two ADRs with no single trust page. The set is close: most fixes are
small edits, plus one code fix (persisted approvals over MCP) and one decision (partial `commandPolicy`).

## Findings by page

Severity in brackets. Line numbers refer to the files at `0aae5da`.

### README.md

1. [High] L26-27, quick start: `daimon "Run the tests in $PWD and tell me if they pass"`. In any real
   project the model runs `swift test`, `npm test`, or similar, which `RuleRiskClassifier` rates
   `moderate` ("runs a build or tests"), and `respond` has no way to ask. Verified from the repo: the
   equivalent prompt returns `error: command not approved: swift test 2>&1: approval required; re-run
   with --yes, use daimon chat to be asked, or lower approval.threshold` and exits 0. The explanation
   ("plain `daimon` refuses unless you pass `--yes`") comes two lines after the example that fails.
   Either add `--yes` to the example, make it a `chat` example, or move the sentence above the block.
2. [Medium] L5-6, "By default nothing leaves your machine". True of inference. Not true of what the model
   may run: `sandbox.allowNetwork` defaults to `true` and the deny list does not cover `curl`, `ssh`, or
   `scp`. Network use is rated `moderate` and asks, so a person is in the loop, but with `--yes` or
   `approval.threshold: never` nothing asks. Qualify the sentence: "no inference leaves your machine;
   commands the model runs may use the network unless you turn it off, and are asked about first".
3. [Medium] L15-16, "runs inside a kernel-enforced sandbox". The profile is `(allow default)` with
   `file-write*` denied outside the writable set and `network*` denied only when configured
   (`CommandPolicy.seatbeltProfile`). Reads, executing any binary, Mach IPC, and AppleEvents
   (`osascript`) are not confined. The claim is technically true and practically overread; say "a
   sandbox that blocks writes outside the project (and, if you choose, the network)".
4. [Medium] L32-34, "State lives in `~/.daimon`: an optional `config.json`, saved chat transcripts, and
   the audit log". Omits `approvals.json`, the file that holds standing permissions for 30 days, and
   `daimon approvals` to revoke them. The front door never tells a user that approvals can outlive the
   session or how to undo one. Add one sentence and the `approvals` line to the quick start.
5. [Low] L42, `"command": "/path/to/daimon"`. After `brew install` the path is
   `/opt/homebrew/bin/daimon` (release.md L13); say so, or use `"daimon"` since it is on `PATH`.
6. [Low] Missing: uninstall (`brew uninstall daimon`, `rm -rf ~/.daimon`) and upgrade (`brew upgrade`),
   and a note that the first `daimon "..."` creates `~/.daimon/logs/audit.jsonl` holding the prompt and
   reply verbatim.
7. [Low] L21, "Homebrew" is a requirement only for the quick start; building from source is the
   alternative (ADR 0012). Fine as written, but the sentence reads as absolute.

### docs/README.md (index)

8. [Medium] The table (L3-19) is flat and unordered for a newcomer: user pages, background surveys,
   contributor pages, and one ADR (`decisions/0013`, L15) sit side by side with no suggested reading
   order. Group into "Using daimon" (daimon, tools, mcp, approval, logging), "How it works" (design,
   context-management, policy-and-sandboxing, decisions), and "Contributing and releasing"
   (engineering, release, backlog, fm-cli, reviews), and state the order for a first read.
9. [Low] `docs/reviews/` is not indexed although it is under `docs/` and the docs rule says every page
   gets a row.
10. [Low] L15, an ADR is listed as a document with its own purpose text while the other fourteen are
    only reachable through L19. Either list none individually or explain why this one.

### docs/daimon.md

11. [Medium] L3-4, "It has six subcommands (`respond`, `chat`, `tools`, `logs`, `doctor`, `mcp`)".
    There are seven; `approvals` is documented on L83 of the same page and appears in `daimon --help`.
12. [High] L114, "`config.json` fields, all optional", and L123, `commandPolicy` described as
    deny/allow patterns and sandbox settings with defaults listed in run_command.md. Verified: the
    object is all-or-nothing. `{"commandPolicy":{"sandbox":{"allowNetwork":false}}}` fails with
    `malformed …/config.json: DecodingError.keyNotFound: Key 'deny' not found`;
    `{"commandPolicy":{"deny":["sudo"]}}` fails with `Key 'allow' not found`; `sandbox` likewise needs
    all of `enabled`, `allowNetwork`, `writablePaths`. `CommandPolicy` and `CommandPolicy.Sandbox` are
    synthesised `Codable` over non-optional properties (CommandPolicy.swift L14-58). policy-and-
    sandboxing.md L58 calls `sandbox.allowNetwork` "the one-field switch"; it is a nine-field switch.
    Fix the decoder (optional fields with defaults, like `AuditConfig` and `ApprovalConfig`) or document
    that `commandPolicy` must be given whole, with the full default object to copy.
13. [Medium] L148, exit code `1` for "a malformed `config.json`". Verified: `respond` and `chat` exit 64
    (`Daimon.begin` maps `Session.Failure` to `ValidationError`, Daimon.swift L111-116), `logs` exits 1
    (it throws `Session.Failure` directly), `doctor` exits 1 by design. Pick one and document it; a
    script cannot distinguish "bad flags" from "bad config" today.
14. [Medium] L54, "Status lines go to stderr, replies to stdout, so `daimon chat 2>/dev/null` pipes
    cleanly". Verified: stdout carries the `> ` prompt before every line (`print("> ", terminator: "")`,
    Daimon.swift L228); `od -c` of the piped output shows `>  ok\n> `. Either move the prompt to stderr
    or drop the claim.
15. [Medium] Missing, and important for command-line use: a refusal is not an error. When approval is
    denied, `respond` prints whatever the model says about the `error: command not approved` tool
    result and exits 0 (verified three times; once the model wrote "The command failed due to an
    approval requirement. Please re-run…"). The page should say that exit status does not reflect tool
    refusals and that the audit log (`daimon logs --kind approval.decided`) is the reliable record.
16. [Low] L23, `echo "Summarise this" | daimon --tool current_date`. Works, but the stdin text is the
    prompt, not material to summarise, so the model replies "Could you clarify what you would like
    summarised?" (verified). Use an example whose stdin is the prompt, such as
    `echo "What time is it in Tokyo?" | daimon --tool current_date`.
17. [Low] L51-52, chat answers `p` "(30 days, this directory)" and `a` "(30 days)". The 30 is
    hard-coded in the prompt text (Approval.swift L81) and does not follow `approval.persistDays`. Say
    "for `approval.persistDays`" or fix the prompt to print the configured value.
18. [Low] L85-88 and the binary: `daimon approvals --help` (Daimon.swift L366) says approvals "are
    exact command lines". Stale since ADR 0015; they are patterns such as `touch *` (verified output:
    `ddc40e90  project  expires 19 Oct 2026  /Users/…/daimon  touch *`).
19. [Low] L103-105, "`tools` and `logs` never create it". Also true of `approvals` (list); `approvals
    revoke` and `clear` create the directory when writing (`ApprovalStore.save`).
20. [Low] L134, "A malformed file or an invalid `commandPolicy` pattern is an error". Also an invalid
    `approval.threshold` (`use safe, moderate, dangerous, or never`) and an unknown `model`. Both
    messages verified.
21. [Low] L118, `instructions` "built-in". State the built-in text
    ("You are daimon, a concise assistant. Use the available tools when they help answer
    accurately."); it is stamped on every `session.start` and a user will wonder where it came from.
22. [Low] L48, chat commands: `/exit`, `/q`, and `/?` are accepted too (ChatInput.swift L32-33).
23. [Low] L64 says "oldest first" and logging.md L58 says "newest last"; same thing, two spellings.
    Also note that events are emitted in file order, so two daimons writing concurrently interleave in
    write order, not strictly by `time` (observed with the MCP server and a CLI run).

### docs/tools/README.md

24. [Low] L25, "Append it to `ToolRegistry.init`" versus design.md L96 ("A static list, `all`") and
    L166 ("append to `ToolRegistry.all`"). The code is an instance `let all` built in `init`
    (ToolRegistry.swift L6-29); the tools page is right, design.md is stale.

### docs/tools/run_command.md

25. [High] L47, `sandbox.writablePaths`: "Writable in addition to the working directory, `$TMPDIR`, and
    `/private/tmp`" contradicts L103-109 on the same page ("The sandbox's writable set is rooted at the
    directory daimon was launched in … A `workingDirectory` chosen by the model changes where the
    command runs, never what it may write"). The code agrees with L103 (`Options.writableRoot`,
    CommandRunner.swift L18-21), and so does the live tool guidance ("rooted at daimon's launch
    directory"); the `Sandbox.writablePaths` doc comment (CommandPolicy.swift L21) still says working
    directory. Verified: from the repo, `touch /Users/pidster/daimon-docs-probe` with `--yes` gives
    `Operation not permitted`. Security-relevant because a user reading the table will believe that
    passing `workingDirectory` widens the writable set. Fix the table row and the code comment, and
    define "launch directory" once (for MCP it is wherever the client started the server, see 39).
26. [Medium] L118-120, "Reads are not restricted; omit the tool … where even that is too much", placed
    under the heading "Process tree and timeouts". Half true: the sandbox does not restrict reads, but
    `cat ~/.ssh/id_rsa` is rated `dangerous` by the rules and asks. The full statement a user needs, in
    one place: reads are never blocked by the sandbox; credential-looking reads ask; with `--yes` or
    `threshold: never` any file can be read and, with network on, sent anywhere. Move the paragraph to
    "Policy and sandbox" and say that.
27. [Medium] L49, "Inside the sandbox everything is readable and executable". Add what else is allowed:
    the profile is `(allow default)`, so IPC, AppleEvents (`osascript`, `open`), and signals are
    permitted; `osascript`/`open` are rated `moderate` by the rules and ask, but nothing in the sandbox
    stops them. Users deciding whether to run `--yes` need this.
28. [Medium] L53-56, the configuration example is valid only because it spells out every field (see
    12). Add "the object must be complete" or fix the decoder.
29. [Low] L43, deny list: also matches `newfs_`, and `| sh` also covers `bash`, `zsh`, `dash`
    (CommandPolicy.swift L68-74). The code calls the list "illustrative, not exhaustive; the sandbox is
    the real barrier" (L67); the page should say the same, so nobody reads it as a blocklist.
30. [Low] L96-101 and L108-109 carry change history ("found by review, fixed 2026-09-19", "Before
    2026-09-19 the per-command directory was the writable root"). ADR 0009 already records it; the user
    page should describe the current state only (docs rule: "Documents describe the current state").
31. [Low] L12, `workingDirectory` default "daimon's current directory". For `mcp` that is the
    directory the client launched the server in; say so here or in mcp.md (see 39).
32. [Low] L110-116 (process group, SIGTERM/SIGKILL, one-second drain) verified against
    CommandRunner.swift L192-206.

### docs/tools/read_file.md

33. [Low] L10, `path`. Relative paths resolve against daimon's current directory (the `Arguments` doc
    comment says so; the `@Guide` text and the page do not).
34. [Low] L29-33. Two details worth stating: the approval uses daimon's process directory as the
    "working directory" for the `cat *` pattern (ReadFileTool.swift L51-52), so a `project` approval of
    `cat *` there covers every later `read_file` call in that directory; and the deny patterns are not
    applied to reads, only the rule classifier. Verified refusal without `--yes` on a dummy `.netrc`
    (`decision=denied … pattern=cat *`).
35. [Low] L32-33, "Refusals come back as `error: command not approved: …`". That is the tool result; the
    user sees the model's paraphrase (see 15).

### docs/tools/current_date.md

No findings. Output format verified (`2026-09-20T…+09:00 (Asia/Tokyo)` via the README example).

### docs/mcp.md

36. [High] L81-83, "Otherwise the call returns `command not approved: … this client does not support
    elicitation …` with `isError: true`, and the calling harness should run the command itself". False.
    The denial is returned to the model as tool output; `respond` returns the model's reply with
    `isError: false`. Verified with a client that advertised no elicitation:
    `{"content":[{"text":"error: command not approved: approval required (moderate: modifies files; …)
    and this client does not support elicitation; …"}],"isError":false,"structuredContent":{…}}`. A
    harness cannot detect a refusal structurally; it has to read prose that the model may reword.
    Document the real shape, and consider the backlog "receipts" item (approvals asked and answered in
    `structuredContent`) as the fix.
37. [High] L78-80, Accept "with the scope picked in the form (this turn by default; session; project,
    30 days in this directory; always, 30 days anywhere)", and approval.md L96, ADR 0014. Over MCP,
    `project` and `always` do nothing beyond the thread, and nothing persisted is consulted:
    `DaimonServer.gate(audit:)` (DaimonServer.swift L71-74) constructs `ApprovalGate` without a `store`
    and without `source`, unlike `Session.begin`. In `ApprovalGate.clearSegment` a persistent scope with
    a nil store falls through to the session cache and `store?.find` returns nil. Verified: a `touch *`
    `project` approval granted in `chat` for the repository directory was ignored by `daimon mcp`
    launched from that directory (denied "this client does not support elicitation"). Further, the gate
    is created per thread at thread creation, so a "session" approval over MCP covers one `thread_id`
    only and dies with it (approval.md L57 says "until the process exits"). This is a code bug that the
    docs faithfully misdescribe; fix the server to pass the store and source, or document the MCP
    scopes as "this turn" and "this thread" until it does.
38. [Medium] L85-88, a table of arguments `command` (required) and `working_directory` sits under
    "Approval" with no tool to belong to. It is a remnant of the direct `run_command` MCP tool removed
    on 2026-09-17 (ADR 0006). Delete it.
39. [Medium] Missing: where an MCP-launched daimon runs. The sandbox's writable root is the launch
    directory; for Claude Code that is the project directory where `.mcp.json` lives, and a relative
    `command` such as `scripts/daimon-mcp` resolves from there. The page never says what "current
    directory" means for a server the user did not start by hand. Also missing: a description of the
    elicitation dialog (title, fields, the picker defaulting to "This turn") so a user recognises it,
    and a `resources/read` example (verified working: `{"method":"resources/read","params":{"uri":
    "daimon://tools.md"}}`).
40. [Low] L105-108, "unknown tool names are JSON-RPC `invalidParams`" and two lines later "unknown tool
    name … `isError: true`". Both are right but about different things: an unknown MCP tool
    (`tools/call` name) is `-32602`; an unknown daimon tool in the `tools` array is a tool error
    (verified: `Unknown tool(s): nope`, `isError: true`). Say which is which.
41. [Low] L112-118, smoke test verified as written. `sleep 10` suffices for "Say hi" (about 1.5 s); a
    prompt that triggers the classifier needs longer (about 3-4 s per simple command). Mention it.
42. [Low] L18-24, the Codex TOML block was not verified against Codex. The repository's own
    `.mcp.json` uses `"type": "stdio"` and a launcher script rather than the L15 shape; either is fine
    but the page could point at the launcher as the dogfooding example.
43. [Low] L67-69, eviction audited as `session.end` with `reason: evicted`: verified in code
    (DaimonServer.swift L179-181), not exercised.

### docs/approval.md

44. [High] L54-59 (scope table) and L96 (mcp row): see 37. As written, the table promises persistence
    and process-wide session scope for every entry point; over MCP neither holds.
45. [Medium] L84-85, "Decisions: approve once, approve this exact command for the rest of the session,
    deny with a reason, or unanswered". Stale twice: approvals are by pattern, not exact command (ADR
    0015), and the sentence omits `project` and `always` four lines below their table. Delete or
    rewrite.
46. [Medium] L85-88, "an approver that hears nothing within `approval.timeoutSeconds` … reports
    `unanswered`", and L108, `timeoutSeconds` "How long an approval may go unanswered". Only the MCP
    `ElicitationApprover` has a timeout (`withOptionalTimeout`, ElicitationApprover.swift L78).
    `TerminalApprover.decide` blocks on `readLine()` indefinitely (Approval.swift L84). The general
    claim and the config row should say "over MCP"; or add the timeout to chat, which the "no answer is
    not an answer" principle would seem to require.
47. [Medium] Missing for trust: the rules themselves. A user deciding on `useModel: false`, or wanting
    to know whether `git commit` will ask, must read `RuleRiskClassifier.swift`. Add a table of the
    24 rules (pattern in words, level, reason) or at least the reason strings, which are already
    written for humans.
48. [Low] L28, "thirteen labelled examples". The instructions list fifteen
    (ModelRiskClassifier.swift L44-58).
49. [Low] L34, "45 labelled commands, ten of them held out": verified (35 + 10 in
    `ClassifierEvalTests.labelled`). The eval was not rerun.
50. [Low] L3, "This is layer 3 of policy-and-sandboxing.md". A reader who starts here (the README
    sends them here) has no idea what a layer is. Drop the cross-reference or spell it out.
51. [Low] L18, `CompositeRiskClassifier` and L24, `ModelRiskClassifier`: type names in a user page.
    Fine for design.md; here "rules" and "model" suffice.
52. [Low] L117-119, audit kinds: verified. `approval.decided` may also carry `persistError` when the
    store cannot be written (Approval.swift L241-243); not in logging.md either.

### docs/logging.md

53. [Low] L38, "(all entry points record the same fields via `Session.begin`)". Thread sessions
    (`entryPoint: mcp-thread`) record only `entryPoint`, `instructions`, `tools`, `model`
    (DaimonServer.swift L183-188); verified in `--json` output. Not `unsafe`, `autoApprove`, `resume`.
54. [Low] L39, `session.end` "`reason`: `closed` (explicit), `evicted`". CLI sessions end with empty
    `details` (verified `"details":{}`); only threads carry a reason.
55. [Low] L52, `approval.decided`: add `persistError` (see 52).
56. [Medium] L88, "Messages are marked public so they are not redacted". The diagnostic log carries
    command lines (`Diagnostics.policy.info("denied: …: \(command)")`, CommandRunner.swift L145) and,
    at debug, tool arguments and outputs (AuditedTool.swift L42), into the system-wide unified log,
    which any administrator can read with `log show` and which persists. The audit file is mode 0600 for
    exactly this content. Say so, and consider `privacy: .private` for command text.
57. [Medium] Not on this page or daimon.md: saved transcripts (`~/.daimon/transcripts/<name>.json`)
    contain the same verbatim conversation as the audit log but are written with the default umask
    (verified `-rw-r--r--` on `t1.json`), while `audit.jsonl` and `approvals.json` are 0600. Either
    protect them the same way or tell the user.
58. [Low] L58-65, example commands verified. Add one example summary line so the reader knows what a
    summary looks like before running it.

### docs/release.md

59. [Low] Maintainer page; claims verified where possible: tags `v0.1.0`-`v0.1.2` exist, the tap
    formula serves 0.1.2 with `depends_on macos: :golden_gate`, `scripts/release` matches the six steps.
    The unsigned-binary and Gatekeeper claims were not tested. User-facing pieces (install path,
    upgrade, uninstall) belong in README or daimon.md, not here.

### docs/context-management.md

60. [Low] Background page; `chat` note ("(context was full; older turns were dropped to continue)")
    and `condensed` flag verified in code. The `ContextOptions` claim (L15) was not verified against
    the SDK. Only structural note: daimon.md L139 uses "turn" before this page defines it (L29-31);
    a half-sentence definition in daimon.md would do.

### docs/policy-and-sandboxing.md

61. [Medium] L42-43, "**Confirmation** in interactive `daimon chat` … Not applicable to MCP, where the
    calling harness has its own confirmation UX". Contradicts L3-5 of the same page, approval.md, and
    mcp.md: MCP elicits. The survey was left as written when layer 3 changed.
62. [Low] L40, "evaluated in `RunCommandTool.call`" (it is `CommandRunner.run`); L45, "defaulting to
    the working directory and `$TMPDIR`" (launch directory, see 25); L47, "persist transcripts … so
    every tool call and output is on disk" (superseded by the audit log, ADR 0010).
63. [Low] The page mixes a dated survey with a "What was done" section that has drifted. Either date
    every section as historical and keep only the survey, or move "What was done" into run_command.md.

### docs/objective.md

64. [Medium] L9, "**On-device**: every inference runs on the local Apple silicon model. No network calls
    for generation", and L34, non-goal "Remote or third-party models". Both contradict ADR 0013 and
    README L5-6: `--model private-cloud` sends prompts and tool output to Apple's servers. Add the
    amendment (on device by default; PCC as explicit opt-in) or the objective reads as if PCC were a
    violation of it.
65. [Low] L37, non-goal "configuration files for tools" versus `commandPolicy` in `config.json`, which
    is configuration for a tool. Reword to what is meant (no per-tool config format or plugin manifest).

### docs/design.md

66. [Medium] L79-85 present `Session.begin` as "the one place an entry point's flags become a running
    configuration", and L63-69 describe one `ApprovalGate` per session. `DaimonServer.respond` builds
    its own registry and gate per thread (DaimonServer.swift L157, L71-74) and omits the store and
    source; that is the cause of 37. Either route thread creation through `Session` or document the
    divergence so the next reader does not assume parity.
67. [Low] L26, the `harness/` row omits `DaimonMCP`; L37 the subcommand list omits `approvals`; L89
    `Home` omits `approvals.json`; L90 `Config` lists three of eight fields; L148 chat commands omit
    `/exit`.
68. [Low] L96 and L166, `ToolRegistry.all` as "a static list": see 24.
69. [Low] L172, "Session persistence (transcript save/resume …) would live in `Agent`": it exists
    (`TranscriptStore`, `--resume`, `--save`). Stale.

### CLAUDE.md (as documentation for agents)

70. [Low] L8, "a CLI (`respond`, `chat`, `tools`, `logs`)": omits `doctor` and `approvals`.
71. [Low] L104, 'choose "Approve for this session" for repeated shapes'. The picker label is "This
    session", and per 37 it covers only the `git` thread; `project`/`always` currently do nothing over
    MCP. Update once 37 is resolved either way.
72. [Low] L16, "`.claude/rules/` (Swift, Rust, docs, shell)": verified, four files.

## Structural improvements across the set

- **One trust page.** Nothing answers, on one screen, "what can this do to my Mac?" A page (or a
  section at the top of approval.md, linked from the README quick start) should state in order: what
  runs (`/bin/sh -c` as you, with your files readable and any binary executable); what the sandbox
  blocks (writes outside the launch directory, temp, `/private/tmp`, caches; network only if you set
  `allowNetwork: false`); what always asks and what never asks (the rule table); what `--yes` and
  `threshold: never` remove; what is remembered and for how long (`approvals.json`, 30 days, revoke
  with `daimon approvals`); what is recorded and where (audit log 0600, transcripts, unified log); what
  leaves the machine (nothing by default; PCC on request; anything a network-using command sends). Every
  one of these facts exists today, spread over README, daimon.md, run_command.md, approval.md,
  logging.md, ADR 0009, and ADR 0014.
- **One canonical description of approval scopes.** They are described five times (daimon.md L50-52,
  run_command.md L60-68, mcp.md L72-83, approval.md L54-96, ADR 0014/0015) and have already diverged
  (45, 37). Make approval.md canonical, reduce the others to one sentence and a link.
- **One name per thing.** "working directory" / "launch directory" / "writable root" (25); "standing"
  / "persisted" / "remembered" approvals; "once" / "this turn" / "y"; "pattern" / "essential
  command" / "program"; "risky" (README) versus "moderate or above" (everywhere else). Define each once
  and reuse.
- **Reading order.** The index should say: README, then daimon.md, then approval.md, then
  tools/run_command.md, then mcp.md, then logging.md; design and ADRs afterwards; engineering, release,
  backlog, fm-cli, reviews for contributors.
- **Keep history in ADRs.** run_command.md and policy-and-sandboxing.md carry dated change notes; the
  docs rule says pages describe the current state. Move the narrative to the ADRs that already hold it.
- **Split policy-and-sandboxing.md.** Keep the survey (dated, historical) and move the live facts into
  run_command.md; today the page is half survey, half stale summary (61-63).
- **Describe outputs, not only inputs.** daimon.md and mcp.md document flags and arguments thoroughly
  but rarely show what the user sees: a refusal, an approval prompt, a `daimon logs` line, an
  elicitation dialog. Each page needs one real example of each (all captured in this review).
- **Binary help text is documentation too.** `daimon approvals --help` (18) is stale; the tool guidance
  strings and the elicitation text are read by users and harnesses and should be reviewed with the docs.

## Todo

Ordered by severity, then by leverage. Effort: S under an hour, M a half day, L longer or needs a
decision.

- [ ] [High] Fix persisted and session approvals over MCP: pass the `ApprovalStore` and `source` from
      the server session into thread gates (or share one gate per server), then re-verify mcp.md
      L78-80 and approval.md L54-59, L96 against the binary (37, 44, 66). Needs a test with an
      in-memory store. M
- [ ] [High] Make `commandPolicy` and `commandPolicy.sandbox` decode partial objects with defaults, or
      document that both must be complete and give the full default JSON to copy (12, 28). S for the
      doc, M for the code.
- [ ] [High] Rewrite mcp.md "Approval" to describe the real refusal shape (`isError: false`, model
      prose) and how a harness should detect it; delete the orphan argument table (36, 38). S.
      Longer term, add approvals to `structuredContent` (backlog "receipts"). M
- [ ] [High] Fix run_command.md L47 and the `Sandbox.writablePaths` doc comment to say "launch
      directory", define the term once, and say what it means when Claude Code launches the server
      (25, 31, 39). S
- [ ] [High] Fix the README second quick-start example: add `--yes`, or make it a `chat` example, and
      move the "refuses unless" sentence above the block (1). S
- [ ] [Medium] Add a trust page or section (see Structural improvements) and link it from the README
      quick start; include the rule table (47), the `--yes` consequences, and undo steps (2, 3, 4, 26,
      27). M
- [ ] [Medium] Qualify README L5 and L15-16 (network on by default; sandbox confines writes) (2, 3). S
- [ ] [Medium] Add `approvals.json` and `daimon approvals` to README L33 and the quick start (4). S
- [ ] [Medium] Decide the exit code for a malformed config and make `respond`, `chat`, `logs` agree;
      then fix daimon.md L148 (13). S
- [ ] [Medium] State in daimon.md that refusals exit 0 with model prose and that the audit log is the
      record (15, 35). S
- [ ] [Medium] Fix daimon.md L3 subcommand count and list (11). S
- [ ] [Medium] Move the chat `> ` prompt to stderr or drop the "pipes cleanly" claim (14). S
- [ ] [Medium] Delete or rewrite approval.md L84-85 (stale "exact command" decisions list) (45). S
- [ ] [Medium] Either scope the timeout claims to MCP or add a timeout to `TerminalApprover` (46). S
      for docs, M for code.
- [ ] [Medium] Fix policy-and-sandboxing.md L42-43 and mark the survey as historical, or fold the live
      parts into run_command.md (61, 62, 63). S
- [ ] [Medium] Amend objective.md for ADR 0013 (64). S
- [ ] [Medium] Document the diagnostic log's exposure of command text, and consider `.private` (56). S
- [ ] [Medium] Protect transcripts (0600) or document that they are not protected (57). S
- [ ] [Medium] Document the `Session`/`DaimonServer` divergence in design.md or remove it (66). S
- [ ] [Medium] Regroup and order the docs index; add `reviews/` (8, 9, 10). S
- [ ] [Low] Update `daimon approvals --help` text to patterns (18). S
- [ ] [Low] Make the chat prompt print `persistDays` instead of a hard-coded 30 (17). S
- [ ] [Low] Replace the daimon.md stdin example (16); list `/exit`, `/q`, `/?` (22); state the default
      instructions (21); list the other config errors (20); note `approvals` in the "never creates"
      sentence (19). S
- [ ] [Low] Strip change history from run_command.md L96-101, L108-109 (30); mark the deny list
      illustrative (29); mention `newfs_` and the shell variants (29). S
- [ ] [Low] read_file.md: relative path resolution, the `cat *` pattern, deny patterns not applied
      (33, 34). S
- [ ] [Low] mcp.md: disambiguate the two "unknown tool" errors (40), note the smoke-test sleep (41),
      point at `scripts/daimon-mcp` (42). S
- [ ] [Low] approval.md: fifteen examples (48), drop "layer 3" jargon (50), plain names for
      classifiers (51), `persistError` (52). S
- [ ] [Low] logging.md: thread `session.start` fields (53), CLI `session.end` has no reason (54),
      `persistError` (55), an example summary line (58). S
- [ ] [Low] design.md: `DaimonMCP` in layout, `approvals` subcommand, `approvals.json`, full config
      field list, `/exit`, `ToolRegistry` instance property, transcript persistence exists
      (67, 68, 69). S
- [ ] [Low] CLAUDE.md: subcommand list and the picker label (70, 71). S
- [ ] [Low] README: Homebrew path in the MCP snippet, uninstall and upgrade lines (5, 6). S
- [ ] [Low] daimon.md: mention `/q`, and add a half-sentence definition of "turn" (22, 60). S

## What was verified and how

- Built at `0aae5da`; `daimon --version` printed `0.1.2`; every subcommand's `--help` compared with
  daimon.md.
- Ran under `DAIMON_HOME=/tmp/daimon-docs-review`: `doctor`, `tools` (plain, `--json`,
  `--markdown`), `logs` with every documented filter and an unknown kind, `approvals` list, revoke,
  clear, `chat --list`, `chat --save`, `chat --resume`, the three `respond` examples from daimon.md,
  `--yes` with `uname -m`, refusals without `--yes` for `touch`, `swift test`, and a credential-named
  file via `read_file`, a sandboxed write outside the launch directory, `--unsafe`, exit codes for
  empty stdin, unknown `--tool`, unknown `--model`, and four malformed configs, nine partial config
  shapes, a piped `chat` session answering `p`, and `daimon mcp` with the documented smoke test plus
  `tools/list`, `resources/list`, `resources/read`, a refusal without elicitation, a second call on a
  thread with `tools`, `close_thread` on a missing and an existing thread, and a missing `prompt`.
- Checked the Homebrew tap and release tags over HTTPS (read-only).
- Not exercised: Private Cloud Compute, log rotation, context condensation, the eval suite, a real
  elicitation-capable client, Codex configuration, Gatekeeper behaviour.
