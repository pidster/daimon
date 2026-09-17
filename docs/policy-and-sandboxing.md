# Policy and sandboxing: what is available and what daimon should do

Status: investigation, 2026-09-17. No policy is implemented yet; `run_command` is unsandboxed by
[ADR 0005](decisions/0005-tools-as-plain-binaries.md). This page records the options so the decision can be
made deliberately.

## What the Foundation Models framework offers

Read from the macOS 27 SDK interface.

| Capability | What it controls | Relevance to tool policy |
| --- | --- | --- |
| `SystemLanguageModel(useCase:guardrails:)` | `useCase`: `.general` or `.contentTagging`. `guardrails`: `.default` or `.permissiveContentTransformations` | Content safety of model input and output only. Nothing about tools. |
| `LanguageModelError.guardrailViolation` / `.refusal` | Raised when the model or guardrails decline | Surfaces as an error the harness must render; not configurable beyond the two guardrail levels. |
| `Tool` protocol | daimon implements `call(arguments:)` itself | **This is the policy point.** The framework never executes anything; every tool call passes through our code, so allow, deny, confirm, or sandbox all happen here. |
| `LanguageModelSession(tools:)` binding | Tools are fixed per session | Per-session least privilege is free: give a session only the tools its task needs (already exposed as `--tool` and the MCP `tools` argument). |
| `Tool.includesSchemaInInstructions` | Whether the tool's schema is put in the prompt | Cost control, not policy. |
| `Transcript.ToolCalls` / `ToolOutput` entries | Every call and result is in the transcript | Free audit trail once transcripts are saved to `~/.daimon/transcripts`. |

Conclusion: the framework gives content guardrails and nothing else. Tool policy is entirely daimon's job, and
the `Tool.call` boundary is the natural place for it.

## What macOS offers for confining child processes

| Mechanism | Notes |
| --- | --- |
| `sandbox-exec -p '<profile>' cmd` (Seatbelt) | Present at `/usr/bin/sandbox-exec` on macOS 27. Marked deprecated for years but still used by Chromium, Bazel, and Nix. Profiles are S-expressions: `(version 1) (deny default) (allow process*) (allow file-read*) (allow file-write* (subpath "/private/tmp"))`. Works on any unsigned binary, no entitlements. Best available option for `run_command`. |
| App Sandbox entitlements | Confines daimon itself, not a chosen child. Needs code signing and a bundle; wrong shape for a CLI whose whole job is to run commands. |
| Endpoint Security / TCC | Observability and user-consent prompts for protected locations (Desktop, Documents). Already applies to daimon's process implicitly; not a policy tool we drive. |
| Separate user or VM | Strongest isolation; out of scope for a microharness. |

## Policy layers daimon can implement

Ordered from cheapest to strongest. They compose.

1. **Tool selection per session** (exists). Least privilege by omitting `run_command` where it is not needed.
2. **Command policy in `config.json`**: `allow` and `deny` lists of regexes over the command line, evaluated
   in `RunCommandTool.call`. Deny wins. Example defaults: deny `rm -rf /`, `sudo`, `curl | sh`. Cheap,
   auditable, and testable, but bypassable by a determined model (`sh -c` inside the command).
3. **Confirmation** in interactive `daimon chat`: before a `run_command` executes, print the command and ask.
   Not applicable to MCP, where the calling harness has its own confirmation UX.
4. **Seatbelt profile** via `sandbox-exec` wrapping `/bin/sh -c`: a shipped read-only profile plus a
   configurable list of writable subpaths (defaulting to the working directory and `$TMPDIR`). Blocks writes
   and optionally network regardless of what the command line says. This is the layer that actually enforces.
5. **Audit**: persist transcripts for MCP threads and chat, so every tool call and output is on disk.

## Recommendation

Implement 2 and 4 together as one `CommandPolicy` type in `DaimonCore`, configured from `config.json` with
safe defaults (deny list on, sandbox on, writes allowed under the working directory and temp), and a
`--unsafe` style opt-out for both CLI and MCP. Add 3 to `chat`. Record the choice in an ADR, and treat the
Seatbelt dependency as a known risk: if Apple removes `sandbox-exec`, layer 2 remains.

Open questions for the owner:

- Should MCP `respond` default to a stricter policy than the CLI, given the caller is another agent?
- Is network access from `run_command` needed at all in the first cut?
