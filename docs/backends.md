# Model backends

Which models daimon can run a conversation on, how to get their assets onto this Mac, how to name
them, what each declares it can do, and what goes wrong. The decisions are
[ADR 0013](decisions/0013-model-selection.md), [ADR 0016](decisions/0016-local-runtimes-through-an-executor.md),
and [ADR 0019](decisions/0019-model-backends.md).

## How selection works

`--model`, `config.json`'s `model`, and the MCP `respond` argument `model` all take the same spelling:

| Spelling | Backend | Where the model runs |
| --- | --- | --- |
| `system` (default) | Apple's Foundation Models | on device |
| `private-cloud` (alias `pcc`) | Apple's Private Cloud Compute | Apple's servers, with a note on stderr |
| `ollama:<name>` | a local Ollama server | on device, in Ollama's process |
| `coreai:<name-or-path>` | Apple's Core AI framework, in daimon's process | on device |
| `mlx:<name-or-path>` | MLX Swift, in daimon's process | on device; only in builds made with the `MLX` trait |

`daimon models` lists what each backend can serve right now; `daimon doctor` checks the configured
model resolves. A backend this build lacks is refused with the registered ones named.

Every backend is the same above the model: the tool loop, the approval gate, the sandbox, transcripts,
and the audit log are unchanged. When a conversation opens, daimon records `model.resolved` with the
backend, the model, the asset behind it, and its declared capabilities (`docs/logging.md`).

## Private Cloud Compute

`private-cloud` needs the managed entitlement `com.apple.developer.private-cloud-compute`, which Apple
assigns to an App ID on request (App Store Small Business Program, under two million first-time
downloads) and which only a provisioning profile can authorise. An ad-hoc signed command-line tool such
as the Homebrew or `swift build` binary cannot carry it. The framework does not say so: on this Mac on
2026-09-20 `PrivateCloudComputeLanguageModel.availability` was `available` and `quotaUsage` below the
limit, and the first request failed with `LanguageModelError` code -1 wrapping
`ModelManagerServices.ModelManagerError` code 1046. daimon therefore checks its own code signature
before asking the framework and refuses with a sentence:

```
model 'private-cloud' is unavailable: this binary lacks the com.apple.developer.private-cloud-compute entitlement, …
```

`daimon models` shows the same line. Until daimon ships as a signed app with the entitlement, the
spelling is accepted for that future and every run of it is refused before any data leaves the Mac.

## Capabilities are declared, never assumed

A model may run a conversation, call tools, produce schema-shaped output, or reason. daimon opens a
conversation only when the model declares what the request needs, and refuses before generation with a
hint otherwise. Who declares them:

| Backend | Source of the declaration |
| --- | --- |
| `system`, `private-cloud` | the framework |
| `ollama` | the server's `/api/show` `capabilities` for that model (`tools`, `completion`, `thinking`, `vision`); an embedding model declares nothing |
| `coreai` | the bundle: tool-call markers in the tokenizer, a thinking format, the engine's guided-generation support |
| `mlx` | the operator, in `config.json`; an undeclared model is text only |

A text-only model can always run a conversation with no tools: `--no-tools` on the CLI, `tools: []`
over MCP. Declared support is eligibility, not quality: a model that declares tool calling may still
call tools badly, and only an evaluation says how well.

## Ollama

Install and run [Ollama](https://ollama.com); `ollama pull <name>` fetches a model. `config.json`:

```json
{ "model": "ollama:qwen3-coder", "ollama": { "baseURL": "http://127.0.0.1:11434", "timeoutSeconds": 120, "contextLength": 8192 } }
```

Errors: `no Ollama server at <url>` when nothing listens; `Ollama has no model '<name>'; installed: …`
when the name is unknown (the `:latest` tag may be omitted). Ollama does not signal context overflow; it silently drops the front of the prompt once it passes the
server's window. daimon therefore asks for an explicit window on every request (`contextLength`, sent as
`num_ctx`; larger windows cost memory) and reads the token usage every reply reports, and `Agent`
condenses the transcript ahead of the window when the last request plus the new prompt would pass 85%
of it (`docs/context-management.md`). `/tokens` in `daimon chat` shows that reported usage for these
models.

## Core AI

