# tools

Cargo workspace for wisp's tool binaries. Each tool is an ordinary CLI program (arguments in, stdout out,
meaningful exit code) that knows nothing about agents; the harness under `../harness` declares the
model-facing schema and invokes the binary. See `../docs/decisions/0005-tools-as-plain-binaries.md`.

Add a tool: `cargo new --bin <name>` here, list it in `members`, and register a Swift `Tool` for it in
`harness/Sources/WispCore/Tools/`.
