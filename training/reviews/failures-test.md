# Review: failures test set (`testsets/failures-test.tsv`)

Reviewed 2026-09-26 against `training/failures/labels.md` and the set's own header (lines 26 to 69). Line numbers are lines of the file; the header is lines 1 to 70. Fixes are in `fixes-failures.tsv` (21 rows, all remove). Every row matches an existing line exactly.

**Verdict: usable after fixes.** The labels are careful, and I found no line whose label is plainly wrong under the rules as written. Two things need fixing: about 16 lines are train or dev templates with a name, hash or number swapped, and five lines break the header's own rule for lines whose label depends on their context.

## 1. Mislabels and added rules

- **453** `AssertionError: no rows loaded` is labelled crash (the top-level assert). Lines 474, 476, 479 and 482 (`AssertionError: ...`) and train's `AssertionError: expected 2 to equal 4` are test-failure. Read alone, they cannot be told apart. The header (lines 35 to 37) left out Python final exception lines for exactly this reason. Fix: remove.
- **147** `called Result::unwrap() on an Err value: ParseIntError ...` and **148** `index out of bounds: the len is 0 but the index is 0` are crash, but provenance says they came from test threads (`cargo-test`). The header's rule at lines 27 to 30 makes them crash. Its rule at lines 35 to 37 left out the Python equivalent (`IndexError: list index out of range` under unittest) because the same text is crash when uncaught and test-failure under a runner. The two rules conflict. Fix: remove both, following the stricter rule.
- **446** `1 !== 2` is labelled none. labels.md says the finding is "the line stating the comparison", and this line states one. It came from an uncaught assert (crash). Alone, it cannot carry a label. Fix: remove.
- **468** `database connection: "pool exhausted"` is labelled crash. It is the program's own `expect()` text and reads like a log line. The header left out the messages a test's own `assert!` or `Err` printed for this reason (lines 66 to 68). Fix: remove. **119** `failed to read settings: Os { ... }` is borderline, but the Rust `Os { code, kind }` debug form marks it as a panic payload, so I kept it.
- **349** `StoreTests/CrashTests.swift:5: Fatal error: Unexpectedly found nil` is labelled crash by the header's rule at lines 31 and 32. labels.md says "A panic in a thread named like a test path is test-failure" and "An assertion that aborts inside a test function is test-failure". A trap at a test file path is the Swift analogue, so the added rule works against labels.md. The line is also a leak (see 3). Fix: remove.
- The rule for UBSan (lines 41 and 42; lines 87 and 88 are labelled error) is defensible but is the labeller's judgement: labels.md puts "a sanitizer abort" under crash and says nothing about reports that do not abort.
- Disagreement with train: train has `error  Error: Cannot find module '@babel/preset-env'`, but test **459** `Error [ERR_MODULE_NOT_FOUND]: Cannot find package 'express' ...` is crash. Both are Node failing to load a module. The test will count a classifier that learned train's label as wrong.

## 2. Inconsistency

- Lines 335 (error) and 372 (warning) are the same Swift diagnostic with a different severity word. That is intended, and it makes a good contrast.
- The context rule is applied unevenly across languages. Python final exception lines under a runner were dropped; Rust panic payloads under a runner were kept as crash (147, 148); Node `AssertionError [ERR_ASSERTION]` lines under a runner are test-failure (232, 235 to 237).

## 3. Leakage

The builders removed every exact, normalised, family and near-match overlap, and I confirmed that none remains by the repo's rules. Real template leaks remain that those rules do not see:

