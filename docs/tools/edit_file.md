# edit_file

Writes a text file: the whole file, an addition at the end, or one exact replacement. The counterpart of
[read_file](read_file.md): read a page, then replace exactly what was shown. Decided in
[ADR 0024](../decisions/0024-edit-file.md).

## Arguments

| Name | Type | Required | Meaning |
| --- | --- | --- | --- |
| `path` | string | yes | Path of the file. Its directory must exist; `edit_file` never creates directories. |
| `mode` | string | yes | `write` replaces the whole file, creating it if absent. `append` adds to the end, creating it if absent. `replace` swaps one exact occurrence of `find` for `content`. |
| `content` | string | yes | The text to write or append, or the replacement text. |
| `find` | string | for `replace` | The exact existing text to replace. It must occur exactly once; otherwise nothing changes and the error says how many times it occurs. |

## Result

One line:

```
created /repo/notes.md; now 42 bytes
appended to /repo/notes.md; now 60 bytes
replaced at line 3 of /repo/notes.md; now 58 bytes
```

Errors come back as text so the model can react: `error: text to replace not found: …`, `error: text to
replace occurs 2 times, include more surrounding text: …`, `error: cannot write …: outside the writable
directories (…)`, `error: edit not approved: …`.

## Confinement

Writes land only under the directories the sandbox lets `run_command` write under: the directory daimon
was launched in, the temporary directory, `/private/tmp`, the user cache directory, and
`sandbox.writablePaths` from `config.json`. The check canonicalises the path (symlinks resolved, so
`/tmp` is `/private/tmp`) and refuses anything else before touching the file system. With the sandbox
off (`sandbox.enabled: false` or `--unsafe`) there is no confinement, as for commands.

## Approval

Every edit is judged as the command `edit_file <mode> <path>` by the full classifier, rules and, when
configured, the model. The rules rate every edit at least `moderate` ("edits a file") and credential
paths (`.ssh/`, `.aws/credentials`, `.netrc`, keys) `dangerous`, so under the default threshold the
first edit in a conversation asks and the answer's scope applies to later ones: "this session" covers
every `edit_file` call, project and always scopes are keyed to the pattern `edit_file *` as for a
program. Where nobody can answer the edit is refused and the file is untouched.

## Limits

| Limit | Value |
| --- | --- |
| `replace` file size | 1 MiB; larger files are refused (`FileWriter(maxBytes:)`, fixed in code) |
| Binary files | Refused for `replace` (a NUL byte); `write` and `append` do not read the file |
| Directories, missing parent directory, unknown `mode`, `replace` without `find` | Errors |
| Atomicity | The file is written in place; a failure during the write can leave it partial |

## Audit and receipts

Each edit that happens is recorded as `file.write` with `path`, `mode`, `created`, `bytesBefore`, and
`bytesAfter` ([logging.md](../logging.md)); the MCP receipt lists it under `files`. The content itself
is in the `tool.call` event's arguments.

## Observed with the model

Probed on this Mac on 2026-09-20 with the system model and `--yes`: asked to read a two-line file and
replace exactly `let x = 1` with `let x = 42`, the model supplied `find` verbatim but put both lines of
the file in `content`, so the second line was duplicated. The tool did what it was told; the prompt
must say that `content` is only the replacement for `find`. A write outside the writable set was refused
with the directories named and no file created. Not yet in the eval harness.

## Implementation

`FileWriter` in `harness/Sources/DaimonCore/Tools/FileWriter.swift` (confinement from
`CommandPolicy.writableRoots`, the list the Seatbelt profile is built from), tested in `FileWriterTests`;
`EditFileTool` is the model-facing wrapper, tested in `ToolWrapperTests`.