Apple's Core AI framework runs models exported to `.aimodel` bundles, through the `CoreAILanguageModel`
bridge from [apple/coreai-models](https://github.com/apple/coreai-models), which daimon pins by commit
(`harness/Package.swift`). Requires macOS 27 and Xcode 27 to build; nothing extra to run.

Preparing an asset (once, on any Mac with `uv`; downloads the source weights from Hugging Face):

```
git clone https://github.com/apple/coreai-models.git && cd coreai-models
uv run coreai.llm.export Qwen/Qwen3-0.6B --output-dir ~/.daimon/models/coreai
```

That writes a bundle directory (`metadata.json`, the `.aimodel`, a `tokenizer/` folder) under the
models directory. `uv run coreai.model.registry --list-models` lists the supported source models; the
recipes under `models/` give per-family options such as 4-bit weights. Measured on 2026-09-20: Qwen3
0.6B exported in two minutes to 331 MB.

Naming: `coreai:<bundle-directory-name>` under the models directory, or `coreai:/absolute/path` and
`coreai:~/path`. `config.json`:

```json
{ "model": "coreai:qwen3_0_6b_4bit_dynamic", "coreai": { "modelsDirectory": "~/.daimon/models/coreai" } }
```

`modelsDirectory` defaults to `<home>/models/coreai`. daimon never exports or downloads.

Capabilities come from the bundle: the bridge detects tool-call markers in the tokenizer vocabulary,
a thinking format, and whether the loaded engine supports guided generation. What daimon has verified,
and with which model, is in the changelog for the release that shipped it; treat any other model as
unverified until you run it.

Verified on 2026-09-20 with Qwen3 0.6B (4-bit, exported as above) on an M4 Max: the bridge declared
tool calling, guided generation, and reasoning from the bundle; a text-only reply took 6 s cold and 1 s
warm and was right every time; the `current_date` tool loop ran through the framework, with the model's
thinking recorded as `reasoning` transcript entries, in 3 of 6 attempts. The other 3 ended with
"Session ended without producing a response" from the same prompt, so at this model size and bridge
revision tool calling is declared and demonstrated but not reliable. The live test
(`DAIMON_COREAI_TESTS=1 DAIMON_COREAI_MODEL=<bundle> swift test --filter CoreAILiveTests`) asserts the
declaration and the text reply and reports the tool-loop outcomes. Two things to know about thinking models: the bridge lets the model
think before it answers and budgets 2048 tokens for reasoning models, so a small model that never
closes its thinking ends the turn with the framework error "Session ended without producing a
response" (daimon reports it as a turn error and audits it); and Qwen3's `/no_think` switch made the
bridge fail every tool call in that probe, so do not put it in the instructions of a tool-using thread.

Errors: `no Core AI bundle at <path> (no metadata.json); bundles under <dir>: …; export one with …`
when the name points nowhere; the bridge's own message (missing asset, malformed metadata, wrong bundle
kind) when the bundle is incomplete. Loading reads the tokenizer synchronously at resolve time and the
engine on first use, so the first reply after `daimon` starts is slow.

Limitations: text and tool calling only; no images or audio (the bridge supports vision models, daimon
does not pass images). Structured output is used by daimon only where a model declares guided
generation, and daimon has no structured-output feature yet. Memory is the model's: a 4B model wants
several GB.

## MLX Swift

[mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm)'s `MLXLanguageModel` bridge runs models in
MLX or Hugging Face safetensors layout in daimon's own process on the GPU. MLX compiles Metal kernels at
build time, so the bridge is behind the `MLX` package trait: the ordinary build and the sandboxed
pre-commit hook never need the Metal toolchain, and a build without the trait refuses every `mlx:` model
with a message saying so. The Homebrew release is built without the trait, because MLX looks for its
Metal library in a `mlx-swift_Cmlx.bundle` beside the executable at run time and the one-file release
does not carry it; MLX is a self-build option. To build with it:

```
xcodebuild -downloadComponent MetalToolchain     # once; several GB
cd harness && swift build -c release --traits MLX
```

Preparing an asset: a model directory holding `config.json`, the `*.safetensors`, and the tokenizer files
(`tokenizer.json`, `tokenizer_config.json`). A Hugging Face snapshot works as it is, and the
`mlx-community` quantised repositories are the usual choice; daimon does not download. Put the directory
under `<home>/models/mlx` (`config.json` `mlx.modelsDirectory`), or name it by path.

Capabilities come from the operator, because the bridge never infers them: declare per model in
`config.json`, only what you have verified, and an undeclared model runs text-only conversations.

```json
{
  "model": "mlx:Qwen3-1.7B-4bit",
  "mlx": {
    "modelsDirectory": "~/.daimon/models/mlx",
    "models": { "Qwen3-1.7B-4bit": { "capabilities": ["toolCalling", "reasoning"] } }
  }
}
```

Accepted capability names: `toolCalling`, `guidedGeneration`, `reasoning`, `vision`; another spelling is
refused at resolve. `daimon models` lists the directories with architecture, quantisation, and the
declaration.

Verified on 2026-09-20 with `mlx-community/Qwen3-1.7B-4bit` (a Hugging Face cache snapshot, 938 MB)
on an M4 Max, through the CLI built with `--traits MLX`: undeclared, a text-only reply in 2.5 s
including the weight load; declared `toolCalling`, the `current_date` loop ran 3 of 3 attempts, about
4 s each, with the right arguments; undeclared with tools requested, refused before generation with the
hint. The live test (`DAIMON_MLX_TESTS=1 DAIMON_MLX_MODEL=<directory> swift test --traits MLX --filter
MLXLiveTests`) cannot run under `swift test` today: MLX looks for its Metal library beside the main
executable, which in the test runner is Xcode's, and fails with "Failed to load the default metallib";
verify through the binary instead, as above.

Errors: `this build has no MLX support` when the trait is off; `no MLX model at <path> (no config.json);
models under <dir>: …` when the name points nowhere; `unknown capability '<x>'` for a bad declaration; the
bridge's own message when weights fail to load. Weights load on first use, so the first reply is slow.

## Deferred candidates

Recorded, not implemented: llama.cpp; LM Studio (`llmster`); ONNX Runtime; PyTorch and Hugging Face
Transformers; vLLM. Several of these serve an OpenAI-compatible HTTP API, and the Ollama executor's
transcript-to-chat mapping is most of a shared HTTP executor for them. Embeddings, reranking, and other
non-conversational models need task-specific interfaces rather than a `LanguageModel`, and are a
separate design.
