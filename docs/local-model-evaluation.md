# Local models: research and evaluation design

Research date: 2026-09-17. Installation follow-up: 2026-09-19.

Status: dated research findings and an evaluation design agreed with the project owner.
The main research and initial installation sections below record the 2026-09-17 to 2026-09-19 snapshot.
At that point, three MLX downloads had completed Python smoke checks and Swift integration was pending.

Integration note, 2026-09-22: Wisp now has the [model backends](backends.md) accepted in
[ADR 0019](decisions/0019-model-backends.md). Subsequent local checks on 2026-09-20 exercised nine
backend/model combinations through 45 CLI requests and seven MCP turns. Those checks, and the Core AI
export, supersede the earlier pending-integration status; they are not the full workload benchmark
proposed here. Their machine-local evidence is recorded in the [installation follow-up](local-model-installation.md).
No production winner has been selected. The project was renamed from Daimon to Wisp on 2026-09-21;
real evidence paths retain their original names.

## Purpose and scope

Use existing local models to discover which workloads wisp can complete usefully and how other agent
harnesses can delegate those workloads to it. Use the resulting evidence to inform whether custom models
would help, and what behaviour they should learn.

For this investigation, assume the main Agent can select a model instead of always using the system model.
The mechanism for that selection is outside this research. Configuring the command-risk classifier is a
later concern.

At the initial research date, the implementation used Apple's system model. The current supported
backends are described in [backends.md](backends.md). This evaluation proposal does not change the
[objective](objective.md) or accepted architecture decisions, and selects no production runtime or model.

## Evidence and proof boundaries

The investigation used repository source, the installed Xcode SDK's public Swift interface, Apple's
documentation, model publishers' cards, and the upstream Core AI and MLX repositories.

On this machine, the SDK interface exposes the macOS 27 LanguageModel and LanguageModelExecutor protocols,
along with LanguageModelSession initializers accepting a custom LanguageModel. It marks
SystemLanguageModel.Adapter deprecated in macOS 26.4 and obsolete in macOS 27.0. This was a source inspection,
not a compile or inference probe.

Upstream sources linked below were inspected during this research. Links to main branches and model cards
can change; an actual experiment must record exact source and model revisions. A published model conversion
or runtime implementation establishes a candidate for testing, not compatibility with wisp.

## What providing a custom model means

Foundation Models is now an interface to model providers as well as Apple's supplied models. The supported
macOS 27 direction is to supply our own model through a LanguageModel implementation and use it in a
LanguageModelSession. Core AI and MLX provide such integrations.

This gives wisp its own model assets and runtime. It does not replace the system model used by Apple
Intelligence, nor does it register our model globally for other applications to discover.

Customisation has three distinct levels:

| Level | What changes | Implication |
| --- | --- | --- |
| Instructions, context and tools | Inputs supplied to an existing model | No weight training; establish this baseline first |
| Fine-tuned checkpoint | Weights or adapters for a supported architecture | Requires task data, evaluation and versioned deployment assets |
| New architecture | Model structure as well as weights | Requires compatible inference and export implementations |

Apple's former system-model adapter API is not the proposed route for this macOS 27 project. LoRA on our own
selected model is a separate mechanism and remains an option.

