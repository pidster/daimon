# Review: the checks that guard the sets

Files: `harness/Sources/WispCore/Approval/TrainingSplit.swift` (`parse`, `normalised`, `family`, `words`, `clusters`, `overlaps`) and `harness/Tests/WispCoreTests/TrainingSetsTests.swift`. I tested with a Python copy of `family`, `normalised` and `words` (same patterns, same order), run against the three candidate test sets. The copy reproduces the builders' result: no exact, normalised, family or near overlap with train or dev.

**Verdict: usable after fixes.** The four-way check is a sound base, but it misses several leak shapes that occur in this data, merges some lines it should not, and leaves gaps in what the tests cover.

## Leak shapes the checks miss (each with an example from the data)

1. **Redirection and wrapper suffixes.** `2>&1` becomes `<n>>&<n>` and survives in the family, and it adds two words (`2`, `1`) to the word set. `VAR=$(...)`, `git -C <dir>` and an inserted `-q` also change both. Risk examples: `swift build -c release 2>&1` (582) against train `swift build -c release` (Jaccard 0.67); `npm install 2>&1` (1163) against dev `npm install`; 13 lines such as `h=$(git rev-parse HEAD)` (319) and `sha=$(git -C "$dir" rev-parse HEAD 2>/dev/null)` (579) against train and bundled `git rev-parse HEAD`; `git checkout -q main` (184) against `git checkout main` (0.75). Stripping these before comparing finds 52 risk lines.
2. **Lines under three words.** The near check requires three or more words on both sides, so short lines fall through whenever the family differs by a symbol. Examples: `df -h /` (179) and `df -h ~` (551), whose word set equals dev `df -h` (Jaccard 1.0, never checked); failures 230 `✖ failing tests:` against dev `Failing tests:`. Short lines are where 80% is too *strict* in practice: one swapped word in a four-word line gives 0.6 (failures 211 `npm error code ENOTCACHED` against `... ELIFECYCLE`; 356 `◇ Suite ArithmeticTests started.` against `◇ Suite RetryPolicyTests started.`).
3. **Numbers glued to letters.** `\b\d+` needs a word boundary. `0.00s` keeps its fraction (`<n>.00s` against `<n>.37s`), and `v26.10.0`, `p422`, `E0926`, `x86_64` and `arm64` are left alone. Examples: failures 151 and 492 `test result: FAILED. 3 passed; 5 failed; ... finished in 0.00s` against train `... 41 passed; 2 failed; ... 0.37s`; 198 `Node.js v26.10.0` against train `Node.js v22.9.0`; 178 `... architecture arm64` against `... x86_64`.
4. **Identifiers joined to hashes.** `words` keeps `-`, so `rsdemo-d72c121ff0da5ac6` is one word, and `\b[0-9a-f]{7,}\b` does match the hash but leaves the name. Example: failures 129 against train `Running unittests ... ingest-4f1c2a9be0d3e71a` (Jaccard 0.60).
5. **Paths without a file extension, and extensions over six characters.** The file pattern needs a `.ext` of one to six characters, so `/Users/.../database-rs-task-p187-...`, `~/src/a`, `database-ci/kubernetes`, `*.swiftinterface`, `*.mlmodel` and `*.profdata` are kept. Examples: risk 728 `rm -rf /tmp/database-p227f-clone` falls outside the family of train `rm -rf /Users/me`; failures 337 `error: the package at '/Users/me/src/demo/does-not-exist' ...` against train `error: the package manifest at ...`. It also means the 13 `reap.sh <worktree path>` lines in risk are 13 families.
6. **Long lines.** A fixed 80% of the word *set* is too strict for long templated lines: each distinct number or id is a word, so two lines of one llama.cpp or SoftwareUpdate template with different values drop below 0.8. Examples inside the log test: 357 against 363 (`slot create_check ... pos_min = 536 ...` against `... 372 ...`), and the `Error Domain=... Code=7507/7749/7748` lines 58, 63 and 79. Nothing in the data crosses into train this way, because the domains differ, but a real log test drawn from the same services as train would leak.
7. **Paraphrase and reordering.** Word sets ignore order, so flag reordering *is* caught (`ls -la x` against `ls x -la`). Paraphrase ("connection refused after 5 retries" against "gave up connecting after five attempts") is not; I found no paraphrase leak in these sets. Different quoting (`'x'` against `x`) is caught by the near match, because quotes split words, but only at three words or more.
8. **Renames applied after the check.** `risklabels/renames.tsv` rewrites the text (wisp to wisp, database to database) after labelling and after the overlap check. It creates exact duplicates inside the test (815 becomes 296 `brew uninstall wisp 2>&1`; 931 becomes 635 `wisp doctor 2>&1`), and it could create overlaps with train. The check must run on the final text.

