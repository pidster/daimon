---
paths:
  - "tools/**"
---

# Rust guidance for the Cargo workspace

- One crate per binary under `tools/<name>`, listed in the workspace `members`. Today there is one,
  `wisp-tui`; `scripts/check` runs fmt, clippy, build, and tests on the workspace.
- `wisp-tui` is a front end, not a tool (ADR 0029): it speaks the `wisp chat --json` protocol
  (`docs/wisp.md`, "Headless chat") and owns the terminal; it has no model or policy logic of its own.
  Its crate version follows `WispVersion.current`, and the release checks they match.
- A tool binary is an ordinary CLI program: arguments in, stdout out, meaningful exit code. It knows
  nothing about agents or MCP (ADR 0005). The harness declares the model-facing schema and description in
  Swift; the model may also reach any binary through `run_command`.
- Bound output. The model's window is about 4k tokens; a tool that can produce more must page or
  summarise, never dump.
- Workspace lints are inherited and enforced by the gate: `unsafe_code = "forbid"`, clippy `all` and
  `pedantic` as warnings with warnings-as-errors, `unwrap_used` and `expect_used` warned. Prefer `?` with
  typed errors (`thiserror` is fine) and `anyhow` only at `main`.
- Edition 2024, `rustfmt.toml` at 100 columns, `cargo fmt --all` before committing.
- Tests live beside the code (`#[cfg(test)]`) and must not need the model or the network. Cargo works
  inside wisp's sandbox unchanged.
- Document the tool under `docs/tools/<name>.md` (contract, result format, limits) in the same commit.
