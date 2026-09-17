---
paths:
  - "tools/**"
---

# Rust guidance for tool binaries

- One crate per tool under `tools/<name>`, listed in the workspace `members`. The workspace is empty until
  the first real tool; `scripts/check` skips Rust checks until a `tools/*/Cargo.toml` exists.
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
  inside daimon's sandbox unchanged.
- Document the tool under `docs/tools/<name>.md` (contract, result format, limits) in the same commit.
