# read_file

Reads a page of lines from a text file, numbered, and tells the model how to fetch the next page. The file is
streamed, so reading the first page of a multi-gigabyte log costs only the bytes up to the end of that page.

## Arguments

| Name | Type | Required | Meaning |
| --- | --- | --- | --- |
| `path` | string | yes | Path of the file. |
| `offset` | integer | no | 1-based line number to start from. Default 1. |
| `limit` | integer | no | Maximum lines to return. Default 100. |

## Result

Numbered lines, then a marker.

```
1	# daimon
2
3	An on-device, tool-using AI microharness ...
[more: call again with offset 4]
```

The final line is either `[more: call again with offset N]` or `[end of file]`. A range past the end yields
`(no lines in range)` and `[end of file]`.

## Approval

Paths go through the approval gate's rule classifier as if they were `cat <path>`: credential-like paths
(`.ssh`, `.aws/credentials`, `.netrc`, keys) are rated dangerous and ask, or are refused where nobody can
answer, exactly as the command would be. Ordinary files pass without a model call. Refusals come back as
`error: read not approved: …`.

## Limits

| Limit | Default | Configure |
| --- | --- | --- |
| Bytes of line content per page | 4 KiB; the page ends early and the marker points at the next line | `FileReader(maxBytes:)` (not yet in `config.json`) |
| Line length | A single line longer than the budget is cut to the budget, on a character boundary | same |
| Binary files | Rejected if the first chunk contains a NUL byte | not configurable |
| Directories, missing files, `offset`/`limit` below 1 | Errors | |

CRLF line endings are handled; the returned lines never include `\n` or `\r`.

## Implementation

`FileReader` and `LineScanner` in `harness/Sources/DaimonCore/FileReader.swift`, tested in `FileReaderTests`
including chunk-boundary and early-stop cases; `ReadFileTool` is the model-facing wrapper.
