# Review: failures.tsv

**Verdict: usable after fixes.** 610 examples. Labelling is mostly careful and the header rules are applied consistently in most places. The fixes that matter are four mislabels that contradict the file's own rules, about a dozen lines made by joining two or three real output lines into one (no tool prints them), a doubled-letter typo shortcut on error lines, and some rules that break the "one line read alone" premise. Leakage into the triage eval is limited to universal banners and fixed-format summary lines; the details are below.

Line numbers are file line numbers, comments included. `fixes-failures.tsv` holds 5 relabels, 17 edits, 6 removals and 34 additions. Every non-add row was checked by script to match an existing line exactly.

## 1. Mislabels against the file's own rules

| Line | Label | Text (abridged) | Problem | Fix |
| --- | --- | --- | --- | --- |
| 243 | test-failure | `Scenario: Guest checkout fails  # features/checkout.feature:12` | Cucumber prints this header for every scenario, passing ones included. "fails" is part of the scenario's name, which is exactly the trap the none rule describes (`✔ Test failsGracefully() passed`). | none |
| 283 | warning | `=== warnings summary ===` | A banner that names nothing. `=== FAILURES ===` (479) and `short test summary info` (481) are none, so this should be none too. | none |
| 480 | none | `____ test_refund_math ____` | pytest prints this header only for a failing test, and it names the test. The jest equivalent `● Cart › removes the last item…` (185) is labelled test-failure. The rule's exemption covers headers with *no* failure named in them, and this one names the failure. | test-failure |
| 522 | none | `➤ YN0000: · Done with warnings in 1s 204ms` | A summary that reports warnings. `⚠ Compiled with warnings in 4.1s` (336) is warning. | warning |
| 286 | warning | `app/views.py:88:1: E501 Line too long` | pycodestyle's E codes are its error class, and they fail flake8/ruff with exit 1, just as `F821` on line 83 (error) does. As labelled, the classifier learns "E501 → warning, F821 → error" from the code letter alone. | error (or relabel 83 as well; either way, make them consistent) |

Debatable lines, kept as they are but flagged:
- 152 `Error: Cannot find module '@babel/preset-env'` is labelled error. In Node this is normally an uncaught require failure, which the header's own definition makes crash. Compare 392 and 630 (crash).
- 135 `##[error]The operation was canceled.` is labelled error. A cancellation is not a failure of the build.
- 330: biome's `lint/style/useConst` line carries no severity. Biome treats recommended rules as errors, so warning is a guess.
- 332: shellcheck `(info)` severity is labelled warning. Acceptable, but the finding is only info-level.
- 408 `Restarting after unexpected exit, crash, or test timeout in SyncTests.testLargeMerge()` names a test and could be test-failure.
- 411 `Kernel panic - not syncing` is outside the build and test domain.

## 2. Inconsistency, and rules that are wrong

- **"Read alone" is broken by design in several places.**
  - 167 `    NotesTests.SyncTests/testMergeConflict()` and 238 `    session::tests::expires_after_ttl` are bare test identifiers. They are test-failure only because of the header line before them. Read alone they look the same as `cargo test -- --list` output or a passing list. The classifier will learn "indented `::` path → test-failure". I added a hard negative (`session::tests::expires_after_ttl: test`); consider removing both lines.
  - Bare exception lines (378–384, 626, 627, 634) are labelled crash on the grounds that they end an *uncaught* traceback. Read alone, the same line appears in handled, logged tracebacks from servers that keep running. The same goes for 389 `Caused by:` (Java prints `Caused by:` chains in every logged exception). This rule will produce false crashes on runtime logs. Suggest narrowing it: crash only for the traceback head and the runtime's own abort lines, and leave bare `XError:` lines to context.
- **The exception class name decides the label.** Bare `AssertionError:` lines (191, 218) are test-failure, while every other bare `XError:` line is crash. That is consistent with the assertion rule, but it is a surface shortcut. An `AssertionError` from library code, which the header says is crash, has no example.
- **Go panic rule.** The header says Go `panic:` is crash, but 234 `panic: test timed out after 30s` is test-failure. The label is defensible; the header should state this exception.
- **pytest ERROR versus KnownFailures.** `KnownFailuresTests.pytestAndGoTestSummariesAreRead` scans `ERROR tests/test_db.py::test_connect` as kind `error`. The set has only the collection form (77, error) and unittest `ERROR: test_x` (219, test-failure by rule). The setup-error-on-a-named-test shape, the one the exact scanner reads, is missing. I added it as error to agree with the scanner.
- **`note:` lines.** javac `Note:` (307) and the mypy note (331) are warning, while SwiftPM, rustc and xcodebuild notes (435, 453, 454) are none. 307 is fine on substance. 331 is also invented (see §5).

## 3. Near-duplicates and templated families

