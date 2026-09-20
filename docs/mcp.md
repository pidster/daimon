# daimon as an MCP server

`daimon mcp` speaks the Model Context Protocol over stdio, so other agent harnesses can delegate work to the
on-device model. It advertises two tools: `respond` and `close_thread`. daimon's own tools (`run_command`,
`read_file`, `current_date`) are not exposed directly; they are reachable only by asking `respond` to use
them, so every command runs under the model's policy, sandbox, and approval with the audit trail of a
turn ([ADR 0006](decisions/0006-mcp-server-over-stdio.md), amended). Stdout is the protocol channel; diagnostics go to stderr. The
server runs until the client closes stdin.

## Client configuration

Claude Code (`.mcp.json`):

```json
{ "mcpServers": { "daimon": { "command": "/path/to/daimon", "args": ["mcp"] } } }
```

Codex (`~/.codex/config.toml`):

```toml
[mcp_servers.daimon]
command = "/path/to/daimon"
args = ["mcp"]
```

## Client compatibility

daimon speaks MCP through the official Swift SDK (0.12.1). Where the SDK is stricter than the protocol,
daimon normalises the message before the SDK sees it, in `CompatibilityTransport`, rather than refuse a
compliant client. One case so far: an `initialize` whose `capabilities.experimental` has object values,
which the specification allows and Codex sends (`{"codex/auth-change": {}}`); the SDK declares the field
as a map of strings and fails the whole request with `-32603`. Each object value is replaced by its
compact JSON text (`"{}"`), nothing else in the message changes, and daimon never reads the field. Found
and fixed on 2026-09-20 against 0.1.4; the captured request is a regression test.

## Discovering the model's tools

daimon's own tools are not MCP tools, so a client learns about them from two resources:

| URI | Content |
| --- | --- |
| `daimon://tools` | JSON: for each tool its `name`, `description`, `parameters` (JSON Schema generated from the same `@Generable` type the model sees), `limits`, and `examplePrompt`. |
| `daimon://tools.md` | The same as Markdown, with the prompting rules that work for the on-device model. |

Both are generated from the live registry, so they cannot drift from what the model can actually call.

## Inspecting daimon

Four more resources and one template let a client read daimon's own state without spending a model turn
([ADR 0018](decisions/0018-introspection.md)). They are read-only and show the same views as the model's
[`inspect`](tools/inspect.md) tool and `daimon config`.

| URI | Content |
| --- | --- |
| `daimon://config` | JSON: every setting with defaults applied, the model, the `run_command` policy, and the paths under `~/.daimon`. |
| `daimon://status` | JSON: the server session id, entry point, model, tools, live `threads` (most recent first), approvals in force for the session, and the count of standing approvals. |
| `daimon://approvals` | JSON: the standing approvals with pattern, directory, scope, level, expiry, and source. |
| `daimon://measurements` | JSON | What the eval harness found each delegated task achieves ([measurements.md](measurements.md)); the per-tool ones also appear on `daimon://tools`. |
| `daimon://audit` | JSON Lines: the last 100 audit events across every session, as written to the audit file. |
| `daimon://audit/{session}` | JSON Lines: every event of one session or thread id (a `respond` `thread_id`), for reconstructing what a delegated task did. Listed as a resource template. |

