# Releasing daimon

daimon ships as one arm64 binary through a Homebrew tap. This page is the procedure; the decision is
[ADR 0012](decisions/0012-homebrew-release.md).

## What a release is

- A git tag `vX.Y.Z` on `main` whose version equals `DaimonVersion.current` (semver, from 0.1.0).
- A GitHub release for that tag with `daimon-X.Y.Z-arm64.tar.gz` (the stripped release binary and the
  LICENSE) and `daimon-X.Y.Z-arm64.tar.gz.sha256`.
- A formula update in `pidster/homebrew-tap` (`Formula/daimon.rb`) pointing at that tarball with its
  checksum. Users run `brew install pidster/tap/daimon`, which installs to Homebrew's prefix
  (`/opt/homebrew/bin/daimon`), already on `PATH`.

The binary is unsigned for now; Homebrew does not quarantine what it downloads, so Gatekeeper does not
intervene. A signed and notarised `.pkg` is a possible later channel.

## Procedure

`scripts/release X.Y.Z` does all of it and refuses to continue at the first problem. `--dry-run` performs
every local step and prints the remote ones instead of executing them.

1. Preflight: clean tree on `main`, `DaimonVersion.current` equals `X.Y.Z`, no existing tag, `gh` is
   authenticated, `scripts/check` passes, `scripts/check eval` passes.
2. Build: `swift build -c release`, `strip`, verify `daimon --version` prints `X.Y.Z` and `daimon doctor`
   passes on the build machine.
3. Package: tarball with `daimon` and `LICENSE`; SHA-256 file.
4. Publish: `git tag -a vX.Y.Z`, push the tag, `gh release create` with both assets and generated notes.
5. Tap: clone or update `pidster/homebrew-tap`, write `Formula/daimon.rb` from the template with the new
   URL and checksum, commit, push.
6. Verify from a clean shell: `brew update && brew install pidster/tap/daimon && daimon doctor`.

Until a macOS 27 CI runner exists this runs on a developer's Mac with Xcode 27.

## Bumping the version

`DaimonVersion.current` in `harness/Sources/DaimonCore/Audit/AuditEvent.swift` is the single source. Bump
it in its own commit ("Bump version to X.Y.Z"), then run the release. The tag check in preflight makes a
mismatch impossible to ship.

## First-run support

`daimon doctor` checks what a new install needs: the on-device model is available and enabled, macOS
is 27 or later, `sandbox-exec` exists, `~/.daimon/config.json` parses, and the home directory is writable.
It is the first thing to ask for when someone reports a problem.
