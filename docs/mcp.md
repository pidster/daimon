# wisp as an MCP server

`wisp mcp` speaks the Model Context Protocol over stdio, so other agent harnesses can delegate work to the
on-device model. It advertises two tools: `respond` and `close_thread`. wisp's own tools (`run_command`,
`read_file`, `current_date`) are not exposed directly; they are reachable only by asking `respond` to use
them, so every command runs under the model's policy, sandbox, and approval with the audit trail of a
turn ([ADR 0006](decisions/0006-mcp-server-over-stdio.md), amended). Stdout is the protocol channel; diagnostics go to stderr. The
server runs until the client closes stdin.

## Client configuration

Claude Code (`.mcp.json`):

```json
{ "mcpServers": { "wisp": { "command": "/path/to/wisp", "args": ["mcp"] } } }
```

Codex (`~/.codex/config.toml`):

```toml
[mcp_servers.wisp]
command = "/path/to/wisp"
args = ["mcp"]
```

## Client compatibility

wisp speaks MCP through the official Swift SDK (0.12.1). Where the SDK is stricter than the protocol,
wisp normalises the message before the SDK sees it, in `CompatibilityTransport`, rather than refuse a
compliant client. One case so far: an `initialize` whose `capabilities.experimental` has object values,
which the specification allows and Codex sends (`{"codex/auth-change": {}}`); the SDK declares the field
as a map of strings and fails the whole request with `-32603`. Each object value is replaced by its
compact JSON text (`"{}"`), nothing else in the message changes, and wisp never reads the field. Found
and fixed on 2026-09-20 against 0.1.4; the captured request is a regression test.

## Discovering the model's tools

wisp's own tools are not MCP tools, so a client learns about them from two resources:

| URI | Content |
| --- | --- |
| `wisp://tools` | JSON: for each tool its `name`, `description`, `parameters` (JSON Schema generated from the same `@Generable` type the model sees), `limits`, and `examplePrompt`. |
| `wisp://tools.md` | The same as Markdown, with the prompting rules that work for the on-device model. |

Both are generated from the live registry, so they cannot drift from what the model can actually call.

## Inspecting wisp

Four more resources and one template let a client read wisp's own state without spending a model turn
([ADR 0018](decisions/0018-introspection.md)). They are read-only and show the same views as the model's
[`inspect`](tools/inspect.md) tool and `wisp config`.

| URI | Content |
| --- | --- |
| `wisp://config` | JSON: every setting with defaults applied, the model, the `run_command` policy, and the paths under `~/.wisp`. |
| `wisp://status` | JSON: the server session id, entry point, model, tools, live `threads` (most recent first), approvals in force for the session, and the count of standing approvals. |
| `wisp://approvals` | JSON: the standing approvals with pattern, directory, scope, level, expiry, and source. |
| `wisp://measurements` | JSON | What the eval harness found each delegated task achieves ([measurements.md](measurements.md)); the per-tool ones also appear on `wisp://tools`. |
| `wisp://audit` | JSON Lines: the last 100 audit events across every session, as written to the audit file. |
| `wisp://audit/{session}` | JSON Lines: every event of one session or thread id (a `respond` `thread_id`), for reconstructing what a delegated task did. Listed as a resource template. |

