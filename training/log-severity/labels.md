# Labels and rules for the log-severity set

The header the set was drafted with, then adjusted after review (see ../README.md and ../reviews/log-severity.md).

```
Labels match LogDigest's severities: fault (the process or a component died), error, warning, info.
LogDigest reads a declared level only from log show's type column; every other line reaches the
classifier as it is, so lines here carry written levels (ERROR, [warn], level=info, glog's E0926)
as often as not, and a written level can be wrong about the line (tricky cases near the end).
debug is folded into info, since LogDigest has no debug level; lines where a process died are fault.
Drafting notes follow; where they mention debug or fold fault into error, the lines above supersede them.
Labelled log lines for a severity classifier: one per line, `label<TAB>line`. Lines starting with `#`
are comments. Every line is a log line that carries NO declared level: no INFO/WARN/ERROR/DEBUG/TRACE/
FATAL tokens used as a level, no level=/"level":/severity= fields, no <N> syslog priorities, no
`log show` type columns, no [warn]-style tags. Those are read by LogDigest's declared-level parsing;
this classifier handles the rest. Words such as "error" or "failed" inside a message are allowed.

Labels:
error   - an operation failed and was not recovered: HTTP 5xx in access logs, unhandled exceptions and
          stack-trace heads, crashes, panics, fatal signals (LogDigest's `fault` severity folds into
          `error` here), connections refused or lost after retries are exhausted, data corruption,
          failed jobs, failed deploys, a failed health check that takes a service out, disk full, OOM
          kills, an auth backend down.
warning - degraded but continuing: a retry (attempt 2 of 5), a timeout that will be retried, slow
          queries or requests over a threshold, deprecation notices, 429 rate limiting, 401 and 403 in
          access logs (possible misuse), high disk/memory/pool usage, certificates expiring soon, config
          falling back to defaults, clock skew, replication lag, a circuit breaker opening.
info    - normal lifecycle and business events: start, stop, listening, 2xx and 3xx access lines,
          404 and other ordinary 4xx (400, 405, 409, 410, 422) access lines, health check OK, jobs
          completed, migrations applied, audit lines (user signed in, role granted), CI steps that
          start or finish successfully, scheduled tasks run, cache warmed.
debug   - internal detail meant for developers: SQL echo with bind parameters, cache hit/miss per key,
          header dumps, function entry/exit, variable or state dumps, config resolution traces,
          per-tick timers, lock acquire/release, byte counts per chunk, retry-policy arithmetic with no
          failure implied, gRPC/HTTP2 frame traces.

Judgement rules:
- Access logs are judged by status: 5xx error; 401, 403, 429 warning; 404 and other 4xx info (clients
  asking for missing or malformed things is ordinary traffic); 1xx/2xx/3xx info.
- A retry that will be attempted again is a warning even when the line says "failed"; the final
  attempt giving up is an error.
- A failed health probe the orchestrator will retry is a warning; the one that kills or removes the
  container or instance is an error. A passing probe is info.
- "0 errors", "error rate 0.0%", "no errors found", "0 failed" are info.
- A failed login in an audit trail is a warning (possible misuse, the system is fine); an account
  lockout after repeated failures is also a warning; a successful sign-in is info.
- Graceful shutdown on SIGTERM is info; an exit by signal (SIGSEGV, SIGABRT, SIGKILL) is an error.
- A deprecation notice is a warning even when phrased neutrally.
- Lines that mention an exception or error only as a name in a trace of normal behaviour (a handler
  registered, an error counter read as zero, an error page served from cache) are debug or info.
- A stack-trace head (the exception line) is error; this set holds no bare frame lines.
- Kubernetes events: Scheduled/Pulled/Created/Started are info; BackOff and Unhealthy are warning;
  OOMKilled, FailedMount after timeout, and Evicted are error.
All hosts, addresses, names and ids are synthetic (example.com/.internal, 192.0.2.0/24,
198.51.100.0/24, 203.0.113.0/24).

error

warning

info

debug
```
