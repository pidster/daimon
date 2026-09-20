# ADR 0024: `edit_file` writes inside the sandbox's writable set, approved like a command

Date: 2026-09-20. Status: accepted.

## Context

The model could read files a page at a time (`read_file`) but could only change them through
`run_command` with shell redirection or `sed -i`, which a small model gets wrong (quoting, escaping,
whole-file overwrites) and which a reader of the audit log cannot easily interpret. A write tool is the
counterpart of `read_file`: the model reads a page, then changes exactly what it saw.

Three questions: how far a write may reach, how it is approved, and what edits it offers. And a fact
worth stating: the tools do not share one control path. Only `run_command` passes `CommandPolicy`, the
gate, and Seatbelt; `read_file` runs the gate's rules only; `inspect` and `current_date` have none.

## Decision

- **Reach.** `FileWriter` refuses any path outside the canonical writable set the Seatbelt profile is
  built from (`CommandPolicy.writableRoots`: the launch directory, the temporary directory,
  `/private/tmp`, the user cache directory, `sandbox.writablePaths`). One list, two enforcers, so
  `edit_file` can change no more than a command could. With the sandbox off there is no confinement,
  as for commands. Directories are never created. The write itself is in-process, not under Seatbelt,
  and the deny/allow command patterns do not apply to it; the writable list and the gate are its controls.
- **Approval.** Each edit is cleared by the gate as the synthetic command `edit_file <mode> <path>`
  through the full classifier. The rules rate every edit at least `moderate` and reuse the credential
  rule for `dangerous`, so thresholds, scopes, and persistence work exactly as for a program: the
  approval pattern is `edit_file *`. Unlike `read_file`, which runs the rules only, writes run the model
  classifier too when it is configured, because they change state.
- **Edits.** `write` (whole file, creating it), `append`, and `replace` of one exact occurrence of
  `find`. A `find` that matches zero or several times changes nothing and the error says which, so the
  model cannot change more than it showed it meant to. `replace` loads at most 1 MiB and refuses binary
  files. No line-number edits: numbers drift and small models miscount; the exact text is the anchor.
- **Audit.** A landed edit is recorded as `file.write` (path, mode, created, sizes); the content is
  already in the `tool.call` arguments. Receipts list writes under `files`.

## Consequences

- A conversation that should not write leaves `edit_file` out with `--tool` or `tools`; a conversation
  with it can write only where the sandbox would have let a command write, after the same approval.
- The file is written in place, not atomically; a failure mid-write can leave it partial. Acceptable for
  now: the sizes are small and the audit shows the attempt.
- Probed once with the system model on 2026-09-20: `find` came back verbatim after a `read_file` page,
  but `content` carried the following line too, duplicating it. The tool cannot tell intent from
  accident; the tool description now says `content` replaces only `find`, and a proper measurement
  belongs in the eval harness with the other tool tasks (backlog, task catalogue).
- Tests without the model: confinement including symlinks and look-alike siblings, every failure,
  each edit and its rendering (`FileWriterTests`); the tool's gate refusal, audit event, receipt
  entry, and classifier levels (`ToolWrapperTests`, `ReceiptTests`).
