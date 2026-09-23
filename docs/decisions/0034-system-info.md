# ADR 0034: `system_info` answers questions about the Mac with fixed, read-only probes

Date: 2026-09-23. Status: accepted.

## Context

"What is using port 8080?", "what is filling my disk?", "which process is eating CPU?" are questions a
developer asks their Mac, and wisp's sandbox, approval gate, and audit log make it reasonable to let a
model look. With only `run_command`, the small on-device model composes the shell itself, and on
2026-09-23 it reached for Linux commands (`ss -tulnp`), for `ls` where `du` was needed, and for `ps`,
which cannot run in wisp's sandbox at all: `/bin/ps` and `/usr/bin/top` are setuid root, and Seatbelt
refuses to execute a setuid binary (`sandbox-exec: execvp() of '/bin/ps' failed: Operation not
permitted`, verified on macOS 27 the same day). Raw `lsof` or `du` output also costs the 4k-token window
far more than the answer needs.

## Decision

- **A model tool, `system_info`, with a topic** (`ports`, `freeSpace`, `folderSizes`, `processes`,
  `memory`, `process`, `battery`, `system`, `network`) and typed arguments where a topic takes one: a
  `port` integer, a `process` name or id, a `path`. wisp chooses the commands, parses their output, and
  returns a short table, at most 15 rows and 4 KiB.
- **Probes run through the conversation's `CommandRunner`**, so the policy, the sandbox (with nested
  detection), the timeout (raised to 30 s for `du`), the output bound, and `command.outcome` audit
  apply, **but not the approval gate**: the model supplies no command, only a topic and values that are
  validated (a port is 1 to 65535, a process id is a number and a name is matched in Swift, a path must be
  an existing folder and is passed single-quoted). The commands are fixed and read-only: `lsof`, `df`,
  `du`, `memory_pressure`, `pmset`, `sw_vers`, `sysctl`, `uptime`, `scutil --nwi`.
- **Process topics use `libproc`, not `ps`**: `ProcessTable` lists pids (`proc_listallpids`), reads
  task info (`proc_pidinfo`, `PROC_PIDTASKALLINFO`: name, parent, resident size, CPU time converted
  through the Mach timebase), samples CPU time twice half a second apart for a CPU percentage, and reads
  a process's arguments with `sysctl(KERN_PROCARGS2)`. Without root this sees only the user's own
  processes, and every report says so; `lsof` has the same limit and its report says so too. A process's
  command line passes through the secret rules (ADR 0031) before the model sees it.
- **The description tells the model to prefer the tool** to shell commands for these questions and why
  (`ps` and `top` cannot run). A `process` call without a name is refused with an error that says how to
  retry, which the model then follows.

## Consequences

- Measured with `SystemInfoEvalTests` on 2026-09-23 on the system model, eight plain questions that do
  not name the tool, twice each, with `run_command` also offered behind a gate that refuses anything
  above safe: 11 of 16 with the first design (a string `target`, topics `disk` and `diskUsage`); after
  typed arguments, a steering description, the topics renamed `freeSpace` and `folderSizes`, and the
  directive error, 15, 14, and 16 of 16 on three runs. The miss that remains is the question naming an
  app ("Is Ollama running…?"), where the model sometimes calls `process` without the name and then falls
  back to `ps`, which fails in the sandbox.
- Probes are fast: under 0.1 s for `lsof`, `df`, and the rest, about 0.5 s for the process topics (the
  CPU sample), and seconds for `du` over a large folder (4.3 s for 18.8 GB of `~/Library/Caches`).
- A seventh tool schema is in the prompt of every conversation that enables all tools; the description is
  two sentences and the arguments are four.
- `run_command` still cannot run `ps` or `top`; its page says so and points here.
- Tests without the model: every parser over captured output, each topic through a scripted probe and
  fixed process samples, validation, the tool's error text, the `KERN_PROCARGS2` layout, the CPU
  arithmetic, and a live read of the test process itself through `ProcessTable`.
