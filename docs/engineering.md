# Engineering standards

daimon is held to the highest standard of coding and software-engineering practice. This page lists what that
means in practice and how it is enforced. Everything here is mechanical where it can be; judgement calls are
recorded as [decisions](decisions/).

## The gate

`scripts/check` is the single entry point used by the pre-commit hook, CI, and humans:

| Command | What it does |
| --- | --- |
| `scripts/check lint` | `swift format lint --strict` over `Sources`, `Tests`, `Package.swift` |
| `scripts/check build` | `swift build -Xswiftc -warnings-as-errors` |
| `scripts/check test` | `swift test` |
| `scripts/check hygiene` | Staged-file checks: conflict markers, trailing whitespace, files over 1 MiB, commit author uses a GitHub noreply address |
| `scripts/check all` | Everything above, in that order |
| `scripts/check install-hooks` | Points `core.hooksPath` at `.githooks/` |

Run `scripts/check install-hooks` once after cloning. The pre-commit hook runs `hygiene`, `lint`, `build`,
and `test`; on a warm build cache this takes a few seconds. Bypass with `git commit --no-verify` only for
work-in-progress commits on a branch that will be squashed.

`swift format --in-place --recursive Sources Tests Package.swift` fixes most lint findings automatically.

## Rules

- **Formatting** is defined by `.swift-format`: 4-space indent, 120 columns, ordered imports.
- **Documentation**: every `public` declaration has a `///` comment; `Throws:` and `Parameters:` sections are
  validated by the linter.
- **Safety**: no force unwrap, force try, or implicitly unwrapped optionals. No `fatalError` in library code.
- **Concurrency**: Swift 6 strict concurrency stays on. Never silence a diagnostic with `@unchecked Sendable`
  or `nonisolated(unsafe)`; restructure instead.
- **Errors** are typed enums with `CustomStringConvertible` descriptions.
- **Tests** accompany every behaviour change and never require the on-device model. Keep logic in pure
  functions and test those; the live model is exercised by running the binary.
- **Layering**: logic in `DaimonCore`; the executable target holds only argument parsing and I/O.
- **Commits** are small and single-purpose. The subject says what, the body says why.
- **Decisions** that are non-obvious or hard to reverse get an ADR in `docs/decisions/`.

## CI

`.github/workflows/ci.yml` runs `scripts/check lint`, `build`, and `test` on every push to `main` and every
pull request. CI compiles against the framework but does not exercise the model.
