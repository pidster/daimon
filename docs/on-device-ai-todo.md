# TODO: on-device task assessment, routing and audit

Date: 2026-09-19. Status: draft backlog from the project discussion; not implemented.

## Goal and scope

Evaluate on-device AI for four jobs: input classification and pre-processing, dynamic context assembly,
tool approval escalation classification, and local generation with tool execution. Select useful model
and task combinations based on measured speed and accuracy. A specialist can be useful without handling
every job.

This extends the [local-model evaluation design](local-model-evaluation.md). The
[installation record](local-model-installation.md) describes the existing Python MLX smoke checks.
Those checks do not establish Swift provider compatibility or workload quality.

Integration note, 2026-09-22: explicit model selection and modular backends are now implemented; see
[backends.md](backends.md) and [ADR 0019](decisions/0019-model-backends.md). The automatic task-routing
policy below remains proposed work. Classifier and model configuration mechanisms are outside this
draft. This backlog does not change the [objective](objective.md), accepted ADRs or runtime behaviour,
and does not introduce remote generation.

## 1. Input classification and pre-processing

"Optimal" means matching the model type, capability and execution settings to the request's complexity,
urgency and nature. It does not mean always selecting the fastest or largest model.

- [ ] Define a request profile covering intent, task type, modalities, complexity, urgency, requested
  reasoning effort, required capabilities, constraints and uncertainty.
- [ ] Distinguish explicit user preferences from inferred preferences. Preserve the original prompt and
  record any extracted or transformed input separately.
- [ ] Define complexity labels using reasoning depth, ambiguity and task dependencies. Permit selection of
  stronger reasoning, higher requested effort, or a larger model where measurements support it.
- [ ] Define urgency labels or time budgets. Prefer fast models or faster models with equivalent relevant
  capability when the request calls for speed.
- [ ] Define capability requirements for text generation, image analysis, extraction, coding, tool use and
  mixed requests. Do not infer capability from parameter count alone.
- [ ] Build a versioned model capability catalogue using measured quality, latency, memory, supported
  inputs, context limits and available execution settings.
- [ ] Define routing policy for conflicting preferences, uncertain assessments, unavailable models and
  requests no eligible local model can handle. Record the reason for each fallback or override.
- [ ] Evaluate request assessment separately from model selection. Use an explicit user choice where
  feasible and make any inability to honour it visible.

## 2. Dynamic context assembly

- [ ] Evaluate selection of relevant history, files, passages and tool results for the assessed request.
- [ ] Compare deterministic retrieval, embedding models, rerankers and generative models where applicable.
- [ ] Evaluate selection and compression separately. Retain source references, constraints, contradictory
  evidence and uncertainty in assembled context.
- [ ] Fit context to the selected model's actual tokenizer and budget, reserving space for tools and output.
- [ ] Record which evidence was selected, omitted or compressed, and the context assembler's version.
- [ ] Measure evidence retention, irrelevant content, assembly latency, token reduction and downstream
  answer accuracy. Include cases where an omitted detail changes the correct answer.

## 3. Tool approval escalation classification

- [ ] Evaluate proposed tool requests for required human escalation, separately from request routing.
- [ ] Preserve [ADR 0011](decisions/0011-risk-classifier-and-approval.md): the model can raise the rules'
  verdict but cannot lower it, bypass policy or weaken the sandbox.
- [ ] Define handling of uncertain, malformed and failed classifications. Test the resulting approval
  behaviour explicitly, including clients that cannot obtain approval.
- [ ] Measure missed required escalations, unnecessary escalations and decision latency separately.
  Set acceptance criteria that give missed escalations greater weight.
- [ ] Include ambiguous commands, contextual risks and misleading text in labelled evaluation cases.
- [ ] Link the assessment, policy verdict and human decision to the originating prompt and tool call.

## 4. On-device generation and tool execution

- [ ] Evaluate bounded text generation, evidence-based answers and complete tool interactions locally.
- [ ] Verify model-specific chat templates, tool-call parsing, argument validation, tool results and
  conversation continuation through the intended Swift provider and packaged CLI.
- [ ] Keep model proposals distinct from Wisp's validated execution. Score actual completion and
  supporting evidence, not merely a plausible tool request or a claim of success.
- [ ] Measure end-to-end latency, first-attempt success, retries, unsupported claims and peak memory.
  Report policy denials, approval waits and execution failures separately.