Sources: [Foundation Models updates](https://developer.apple.com/documentation/Updates/FoundationModels),
[bringing a provider to Foundation Models](https://developer.apple.com/videos/play/wwdc2026/339/).

## Creation, installation and configuration lifecycle

1. Select a supported checkpoint and evaluate its existing behaviour.
2. If justified by failures, train on task-specific examples with a separate evaluation set.
3. Prepare a runtime-compatible release, including weights, configuration, tokenizer and chat template.
4. Bundle the assets or download a versioned resource directory.
5. Load the local assets through the provider and evaluate the delivered release.

MLX-LM supports LoRA, QLoRA and full fine-tuning. Its datasets include conversation and tool formats. A LoRA
adapter is tied to its base checkpoint; MLX can fuse the adapter into a complete model release. A fused
checkpoint is the initial packaging preference for an eventual custom model, because it simplifies version
identity. This has not been tested here.

Sources: [MLX training](https://github.com/ml-explore/mlx-lm/blob/main/mlx_lm/LORA.md),
[adapter fusion](https://github.com/ml-explore/mlx-lm/blob/main/mlx_lm/fuse.py).

For a model release, retain the upstream checkpoint identity, exact weights revision, quantization recipe,
tokenizer, chat template, model configuration and generation defaults. A manifest should identify the
components and their hashes. Model selection, asset installation and inference are distinct operations;
none inherently requires an inference server.

Configuration includes architecture and quantization settings, context limits, chat formatting, stop tokens,
sampling, output budgets and reasoning behaviour. These are part of reproducible model behaviour, not just
a model name.

## Core AI and MLX

The current working recommendation is MLX for initial model experimentation, with Core AI as a deployment
comparison once useful workloads are identified. This is a workflow judgement, not a measured performance
advantage.

| Concern | MLX | Core AI |
| --- | --- | --- |
| Training workflow | MLX-LM provides fine-tuning tools | Train upstream, then export |
| Model assets | Weights, configuration and tokenizer resources | Resource folder with .aimodel, metadata and tokenizer resources |
| Preparation | Convert or quantize for supported MLX architectures | Export and compress, then specialise for hardware |
| Mac execution | CPU/GPU; Metal GPU backend | CPU, GPU or Neural Engine according to model structure and export |
| Cold start | Weight loading and possible first-generation shader compilation | Asset loading and outstanding hardware specialisation |
| Local loading | Custom loader and on-disk weights directory | CoreAILanguageModel loads a resource folder |
| Main research tradeoff | Convenient checkpoint iteration | Additional conversion and hardware optimisation options |

Sources: [MLX provider](https://github.com/ml-explore/mlx-swift-lm/tree/main/Libraries/MLXFoundationModels),
[MLX memory model](https://ml-explore.github.io/mlx/build/html/usage/unified_memory.html),
[Core AI model integration](https://developer.apple.com/documentation/foundationmodels/running-a-core-ai-model-in-a-foundation-models-session).

### Export and packaging limits

Core AI's catalogue supplies supported export recipes. Unregistered checkpoints use an experimental path
and still need an implemented architecture. The exporter resolves the architecture from model configuration.
Do not assume arbitrary fine-tuned checkpoints or MLX-quantized weights convert unchanged.

Sources: [Core AI catalogue](https://github.com/apple/coreai-models/tree/main/models),
[export command](https://github.com/apple/coreai-models/blob/main/python/src/coreai_models/llm/export.py),
[export pipeline](https://github.com/apple/coreai-models/blob/main/python/src/coreai_models/export/pipeline.py).

Core AI can compile architecture-specific .aimodelc assets ahead of time, reducing device-side preparation.
Some specialisation remains on the device. Distributing compiled variants requires choosing the matching
hardware asset. Current CoreAILanguageModel source defaults to lazy engine loading, so construction alone
does not establish that inference is warmed up.

Sources: [ahead-of-time compilation](https://developer.apple.com/documentation/coreai/compiling-core-ai-models-ahead-of-time),
[Core AI provider source](https://github.com/apple/coreai-models/blob/main/swift/Sources/CoreAILanguageModels/LanguageModel/CoreAILanguageModel.swift).

Offline operation requires all resources to be present. Core AI prefers an embedded tokenizer but falls back
to a Hugging Face identifier if it is absent. MLX exposes an injectable loader; its example Hugging Face
downloader is optional. Verify offline operation from a clean installation with network access blocked,
rather than relying on previously populated caches.

Source: [Core AI tokenizer loading](https://github.com/apple/coreai-models/blob/main/swift/Sources/CoreAILanguageModels/Bundle/LanguageBundle.swift).

CLI packaging also needs verification. MLX Swift's current README documents an Xcode build step for Metal
shaders. A binary that compiles is not proof that the distributed CLI includes all runtime resources.

Source: [MLX Swift build documentation](https://github.com/ml-explore/mlx-swift/blob/main/README.md).

### Capabilities and performance

Both providers support tool-use and constrained-output paths, subject to model and engine capabilities.
Core AI detects tool-call formats from the tokenizer. MLX uses explicitly declared capabilities and
model-specific routing. Grammar constraints can enforce structure; they do not establish correct tool
selection, correct argument values, or factual answers.

Sources: [Core AI provider source](https://github.com/apple/coreai-models/blob/main/swift/Sources/CoreAILanguageModels/LanguageModel/CoreAILanguageModel.swift),
[MLX provider source](https://github.com/ml-explore/mlx-swift-lm/blob/main/Libraries/MLXFoundationModels/MLXLanguageModel.swift),
[MLX guided generation](https://github.com/ml-explore/mlx-swift-lm/tree/main/Libraries/MLXGuidedGeneration).

There is no measured runtime winner. Neural Engine access alone does not establish that Core AI is faster
or more efficient for these workloads. A hypothetical 4-billion-parameter model at exactly four bits per
weight requires about 2 GB for weights alone; quantization metadata, activations, context caches and runtime
buffers add to that. Download size is not peak inference memory, and inference memory is not training memory.

## Initial model shortlist

| Candidate | Role | Initial runtime |
| --- | --- | --- |
| Apple's system model | Current wisp baseline without separately distributed weights | Foundation Models |
| Qwen3-1.7B, 4-bit | Small model: discover the useful low-resource workload range | MLX |
| Qwen3-4B, 4-bit | Capacity comparison within a family; common model for runtime comparison | MLX, then Core AI |
| Qwen3.5-4B, 4-bit | Newer model at a similar parameter count | MLX |

Candidate MLX assets:

- [mlx-community/Qwen3-1.7B-4bit](https://huggingface.co/mlx-community/Qwen3-1.7B-4bit)
- [mlx-community/Qwen3-4B-4bit](https://huggingface.co/mlx-community/Qwen3-4B-4bit)
- [mlx-community/Qwen3.5-4B-MLX-4bit](https://huggingface.co/mlx-community/Qwen3.5-4B-MLX-4bit)

Apple documents Core AI exports for both Qwen3 sizes. MLX Swift implements Qwen3.5. Exact candidate
revisions and a Python MLX-LM runtime are pinned in the [installation record](local-model-installation.md).
Swift provider compatibility remains untested. Add a different family, such as
Gemma, if shared Qwen failures make a family comparison useful.

Sources: [Qwen3 export recipe](https://github.com/apple/coreai-models/blob/main/models/qwen3/README.md),
[MLX Qwen3.5 implementation](https://github.com/ml-explore/mlx-swift-lm/blob/main/Libraries/MLXLLM/Models/Qwen35.swift),
[Qwen3.5 model card](https://huggingface.co/Qwen/Qwen3.5-4B).

## Workload set

Create 60 cases: ten in each family. Cases and expected outcomes are not yet authored.

| Family | Example task | Success evidence |
| --- | --- | --- |
| Extraction | Extract failed tests, locations and messages from supplied output | Correct fields, omissions identified, no fabricated entries |
| Classification and routing | Categorise an issue using a supplied project taxonomy | Correct category with evidence; ambiguity recognised |
| Evidence-based summarisation | Summarise decisions, constraints and unresolved questions | Required facts retained; disagreements preserved |
| Repository navigation | Locate a behaviour's definition and callers | Correct paths and evidence; bounded search |
| Build/test interpretation | Run a specified check and explain its result | Actual exit status and diagnostics; execution failure distinguished from test failure |
| Bounded investigation | Inspect a failing test and relevant implementation | Supported explanation, or precise missing evidence |

Include ordinary cases and difficult variants: missing evidence, misleading nearby text, contradictory
information, truncated output, and tasks whose answer cannot be established. Treat instructions embedded in
input documents as data. Use controlled fixtures with known outcomes for build and test cases.

For tasks a deterministic command or parser can solve, include that baseline. It establishes whether the
model contributes anything beyond execution or formatting.

Use three development and seven held-out cases per family: 18 development cases and 42 held-out cases.
Keep related fixture variants in the same split to avoid leakage. Freeze prompts, budgets and scoring before
held-out runs. Do not use held-out examples as later fine-tuning data while retaining them as evaluation cases.

## Direct and delegated evaluation

Separate model ability, protocol behaviour and parent-harness task preparation.

| Comparison | What it isolates |
| --- | --- |
| Direct wisp with a fixed task packet | Local completion under controlled instructions |
| The same packet replayed through MCP respond | Delegation interface and conversation behaviour |
| Parent harness prepares a delegation and finishes the user task | Context selection, instructions, result consumption and repair |
| The same parent completes the task without wisp | End-to-end baseline for quality, effort and elapsed time |

Use the same tools and task content for direct/MCP comparisons. Test more than one parent harness, with
each compared against its own non-delegating baseline. Pin the parent model, settings and harness version.
Control access to task evidence so that a parent does not accidentally receive the answer key.

The current [MCP contract](mcp.md) provides respond, thread continuation and close_thread. Its separate
run_command tool bypasses the local agent model; count that separately from local-model delegation.
The current respond result contains text, not a caller-selected generation schema. Validating JSON returned
as text is not evidence that framework-guided generation was used.

A fixed task packet records:

- Objective and completion criteria.
- Input text or exact available files.
- Permitted actions and time/tool-call budget.
- Required evidence and output format.
- What to return when the task cannot be completed.

Example: inspect a supplied test log, report failing test names, error locations and supporting excerpts,
and do not infer a root cause beyond the evidence.

Score the parent-directed result as well as wisp's intermediate answer. A correct final answer can still
represent failed delegation if the parent had to repeat the work.

## Scoring and measurements

| Measurement | Purpose |
| --- | --- |
| Correct completion on first attempt | Useful work delivered without repair |
| Unsupported claims and false completion | Trustworthiness of the result |
| Appropriate escalation | Recognition of insufficient evidence |
| Parent repair or rework | Whether delegation actually reduces effort |
| End-to-end elapsed time | Includes preparation, verification and retries |
| Parent token usage | Includes producing and consuming delegation requests |
| Peak memory and cold/warm latency | Practical local operating conditions |
| Tool calls, execution failures and approval waits | Explanation of operational overhead |

Use deterministic checks where possible and a predefined evidence rubric for summaries and explanations.
Evaluate correctness independently of the parent accepting an answer. Appropriate escalation is useful
behaviour but is not completed work. Structural validity is scored separately from semantic correctness.

Record policy denials and approval waits separately from model failures. Do not interpret a denied command
as lack of reasoning ability. Report task outcomes by workload family rather than hiding differences in
one aggregate score.

A run record should include case and fixture revision, model and asset revision, runtime and OS version,
hardware and memory, prompt, tools, generation settings, actual tool trace, output, timings, memory,
condensation events, parent actions, scores and failure category.

## Experimental controls and sequence

1. Author and review the workload cases, answer keys and scoring rubrics.
2. Establish the system-model baseline and verify each candidate's loading, tool and transcript behaviour.
3. Screen all candidates once; use development cases to select settings.
4. Repeat held-out runs for the strongest candidates to expose variability.
5. Test MCP replay, then parent-directed delegation against matched parent-alone runs.
6. Compare Qwen3-4B through MLX and Core AI using the same upstream checkpoint.
7. Investigate longer context, continued threads and concurrency separately from the initial single-task runs.

Use the same source content within the smallest model's usable context for the common comparison. Count
tokens using the actual tokenizer; equal token counts across models need not represent equal evidence.
Reserve room for instructions, tool schemas, tool results and output. Keep output and task budgets explicit.

Start with non-thinking mode for short delegated tasks, then measure whether additional reasoning earns
its latency. Use supported, recorded generation settings rather than forcing identical greedy decoding:
Qwen's publisher specifically warns against greedy decoding in thinking mode.

Source: [Qwen3 generation guidance](https://huggingface.co/Qwen/Qwen3-1.7B).

Separate model preparation and cold-start costs from steady-state requests. Record actual memory rather than
estimating it from weights. Randomise or interleave run order to reduce effects from thermal state and
background load. Repeated seeds, where supported, do not prove determinism.

For the runtime comparison, account for different quantization and export recipes before attributing
differences to the inference engine. A successful Python inference run does not prove the Swift
Foundation Models path or packaged CLI works.

## How the findings inform custom models

Classify failures before deciding on training:

| Observed failure | First investigation |
| --- | --- |
| Required facts absent from the delegation | Context selection and task packet |
| Wrong or unavailable tool | Tool contract and runtime capability |
| Context loss or excessive tool output | Context budget, paging and task size |
| Useful answer but poor parent consumption | Delegation output contract |
| Repeated domain or behavioural mistakes despite sufficient evidence | Model selection, prompting, then possible fine-tuning |
| Broad reasoning failure | Task decomposition or a stronger model |
| High latency or memory with otherwise correct results | Runtime, quantization and model size |

A custom model becomes a candidate when a recurring, valuable workload has failures plausibly addressable
by training and enough representative examples to evaluate improvement. A specialist should be compared
against the general model on both its intended workload and relevant regression cases.

The intended evaluation deliverable is a delegation suitability table: each workload is marked useful
locally, useful under stated conditions, or not yet useful, with supporting outcomes and failure examples.
A small exploratory set will guide the next experiments; it will not establish production reliability.

## Outstanding work

- Author the 60 workload cases and their expected outcomes.
- Define exact scoring rubrics and operational budgets.
- Validate the pinned candidates through the Swift Foundation Models provider and packaged wisp CLI.
- Implement the evaluation paths and collect results.
- Measure cold/warm performance, offline operation and delegation overhead.
- Decide whether evidence supports a runtime choice, more model comparisons or custom training.

The 2026-09-19 installation follow-up establishes asset integrity and offline Python inference for all
three candidates. The work above remains outstanding for the actual evaluation. Workload cases, expected
outcomes and scoring rubrics still need to be assembled, with held-out cases separated from prompt
development.