| Test line | Train/dev line | Why the check misses it |
| --- | --- | --- |
| 129 `Running unittests src/lib.rs (target/debug/deps/rsdemo-d72c121ff0da5ac6)` | train `...deps/ingest-4f1c2a9be0d3e71a)` | crate-hash is one word, not a `\b` hex run; Jaccard 0.60 |
| 151, 492 `test result: FAILED. 3 passed; 5 failed; ... finished in 0.00s` | train `test result: FAILED. 41 passed; 2 failed; ... 0.37s` | `0.00s` keeps its fraction in the family; numbers split the word set |
| 132 `test result: ok. 1 passed; 0 failed; ...` | dev `test result: ok. 64 passed; ...` | same |
| 128, 135 ``Finished `test` profile ... in 0.00s`` | dev ``Finished `dev` profile ... in 21.44s`` | one word and a number swapped |
| 178 `ld: symbol(s) not found for architecture arm64` | train `... x86_64` | one word in seven; Jaccard 0.70 |
| 198 `Node.js v26.10.0` | train `Node.js v22.9.0` | `v` prefix blocks `\b\d` |
| 211 `npm error code ENOTCACHED` | train `npm error code ELIFECYCLE` | one word in four |
| 230 `✖ failing tests:` | dev `Failing tests:` | under three words the near check is skipped |
| 243, 244 pip `ERROR: Could not find a version ...` / `No matching distribution found for nothing-here-abc` | train, the same with `torch`, `numpyy` | package swapped |
| 337 `error: the package at '...' cannot be accessed (... doesn't exist in file system)` | train `error: the package manifest at ...` | extensionless paths are kept |
| 342, 349 `<file>:N: Fatal error: Unexpectedly found nil ...` | train `Fatal error: Unexpectedly found nil ...` | only a prefix added; Jaccard 0.77 |
| 356 `◇ Suite ArithmeticTests started.` | train `◇ Suite RetryPolicyTests started.` | name swapped in four words |

Fix: remove all 16. Removing them only strengthens the builders' own choice to leave out common real lines that overlap train.

## 4. Representativeness

- Label mix: none 183 (42%), test-failure 77, error 66, crash 57, warning 53. Every class has at least 53 lines, enough for a per-class recall within about ±11 points (95%).
- **The output is not what wisp meets.** Every line comes from throwaway projects written that day, with the failure messages chosen by the scratch programs. There is no pytest, Go, Java or Gradle, Docker, xcodebuild (`** BUILD FAILED **`), swiftlint or CI output, although labels.md names all of them. The builder also removed every line that overlaps train, including the commonest real ones (`Traceback (most recent call last):`, `Building for debugging...`). The set measures generalisation to less common lines of a few toolchains. It does not measure the mix in real `wisp triage` input.
- Scenario clustering: `swift-test-failures` supplies 20 lines, `cargo-test` 19, `npm-test` 18, `clang-warnings` 16 (lines 386 to 400 are one file's diagnostics), `cargo-build-errors` 15 and `swift-build-errors` 14. The cap of three per family does not stop one run from supplying many lines of the same shape. The effective sample is smaller than 436.
- Ruby is the system Ruby 2.6 and Python is 3.14: the version mix is odd, but both are real.

## 5. Privacy

**Safe to publish.** Paths are `/Users/me/src/demo`, PIDs and addresses are harmless, and no host, user, project name or credential appears. `wisp scan --personal` flags only the placeholders, as the header says. I grepped for me, database, sql, 192.168 and email-like strings and found none.

## 6. Format

Every line is `label<TAB>text` with known labels. There are no tabs in the text, no blank lines, no CRs and no duplicates. The header counts (line 70) match the data. **95 texts start with whitespace, and the indentation is part of their meaning.** The header labels `    tests::first_of_empty` (149) test-failure because it is indented under a failures header. `TrainingSplit.parse` trims leading whitespace, so every loader and the overlap check see the line without its indent (see review-checks.md).

## Most harmful problems

1. 16 template leaks from train and dev that the family and near checks miss (hash-suffixed names, numbers with units, version prefixes, lines under three words, one-word swaps).
2. The rule for context-dependent lines is broken for Rust (147, 148), Python's top-level assert (453) and Node (446), so the test scores labels the text alone cannot support.
3. The set is synthetic in origin: scratch programs on a few toolchains, with none of pytest, Go, Java, Docker, xcodebuild or CI. It is not a sample of what `triage` meets.
