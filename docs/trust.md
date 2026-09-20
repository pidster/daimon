# What daimon can do to your Mac, and how you stay in control

This page answers the questions a careful person asks before letting an agent run commands: what it can
touch, what leaves the machine, what it remembers, how to see what happened, and how to undo. Every claim
here is enforced by code and covered by tests; the linked pages hold the detail.

## What runs, and where

The model has four tools: `current_date`, `read_file`, `inspect`, and `run_command`. Only `run_command` changes
anything. It runs a shell command through `/bin/sh -c` with daimon's own privileges, inside a Seatbelt
sandbox ([run_command](tools/run_command.md)):

| The sandbox confines | It does not confine |
| --- | --- |
| **Writes**: only under the directory daimon was launched in, the temporary directory, `/private/tmp`, and configured build caches. A command's own working directory never widens this. | **Reads**: any file the user can read. `read_file` and `run_command` can read your home directory. Credential-like paths ask first. |
| **Network**, only if you set `sandbox.allowNetwork: false`. | **Network by default**: on, because builds fetch dependencies. |
| **The process tree**: a timeout kills the whole group. | **Inter-process messaging and the rest of macOS**: unchanged. |

Before a command runs it must also pass a deny list (`sudo`, `rm -rf /`, piping into a shell, disk
tools) and a risk check.

## What leaves the machine

Nothing, with the default model. The on-device model runs on your Apple silicon; prompts, files, and
command output stay local.

If you choose `--model private-cloud`, prompts and tool output go to Apple's Private Cloud Compute under
Apple's privacy guarantees. daimon prints a note on stderr when that model is selected and records it in
every session's audit event. The risk classifier always uses the on-device model, whatever the session
runs on ([ADR 0013](decisions/0013-model-selection.md)).

## When you are asked

Every simple command in a line is classified `safe`, `moderate`, or `dangerous` by rules plus the
on-device model ([approval](approval.md)). At `moderate` and above a person is asked: on the terminal in
`chat`, through a dialog in your MCP client, and never in plain `daimon "…"`, which refuses instead
unless you pass `--yes`.

Your answer has a scope. "This turn" covers the rest of the current prompt. "This session" covers the
process. "This project" and "Always" are written to `~/.daimon/approvals.json` for 30 days, keyed by the
program (`head *`), never by exact arguments and never for a dangerous verdict. `daimon approvals` lists
them; `daimon approvals revoke <id>` and `clear` remove them. A dialog nobody answers within ten minutes
counts as a refusal.

## Switches that remove protection

| Switch | Removes | Leaves |
| --- | --- | --- |
| `--yes` | every human approval | deny list, sandbox, classification, audit |
| `--unsafe` | the deny list and the sandbox | approval, classification, audit |
| `approval.threshold: "never"` | approval prompts | everything else |
| `--model private-cloud` | on-device only | approval, sandbox, audit |

Both flags print a warning on stderr. There is no switch that turns off the audit log except
`audit.enabled: false` in `config.json`.

## Seeing what happened

`~/.daimon/logs/audit.jsonl` records every prompt, reply, tool call and result, policy decision,
classifier verdict, approval, and command outcome, verbatim, in the order they happened, user-only on
disk. `daimon logs` reads it; `daimon logs --kind approval.decided` shows every approval and what it was
remembered as ([logging](logging.md)).

## Undoing

- Revoke a remembered approval: `daimon approvals revoke <id>` or `daimon approvals clear`.
- Forget a conversation: delete `~/.daimon/transcripts/<name>.json`.
- Remove everything daimon keeps: delete `~/.daimon`. Nothing else is written outside the sandbox's
  writable set.
- Uninstall: `brew uninstall daimon`.

## Files daimon writes

| Path | Contents | Permissions |
| --- | --- | --- |
| `~/.daimon/config.json` | your settings, written by you | yours |
| `~/.daimon/logs/audit.jsonl` | the audit log, rotated | user-only |
| `~/.daimon/approvals.json` | remembered approvals | user-only |
| `~/.daimon/transcripts/*.json` | saved chats | user-only |
