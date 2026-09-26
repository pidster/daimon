# Review: log-severity.tsv

**Verdict: usable after fixes.** The labels are mostly right against the file's own rules, the format is
clean, and there is no leakage. The serious problems are not individual labels but the set's premise and
integration: the header's claim about LogDigest is false, the label space does not match LogDigest's, and
a handful of shortcut features (timestamps, recurring ids, the word "error") correlate with labels.

Line numbers are file line numbers (`cat -n`). 451 labelled lines: error 111, warning 103, info 130,
debug 107. Fixes: `fixes-log-severity.tsv` (8 relabel, 5 remove, 15 edit, 44 add).

## 0. The premise and integration (most important)

- **The header's claim that declared levels are "read by LogDigest's declared-level parsing" (lines 3-5)
  is false.** `harness/Sources/WispCore/Condense/LogDigest.swift` `declaredColumns` recognises only
  `log show`'s default-style type column and compact-style type code. `INFO`/`WARN`/`[error]`/`level=`/
  `"level":`/syslog `<N>` are not parsed at all; such lines go to the word regexes (`severityPatterns`).
  So either LogDigest must gain generic declared-level parsing before this classifier ships, or the
  classifier will be fed level-carrying lines it has never seen. Decide which, and state it in the header.
- **Many lines are real formats with their level surgically removed**, producing text no tool emits:
  nginx error log (52-54, 165-167: real lines always carry `[error] pid#tid: *cid`), Apache (55, 56, 168,
  169: `[proxy:pid 2211]` is an invented token; real is `[proxy:error] [pid 2211:tid N]`), MySQL (111, 112,
  219, 220: real lines have `[ERROR]`/`[Warning]`/`[System]` before `[MY-...]`), MongoDB JSON (113, 221,
  332: real lines always have `"s":"E"/"W"/"I"`), Kafka log4j (114, 222, 223, 333, 334), Elasticsearch
  (115, 224, 225, 335: real `[WARN ][o.e...]`), GitHub Actions (117: real `##[error]Process completed...`),
  Kubernetes events (125-127, 203-205, 349-352: `kubectl get events` always prints a TYPE column,
  Normal/Warning, and never the double-space `Reason  pod/x  message` layout used here), Caddy JSON (277:
  always `"level":"info"`). If LogDigest is extended to read declared levels, these ~30 lines describe
  input the classifier will never receive; if it is not, the realistic line keeps its level. Either way
  they are dead weight or distribution-shifted. Only the Apache tokens are outright wrong; edits proposed.
- **Label space mismatch.** `LogDigest.Severity` is fault/error/warning/info. This set has no fault
  (the header folds it into error, line 11) and adds debug, which LogDigest has no bucket for. Folding
  fault into error means a classifier can never produce LogDigest's top rank; crash/panic lines (76-84,
  97-104, 148, 149) would drop from fault to error unless the word rule is kept in front of the
  classifier. Debug must map to info in LogDigest; say so.
- **LogDigest classifies the template, not the raw line** (`Self.severity(of: parsed.template)`, line 223
  of LogDigest.swift): leading ISO/syslog timestamps are stripped and every number becomes `<n>`. An access
  line's status code becomes `<n>`, so the whole access-log rule (lines 29-30) cannot be applied to what
  the classifier would be given. Either classify the raw line or train on templates; the set trains on raw
  lines.

## 1. Mislabels

| Line | Label | Problem | Fix |
| --- | --- | --- | --- |
| 98 | error | launchd "Pushing respawn out by 10 seconds": a throttled respawn is a retry by the file's own rule (line 32-33) | warning |
| 209 | warning | systemd "Watchdog timeout" is followed by SIGABRT of the service; the service dies | error |
| 216 | warning | PostgreSQL "out of shared memory" is an ERROR that aborts the transaction; "(query will be retried)" is invented to fit the retry rule | edit to real text, error |
| 223 | warning | a consumer-group rebalance is routine; its completion (334) is info | info |
| 227 | warning | "Cache not found" is ordinary first-run CI behaviour; the restore (492) is debug | info |
| 132 | error | a declined card is a business outcome; the system is fine | warning (a rule for business outcomes is missing) |
| 118 | error | Actions prints "The operation was canceled." for manual cancels too | remove (ambiguous) |
| 73 | error | Node source-snippet/frame line; the header (line 40) promises no bare frame lines | remove |
| 488 | debug | bare ` ---> 4f1c2e9a0b3d` layer id; no label defensible | remove |

Arguable but left: 91 (NVMe timeout with abort; the kernel resets and retries, could be warning), 107
(PostgreSQL "interrupted while in recovery", logged at LOG with a corruption HINT), 443 (JVM
`-Xlog:gc` prints GC pauses at info level; debug is defensible only because 225/255 set a threshold).

## 2. Inconsistency and rules

- Docker/BuildKit build progress is info at 372-375 but debug at 487-490. Relabelled 487, 489, 490 info.
- Cache: 227 miss warning, 492 restore debug. Relabelled 227 info.
- Security-relevant audit: 250 (bucket made public) warning vs 361 (role granted) info. Defensible, but
  the header lists only "role granted" as an audit example; add a rule that access widening is warning.
- Retry vocabulary is split by label: "retry/retrying" appears in 7 warning lines and 0 error lines; the
  give-up errors (130, 131, 133) all say "attempts". The classifier will learn "retry" means warning.
  Adds cover exhausted retries.