- [ ] Verify offline operation and compare direct use, MCP replay and parent-harness delegation as
  described in the existing evaluation design.

## 5. Prompt-linked transcript and audit records

Current audit events use `session`, `turn` and optional `call`. `Agent` records prompt text before invoking
the model. `TranscriptStore` saves the Foundation Models transcript separately. A transcript-prompt-ID
link is not present in the audit envelope; adding that link is required work, not an existing guarantee.
See [logging](logging.md), [Agent](../harness/Sources/WispCore/Session/Agent.swift),
[AuditEvent](../harness/Sources/WispCore/Audit/AuditEvent.swift) and
[TranscriptStore](../harness/Sources/WispCore/Config/TranscriptStore.swift).

- [ ] Define stable prompt identity and its mapping to the transcript prompt entry. Support assessment
  before generation and failures that occur before a framework prompt entry exists.
- [ ] Link the request profile and routing decision to that prompt ID in the persisted transcript/audit
  representation. Choose the storage mechanism without assuming the framework transcript accepts custom
  entries or arbitrary metadata.
- [ ] Record task type, complexity, urgency, requested effort, capabilities, explicit preferences and
  uncertainty. Treat reported confidence as uncalibrated until evaluated.
- [ ] Record the selected model and exact revision, runtime, generation/reasoning settings, classifier
  identity, classifier instructions/schema version, routing-policy version, timing and a concise decision
  reason. A reason is a decision summary, not a request to retain hidden reasoning.
- [ ] Record context provenance, user overrides, unavailable candidates, fallbacks and later routing
  changes as linked events. Preserve the original assessment and decision.
- [ ] Append outcomes under the same prompt ID: elapsed time, completion status, retries, tool-call links
  and separately measured quality results. Include evaluator identity/version when quality is scored;
  an unscored result must not imply correct completion.
- [ ] Preserve correlation through streaming, retries, context condensation, transcript save/resume and
  concurrent MCP threads. Distinguish one logical prompt from its separate execution attempts.
- [ ] Define schema compatibility, audit-disabled behaviour and retention so saved records remain
  interpretable. Update `AuditEvent.Kind`, `docs/logging.md` and relevant transcript documentation.

## 6. Common model controls

The [model-controls proposal](model-controls.md) defines the draft contract for reasoning mode, effort,
native speed mode, separate performance preferences and reasoning output. These are proposed controls,
not implemented settings.

- [ ] Describe supported controls and values per model/runtime/adapter combination, with provenance.
- [ ] Translate common controls in each backend and reject unsupported explicit requests before use.
- [ ] Keep reasoning generation separate from whether reasoning text is exposed to the caller.
- [ ] Expose supported native standard/fast modes as explicit controls and reject unsupported requests.
  Keep routing preferences separate; preserve explicit model, reasoning, capability, context, quality
  and locality constraints.
- [ ] Validate combinations with tools, schema output and streaming, rather than independent flags alone.
- [ ] Audit requested and resolved controls against the prompt/attempt, and evaluate their actual effects.

## Evaluation and completion criteria

- [ ] Adapt the existing workload cases into the four tracks, with separate development and held-out
  cases. Define expected results, latency budgets and accuracy thresholds before comparing candidates.
- [ ] Use deterministic baselines where they can solve the task. Compare model/settings combinations,
  including reasoning levels, and account for assessment and context-assembly overhead.
- [ ] Report speed versus accuracy per workload. Measure cold/warm execution, short/long inputs, retries
  and fallbacks; include time to a correct result where correctness can be established.
- [ ] For recurrent/state-space candidates, test fact retention, corrections and continued state alongside
  memory use. Distinguish base-model limitations from architecture or runtime failures.
- [ ] Select initial candidates from the researched shortlist without declaring architecture or parameter
  count a winner in advance. Pin assets and runtimes before each comparison.
- [ ] Produce a suitability table identifying useful model/task/settings combinations, measured limits
  and fallback conditions for each track.
- [ ] Add model-independent tests for routing policy, identity correlation and audit persistence. Keep
  live-model evaluation separate from the unit-test gate, consistent with repository guidance.
- [ ] Demonstrate that an auditor can trace a prompt through assessment, selection, context assembly,
  tool approvals, execution and outcome, including any changes to the original decision.
