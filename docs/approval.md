# Risk classification and approval

Before `run_command` executes anything that passed the [policy](tools/run_command.md#policy-and-sandbox), a
classifier assesses the command's risk and, at or above a threshold, a human is asked. This is layer 3 of
[policy-and-sandboxing.md](policy-and-sandboxing.md) and is recorded in
[ADR 0011](decisions/0011-risk-classifier-and-approval.md).

## Levels

| Level | Meaning | Examples |
| --- | --- | --- |
| `safe` | Read-only, or reversible within the working directory | `ls`, `git status`, `grep` |
| `moderate` | Modifies files or state but is recoverable, or reaches the network | `touch`, `git commit`, `npm install`, `curl` |
| `dangerous` | Destructive, irreversible, privilege-escalating, or exfiltrates data | `rm -rf`, `git push --force`, `sudo`, `… \| sh` |

## Classifiers

Two run and the higher verdict wins (`CompositeRiskClassifier`):

- **Rules** (`RuleRiskClassifier`): regexes with a level and a reason each, covering privilege, deletion,
  history rewriting, credentials, uploads, network use, package installs, file modification, builds. Cheap,
  deterministic, tested against a labelled set. Rules cover the model's weak spot: ordinary modifications it
  tends to call safe.
- **Model** (`ModelRiskClassifier`): one fresh on-device session per command with a `@Generable` verdict.
  The verdict generates the one-sentence `reason` before the `risk` level, so the level follows the
  reasoning. The instructions give the model facts it otherwise guesses at (project build output is the
  project's own programs; filtering output is not network access; git reads are safe; anything that
  changes a file, setting, or repository state is at least moderate) and thirteen labelled examples.
  Sampling is greedy, so the same command always gets the same verdict. The command is placed between
markers and the model is told to treat it as data, but a command containing persuasive prose can still
steer the verdict; that is why the rules floor exists and the model may only raise a level, never lower one. If the model is unavailable or
  fails it reports `moderate`, so a broken classifier asks rather than waves through.

Measured on this machine (`scripts/check eval`, 45 labelled commands, ten of them held out from the
instruction examples): the model alone scores 44 correct, 0 over, 1 under, identically on repeated runs,
at about 1.5 s per call. Its one miss (a shell redirect into a file, rated safe) is caught by the rules, so
the composite is right on all 45. Before the instruction rewrite the model scored 26 of 32 and varied
between runs. The eval suite asserts only the hard requirement (no dangerous command below moderate),
prints every miss with the model's reason, and is the place to add any command the model gets wrong.

## The gate

`ApprovalGate` (one per conversation) classifies, audits the verdict, and if the level is at or above the
threshold asks the session's `Approver`. `read_file` uses the same gate over the equivalent `cat <path>`
with the rule classifier only, so credential paths ask and ordinary reads cost no model call.

A line is split into its simple commands (`ls && curl … | sh` is three), each is classified and, if
risky, approved on its own with the whole line shown for context; a denial for any part refuses the line
([ADR 0015](decisions/0015-per-command-approval.md)). Approvals are remembered by the essential command,
the program that actually runs after unwrapping `sudo`, `env`, `time`, and the like, as a pattern such as
`head *`, so arguments never matter to remembering. An approval has a scope
([ADR 0014](decisions/0014-persisted-approvals.md)):

| Scope | Covers | Lives |
| --- | --- | --- |
| `once` | this pattern in this directory | the rest of the current turn: the prompt's whole tool loop, however many calls it makes |
| `session` | this pattern in this directory | until the process exits |
| `project` | this pattern in this directory | `approval.persistDays` (30), in `~/.daimon/approvals.json` |
| `always` | this pattern in any directory | `approval.persistDays` (30), in `~/.daimon/approvals.json` |

### The order of checks

For each simple command in a line, the gate does the following, in this order, stopping at the first
step that decides:

1. Classify it with the rules and the model.
2. If the verdict is below the threshold, run it. Nothing else is consulted.
3. Check the session cache for this pattern in this directory.
4. Check the turn cache for a once-approval given earlier in this turn.
5. Check the persistent file for a `project` entry in this directory or an `always` entry, **but only if
   the verdict is not dangerous**.
6. Ask the approver.

Step 5's exception is deliberate: a dangerous verdict skips the persistent file and always asks, so a
stored `rm *` never covers `rm -rf build` and a stored `git *` never covers `git push --force`. The session
and turn caches do apply to dangerous commands, because those were answered in this process by a person
who saw the command; the persistent file may be weeks old. And because classification always comes first,
a stored approval decides only whether to ask, never whether the command is acceptable.

A dangerous verdict is never persisted: `project` or `always` is downgraded to `session` and the audit
says so. Remembered approvals only decide whether to ask; deny patterns, the sandbox, and the classifier
run on every part every time, so `rm *` never covers `rm -rf build`, and each use is audited with the
approval id.
`daimon approvals` lists them, `daimon approvals revoke <id>` and `clear` remove them. Decisions: approve with a scope (see below), deny with a reason, or unanswered. **An unanswered request is a denial**: no answer is not
an answer, so the MCP approver that hears nothing within `approval.timeoutSeconds` (default 600, ten
minutes) reports `unanswered`, the gate refuses the command and audits the decision as `timed-out`. Set it
to `0` to wait indefinitely. The terminal prompt in `chat` has no timeout: a person is at the keyboard,
and end of input counts as a refusal. A denial returns to the
model as `error: command not approved: …` (or `error: read not approved: …` from `read_file`) so it can
choose another approach. The gate itself throws `ApprovalGate.Failure.refused`; each tool renders it
through `ToolOutput.error`. `CommandRunner` splits the line once, checks the policy over each part, and
passes the parts to the gate, so a line is never split twice.

"This turn" is defined by the conversation's `TurnClock`, which the agent advances once per prompt and
the gate and the audit log both read, so a once-approval covers the rest of the tool loop whether or
not an audit log is attached, and the refusals `respond` reports are those of the turn just run.

| Entry point | Approver | Behaviour |
| --- | --- | --- |
| `daimon respond` | denying, unless `--yes` | Non-interactive: risky commands are refused with a message naming the three ways forward. `--yes` approves everything. |
| `daimon chat` | terminal | Prints the command, level, and reasons on stderr; reads `y` (this turn), `s` (session), `p` (project), `a` (always), or `n`. |
| `daimon mcp` | MCP elicitation, unless `--yes` | For commands the model runs inside `respond`: asks the client's user through the protocol. Accept runs it with the scope picked (this turn by default, or session, project, always); Decline or silence for `approval.timeoutSeconds` refuses. If the client did not advertise elicitation, denies with a message telling the calling harness to run the command itself, start daimon with `--yes`, or lower the threshold. |

## Configuration

```json
{ "approval": { "threshold": "moderate", "useModel": true } }
```

| Field | Default | Meaning |
| --- | --- | --- |
| `threshold` | `moderate` | Ask at this level and above: `safe`, `moderate`, `dangerous`, or `never`. |
| `classifier` | `system-model` | What runs beside the rules: `rules` (nothing; fast and deterministic), `system-model` (Apple's on-device model), or `coreml` (a Core ML text classifier, below). Independent of `model`. |
| `useModel` | `true` | The pre-0.2 switch; `false` means `classifier: rules`. Read only when `classifier` is absent. |
| `coremlModel` | none | For `coreml`: the `.mlmodel` or `.mlmodelc`, absolute, `~`, or under `<home>/models/coreml`. |
| `coremlMinimumConfidence` | `0.6` | For `coreml`: below this top-label probability the verdict is raised to at least `moderate`. |
| `timeoutSeconds` | `600` | How long an approval may go unanswered before it counts as declined; `0` waits forever. |
| `persistDays` | `30` | Lifetime of `project` and `always` approvals. |

How approval should reach clients that do not render elicitation at all remains an open design question.

`never` still classifies and audits; it just does not ask.

### A Core ML classifier

`classifier: coreml` runs a Core ML text classifier beside the rules ([ADR 0020](decisions/0020-coreml-risk-classifier.md)).
The rules, the threshold, and the human stay authoritative: the higher of the two levels wins, and
nothing the classifier does can lower a level or grant an approval.

The model must follow contract version 1: input `text`, a string; output `label`, one of `safe`,
`moderate`, `dangerous`; creator metadata `daimon.classifier.contract` = `1` and
`daimon.classifier.labels` = `safe,moderate,dangerous`. daimon gives it the command line trimmed with
runs of whitespace collapsed to one space, case kept. A model declaring anything else is rejected when
it loads. Its metadata version string is its identity in the audit.

Every failure is a `moderate` verdict with the reason: no path configured, a missing asset, a model
Core ML cannot load, a contract mismatch, an inference error, no prediction, an unknown label, or a
top-label probability below `coremlMinimumConfidence`. Confidence is recorded only when the model gives
label probabilities (Create ML text classifiers do); it is uncalibrated, and the threshold guards
against guessing rather than measuring accuracy. `daimon doctor` checks the configured model prepares.

Train one from a `text,label` CSV, then measure it before relying on it:

```
scripts/train-risk-classifier docs/examples/risk-labels.csv ~/.daimon/models/coreml/risk.mlmodel
DAIMON_MODEL_TESTS=1 DAIMON_COREML_MODEL=~/.daimon/models/coreml/risk.mlmodel scripts/check eval
```

`docs/examples/risk-labels.csv` is the 45-command eval set: enough to prove the pipeline, not to trust
a model trained on it. Loading and producing valid labels is not evidence of suitability; the eval's
hard requirement is that no dangerous command is rated safe, and its accuracy figure is what you judge.

## Audit

Every command produces `classifier.verdict` (level, reasons, sources, seconds) and, when asked,
`approval.requested` and `approval.decided` (decision, reason; `cached` for session approvals). See
[logging.md](logging.md).

## Testing policy without the model

`PolicyScenarioTests` is a table: for a command line it states the parts the splitter must find, whether
the deny patterns refuse it, and which patterns a user would be asked for at the default threshold, all
driven through the real splitter, deny list, and rule classifier with a recording approver. No model, no
MCP client. When a real line surprises you, add a row there first; it documents the intended behaviour
and fails until the code matches.

## Extending

Add a rule to `RuleRiskClassifier.defaultRules` with a reason a human would accept, and a case to the
labelled set in `ApprovalTests`. Add commands to `ClassifierEvalTests.labelled` when the model gets one
wrong, so the eval tracks it; keep held-out cases that do not resemble the instruction examples, or the
score measures recognition rather than judgement. Change the instructions only with a before-and-after
eval run in the commit message.
