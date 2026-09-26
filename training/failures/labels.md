# Labels and rules for the failures set

The header the set was drafted with, then adjusted after review (see ../README.md and ../reviews/failures.md).

```
Labelled lines of build, test, and runtime output for training a failure classifier: one per line,
`label<TAB>text`. Lines starting with `#` are comments (a text beginning with `#` follows its label).
The label says what ONE line, read alone, reports.

error: a build, compile, link, install, lint-as-error, or command step failed, or a diagnostic of
  severity error (`file:line: error:`, `error[E0433]`, `npm ERR!`, `make: *** ... Error 2`,
  `command not found`, `ld: symbol(s) not found`, `** BUILD FAILED **`, `exit code 1` in CI, docker
  `failed to solve`, gradle `FAILURE: Build failed`, pytest collection `ERROR tests/...`). A linter
  finding the tool itself marks `error:` (warnings as errors, a serious swiftlint violation) is error.
test-failure: a line naming a failing test, an assertion or comparison that failed inside test output,
  or a summary whose counts show more than zero failures. A panic in a thread named like a test path
  is test-failure; unittest `ERROR: test_x (...)` (a named test that raised) is test-failure.
warning: a warning or deprecation that does not fail the run. pip's "dependency resolver does not
  currently take into account" line is a warning despite its ERROR prefix (pip continues); a linter
  summary with 0 errors and some warnings is warning.
crash: the process died abnormally: a signal (segfault, abort, bus error, SIGILL, Killed: 9, exit 137
  or 139), a runtime trap (`Fatal error:`, `Precondition failed`, `thread 'main' panicked`, Go
  `panic:` / `fatal error:`), a sanitizer abort, an uncaught exception head (`Traceback (most recent
  call last):`, `Exception in thread "main"`, `FATAL ERROR: Reached heap limit`, NSException), the
  final exception line of an uncaught traceback (`KeyError: 'x'`), a `Caused by:` line in such a chain,
  and crash-report headers (`Thread 0 Crashed::`, `Exception Type:`). An assertion that aborts inside
  a test function is test-failure; one that aborts in library code is crash.
none: everything else: progress, compiling, downloading, linking, passing tests, clean summaries, and
  context lines that carry no verdict of their own:
  - stack frames, code snippets, caret and gutter lines (`   |`, `^^^^`), `-->` location lines;
  - section headers and banners with no failure named in them (`=== FAILURES ===`, `failures:`,
    `Failing tests:`, `[ERROR] Failures:`, `The following build commands failed:`, go's
    `# package` header): the finding is the line that follows;
  - one-sided assertion detail (`left: 1250`, `expected: 108.0`, `Expected: 0`): the finding is the
    line stating the comparison or the failing test;
  - lines that mention error or fail without reporting one (`0 errors`, `0 failed`,
    `test_error_handling PASSED`, `✔ Test failsGracefully() passed`, `Compiling error-chain`,
    `ErrorBoundary.tsx` in a file list, `--fail-fast`, commit subjects).

Distribution: none is the largest class on purpose (about a third), because most lines of real output
are not failures; every other label is at least 14%.
Real output sometimes holds tabs (go's `FAIL<TAB>pkg`, crash-report columns, Java `<TAB>at` frames);
they are replaced by spaces here so each line has exactly one tab, after the label.
All paths, package names, ids, and hosts are invented.
error: build, compile, link, install, lint-as-error or command step failures
```
