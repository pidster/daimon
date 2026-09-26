# Review: log-severity test set (`testsets/log-severity-test.tsv`)

Reviewed 2026-09-26 against `training/log-severity/labels.md` (the top block, which overrides the draft notes), `training/README.md`, and the set's header (lines 1 to 52). Line numbers are lines of the file. Fixes are in `fixes-log-severity.tsv` (7 rows: 2 relabel, 5 optional privacy removals).

**Verdict: usable after fixes, for error, warning and info only.** The labels mostly follow the header's rules, and I found no leakage. **It cannot measure fault**: the class has one line. It also measures a very different distribution from the one the classifier was trained on.

## 1. Mislabels and added rules

- The header rule (lines 33 to 35) says: '"Failed to ..." / "Unable to ..." / "Could not ..." for a named operation, with nothing saying it carries on, is error'. Two lines break it:
  - **126** `opendirectoryd: [session] unable to find session module 'keychain'` is labelled warning. Under the rule it is error, like 55 `Failed to get bridge device` and 115 `Unable to initialize unified logger`. Fix: relabel to error.
  - **130** `Installer Progress: Unable to quit because there are connected processes` is labelled warning. Under the rule it is error, like 75 and 77 (`Unable to get ...`). Fix: relabel to error.
- The rule itself is taste. It makes harmless noise into errors: 55 on a Mac without a bridge chip, 94 "Failed to load specified background image", 95 "Could not load resource readme", and the airportd lines 112 to 114, which the header admits repeat hundreds of times a day. 114 `Usb Host Notification Error Apple80211Set: Device power is off` reports Wi-Fi being off, which is expected. labels.md defines error as "an operation failed and was not recovered", which fits these lines only loosely. A classifier that calls them warning will be marked wrong for a defensible judgement. Consider whether the test should hold these lines at all.
- Written levels are overridden on purpose: 152 and 153 (`level=INFO`) are labelled warning, and 120 "Package Authoring Error ... will be skipped" is warning. README and labels.md allow this. The test therefore rewards a model for ignoring a written level in exactly the cases the labeller disagreed with. That is fine to measure, but report it apart from the rest.
- 104 `./postflight: KeyError: 'install'` and 423 `./postflight: Traceback (most recent call last):` are labelled error. labels.md's top block says "lines where a process died are fault", and here the postflight script died. The header argues that the installer carried on; train labels `Traceback (most recent call last):` as error. The labels agree with train, so there is no fix, but they sit on the fault/error line that the set cannot test anyway.
- The rest agree with labels.md: the XPC interrupted and invalidated rules (117, 121 to 123 and 133 warning; 67, 70, 80 and 92 error; 174 info), the authorisation refusals as warning (125, 127 to 129, 140), `Scan completed with error: nil` as info (169), `fault[0] crash[0]` as info (306), and Ollama 404 as info (401).

## 2. Inconsistency

- The same message shape gets different labels: 126 and 130 (warning) against 55, 75, 77 and 115 (error); fixed above.
- 86, 87, 91, 101 and 108 (softwareupdated scans failing offline) are error, while 134 `Last scan failed, should re-scan` is warning. Scans are periodic and will run again. By labels.md's retry rule ("A retry that will be attempted again is a warning") the offline scans are closer to warning. The header's rule decides them because nothing in the line says the scan will retry. This is taste; I left the labels alone.

## 3. Leakage

None. I found no exact, normalised, family or near-match overlap with train or dev. Nothing matched at Jaccard 0.6 either, or in a looser, order-insensitive family that also replaces extensionless paths, variables and every digit run. That is no surprise: train and dev are synthetic web-service logs, and this set is macOS system logs.

## 4. Representativeness

- Label mix: info 283 (73%), error 63, warning 43, **fault 1**. With one fault line, fault recall is 0% or 100%: a hit bounds the miss rate only at 95%. Fault needs dozens of lines from somewhere else (crash reports, `ReportCrash`, launchd "exited due to SIGKILL", jetsam) before the set can say anything about it.
- Sources: install.log 241 lines (62%), Ollama 84, airportd 53, system.log 11. By component: softwareupdate 111 lines (33 of the 63 errors), installer 75, Ollama and llama.cpp 84 (no errors), airportd 53, and opendirectoryd 43, of which 31 come from one migration minute (`May 9 12:59`) and 13 from one boot (`Dec 10 12:08:02 localhost`). The error class is mostly SoftwareUpdate's `Error Domain=...Code=...` lines.
- It is not what `condense_log` meets. The classifier sees lines without a `log show` level, which usually means application, server, container and CI logs. This set has none of the developer's own logs, although the risk set shows that `/tmp/database-logs/automata.log` and `ui.log` exist on this Mac. Nor does it have launchd, crash reports or docker. It tests transfer to macOS installer logs.
- Train is synthetic web-service logs, so the gap between train and test is large. A low score here would mix domain shift with classifier quality. Report the number with that caveat.

## 5. Privacy

**Safe to publish, with owner consent on a few low-risk traces.** Host names, user name, addresses and machine UUIDs are replaced, as the header says, and I found no credential. What remains:

- Location and travel: timezone offsets (25 lines at `-07`, 120 at `+01`, 42 at `+00`, 2 at `+02`) show where the owner was on which dates, and 176 names the British keyboard layout.
- A fingerprint of the machine and its software: Apple M4 Max with 48 GB (366, 374, 417), and installed apps (Zoom, Slack, 1Password, VirtualBox, Keynote, Pages Creator Studio, Xcode).
- Behavioural traces: Messages.app video-encoder lines with times (433 to 437) and login tty sessions (429, 430). The fix list offers 433 to 437 as optional removals; they add nothing the other info lines lack.

## 6. Format

Every line is `label<TAB>text` with known labels. There are no tabs in the text, no blank lines, no CRs and no duplicates, and the counts match the header. Lines 426 to 428 are syslog continuation lines that start with four spaces. `TrainingSplit.parse` trims that indentation, so the loader sees different text from the file. Seven lines are longer than 600 characters, the longest 1,426 (line 79).

## Most harmful problems

1. One fault line: the class the log digest most needs to get right is untested.
2. The distribution is far from both train (synthetic web logs) and real `condense_log` input (application and server logs). Half the error class is one daemon's `Error Domain` lines.
3. The added "Failed/Unable is error" rule turns routine macOS noise into errors, and the set breaks it itself (126, 130), so part of the score measures the labeller's taste.
