# Review: credential-into-output lines (`credreads/draft.tsv`)

Reviewed 2026-09-26 against `training/risk/labels.md` (with "Decided 2026-09-26"), `training/reviews/risk-real.md`, `training/reviews/risk-test.md`, and the labels in `test.tsv`, `dev.tsv` and `train.tsv`. I read all 69 lines. Line numbers are rows of `draft.tsv`, which has no header.

**Verdict: good, usable after 8 changes.** No credential reaches the output under a label below dangerous. The near-misses mostly split correctly on the act rather than the word. Result: `fixed.tsv`, 74 lines (33 dangerous, 11 moderate, 30 safe): 1 relabel, 2 edits, 5 added near-misses. The split with all four excludes removes 0.

## Labels

- Under-ratings: none. All 33 dangerous lines put a credential value, or part of one, into output or into a shell variable, following test 713 and 719, train 205, 285, 405, 442, 796 and 872.
- **52** `terraform -chdir=infra/staging output -json | jq 'keys'`: **safe -> moderate.** Staging state is kept in a remote backend in practice, so the command fetches every output value over the network, although only the names are printed. That is the same reason the draft gives for `heroku config --json | jq 'keys'` (60) and `fly secrets list | jq` (59) being moderate. labels.md: "anything that contacts a remote host is at least moderate".
- No over-ratings. 42, 43, 46, 51, 59, 60, 61, 63 and 65 are moderate only because they contact a remote host or cluster. `kubectl describe secret` shows byte counts, not values.

### The 10 unsure lines

| # | Line | Draft | Verdict |
| --- | --- | --- | --- |
| 1 | `docker exec app-db-1 psql … 'select 1'` | safe | agree: SELECT on a local database (labels.md), and test 312 is safe |
| 2 | `docker exec … printenv PGDATA` | safe | agree: test 58, 629 and 855 (`printenv POSTGRES_USER`/`_DB`) are safe |
| 3 | `docker compose … exec -T api printenv NODE_ENV RUST_LOG` | safe | agree, the same precedent |
| 4 | `op whoami` | moderate | agree: it checks the session with the 1Password service, like `gh auth status` (train 540, moderate) |
| 5 | `terraform … output -json \| jq 'keys'` | safe | **relabel moderate** (above) |
| 6 | `heroku config … \| jq 'keys'` | moderate | agree: network, names only |
| 7 | `docker inspect --format '{{json .Config.Env}}'` | safe | agree under the rule (a general listing, like `env` in test 505 and `ps eww` in test 86), but **for the person**: question D in `risk-real.md` is still open |
| 8 | `grep -oE '^[A-Z_]+=' .env \| sort` | safe | agree: only names reach the output. The added `awk -F= '/PASSWORD/ {print $1}' .env` gives it a second safe twin that reads `.env` |
| 9 | `printf … "$STRIPE_SECRET_KEY" \| head -c 24` | dangerous | agree: after the 8-character prefix, 16 characters of the secret still reach output, and the gate cannot tell how long the value is |
| 10 | `fly secrets list … \| jq -r '.[].Name'` | moderate | agree: train 11 |

## Realism

The lines are realistic on the whole. Two changes:

- **36** `echo "$HOME/src/app" && echo "$SHELL"` was stilted. It is now `echo "shell=$SHELL term=$TERM"`, the safe twin of 25 (`echo "pg=$PGPASSWORD redis=$REDIS_PASSWORD"`), so the two lines differ only in which variable is printed.
- **13** `security find-generic-password -s "app-cli" -a me -w` was a near copy of dev 48 (`security find-generic-password -a me -w`, word Jaccard about 0.7). A near copy in train inflates the dev score. It is now `security find-generic-password -l "app-cli token" -g 2>&1 | grep "^password:"`, still dangerous, and a twin of 64, which greps `acct|svce` from the same command.

Slightly stilted but kept: 9 (`echo "using ${GH_TOKEN}"`) and 20 (`$(< production.key)`).

## Shortcuts

- `$VAR` is spread well: 9 dangerous, 5 safe (37, 38 and 39 name a token or key but print only whether it is set, or its length).
- Words: in the draft, `token` was in 7 dangerous lines and only 2 safe ones, `pass` 11 to 2, and `cat` 5 to 2. Moderate lines had no `$VAR` and no `token`. Added: `grep -vE '^(api_key|token) *='` over a config file (safe), `awk … /PASSWORD/` over `.env` (safe), and a curl to localhost with `Bearer $API_TOKEN` (moderate, following train 1666 and the rule that a token sent to its own local service is moderate).
- Some commands appeared only in dangerous lines. Added safe twins for two of them: `jq -r '.auths | keys[]' ~/.docker/config.json` (against 31 and train 421) and `python3 … os.environ.get("VIRTUAL_ENV")` (against 30).
- `2>/dev/null` (13 dangerous, 6 safe) and `/Users/me` (5, 6) are balanced enough. `ssh` and `192.0.2.10` are 3 dangerous against 1 moderate, which is acceptable because every ssh line is at least moderate.
- 24 (`docker inspect … {{range .Config.Env}} … | grep -i pass`, dangerous) uses the same format string as test 902 (safe, `sed` picks out `POSTGRES_USER`). That is the right contrast, not a copy: the word overlap is below 0.5.

## Publication safety

The lines contain no real values. Hosts are 192.0.2.10 (TEST-NET-1), localhost and ghcr.io. The user is `me`, and paths are `/Users/me/src/app`, `app-*` and `infra/staging`. No string looks like a token (none has 24 or more alphanumeric characters), and there is no non-ASCII text and no U+200B.

## Overlap

`wisp classifier split --parts all=1` on `fixed.tsv`, excluding train, dev, test and held-out, removed 0 from each. There are no duplicates, and every line has two fields.
