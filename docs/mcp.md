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

## Discovering the model's tools

daimon's own tools are not MCP tools, so a client learns about them from two resources:

| URI | Content |
| --- | --- |
| `daimon://tools` | JSON: for each tool its `name`, `description`, `parameters` (JSON Schema generated from the same `@Generable` type the model sees), `limits`, and `examplePrompt`. |
| `daimon://tools.md` | The same as Markdown, with the prompting rules that work for the on-device model. |

Both are generated from the live registry, so they cannot drift from what the model can actually call.
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
| `instructions` | string | no | System instructions. Only when a thread starts; an error afterwards. |
| `tools` | string[] | no | Names of daimon tools to enable. Only when a thread starts. Default: all. |
| `model` | string | no | `system` (default) or `private-cloud` (data leaves the Mac). Only when a thread starts. |

Result content is the reply text. `structuredContent`:

```json
{ "thread_id": "…", "created": true, "condensed": false, "text": "…" }
```

`condensed` is true when older turns were dropped to fit the window on this call. Threads live in memory for
the server's lifetime; the least recently used is evicted beyond `maxThreads` (32), which is audited as a
`session.end` with reason `evicted`. Naming a new `thread_id` from two concurrent calls creates it once. Calls on one thread run
in order; different threads run concurrently.

## Approval

Risky commands (by default `moderate` and above) need approval. If the client advertised elicitation at
initialize, daimon asks the client's user through the protocol. The command, directory, risk level, and
reasons appear in the title, the message, and the field descriptions, because clients render different
parts; the full command leads the description so it is never trimmed. **Accept runs the command once;
Decline or Cancel refuses it; no answer within `approval.timeoutSeconds` (default 120) refuses it.** The
dialog has no form fields, because a picker made Claude Code's dialog unresponsive. Otherwise the call
returns
`command not approved: … this client does not support elicitation …` with `isError: true`, and the calling
harness should run the command itself or start daimon with `--yes`. See [approval.md](approval.md).

| Argument | Type | Required |
| --- | --- | --- |
| `command` | string | yes |
| `working_directory` | string | no |

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
