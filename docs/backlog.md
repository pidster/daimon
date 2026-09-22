# Backlog

Work agreed but not started, in rough priority order. Each item becomes an ADR when it is picked up.

## Policy

- Done 2026-09-19: each simple command in a line is checked and approved separately, remembered by
  program ([ADR 0015](decisions/0015-per-command-approval.md)).

## Enabling other harnesses (see the objective)

wisp's offer to another harness is work done locally that the harness would otherwise do with its own
tokens on a remote model: reading, condensing, classifying, extracting, and answering over local data, so
the caller's model never ingests the raw material. Other harnesses already run commands locally; that is
not the differentiator. Items, in order of leverage:

- Done 2026-09-20: receipts. Every `respond` result carries `structuredContent.receipt`, the turn's tool
  calls, commands with exit status, denials, approvals, and errors, folded from the audit events
  ([ADR 0021](decisions/0021-receipts.md)). Open: token usage, once wisp records what a runtime reports
  (see "Context estimation from the runtime").
- Done 2026-09-20: structured output. `respond` and the CLI (`--schema`) take a JSON Schema and return
  JSON of that shape through guided generation ([ADR 0022](decisions/0022-structured-output.md)).
- **Condensing tools.** Purpose-built MCP tools that keep raw content on the device and return small
  results ([ADR 0023](decisions/0023-condensing-tools.md)). Done 2026-09-20: `triage`, build or test
  output into a failure list. Done 2026-09-21: `summarise_diff`, a diff into per-file lines and review
  flags. Next: summarise a file, answer a question over a set of files, extract fields to a schema. A deterministic pre-pass for known output formats
  (`file:line:col: error:`, `error[E…] --> file:line`, `FAILED path::test`) would make those cases exact
  and leave the model the rest; measure it against the eval fixtures first.
- Done 2026-09-20: a measured task catalogue. `scripts/check eval` records a `Measurement` per task
  into an embedded resource; the tool catalogue and `wisp://measurements` publish them
  ([ADR 0026](decisions/0026-task-catalogue.md), [measurements.md](measurements.md)).
- **Reverse delegation through MCP sampling.** When the on-device model is stuck on a sub-step, ask the
  calling harness's model through the protocol, with data leaving the device only for that step and only
  with approval.
- **Roots and progress.** Use the client's declared roots as the sandbox's writable root; send progress
  notifications during long commands.

## Terminal front end

Accepted 2026-09-22 ([ADR 0029](decisions/0029-tui-front-end.md)). Next, in order: line editing and
history in `wisp-tui`'s input (cursor keys, multi-line composition, paste); a `turn` event in the
protocol and a decision on raw versus pre-rendered events; a bordered approval dialog with the reasons inside
it; Markdown-ish rendering of replies at commit time.

## Models

- Done 2026-09-19: `ollama:<name>` models through a wisp-supplied executor
  ([ADR 0016](decisions/0016-local-runtimes-through-an-executor.md)).
- Done 2026-09-20: a backend registry with declared capabilities, and MLX Swift and Core AI as backends
  ([ADR 0019](decisions/0019-model-backends.md)); a Core ML approval-risk classifier behind a versioned
  contract ([ADR 0020](decisions/0020-coreml-risk-classifier.md)).
- Done 2026-09-20: context estimation from the runtime. `Agent` condenses ahead of a known window from
  the usage every reply reports; Ollama is asked for an explicit `contextLength`
  ([ADR 0025](decisions/0025-context-estimation.md)).
- Done 2026-09-20: agent tests without the model. `ScriptedModel` drives `Agent`, the tool loop,
  `WispServer` over a real client and in its unit tests (the fake thread is gone), and the whole
  `wisp chat` loop, which moved into `WispCore` as `ChatLoop` with injected input and output.

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
  `-32603`. wisp works around it in `CompatibilityTransport`; drop the workaround when the SDK
  changes the type.

## Open design

- **Escalations.** Approval and inquiry as distinct verbs, delivered over more channels than MCP
  elicitation (the harness's own question dialog, a terminal, a file, a webhook), so an operator who is
  another agent, or absent, still gets a bounded, audited answer. Proposal written 2026-09-20 at
  `proposals/2026-09-20-escalations.md`; awaiting review before an ADR. It subsumes the earlier question of
  approval for clients that do not render elicitation (mobile), paused since
  [ADR 0014](decisions/0014-persisted-approvals.md).