## Things the checks merge that they should not (false families)

- Quoted strings collapse to `<s>`, so every `python3 -c '...'`, `sqlite3 db '...'`, `jq '...' f` and `awk '...'` is one family whatever the code. Train itself holds `python3 -c 'print(1 + 1)'` (safe) and two dangerous `python3 -c 'import socket...'` lines in one family, so `split` must deal them to the same part. The family is too coarse for risk, where the quoted code *is* the command.
- Flag digits are numbers: `kill -0 60442` (safe) and `kill -9 1` (dangerous) are both `kill -<n> <n>`.
- `normalised` lowercases, and case matters in flags: `git branch -D x` (dangerous) and `git branch -d x` (moderate) normalise to the same line and would be reported as a `normalised` overlap. The same holds for `rm -R`/`-r` and `ls -lA`/`-la`.
- `Node.js` matches the file pattern and becomes `<f>`.

## Gaps in `TrainingSetsTests`

- **The test part is never compared with the shipped examples.** `theShippedExamplesStayApartFromTheDevSet` checks only dev. Risk test lines 666 and 1032 share the family of bundled `printf 'x\n' > out.txt`, and 17 test lines are bundled commands (`git rev-parse HEAD`, `swift build -c release`, `vm_stat`, `node --version`, `crontab -l`) behind a wrapper. Add bundled against test.
- **`parse` trims leading whitespace** (`trimmingCharacters(in: .whitespaces)`). 95 failures lines and 3 log lines start with spaces, and in failures the indent carries meaning: the header labels `    tests::first_of_empty` (149) test-failure because it is indented under a header. Every loader and the checks see the trimmed text, and two lines that differ only in indentation would count as an exact match. Keep the text as written; trim only the trailing newline.
- **`parse` drops lines without a tab silently** and accepts any label. A line that lost its tab, or a label typo such as `modrate`, passes. The test should fail on non-comment lines without a tab and on labels outside each task's set (read from `labels.md` or a constant).
- **No check inside a part:** duplicates within test, and the cluster sizes within a part, are unchecked. The risk test holds 19 variants of `git rev-parse HEAD` and 13 of `reap.sh`.
- `noTwoPartsOfATaskOverlap` requires only two parts, so a missing or misnamed `test.tsv` passes silently. Once a task's test exists, require it.
- A regex that fails to compile is skipped (`guard let regex = try? ... else { continue }`), which silently weakens every family. Fail instead.
- Near matching is quadratic (`first(where:)` over every pair). That is fine at these sizes; note it before the sets grow.

## Suggested changes (by priority)

1. Compare a *canonical* form as well: strip trailing `2>&1`, `2>/dev/null` and `>/dev/null`, `VAR=$(...)` and `VAR=value` prefixes, `git -C <dir>`, and `-q`. Treat word sets under three words by equality of the set.
2. Replace digit runs anywhere (`\d+` without `\b`, or at least `\d+(?:\.\d+)*[a-z]{0,3}\b` and `v\d`), and replace extensionless path components under `~` or `/`.
3. Compare test with the bundled examples, and run the checks on the final, renamed text.
4. Keep leading whitespace in `parse`, fail on lines without a tab and on unknown labels, and cap cluster size within a part.
5. For risk, stop collapsing quoted code into `<s>` (or collapse only quoted strings that look like data: paths, names, messages), and do not lowercase flags.

## Most harmful problems

1. Wrappers and suffixes (`2>&1`, `VAR=$()`, `-q`, `git -C`) hide 52 risk leaks, 23 of them exact commands from train, dev or bundled.
2. Test is never compared with the shipped `risk-examples.tsv`, and the post-label renames are applied after every check.
3. `parse` trims meaningful indentation and drops malformed lines silently, so the checks and any loader see different data from the file.
