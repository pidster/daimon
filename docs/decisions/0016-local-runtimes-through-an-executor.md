# ADR 0016: Locally installed models plug in through a daimon-supplied executor

Date: 2026-09-19. Status: accepted. Amends [ADR 0013](0013-model-selection.md).

## Context

The intent is to run daimon on any model installed on this Mac, not only Apple's. ADR 0013 left custom
backends "out of scope until a spike shows what the executor protocol allows". This is that spike,
done on 2026-09-19 against the macOS 27.0 SDK and this machine (M4 Max, 48 GiB, Ollama 0.33.3).

What the framework offers, read from `FoundationModels.swiftinterface`:

- There is no catalogue of installed models. `SystemLanguageModel` is one model with two use cases
  (`general`, `contentTagging`). `SystemLanguageModel.Adapter` is obsoleted in 27.0 on every platform,
  so adapter files cannot be loaded. `PrivateCloudComputeLanguageModel` is the only other Apple model.
- Since 27.0, `LanguageModelSession` accepts any `LanguageModel`. A model declares `capabilities` and an
  `Executor: LanguageModelExecutor`, whose one method turns a `LanguageModelExecutorGenerationRequest`
  (the transcript, the enabled tool definitions with JSON schemas, an optional output schema, generation
  and context options) into events on a `LanguageModelExecutorGenerationChannel`: `response` text
  appended or replaced, `toolCalls` with argument fragments, `reasoning`, and `updateUsage` token counts.
- The framework keeps everything above the executor: the tool loop (it invokes daimon's `Tool`s from a
  `toolCalls` event, appends the `toolOutput`, and calls the executor again), streaming snapshots, the
  transcript, guided generation parsing, and capability gating.

Measured with two executors in `DaimonCoreTests` (`ExecutorSpikeTests`, `OllamaSpikeTests`):

| Probe | Result |
| --- | --- |
| Scripted executor (no model) drives `LanguageModelSession` with `CurrentDateTool` | Tool loop ran: two executor calls, transcript `instructions, prompt, toolCalls, toolOutput, response`; text streamed in fragments. 4 ms. |
| `Agent` over the scripted model with an audit log and a scripted `contextSizeExceeded` on the first call | Overflow recovery condensed and retried; audit `prompt, condensation, response`; `contextTokens()` nil. |
| Tools given to a model whose `capabilities` lack `toolCalling` | Framework throws `unsupportedCapability` ("does not support tool calling"); the executor is not called. |
| `respond(generating:)` without `guidedGeneration` capability | Same typed error. With it, the schema arrives in `request.schema` and JSON text from the executor is parsed into the `@Generable` type. |
| Executor emits non-JSON tool arguments, or an unknown tool name | Framework errors ("cannot be completed into valid JSON", "unrecognized name"); the session does not run the tool. |
| Ollama executor over `/api/chat` (streaming, tools, `format`) with `qwen3-coder:latest` (30.5B MoE) | Tool loop and streaming: 9 fragments, correct date via `current_date`, 9.1 s cold. Guided generation: `Paris` in 8.3 s. Transcript shape identical to the system model's. |

Runtimes present on this machine: Ollama (installed, serving on 11434, models `qwen3-coder`,
`deepseek-coder-v2`, `nomic-embed-text`) and MLX weights in the Hugging Face cache without `mlx_lm`.
Ollama's `/api/tags` is a real "what is installed" list.

## Decision

- A third `ModelSelection` will name a locally served model, backed by a daimon-owned `LanguageModel`
  whose executor speaks to the runtime. Ollama is the first runtime: no build dependency, an HTTP API
  with streaming, tool calling, and JSON-schema output, and an installed-models list. Selection spelling
  and config shape are decided when it is built, but discovery of "what is installed" is daimon's (the
  runtime's list), never the framework's.
- `ResolvedModel(selection:custom:)` and `Agent.init(instructions:tools:model: ResolvedModel)` are the
  seam, added by this spike. Everything above them (`Agent`, `Session`, the MCP server, audit, approval)
  is unchanged by the choice of model, as ADR 0013 intended.
- The risk classifier keeps using the system model (ADR 0013), whatever a session runs on.
- A local runtime is on-device but is a separate process: the CLI's note for off-device models does not
  apply, but `session.start` records the model as it does today.
- Executors declare exactly the capabilities they implement; the framework's typed errors are the
  contract for the rest.

## Consequences

- Tests can drive `Agent` and the tool loop without any model through a scripted executor, so "tests
  never need the model" now extends to the agent layer; `ExecutorSpikeTests` is the first such test.
- `OllamaLiveTests` is gated by `DAIMON_OLLAMA_TESTS=1` and `DAIMON_OLLAMA_MODEL`, like the model eval;
  `OllamaModelTests` covers the mapping, bodies, chunks, and the unreachable case without a server.
- Token counting is not in the protocol; a custom model reports usage through `updateUsage` per turn,
  and `contextTokens()` stays nil. Ollama does not signal context overflow (it truncates to `num_ctx`),
  so `ContextPolicy`'s recovery never triggers on it; a later change may estimate from the usage it
  reports.
- Built the same day: `ModelSelection.ollama(name)` spelled `ollama:<name>`; `config.json`'s `ollama`
  section (`baseURL`, `timeoutSeconds`); `daimon models`, which lists Apple's two and the server's
  `/api/tags`; the doctor's configured-model check resolves through the same path. `resolve` for an
  Ollama model blocks on one `/api/tags` call with a five-second limit.