- Rule challenge, 401 as warning (line 29): in API access logs 401 is the routine auth challenge (expired
  tokens, refresh flows) and is often the most common non-2xx; labelling every 401 warning will flood a
  digest. Consider 401 info and only a burst or repeated failed login warning.
- Rule challenge, fault folded into error (line 11): see section 0.
- Missing rule: business outcomes (declined card, validation rejected, out of stock) versus system
  failures.

## 3. Near-duplicates and templated families

No exact duplicates (checked by script). Families are small and varied; none needs cutting:
- Access logs (47-51, 160-164, 265-277): lines 47/265 and 48/266 share IP, timestamp, UA and referer with
  only path and status differing. These are good contrastive pairs; keep all.
- Retry warnings (170-173, 222, 232, 233, 237): 8, keep.
- SQL echo debug (397-404, 485, 501-503): 12 across different ORMs, keep.
- Deprecations (179-182, 226): 5, keep.

## 4. Leakage

There is no named eval set for log severity. The only log fixtures in the repository are in
`harness/Tests/WispCoreTests/LogCondenserTests.swift` (lines 9-45: `log show` lines, a nine-line
`info:/error:/warning:/panic:` log, a crash report). None matches or trivially varies a training line.
No leaks.

## 5. Realism and shortcut features

- **Timestamp shortcut (serious).** Only 1 of 107 debug lines carries a date or syslog prefix (`2026`:
  error 22, warning 19, info 30, debug 1; `Sep 26`: 12/7/9/0). A classifier can learn "timestamped, so not
  debug". Adds give four timestamped debug lines; more are needed.
- **Recurring-id shortcut.** `4412` appears in 11 of 15 lines in debug, `212` in 8 of 10, `SKU-2231` in 5
  of 6, `->` in 12 of 13. Edits vary seven of them; regenerate the rest with diverse ids.
- **"error" word shortcut.** Lowercase "error" appears in 15 error lines, 6 info (hard negatives, good),
  and 0 warning lines. Adds give warnings containing "error".
- Invented text: 150 ("the monkey threw a ClassCastException"; removed), 177 (Rails never appends
  "exceeds slow request threshold"; removed, 178 covers the case), 216 (above), 130 ("level-3 cache
  node": a contrived use of the word level in a level-free set; edited).
- 315: `SHA256:k9ExampleFingerprintAbc123` is not a 43-character base64 fingerprint and carries an
  "Example" tell; edited to a hash of a fixed string.
- 493 (`set-output name=version::1.14.2`) is a workflow command, not a log line (real form
  `::set-output ...`); harmless.

## 6. Safety of the data

Clean. Emails are `@example.com`, public IPs are documentation ranges, hosts are `.example.com`/
`.internal`, names are initial-plus-surname or first names. Minor: 366's tracking number
`00340434161094012345` is close to DHL's published sample number; edited to an obviously synthetic id.
The header (43-44) says all addresses are documentation ranges, but private ranges are used (52, 63, 164,
202, 330, 441, 453-455); they are safe, the header is just inexact.

## 7. Balance and coverage gaps

Balance is good (103-130 per label). Gaps, filled by adds where a line suffices:
- macOS, which is wisp's platform: sandbox denials (`Sandbox: bash(N) deny(1) ...`), launchd abnormal
  exits, app low-disk warnings. Sandbox denials matter most to wisp and are absent.
- Access-log formats beyond CLF/nginx/Rails/Django: AWS ALB, HAProxy, Envoy (`503 UH`), IIS W3C.
- Hard negatives for LogDigest's fault words in info/debug: critical section, crash reporter enabled,
  `panic_on_oom=false`.
- Hard negatives for "failed"/"Error" in names: a job named retry-failed-payments, a passing
  ErrorHandlingTests suite.
- Exhausted retries as error (see section 2); systemd restart lifecycle (scheduled restart warning, "Start
  request repeated too quickly" error, Stopped info); Elasticsearch GREEN to YELLOW (only RED and GREEN
  are present); lint summaries with errors versus warnings only; `npm audit` summaries; terraform success
  and partial failure; git `fatal:` in CI.
- Not added, but missing: multi-line continuation lines (LogDigest gives them the previous line's
  severity, so they may never reach the classifier; say so), Windows/.NET event text, and lines with
  levels (see section 0).

## 8. Format

All 451 data lines are `label<TAB>text` with exactly one tab, no empty text, only the four labels.
The declared-level promise was checked by script (`INFO|WARN|WARNING|ERROR|DEBUG|TRACE|FATAL|CRITICAL|
NOTICE`, `level=`, `"level"`, `severity=`, `<N>`, `[warn]`-style tags, glog `I0926` prefixes): no
violations. The only hits for a leading `Error:` (74, 118) are JavaScript exception names, not levels.
One add uses git's `fatal:` prefix, which is git's own message class; drop it if the rule is read strictly.

## Most harmful problems

1. The header's premise is false: LogDigest parses no generic declared levels, so the set trains on
   level-stripped versions of formats (nginx, Apache, MySQL, MongoDB, Kafka, Elasticsearch, Kubernetes
   events) that always carry a level, and the classifier's real input will differ.
2. Integration mismatch: LogDigest classifies templates in which the status code and every number are
   `<n>`, and its severity space is fault/error/warning/info with no debug; the access-log rules and the
   debug label cannot work as written.
3. Shortcut features: timestamps almost never appear on debug lines, the ids 4412/212/SKU-2231 and `->`
   cluster in debug, and "error" never appears in a warning line.