There is no exact duplicate. Grouping by shape (identifiers and digits masked) finds mostly healthy pass/fail pairs that differ only in the verdict token. Keep those; they teach the right feature: 163/424, 165/425, 169/447/448, 173/449, 175/461/462, 205/532, 215/555, 221/570, 227/566, 138/590.

Families to watch:
- Swift Testing `✘` lines: 156–160, 239, 250, 649 (8, all test-failure). Every `✘` line is test-failure. That is true of the real tool, so it is not a false shortcut. Keep 5–6.
- Joined unittest pair 216 (`Ran 32 tests … FAILED (failures=2)`) and 556 (`Ran 32 tests … OK`). The label depends only on the trailing token, and the text is not real output. Both are edited.
- Signal-by-shell lines: 342, 344, 347, 620 (`zsh: <signal> <cmd>`), plus 341, 343, 345, 348 (`<Signal>: N`). 8 in total is fine.
- `Fatal error:` family: 351–354, 406, 622 (6). Keep 4.
- `thread 'main' panicked at`: 366, 400, 625 (3). Fine.
- No family is large enough to inflate accuracy on its own.

## 4. Leakage against the eval and scanner tests

I compared whitespace-collapsed text exactly and after masking digits, and also by sequence similarity above 0.72, against `harness/Tests/ModelEvalTests/TriageEvalTests.swift` and `harness/Tests/WispCoreTests/KnownFailuresTests.swift`.

**Exact matches** (same text after whitespace collapse):

| Line | Label | Text | In |
| --- | --- | --- | --- |
| 237 | none | `failures:` | KnownFailures (twice) |
| 415 | none | `Building for debugging...` | TriageEval |
| 453 | none | ``note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace`` | KnownFailures |
| 471 | none | `=== test session starts ===` | TriageEval |
| 479 | none | `=== FAILURES ===` | both |
| 481 | none | `=== short test summary info ===` | both |

**Same after masking digits:**

| Line | Label | Matches |
| --- | --- | --- |
| 159 | test-failure | `✘ Test run with N tests in N suites failed after N seconds with N issues.`, identical in shape to the eval fixture line |
| 450 | none | `running N tests` (KnownFailures) |
| 474 | none | `collected N items` (TriageEval) |

**Same template with different identifiers:**
- 157 and 158 match the Swift Testing `✘ Test x() failed after…` and `✘ Suite X failed after…` lines.
- 175 `--- FAIL: TestX (Ns)` matches the KnownFailures go fixture.
- 183 matches the pytest `N failed, N passed in Ns` summary.
- 64 `error: could not compile … due to N previous errors` matches both files.
- 58 `fatal error: '…' file not found` matches the KnownFailures clang line.
- 256 matches the eval's Swift "never used; consider replacing with '_'" warning.
- 458 and 459 match the eval's rustc caret and `-->` lines.
- 480 matches the eval's `___ test_divide ___` header.
- 423 and 426 match eval Swift Testing and XCTest pass lines.

Impact: the triage eval scores recall per fixture, not per line. Every exact match is a universal banner that any real run prints, so removing them would only hide coverage of the rules. I propose no removals for these. However, when this classifier is evaluated on the eval fixtures, the result will be optimistic: every line shape in all four fixtures is represented in training. The eval needs held-out fixtures with formats absent from training, such as nextest, Gradle, rspec and xcodebuild. One of my draft additions contained the KnownFailures string ``error: linker `cc` not found``; I replaced it, and no addition matches either file.

## 5. Realism and synthetic tells

**Joined lines.** Each of these is two or three real output lines glued into one, which no tool prints:

| Line | What was joined | Fix |
| --- | --- | --- |
| 232 | go `=== RUN … --- FAIL:` | edited |
| 216, 556 | unittest `Ran N tests` with `FAILED` / `OK` | edited |
| 278 | go `# pkg` header with an ld warning | edited |
| 329 | cargo `Compiling …` with `warning:` | edited |
| 394 | node location line with its code line | removed; by the file's rule both halves are none |
| 629 | node location, `throw err;`, and caret | removed |
| 631 | lldb `Process N stopped` with the thread line | edited |
| 651 | Gradle `FAILED` with the exception line | edited |
| 652 | Playwright `N failed, N flaky, N passed` | not edited; Playwright prints these on separate lines |

**Invented formats:**
- 331 `mypy: note: unused "type: ignore"`: mypy reports this as `file:line: error: Unused "type: ignore" comment`. Edited, and relabelled error.
- 332 `shellcheck: In deploy.sh line 14: SC2086 …` on one line: edited to shellcheck's real `^-- SC2086 (info):` line.
- 253 `mix test failed:` prefix: edited.
- 608 and 609: bare `Compiling X` / `Linking X` lines. Edited to SwiftPM's form.