The audit resources read the audit file, so they are empty when `audit.enabled` is false. Reading them is
not itself audited (the model's `inspect` calls are, as tool calls).
`daimon tools --json` and `daimon tools --markdown` print the same text on the command line. The `respond`
tool description points at `daimon://tools`.

How to prompt for a tool, in short: name it, give exact arguments, say how to report the result, one tool
per prompt, and restrict `tools` on a new thread to what the task needs. For example:

```
Use run_command with working directory /path/to/repo to run exactly: swift test 2>&1 | tail -3 .
Report the exit status and output verbatim, nothing else.
```

## Tools

### `respond`

Run a prompt on the on-device model, with daimon's tools available to it, on a conversation thread.

| Argument | Type | Required | Meaning |
| --- | --- | --- | --- |
| `prompt` | string | yes | The task. Keep it short; the model's window is about 4k tokens. |
| `thread_id` | string | no | Omit to start a thread (an id is generated). Supply an unused id to name a new thread. Supply a known id to continue it. `[A-Za-z0-9._-]{1,64}`. |
| `instructions` | string | no | Instructions for this thread, added under daimon's own system prompt and the server's configured extension; replaces the server's `--instructions` for the thread. Only when a thread starts; an error afterwards. |
| `tools` | string[] | no | Names of daimon tools to enable. Only when a thread starts. Omitted: all. `[]`: a text-only thread, which a model that declares no tool calling can still run; a thread that needs tools on such a model is refused with a hint before generation. |
| `model` | string | no | `system` (default), `private-cloud` (alias `pcc`; data leaves the Mac), or `ollama:<name>` (a model the local Ollama serves; `daimon models` lists them). Only when a thread starts. |
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
| `turn` | The thread's turn number, which `daimon://audit/{thread_id}` events carry as `turn`. |
| `tools` | Every tool call in order: `name`, the model's `arguments` JSON, and the result's `bytes` and `seconds`; a call that threw has `error` instead. |
| `files` | Every file `edit_file` wrote: `path`, `mode`, `created`, `bytes` after the edit. |
| `commands` | Every command that ran: `exitStatus`, `timedOut`, `truncated`, `seconds`. Output is not repeated; the audit log has it verbatim. |
| `denials` | Commands turned away before running: `verdict` is `denied` (policy, with `reason`) or `disapproved` (the gate; also in `refusals`). |
| `approvals` | Every gate decision: `decision` (`approved`, `denied`, `timed-out`, `cached…`), the `level` it was asked at, the `scope` given. |
| `errors` | Errors not tied to a tool call, such as a failed turn. |
| `condensed`, `seconds` | As for the turn; `seconds` is null when the turn did not complete. |

Lists hold at most 64 entries each. Token usage is not reported yet: the framework does not expose it
for Apple's models, and daimon does not record what local runtimes report (`docs/backlog.md`).

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

The accepted subset is what a small model can fill and the framework can constrain:

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
If the client advertised elicitation at initialize, daimon asks the client's user through the protocol. The command, directory, risk level, and
reasons appear in the title, the message, and the field descriptions, because clients render different
parts; the full command leads the description so it is never trimmed. **Accept runs the command with the
scope picked in the form (this turn by default; session; project, 30 days in this directory; always, 30
days anywhere); Decline or Cancel refuses it; no answer within `approval.timeoutSeconds` (default 600; `0`
waits forever) refuses it.** Persisted scopes never apply to dangerous commands
([approval.md](approval.md)). Approvals given here share the process: a "this session" answer covers every
thread, and "project" and "always" are written to `~/.daimon/approvals.json` exactly as from the CLI.
Without elicitation, the model's tool call is refused with
`command not approved: … this client does not support elicitation …`; the reply reports that in prose and
`structuredContent.refusals` carries it structurally. The calling harness should run the command itself
or start daimon with `--yes`. See [approval.md](approval.md).

| Argument | Type | Required |
| --- | --- | --- |
| `command` | string | yes |
| `working_directory` | string | no |

### `triage`

Run a build or test command on this Mac, or read an output file already here, and get back only the
failures. The raw output stays on the Mac: daimon captures it whole (up to 1 MiB, the tail beyond),
cuts it into 4 KiB chunks at line ends, and judges each chunk in a fresh, tool-less model turn with a
schema, then merges the lists, drops duplicates, and caps the result
([ADR 0023](decisions/0023-condensing-tools.md)).

| Argument | Type | Required | Meaning |
| --- | --- | --- | --- |
| `command` | string | one of | Shell command line, run with `/bin/sh -c` under daimon's policy, sandbox, and approval exactly as the model's `run_command` would, and audited as `command.outcome`. Pipe stderr in yourself when it matters: `swift test 2>&1`. |
| `working_directory` | string | no | Absolute directory for the command. Default: daimon's. |
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
`daimon://audit/triage-<id>` shows exactly what the model saw. Approval for the command reaches the
client through elicitation as for `respond`.

Measured with `scripts/check eval` on this Mac on 2026-09-20 with the system model: on four abridged
fixtures (a `swift build` with two errors and a warning, a `swift test` with two failing tests, a
`cargo test` with two compile errors, a `pytest` with one failure) every expected failure was found,
7 of 7, with no spurious findings; the model reports a failing test by its assertion's `file:line` rather
than its name. Output shapes not in the fixtures are not measured.

### `close_thread`

Free a thread's model session.

| Argument | Type | Required |
| --- | --- | --- |
| `thread_id` | string | yes |

## Audit

Every request and result is recorded in `~/.daimon/logs/audit.jsonl` under the server's session, and each
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
| daimon mcp
```

The `sleep` keeps stdin open; a real client holds the pipe for the whole session.
