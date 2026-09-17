# daimon as an MCP server

`daimon mcp` speaks the Model Context Protocol over stdio, so other agent harnesses can delegate work to the
on-device model. It advertises three tools. Stdout is the protocol channel; diagnostics go to stderr. The
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

## Tools

### `respond`

Run a prompt on the on-device model, with daimon's tools available to it, on a conversation thread.

| Argument | Type | Required | Meaning |
| --- | --- | --- | --- |
| `prompt` | string | yes | The task. Keep it short; the model's window is about 4k tokens. |
| `thread_id` | string | no | Omit to start a thread (an id is generated). Supply an unused id to name a new thread. Supply a known id to continue it. `[A-Za-z0-9._-]{1,64}`. |
| `instructions` | string | no | System instructions. Only when a thread starts; an error afterwards. |
| `tools` | string[] | no | Names of daimon tools to enable. Only when a thread starts. Default: all. |

Result content is the reply text. `structuredContent`:

```json
{ "thread_id": "…", "created": true, "condensed": false, "text": "…" }
```

`condensed` is true when older turns were dropped to fit the window on this call. Threads live in memory for
the server's lifetime; the least recently used is evicted beyond `maxThreads` (32). Calls on one thread run
in order; different threads run concurrently.

### `run_command`

Run a shell command directly, without the model. Same limits and safety notes as the model-facing tool:
see [tools/run_command.md](tools/run_command.md).

| Argument | Type | Required |
| --- | --- | --- |
| `command` | string | yes |
| `working_directory` | string | no |

### `close_thread`

Free a thread's model session.

| Argument | Type | Required |
| --- | --- | --- |
| `thread_id` | string | yes |

## Errors

- Malformed arguments (missing `prompt`, bad `thread_id`) are JSON-RPC `invalidParams` errors.
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