**Fabricated hard negatives.** No tool prints these:
- 591 `warning: 0 warnings generated.` is the worst: a `warning:` prefix on a none line.
- 597 `Linking with --fail-fast enabled`
- 599 `Retrying failed jobs: none`
- 618 `Compiled with 0 errors and 0 warnings in 912 ms`

All four are removed. 598, 600 and 601 are also invented but harmless; consider replacing them with real output.

**Doubled-letter typo tell.** About 12 of the 112 error lines carry a deliberately misspelled identifier: `dataTaskk` (41), `serde_jsonn` (66), `numpyy` (79), `ui-kitt` (88), `biuld` (89), `strictNullCheck` (93), `Hedaer` (97), `adapterr` (107), `alpnie` (126), `pyhton3` (128), `setup-nodee` (136), `relase` (148). No other label has any. A character-level model can learn "doubled final letter → error". Five are edited to non-typo causes; the rest are left, because typos are a real cause.

**Leading whitespace** occurs only on none (48), test-failure (27) and warning (5) lines, never on error or crash. Real output has indented error and crash lines, such as xcodebuild's indented `error:` and Python's indented `raise`. This is a minor shortcut; some additions help.

The set is ordered in blocks by label. Shuffle it before any split.

## 6. Safety of the data

No credentials, emails, phone numbers, real people or private hosts. The only IP is `127.0.0.1` (617). Paths use `/Users/dev`. Real public repositories appear (apple/swift-*), which is fine. 132 names `wisp-tui`, a real binary of this project, which contradicts the header's "all names invented"; it is harmless. 318 mentions `ARG "API_TOKEN"` as a name only.

## 7. Balance and coverage gaps

| Label | Count | Share |
| --- | --- | --- |
| none | 218 | 36% |
| error | 112 | 18% |
| test-failure | 99 | 16% |
| warning | 93 | 15% |
| crash | 88 | 14% |

This matches the header's claim. After the fixes: none −4, error +12, test-failure +6, warning +2, crash +5 (approximately). The balance stays within the stated bounds.

Missing cases (added unless noted):
- **pytest:** a progress line with `F` or `E` (the only one in the set, 477, is passing); the `path:line: ExcName` location line; `ERROR` on a named test (the KnownFailures shape); `SKIPPED`, `XFAIL` and `XPASS(strict)`.
- **Go:** `FAIL pkg [build failed]`, which is an error rather than a test-failure; the `-race` detector failing a test.
- **Linux crash forms:** `Segmentation fault (core dumped)`, `Aborted (core dumped)`. All existing signal lines are macOS forms.
- **Crash coverage:** LeakSanitizer (only ASan is present); Xcode's `Thread 3: EXC_BAD_ACCESS`.
- **git:** merge conflict, failed push, network fetch failure; also `curl: (22)`.
- **Hooks and thresholds:** pre-commit hook `Failed`, `Passed` and `Skipped` result lines; coverage-threshold failures (pytest-cov and jest forms).
- **Dependencies and CI:** npm audit vulnerabilities (warning); nextest `FLAKY` (warning); jest test timeout; CI job timeout; PEP 668 `externally-managed-environment`; uv resolver failure.
- **Hard negatives:** Swift/clang `note: … declared here`; XCTest `started` and `skipped` lines as counterweights to 163 and 164; `cargo test -- --list` output.
- **Not added, to avoid leakage:** Swift's most common error, `error: cannot find 'x' in scope` (the eval's own line), and SwiftPM's trailing `error: fatalError` line. KnownFailures treats the latter as noise, but the definitions here would make it error. Decide its label explicitly before adding it.

## 8. Format

Every data line has exactly one tab and a known label, and none is empty. Texts that begin with `#` (75, 197, 387, 388, 553, 574–578) are data lines as the header describes. The section comment lines 155, 255, 340 and 414 are well-formed. No problems.

## Most harmful problems

1. **Rules that label bare exception lines and `Caused by:` as crash** (378–384, 389, 626, 627, 634), and bare test identifiers as test-failure (167, 238). Read alone, these lines appear in handled logs and passing listings. The classifier will report crashes and failures that did not happen.
2. **Mislabels that contradict the file's own rules:** 480 (pytest failure header labelled none), 243 (a passing-scenario header labelled test-failure because of "fails" in its name), 283 (banner labelled warning), 522 (warnings summary labelled none), and 286 versus 83 (flake8 E versus F codes).
3. **Synthetic text:** about ten joined multi-line records and four invented hard negatives (591 has a `warning:` prefix on a none line), plus a doubled-letter typo tell unique to error lines. This teaches features real output lacks. Leakage adds to this: every line shape in the four triage eval fixtures is present in training (159 matches an eval line exactly once digits are masked), so any per-line evaluation on those fixtures will overstate accuracy.
