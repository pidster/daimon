# Backlog

Work agreed but not started, in rough priority order. Each item becomes an ADR when it is picked up.

## Policy

- Done 2026-09-19: each simple command in a line is checked and approved separately, remembered by
  program ([ADR 0015](decisions/0015-per-command-approval.md)).

## Enabling other harnesses (see the objective)

daimon's offer to another harness is work done locally that the harness would otherwise do with its own
tokens on a remote model: reading, condensing, classifying, extracting, and answering over local data, so
the caller's model never ingests the raw material. Other harnesses already run commands locally; that is
not the differentiator. Items, in order of leverage:

- **Receipts.** Every `respond` result reports what happened: tools called with arguments, files read,
  commands run with exit status, approvals asked and answered, tokens used. Makes delegated work
  verifiable by the caller.
- **Structured output.** `respond` accepts a JSON schema and returns validated JSON via guided
  generation, so results feed straight into the caller's logic.
- **Condensing tools.** Purpose-built MCP tools that keep raw content on the device and return small
  results: summarise a file or a diff (chunked map-reduce inside daimon), triage test or build output
  into a structured failure list, answer a question over a set of files, extract fields to a schema.
  These encode the prompting and paging so the caller does not have to coax a small model.
- **A measured task catalogue.** Extend the eval harness to those tools and publish success rates in
  `daimon://tools`, so a caller knows which delegations are reliable.
- **Reverse delegation through MCP sampling.** When the on-device model is stuck on a sub-step, ask the
  calling harness's model through the protocol, with data leaving the device only for that step and only
  with approval.
- **Roots and progress.** Use the client's declared roots as the sandbox's writable root; send progress
  notifications during long commands.

## Models

- **Locally installed models beyond Apple's.** The intent is to select any model installed on the Mac.
  Probed in the macOS 27.0 SDK on 2026-09-19 (`FoundationModels.swiftinterface`): the framework has no
  catalogue of installed models. `SystemLanguageModel` is one model with two use cases (`general`,
  `contentTagging`); `SystemLanguageModel.Adapter` is obsoleted in 27.0 on every platform, so adapter
  files cannot be loaded; `PrivateCloudComputeLanguageModel` is the only other Apple model. The extension
  point is the `LanguageModel` and `LanguageModelExecutor` protocols (27.0): daimon can plug a backend
  into `LanguageModelSession` by implementing an executor over a local runtime (MLX, llama.cpp, Ollama)
  and naming it as a third `ModelSelection` in `config.json`. Next step is a spike on what the executor
  protocol requires (tool calling, streaming, token counting) and which runtime to try first; then an ADR
  amending [ADR 0013](decisions/0013-model-selection.md). Discovery of "what is installed" would be
  daimon's own (a models directory or the runtime's list), not the framework's.

## Open design

- Approval for clients that do not render elicitation (mobile). Paused; see
  `docs/decisions/0014-persisted-approvals.md` for what exists.
