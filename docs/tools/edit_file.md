# edit_file

Writes a text file: the whole file, an addition at the end, or one exact replacement. The counterpart of
[read_file](read_file.md): read a page, then replace exactly what was shown. Decided in
[ADR 0024](../decisions/0024-edit-file.md).

## Arguments

| Name | Type | Required | Meaning |
| --- | --- | --- | --- |
| `path` | string | yes | Path of the file. Its directory must exist; `edit_file` never creates directories. |
| `mode` | string | yes | `write` replaces the whole file, creating it if absent. `append` adds to the end, creating it if absent. `replace` changes one line, by number or by exact text. |
| `content` | string | yes | The text to write or append; for `replace` with `line`, the whole new line; for `replace` with `find` alone, the replacement for `find` only. |
| `line` | integer | for `replace` | The 1-based line to rewrite, as `read_file` numbered it. Past the end, nothing changes. Preferred: the model copies a number it just read instead of retyping the text. |
| `find` | string | for `replace` | Without `line`: the exact existing text to replace, which must occur exactly once. With `line`: text that line must contain, so a stale number changes nothing. |

Read the file first, then replace by `line`:

```
Use read_file to read /repo/Package.swift. Then use edit_file with mode replace on /repo/Package.swift,
with line set to the number read_file showed for `let version = "0.1.0"` and content `let version = "0.2.0"`.
Report the tool results verbatim.
```

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

Writes land only under the directories the sandbox lets `run_command` write under: the directory wisp
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
| Line edits | One line per call: `content` is that line, one trailing newline is dropped, and any other newline (a pasted neighbour or the `[end of file]` marker) is refused with nothing changed; a line that is not there or does not contain `find` is an error |
| Binary files | Refused for `replace` (a NUL byte); `write` and `append` do not read the file |
| Directories, missing parent directory, unknown `mode`, `replace` without `find` | Errors |
| Atomicity | Every write goes to a temporary file beside the target (same directory, the existing mode copied) and is renamed over it, so a reader never sees a partial file and a failure leaves the original untouched |

## Audit and receipts

Each edit that happens is recorded as `file.write` with `path`, `mode`, `created`, `bytesBefore`, and
`bytesAfter` ([logging.md](../logging.md)); the MCP receipt lists it under `files`. The content itself
is in the `tool.call` event's arguments.

## Measured with the model

The eval (`ToolEvalTests`, ten small files) reads a file and rewrites one numbered line; the recorded
result is in [measurements.md](../measurements.md) and on `wisp tools --markdown`. The `line`
argument exists because the first version, replace by `find` only, measured 3 of 5 on 2026-09-20: the
model copied `find` correctly and then put the neighbouring line into `content` too. A write outside
the writable set is refused with the directories named and no file created.

## Implementation

`FileWriter` in `harness/Sources/WispCore/Tools/FileWriter.swift` (confinement from
`CommandPolicy.writableRoots`, the list the Seatbelt profile is built from), tested in `FileWriterTests`;
`EditFileTool` is the model-facing wrapper, tested in `ToolWrapperTests`.
