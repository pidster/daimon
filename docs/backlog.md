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

- Done 2026-09-20: receipts. Every `respond` result carries `structuredContent.receipt`, the turn's tool
  calls, commands with exit status, denials, approvals, and errors, folded from the audit events
  ([ADR 0021](decisions/0021-receipts.md)). Open: token usage, once daimon records what a runtime reports
  (see "Context estimation from the runtime").
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

- Done 2026-09-19: `ollama:<name>` models through a daimon-supplied executor
  ([ADR 0016](decisions/0016-local-runtimes-through-an-executor.md)).
- Done 2026-09-20: a backend registry with declared capabilities, and MLX Swift and Core AI as backends
  ([ADR 0019](decisions/0019-model-backends.md)); a Core ML approval-risk classifier behind a versioned
  contract ([ADR 0020](decisions/0020-coreml-risk-classifier.md)).
- **Context estimation from the runtime.** Ollama reports prompt and completion token counts on every
  reply; use them to estimate context use so the condensing policy acts before the runtime silently
  truncates. Repeated in practice: the git thread on the on-device model lost its instructions to hook
  output. Belongs with `ContextPolicy`, not with a new backend.
- **Agent tests without the model.** `ScriptedModel` (`Tests/DaimonTestSupport`) already drives `Agent`,
  the tool loop, and `DaimonServer.respond` over a real client. Left: replace `FakeThread` in the server
  tests with it and cover the chat loop.

## Model backends, deferred

Candidates recorded on 2026-09-20 with the MLX and Core AI work, not implemented: llama.cpp; LM Studio
(`llmster`); ONNX Runtime; PyTorch and Hugging Face Transformers; vLLM. Several serve an OpenAI-compatible
HTTP API, so the Ollama executor's transcript-to-chat mapping is most of a shared HTTP executor for them,
parameterised by base URL, auth, and the request dialect. Embeddings, reranking, and other
non-conversational models are not `LanguageModel`s and need task-specific interfaces (an `embed` tool, a
`rerank` tool) rather than a backend; that is a separate design. Packaging chores, wanted only when
someone asks for MLX from the tap: shipping MLX in the Homebrew release, which means carrying
`mlx-swift_Cmlx.bundle` beside the binary (libexec plus a symlink, or a bundle-aware formula); and making
the MLX live test find the Metal library under the test runner.

## Upstream

- Report to `modelcontextprotocol/swift-sdk`: `Client.Capabilities.experimental` is `[String: String]?`
  (`Sources/MCP/Client/Client.swift:128`, still so on main at `a0ae212`) while the specification allows
  object values; Codex sends `{"codex/auth-change": {}}` and the server fails `initialize` with
  `-32603`. daimon works around it in `CompatibilityTransport`; drop the workaround when the SDK
  changes the type.

## Open design

- **Escalations.** Approval and inquiry as distinct verbs, delivered over more channels than MCP
  elicitation (the harness's own question dialog, a terminal, a file, a webhook), so an operator who is
  another agent, or absent, still gets a bounded, audited answer. Proposal written 2026-09-20 at
  `proposals/2026-09-20-escalations.md`; awaiting review before an ADR. It subsumes the earlier question of
  approval for clients that do not render elicitation (mobile), paused since
  [ADR 0014](decisions/0014-persisted-approvals.md).
