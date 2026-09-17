# run_command

Runs a shell command on this Mac and returns its exit status and output. This is the generic exec tool: the
model uses it to build, test, list files, and inspect the system, and through it can reach any binary on the
machine.

## Arguments

| Name | Type | Required | Meaning |
| --- | --- | --- | --- |
| `command` | string | yes | A POSIX shell command line, executed with `/bin/sh -c`. |
| `workingDirectory` | string | no | Absolute path to run in. Default: daimon's current directory. A missing directory is an error. |

## Result

```
exit status: 0
stdout:
<tail of stdout>
stderr:
<tail of stderr>
```

Extra lines appear when relevant: `timed out: the command was killed` and
`output truncated: only the tail of each stream is shown`. Empty streams are omitted. A killed process
reports its signal negated (for example `-15` for SIGTERM).

## Limits

| Limit | Default | Configure |
| --- | --- | --- |
| Timeout | 60 s, then SIGTERM, then SIGKILL after 2 s | `commandTimeoutSeconds` in `config.json` |
| Output per stream | 4 KiB, tail kept | `commandMaxOutputBytes` in `config.json` |
| stdin | `/dev/null` | not configurable |

## Safety

There is no sandbox or allowlist: the command runs with daimon's privileges and the model chooses it. This is
a recorded decision ([ADR 0005](../decisions/0005-tools-as-plain-binaries.md)); the options for changing it
are in [policy-and-sandboxing.md](../policy-and-sandboxing.md). Until then, omit the tool where it is not
needed (`--tool current_date`, or the MCP `tools` argument) and run daimon as a user whose permissions you
are comfortable delegating.

## Implementation

`CommandRunner` in `harness/Sources/DaimonCore/CommandRunner.swift` does the work and is tested by running
real commands in `CommandRunnerTests`; `RunCommandTool` is the thin model-facing wrapper.
