# ADR 0036: Custom tools are command templates in the user's own config

Date: 2026-09-24. Status: accepted.

## Context

wisp's tools were fixed at build time. A user who wants the model to reach a command they use often
(`gh issue view`, a project's lint, a deploy status check) had only `run_command`, where the small model
has to compose the line itself and often gets flags wrong. Two ways to add tools were open: command
templates declared in configuration, or wisp acting as an MCP client and exposing other servers' tools.
The second is far broader, costs the 4k window a schema per foreign tool, and needs an approval design
for tools wisp cannot see into. Where definitions may live was also open: the user's `~/.wisp`, or also a
project file, which a cloned repository could use to add tools to someone's agent.

The FoundationModels `Tool` protocol takes a `GenerationSchema` for its arguments; a probe on 2026-09-24
showed a tool whose schema is built at run time from a `DynamicGenerationSchema`, with `GeneratedContent`
as its arguments, is called by the system model like any other.

## Decision

- **Command templates, in `~/.wisp/config.json` only** (`tools.custom`): a name, a description, typed
  arguments (`string`, `integer`, `number`, `boolean`; an `enum` for strings; a `default` makes an
  argument optional), a command line with `{argument}` placeholders, and optionally a working directory
  and timeout. A project cannot define or enable tools. MCP-server tools are left for a later decision.
- **`tools.disabled`** names built-in tools to leave out of the registry entirely, for every face.
- **Validated when the config loads**, so a bad definition is a malformed config with a sentence naming
  the tool and the problem: a snake_case name that is no built-in's and not repeated, a description of 1
  to 300 characters (the window is small), every placeholder declared and every argument used, known
  types, enums only on strings, defaults that fit.
- **A call runs through `run_command`'s runner, gate included.** Values are substituted into the line,
  strings single-quoted for `/bin/sh` and checked against their enum, numbers and booleans as written;
  the line then passes the policy, the classifier, approval, the sandbox, and the output bound, and is
  audited as `tool.call`, `classifier.verdict`, and `command.outcome`. A custom tool therefore grants
  nothing `run_command` does not; it saves the model composing the line.
- The tool appears wherever the registry does: the model's tools, `wisp tools`, `--tool`, the MCP
  `tools` argument, and `wisp://tools`, with limits and an example prompt generated from the definition.

## Consequences

- Smoke-tested on 2026-09-24 with a `word_count` tool (`wc -w {path}`): the system model called it with
  `{"path": "README.md"}` and wisp ran `wc -w 'README.md'` under the sandbox; an undeclared placeholder
  and a built-in's name were each refused at load with the tool named.
- Each custom tool's schema is in the prompt of every conversation that enables all tools; users should
  disable what they do not need, and `--tool` still narrows a session.
- A quoted value cannot break out of its argument, but a template can still do anything its command can;
  the classifier and approval judge the substituted line, exactly as for `run_command`.
- Tests without the model: the validation rules, rendering and quoting, defaults and enums, the schema,
  the registry with disabled and custom tools, config decoding, a real run through the runner, and the
  scripted model calling a custom tool through the gate.
