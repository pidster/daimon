# daimon

An on-device, tool-using AI microharness built on Apple's Foundation Models framework, the same system model the `fm` command family exposes.

```
cd harness
swift build
.build/debug/daimon tools
.build/debug/daimon "What is the date in Tokyo?"
```

Layout: `harness/` (Swift package, the `daimon` binary), `tools/` (Cargo workspace for Rust tool binaries),
`docs/`, `scripts/check` (quality gate).

Requires macOS 27 or later and Xcode 27 (the Command Line Tools alone lack the `@Generable` macro plugin).

After cloning, run `scripts/check install-hooks` to enable the pre-commit gate. Documentation is in [docs/](docs/README.md).
