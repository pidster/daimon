# ADR 0031: Secret scanning and redaction: rules first, the model only over what they leave

Date: 2026-09-23. Status: accepted. Builds on [ADR 0023](0023-condensing-tools.md).

## Context

The use case only an on-device agent serves is handling text that must not reach a remote model:
checking a staged diff for a credential before it is committed, and cleaning a log, crash report, or data
file before it is pasted into an issue or handed to a cloud agent. A cloud model cannot do either
without first receiving the very thing it is meant to protect.

Two approaches were open. A model-only pass reads everything and names what is sensitive; a small model
misses things, invents things, and, if it rewrote the text, could alter it. Rules alone are fast,
deterministic, and exact for shapes that are credentials by construction, but cannot recognise a person's
name or a customer number. `summarise_diff` already carried three credential patterns, and its flag
note quoted the first 60 characters of the added line, which sent the credential to the caller.

## Decision

- **`SecretScanner` holds the rules, in `WispCore/Condense`**: provider key prefixes (AWS, GitHub,
  GitLab, Slack, Stripe, Anthropic, OpenAI, Google), private key blocks, JWTs, a password in a URL,
  secret-named assignments and `.env` lines with a non-placeholder value (in the `secret` category); and
  emails, `+`-prefixed phone numbers, Luhn-valid card numbers, public IPv4 addresses, street addresses
  in the common "number, name, Street/Lane/Road" form, private hostnames (`.internal`, `.corp`, `.lan`,
  `.local`), and the user name in `/Users/<name>/` (in the `personal` category). Overlaps resolve to the
  match that starts first, then the longest. Generic high-entropy detection is left out: lockfiles and
  build output are full of hashes, and a scan that cries wolf is switched off.
- **A match never leaves whole.** A finding carries a masked preview (`ghp_…(40 chars)`); a redaction
  replaces the value with a numbered marker (`[REDACTED:email#1]`, the same value the same number), so a
  reader can still see that two places hold one value. `summarise_diff`'s `secret` flag now uses the
  scanner and the mask.
- **The model pass is opt-in (`thorough`) and runs over the rule-redacted text**, so a credential the
  rules caught never reaches a prompt or the audit log's `prompt` events. Each 4 KiB chunk gets a fresh
  tool-less turn with a schema asking for values and kinds; only values that occur exactly in the chunk
  are kept, and replacing them is the `Redactor`'s job, never the model's, so the model cannot alter or
  invent text. The small model names a couple of values per answer, so a chunk is asked again with what
  it found hidden, up to three turns, stopping at the first answer that adds nothing.
- **A diff is scanned by its added lines**, located as `path:line` in the new file, so a credential the
  change removes is not reported and a pre-commit check reads `git diff --cached | wisp scan`.
- **Faces**: the MCP tools `scan_secrets` and `redact` capture through the conversation's runner and
  gate like `triage`, on conversations `scan-<id>` and `redact-<id>`; the CLI commands `wisp scan`
  (exit 1 when anything is found) and `wisp redact` (stdout, a summary on stderr) read files or
  standard input. The scan defaults to secrets only, since a diff is full of email addresses; the
  redaction defaults to both categories.
- **Audit**: `secrets.scan` records the source, size, and the kinds found with their counts;
  `redaction` records the counts replaced. Neither carries a value or a preview. A command's own output
  is still in its `command.outcome` event, as for every command wisp runs: the audit log is local and
  verbatim by design ([ADR 0010](0010-audit-and-diagnostic-logging.md)).

## Consequences

- Rules-only scans and redactions are instant and deterministic, and are the defaults.
- Measured on 2026-09-23 with the system model (`RedactionEvalTests`, `scripts/check eval`): the
  thorough redaction replaced every expected value in a ticket, a service log, and a meeting note
  (names, an account number, a user id, an address, a private hostname) and left build output and a
  stack trace intact, 5 of 5 fixtures on four runs. Before the repeated turns and the address and
  hostname rules it scored 3 of 5: the model found the values but named only one or two per answer. The
  eval's judge runs under wisp's own system prompt, as callers' passes do; with a one-line instruction
  instead the same model scored lower, so the measurement is of the product, not of the model alone.
- A thorough pass costs up to three turns per 4 KiB, about 2 s each on this Mac.
- The rules are English- and Western-format-leaning (addresses, `+` phone numbers); the model pass is
  the fallback for other forms, and neither is a guarantee. Documented as a best effort in `docs/mcp.md`
  and `docs/wisp.md`.
- Tests without the model: every rule and its rejections, diff location, masking, overlap resolution,
  numbering, the sweep's validation and repeated turns with a scripted judge, the MCP arguments, and both
  tools over the wire with a check that no result or non-command audit event carries the credential.
