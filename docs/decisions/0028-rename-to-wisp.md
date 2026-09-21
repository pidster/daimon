# ADR 0028: The project is called wisp

Date: 2026-09-21. Status: accepted.

## Context

The project was named daimon from its first commit. On 2026-09-21 the repository had already moved to
`pidster/wisp` and the name was to follow, everywhere, at a natural pause between features.

## Decision

- A single mechanical rename in one commit: every tracked occurrence of `daimon`, `Daimon`, and
  `DAIMON` becomes `wisp`, `Wisp`, `WISP`, and the files and directories named for it move. That
  includes the Swift targets and types, the executable, the home directory and its environment
  variable, every `WISP_*` variable, the logging subsystem, the MCP server name and `wisp://` resource
  scheme, the release artefacts, and every page including older decision records, whose reasoning is
  unchanged by the name.
- No compatibility layer. `~/.daimon` is not read or moved, `DAIMON_*` variables are ignored, and no
  formula points from the old name to the new. The change is announced in the changelog.
- Releases go to the existing tap, `pidster/homebrew-tap`, as a second formula `wisp.rb` beside
  `daimon.rb`, which stays and keeps serving the daimon releases. A tap holds any number of formulae,
  so one tap serves every project; a separate `homebrew-wisp` was created first and deleted the same day.
- Version 0.4.0, since every user-visible name changed.

## Consequences

- One commit to read for the rename, with nothing else in it; the ADR is a separate commit.
- An existing install needs `brew uninstall daimon`, `brew install pidster/tap/wisp`, and a manual move
  of `~/.daimon` to `~/.wisp` if its approvals and transcripts are wanted.
- MCP clients change the server name and tool names (`mcp__wisp__respond`); Claude Code needs `/mcp`
  to load the renamed `.mcp.json` entry.
