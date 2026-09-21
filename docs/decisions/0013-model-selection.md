# ADR 0013: Sessions run on a selectable model; system is the default and the only one that stays on device

Date: 2026-09-17. Status: accepted. Amended by [ADR 0016](0016-local-runtimes-through-an-executor.md) (custom executors).

## Context

macOS 27's `LanguageModelSession` accepts any `LanguageModel`, and the SDK ships two: the on-device
`SystemLanguageModel` and `PrivateCloudComputeLanguageModel`, Apple's larger server model with tool
calling and reasoning. Custom LoRA adapters (`SystemLanguageModel.Adapter`) exist in the framework but
are marked unavailable on macOS, so they are not an option here. A custom `LanguageModel` with its own `Executor` is
also possible for other backends. Probed on this machine: PCC reports available with a quota API, and requests from an ad hoc signed CLI
are intermittent: one answered, others failed with `ModelManagerError 1046`. The cause is not yet
understood; a signed app identity or entitlement is the leading hypothesis, service availability another.

## Decision

- `ModelSelection` names the model: `system` (default) or `private-cloud`. It parses
  from `config.json`'s `model`, `--model` on `respond`, `chat`, and `mcp`, and the MCP `respond` argument
  `model` (bound when a thread starts, like instructions and tools).
- `ResolvedModel` checks availability once and erases the concrete model type behind session makers, so
  `Agent` is not generic and the rest of the code does not care which model runs. Token counting is
  optional because only the system model offers it.
- The risk classifier always uses the system model, whatever the session runs on: it must be cheap, local,
  and private, and its verdicts must not depend on the model doing the work.
- Any model that sends data off the machine is explicit opt-in per session: it is never a silent default,
  the CLI prints a note on stderr when one is chosen, the MCP tool description says so, and every
  `session.start` audit event records the model. The README's on-device claim is stated for the default.
- Custom executors for other backends are out of scope until a spike shows what the executor protocol
  allows. Adapters are revisited if Apple enables them on macOS.

## Consequences

- `Agent`'s `contextTokens()` returns nil on models that cannot count; `chat` prints "unknown".
- `wisp doctor` checks the configured model in addition to the system model.
- `--model private-cloud` works when Apple's service accepts the request and otherwise fails with the
  framework's error, which the audit log records. Understanding the intermittent `1046` failure is open
  work, likely tied to the signing decision.
