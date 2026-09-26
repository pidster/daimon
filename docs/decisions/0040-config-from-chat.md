# 0040: Change the configuration from chat, by typing, choosing, or completing

Date: 2026-09-26. Status: accepted.

## Context

Trying a trained classifier (ADR 0038) meant editing `~/.wisp/config.json` by hand: knowing the key
(`approval.classifier`), its values, and a second key (`approval.coremlModel`) it depends on, and
getting the JSON right. The operator asked to set such things from within chat, then for an
interactive choice as well as the typed form, and for tab completion.

The configuration is also part of the safety model: `approval.threshold` and `approval.classifier`
decide which commands ask first, and `audit.enabled` whether anything is recorded. Whoever can change
them can weaken the gate.

## Decision

1. **A catalogue of settable settings.** `ConfigSettings` lists the settings worth changing from chat,
   each with a dotted path, a one-line summary, and what it accepts: a fixed choice, a flag, a bounded
   number, a model, a list of models or built-in tools, a Core ML model, or text. The rest of the file
   (command policy, custom tools, backend model tables) is edited by hand and is kept as it is by any
   change.
2. **Every change is checked before it is written.** `ConfigEdit` reads the file as JSON, sets or
   removes one path (an object left empty goes too), and decodes and validates the result exactly as
   start-up does; an unknown setting, a value the setting does not accept, or a file that would not load
   is refused with the reason, and nothing is written. The file is replaced whole, readable by its owner
   only.
3. **Only a person changes it.** `/config set` and `unset` are commands typed at the prompt, and
   `wisp config set` and `unset` the same from a shell. The model has no tool for it, and the MCP server
   does not offer it. Every change is audited as `config.change`, with the setting, the values before and
   after, and whether it came from chat or the command line.
4. **Weakening is said aloud.** Setting the threshold to `never` or `dangerous`, the classifier to
   `rules`, or turning the audit off prints a warning with the change; setting the classifier to
   `coreml` without a model says what else to set.
5. **Changes apply from the next session.** A session reads the configuration once, and its classifier,
   gate, and model are built from it; the confirmation says so. Rebuilding a running session is left
   out: it would change the rules in the middle of a conversation the person has already approved
   commands in.
6. **Choosing and completing use the same catalogue.** A `/config set` without a setting or a value
   offers the settings, or the setting's choices, to pick from; Tab completes commands, settings, and
   values. Both come from `ConfigSettings`, so every face offers the same things.

## Consequences

- New settings join the catalogue with their kind; the checks, the warnings, choosing, and completion
  follow from it.
- A setting outside the catalogue still needs the file edited by hand, which keeps the command policy
  and custom tools out of reach of a quick change.
- `config.change` is a new audit event, and `config` a new entry point for `wisp config set` and `unset`.
