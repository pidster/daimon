# The `fm` command family, as observed

`/usr/bin/fm` is the "Apple Foundation Models CLI" shipped with macOS 27. These notes record what it offers so
that wisp can borrow its ergonomics and avoid duplicating what it already does. Observed 2026-09-17.

## Subcommands

| Command | Notes |
| --- | --- |
| `fm available` | Reports "System model available" when the on-device model can be used |
| `fm respond` | One-shot prompt. `--instructions`, `--schema <file>`, `--image`/`--label`, `--text`, `--resume`/`--save-transcript`, `--[no-]stream`, `--greedy`, `--use-case`, `--guardrails` |
| `fm chat` | Interactive REPL. Sessions persist under `~/.fm/sessions/`; `--resume <name>`, `--continue` |
| `fm count-tokens` | Token count for prompt, instructions, or a saved transcript |
| `fm schema object` | Generates a structured-output schema from flags such as `--string name --int age` |
| `fm serve` | Chat Completions server: `GET /health`, `GET /v1/models`, `POST /v1/chat/completions`; TCP or Unix socket |

Only one model exists: `system`.

## Tool support

- `--tool <name>` on `respond` and `chat` accepts only the built-ins `barcode` and `ocr`. There is no way to
  register a user-defined tool.
- `fm serve` ignores the OpenAI-style `tools` array. Given a `get_weather` function definition, the model wrote
  prose about wanting to call the tool and never returned `tool_calls`. The server also streams SSE chunks even
  when `stream` is omitted.

These two facts are why wisp links the framework directly instead of wrapping `fm`; see
[ADR 0001](decisions/0001-swift-and-foundationmodels.md).

## Ergonomics worth mirroring

Flag names (`--instructions`, `--[no-]stream`, `--tool`), reading the prompt from stdin when no argument is
given, and streaming by default.