The audit resources read the audit file, so they are empty when `audit.enabled` is false. Reading them is
not itself audited (the model's `inspect` calls are, as tool calls).
`wisp tools --json` and `wisp tools --markdown` print the same text on the command line. The `respond`
tool description points at `wisp://tools`.

How to prompt for a tool, in short: name it, give exact arguments, say how to report the result, one tool
per prompt, and restrict `tools` on a new thread to what the task needs. For example:

```
Use run_command with working directory /path/to/repo to run exactly: swift test 2>&1 | tail -3 .
Report the exit status and output verbatim, nothing else.
```

## Tools

### `respond`

Run a prompt on the on-device model, with wisp's tools available to it, on a conversation thread.

| Argument | Type | Required | Meaning |
| --- | --- | --- | --- |
| `prompt` | string | yes | The task. Keep it short; the model's window is about 4k tokens. |
| `thread_id` | string | no | Omit to start a thread (an id is generated). Supply an unused id to name a new thread. Supply a known id to continue it. `[A-Za-z0-9._-]{1,64}`. |
| `instructions` | string | no | Instructions for this thread, added under wisp's own system prompt and the server's configured extension; replaces the server's `--instructions` for the thread. Only when a thread starts; an error afterwards. |
| `tools` | string[] | no | Names of wisp tools to enable. Only when a thread starts. Omitted: all. `[]`: a text-only thread, which a model that declares no tool calling can still run; a thread that needs tools on such a model is refused with a hint before generation. |
| `model` | string | no | `system` (default), `private-cloud` (alias `pcc`; data leaves the Mac), or `ollama:<name>` (a model the local Ollama serves; `wisp models` lists them). Only when a thread starts. |
| `schema` | object | no | A JSON Schema for this reply. The reply is JSON of that shape through the framework's guided generation, also parsed into `structuredContent.output`. Per call, on any thread; see "Structured output" below. |

Result content is the reply text. `structuredContent`:

```json
{ "thread_id": "…", "created": true, "condensed": false, "text": "…", "refusals": [], "receipt": { … }, "output": null }
```

`output` is the reply parsed as JSON when the call gave a `schema`, and null otherwise.

`refusals` lists every command the gate refused during the turn, as `{ "command", "reason" }`, so a
harness can detect a refusal structurally instead of parsing the model's prose. The result is not
`isError` in that case: the model answered, and its answer says what it could not do.

`receipt` is what the turn did, folded from the thread's audit events so the caller can verify
delegated work without reading the log ([ADR 0021](decisions/0021-receipts.md)):

```json
{
  "turn": 3,
  "tools": [{ "name": "run_command", "arguments": "{\"command\":\"git status\"}", "bytes": 212, "seconds": 0.4 }],
  "commands": [{ "command": "git status", "exitStatus": 0, "timedOut": false, "truncated": false, "seconds": 0.3 }],
  "files": [],
  "denials": [],
  "approvals": [{ "command": "git status", "level": "moderate", "decision": "approved", "scope": "session" }],
  "errors": [],
  "condensed": false,
  "seconds": 2.1
}
```

| Field | Meaning |
| --- | --- |
| `turn` | The thread's turn number, which `wisp://audit/{thread_id}` events carry as `turn`. |
| `tools` | Every tool call in order: `name`, the model's `arguments` JSON, and the result's `bytes` and `seconds`; a call that threw has `error` instead. |
| `files` | Every file `edit_file` wrote: `path`, `mode`, `created`, `bytes` after the edit. |
| `commands` | Every command that ran: `exitStatus`, `timedOut`, `truncated`, `seconds`. Output is not repeated; the audit log has it verbatim. |
| `denials` | Commands turned away before running: `verdict` is `denied` (policy, with `reason`) or `disapproved` (the gate; also in `refusals`). |
| `approvals` | Every gate decision: `decision` (`approved`, `denied`, `timed-out`, `cached…`), the `level` it was asked at, the `scope` given. |
| `errors` | Errors not tied to a tool call, such as a failed turn. |
| `condensed`, `seconds` | As for the turn; `seconds` is null when the turn did not complete. |

Lists hold at most 64 entries each. Token usage is not reported yet: the framework does not expose it
for Apple's models, and wisp does not record what local runtimes report (`docs/backlog.md`).

`condensed` is true when older turns were dropped to fit the window on this call. Threads live in memory for
the server's lifetime; the least recently used is evicted beyond `maxThreads` (32), which is audited as a
`session.end` with reason `evicted`. Naming a new `thread_id` from two concurrent calls creates it once. Calls on one thread run
in order; different threads run concurrently.

## Structured output

Give `schema` and the reply is JSON of that shape rather than prose: the framework constrains
generation to the schema ([ADR 0022](decisions/0022-structured-output.md)), so the result parses and
has the declared properties, and `structuredContent.output` carries it parsed. The model must declare
guided generation (`system`, `private-cloud`, Ollama models that report `completion`, Core AI bundles
whose engine supports it); otherwise the call is refused before generation with a hint. The schema is
per call: the next call on the thread is prose again unless it gives one too.

Shaped replies are capped at 1024 output tokens (`Agent.maximumSchemaTokens`): a small model can loop
inside a string the schema cannot bound, and the cap turns that into a failed call instead of a full
window (probed 2026-09-21: one chunk ran to 8193 tokens and six minutes before the cap). The accepted
subset is what a small model can fill and the framework can constrain:

| Construct | Accepted |
| --- | --- |
| root | `type: object` with `properties`; `required` names the properties that must appear, the rest are optional |
| `string` | plain, or with `enum` of strings |
| `integer`, `number`, `boolean` | plain |
| `array` | `items` of one accepted schema; `minItems`, `maxItems` |
| `object` | nested, same rules; at least one property |
| `description` | passed to the model on the root and on each property |

`$ref`, `anyOf`/`oneOf`/`allOf`/`not`, `pattern`, `format`, `additionalProperties`, and a `type` list
are refused by name with the path (`schema at /notes/items/: '$ref' is not supported`) as a tool error.
The audit `prompt` event carries the schema. Example:

```json
{ "prompt": "Which language is this: fn main() {}", "tools": [],
  "schema": { "type": "object", "properties": { "language": { "type": "string", "enum": ["swift", "rust", "other"] },
              "confidence": { "type": "number" } }, "required": ["language", "confidence"] } }
```

## Approval

Commands the model runs inside `respond` that are risky (by default `moderate` and above) need approval.
If the client advertised elicitation at initialize, wisp asks the client's user through the protocol. The command, directory, risk level, and
reasons appear in the title, the message, and the field descriptions, because clients render different
parts; the full command leads the description so it is never trimmed. **Accept runs the command with the
scope picked in the form (this turn by default; session; project, 30 days in this directory; always, 30
days anywhere); Decline or Cancel refuses it; no answer within `approval.timeoutSeconds` (default 600; `0`
waits forever) refuses it.** Persisted scopes never apply to dangerous commands
([approval.md](approval.md)). Approvals given here share the process: a "this session" answer covers every
thread, and "project" and "always" are written to `~/.wisp/approvals.json` exactly as from the CLI.
Without elicitation, the model's tool call is refused with
`command not approved: … this client does not support elicitation …`; the reply reports that in prose and
`structuredContent.refusals` carries it structurally. The calling harness should run the command itself
or start wisp with `--yes`. See [approval.md](approval.md).

| Argument | Type | Required |
| --- | --- | --- |
| `command` | string | yes |
| `working_directory` | string | no |

### `triage`

Run a build or test command on this Mac, or read an output file already here, and get back only the
failures. The raw output stays on the Mac: wisp captures it whole (up to 1 MiB, the tail beyond),
cuts it into 4 KiB chunks at line ends, and judges each chunk in a fresh, tool-less model turn with a
schema, then merges the lists, drops duplicates, and caps the result
([ADR 0023](decisions/0023-condensing-tools.md)).

| Argument | Type | Required | Meaning |
| --- | --- | --- | --- |
| `command` | string | one of | Shell command line, run with `/bin/sh -c` under wisp's policy, sandbox, and approval exactly as the model's `run_command` would, and audited as `command.outcome`. Pipe stderr in yourself when it matters: `swift test 2>&1`. |
| `working_directory` | string | no | Absolute directory for the command. Default: wisp's. |
| `path` | string | one of | Absolute path of an output file on this Mac; the read clears the gate as `read_file` does. |
| `model` | string | no | The judging model, as for `respond`; it must declare guided generation. Default: the configured model. |
| `max_findings` | integer | no | Findings to return at most (default 20); `more` is true when some were dropped. |

Result content is a headline and one finding per line; `structuredContent`:

```json
{
  "source": { "command": "swift test 2>&1", "workingDirectory": "/repo", "exitStatus": 1,
              "timedOut": false, "truncated": false, "bytes": 18234 },
  "chunks": 5, "more": false,
  "findings": [
    { "kind": "error", "location": "Sources/A.swift:42:13", "message": "cannot find 'fooBar' in scope" },
    { "kind": "test-failure", "location": "CommandRunnerTests.swift:88:9", "message": "Expectation failed: …" }
  ]
}
```

`kind` is `error`, `test-failure`, `warning`, `crash`, or `other`; `location` is the `file:line` or test
name as printed, or null. For a file source `exitStatus` is null. Each triage is its own audited session
(`triage-<id>`: start, the command or read, one prompt and response per chunk, end), so
`wisp://audit/triage-<id>` shows exactly what the model saw. Approval for the command reaches the
client through elicitation as for `respond`.

Measured with `scripts/check eval` on this Mac on 2026-09-20 with the system model: on four abridged
fixtures (a `swift build` with two errors and a warning, a `swift test` with two failing tests, a
`cargo test` with two compile errors, a `pytest` with one failure) every expected failure was found,
7 of 7, with no spurious findings; the model reports a failing test by its assertion's `file:line` rather
than its name. Output shapes not in the fixtures are not measured.

### `summarise_diff`

Run a command that prints a unified diff (such as `git diff HEAD~3`), or read a diff file already on
this Mac, and get back a per-file summary with review flags. The diff stays on the Mac: wisp captures
it whole (up to 1 MiB), cuts it into 4 KiB chunks at file, then hunk, then line boundaries, judges each
chunk in a fresh tool-less turn with a schema, and joins the answers onto the file list the diff itself
gives ([ADR 0023](decisions/0023-condensing-tools.md)). Paths, change kinds, and line counts are read
from the diff headers and hunks, never from the model, and so are the flags the text proves: a deleted
test file, a test disabled on an added line (`.disabled(`, `XCTSkip`, `@pytest.mark.skip`, `#[ignore]`
and the like), a credential literal on an added line (known key prefixes, a private key block, or a
secret-named assignment of a long string, as `scan_secrets` finds them; the flag's note gives the kind
and a masked preview, never the value), and binary content. The model adds the headline, one line
per file, and any flag the rules miss; anything it says about a file the diff does not contain is
dropped. Rules never remove a flag.

| Argument | Type | Required | Meaning |
| --- | --- | --- | --- |
| `command` | string | one of | A command line that prints a unified diff, run under wisp's policy, sandbox, and approval as `run_command` would. |
| `working_directory` | string | no | Absolute directory for the command. Default: wisp's. |
| `path` | string | one of | Absolute path of a diff file on this Mac; the read clears the gate as `read_file` does. |
| `model` | string | no | The judging model, as for `respond`; it must declare guided generation. |
| `max_files` | integer | no | Files to list at most (default 40); the rest are counted in `more`. |

Result content is a headline block and one line per flag and per file; `structuredContent`:

```json
{
  "source": { "command": "git diff HEAD~1", "workingDirectory": "/repo", "exitStatus": 0, "truncated": false, "bytes": 2210 },
  "chunks": 1, "more": 0, "added": 14, "removed": 3,
  "headline": "Adds atomic writes to edit_file and tests them",
  "files": [
    { "path": "Sources/Tools/FileWriter.swift", "change": "modified", "added": 12, "removed": 1,
      "summary": "writes to a temporary file and renames it over the target" },
    { "path": "Tests/FileWriterTests.swift", "change": "modified", "added": 2, "removed": 2, "summary": "checks the mode survives" }
  ],
  "flags": [{ "kind": "deleted-test", "path": "Tests/OldTests.swift", "note": "the timeout test was removed" }]
}
```

`change` is `added`, `modified`, `deleted`, or `renamed`; `summary` is null for a file the model said
nothing about. Flag kinds: `deleted-test` (a test removed or disabled), `secret`, `binary`, `generated`,
`large`; a flag the model leaves pathless lands on the chunk's only file when it had one. Each summary is its own audited session (`summarise-<id>`), so
`wisp://audit/summarise-<id>` shows what the model saw. The measured result is in
[measurements.md](measurements.md).

### `scan_secrets`

Scan a command's output or a file on this Mac for credentials, and optionally personal data, and get
back where they are with the values masked. Rules find shapes that are credentials by construction
(provider key prefixes, private key blocks, a password in a URL, secret-named assignments with a real
looking value); `thorough` adds the on-device model's pass over the rule-redacted text for what rules
cannot recognise ([ADR 0031](decisions/0031-secret-scanning-and-redaction.md)). A unified diff is
scanned by its added lines and located as `path:line` in the new file, so `git diff --cached` checks a
commit before it is made. A best effort, not a guarantee.

| Argument | Type | Required | Meaning |
| --- | --- | --- | --- |
| `command` | string | one of | Shell command line whose output to scan, run as for `triage`. |
| `working_directory` | string | no | Absolute directory for the command. Default: wisp's. |
| `path` | string | one of | Absolute path of a file on this Mac; the read clears the gate as `read_file` does. |
| `personal` | boolean | no | Report personal data too (emails, phone and card numbers, public IPs, addresses, private hostnames, user names). Default false. |
| `thorough` | boolean | no | Add the model's pass: names, customer numbers, unusual credentials. Up to three turns per 4 KiB, about 2 s each. Default false. |
| `model` | string | no | The model for the thorough pass, as for `respond`. |
| `max_findings` | integer | no | Findings to return at most (default 50); `more` is true when some were dropped. |

Result content is a headline and one `location  kind  preview` line per finding; `structuredContent`:

```json
{
  "source": { "command": "git diff --cached", "workingDirectory": "/repo" }, "bytes": 2210, "diff": true,
  "thorough": false, "chunks": null, "more": false,
  "findings": [{ "kind": "github-token", "category": "secret", "location": "Sources/Client.swift:14",
                 "preview": "ghp_…(40 chars)", "detector": "rule" }]
}
```

`detector` is `rule` or `model`. The value itself is in neither the result nor the `secrets.scan` audit
event. Each scan is its own audited session (`scan-<id>`).

### `redact`

Get a command's output or a file on this Mac back with credentials and personal data replaced by
numbered markers such as `[REDACTED:email#1]` (the same value, the same number), so a log, crash report,
or data file can be read without its secrets. Rules always run; `thorough` adds the model's pass, whose
answers are only kept when they occur exactly in the text, and replacing them is done by wisp, never by
the model ([ADR 0031](decisions/0031-secret-scanning-and-redaction.md)).

| Argument | Type | Required | Meaning |
| --- | --- | --- | --- |
| `command` | string | one of | Shell command line whose output to redact, run as for `triage`; narrow it yourself (`tail -500 app.log`). |
| `working_directory` | string | no | Absolute directory for the command. Default: wisp's. |
| `path` | string | one of | Absolute path of a file on this Mac; the read clears the gate as `read_file` does. |
| `secrets_only` | boolean | no | Replace credentials and keep personal data. Default false. |
| `thorough` | boolean | no | Add the model's pass for names, addresses, and identifiers. Default false. |
| `model` | string | no | The model for the thorough pass, as for `respond`. |
| `max_bytes` | integer | no | Bytes of redacted text to return at most (default 32768); `truncated` is true when it was cut. |

Result content is a summary line, a blank line, and the redacted text; `structuredContent` has `source`,
`bytes`, `text`, `truncated`, `thorough`, `chunks`, and `replaced` (occurrences per kind). Each
redaction is its own audited session (`redact-<id>`); the `redaction` event records the counts only.
The measured result of the thorough pass is in [measurements.md](measurements.md).

### `condense_log`

Condense a log on this Mac (an app's log, CI output, `/usr/bin/log show`) to its distinct messages,
without a model ([ADR 0032](decisions/0032-log-and-json-condensers.md)). Each line becomes a template:
the leading timestamp is removed and numbers, hex, UUIDs, long ids, and `log show`'s `[pid:thread]` are
replaced by `<n>`, `<hex>`, `<uuid>`, `<id>`, `[<pid>]`. Lines with the same template form a group,
ranked by severity (`fault`, `error`, `warning`, `info`) and then count. Severity is the log's own type
where it states one (`log show`'s `Error` and `Fault`, or `E` and `F` in its compact style), otherwise
it comes from words such as "failed" or "panic". A line without a timestamp in a log whose lines have
them continues the line before and takes its severity. A macOS crash report (`.ips`) is recognised
instead and returned as the process, version, OS, exception, termination, and the faulting thread's top
12 frames. Up to 8 MiB is read, the tail beyond.

| Argument | Type | Required | Meaning |
| --- | --- | --- | --- |
| `command` | string | one of | Shell command line whose output to condense, run as for `triage`, such as `/usr/bin/log show --last 10m --predicate 'process == "MyApp"'`. |
| `working_directory` | string | no | Absolute directory for the command. Default: wisp's. |
| `path` | string | one of | Absolute path of a log or `.ips` file; the read clears the gate as `read_file` does. |
| `max_groups` | integer | no | Groups to return at most (default 30); `more` is true when some were dropped. |

For a log, `structuredContent` is `{ "kind": "log", "lines", "templates", "more", "truncated",
"severities": { "fault": 3, … }, "groups": [{ "severity", "count", "template", "example", "firstLine",
"lastLine", "firstSeen", "lastSeen" }] }`; `example` is the first line of the group as printed, with
credentials redacted. For a crash report it is `{ "kind": "crash", "process", "version", "os",
"timestamp", "bugType", "exception", "termination", "faultingThread", "frames": [{ "image", "symbol",
"offset" }] }`. Measured on 2026-09-23: two minutes of `log show` (14,333 lines, 2.8 MB) reduced to 1,972
templates in 1.2 s, the top 30 in about 10 KB.

### `json_shape`

Describe the structure of a JSON document or a JSON Lines file on this Mac, or a command's JSON output,
without its data and without a model ([ADR 0032](decisions/0032-log-and-json-condensers.md)): one outline
line per place, indented by depth, giving the types seen there (`integer 1…42`, `array[0…5] of string`,
`null | object`), `?` on a key some objects lack, and a 40-character string example with credentials
and personal data redacted. The elements of an array merge into one outline, so a thousand records read
as one. Up to 16 MiB; larger input is refused rather than cut, since a document without its head does
not parse.

| Argument | Type | Required | Meaning |
| --- | --- | --- | --- |
| `command` | string | one of | Shell command line whose JSON output to outline, run as for `triage`. |
| `working_directory` | string | no | Absolute directory for the command. Default: wisp's. |
| `path` | string | one of | Absolute path of a `.json` or JSON Lines file; the read clears the gate as `read_file` does. |
| `max_depth` | integer | no | Levels of nesting to describe (default 8). |
| `examples` | boolean | no | Show string examples (default true). |

`structuredContent` is `{ "format": "json" | "jsonl", "records", "bytes", "more", "outline": [ … ] }`.
The start of the outline of 1,000 events of wisp's own audit log (471 KB), on 2026-09-23:

```
(root): array[1000] of object
  kind: string e.g. "approval.requested"
  pid: integer 1827…96284
  schema: integer 1
  session: string e.g. "release-git"
  time: string e.g. "2026-09-22T08:13:05.621Z"
  turn?: integer 1…22
  version: string e.g. "0.4.0"
  call?: string e.g. "9bdf339e"
  details: object
    command?: string e.g. "git merge --ff-only main"
```

### `close_thread`

Free a thread's model session.

| Argument | Type | Required |
| --- | --- | --- |
| `thread_id` | string | yes |

## Audit

Every request and result is recorded in `~/.wisp/logs/audit.jsonl` under the server's session, and each
thread's turns under the `thread_id` as its own session. See [logging.md](logging.md).

## Errors

- Malformed arguments (missing `prompt`, bad `thread_id`) and unknown tool names are JSON-RPC
  `invalidParams` errors.
- Execution failures (model unavailable, unknown tool name, unknown thread, command could not start) are tool
  results with `isError: true` and the message as text.

## Smoke test by hand

```
(printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"respond","arguments":{"prompt":"Say hi"}}}'; sleep 10) \
| wisp mcp
```

The `sleep` keeps stdin open; a real client holds the pipe for the whole session.
