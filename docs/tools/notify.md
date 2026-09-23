# notify

Shows the user a macOS notification: a title and a message, the way a long-running task says it has
finished or that it needs you. The same notifier backs `wisp notify` on the command line
([wisp.md](../wisp.md)). Decided in [ADR 0030](../decisions/0030-notifications.md).

## Arguments

| Name | Type | Required | Meaning |
| --- | --- | --- | --- |
| `title` | string | yes | A few words; cut to 64 characters. |
| `message` | string | yes | One or two sentences; cut to 256 characters. |

## Result

`notification shown`, or `error: notification not shown: <reason>` when notifications are off, the
message is empty, the per-minute limit is reached, or macOS refused it. The model is told the reason
and can say so.

## Limits and controls

| Control | Value |
| --- | --- |
| Text | Control characters become spaces; title and subtitle 64 characters, message 256, with an ellipsis when cut |
| Rate | At most `notifications.perMinute` (default 5) in any minute, across every conversation of the process |
| Off switch | `notifications.enabled: false` in `config.json`; every request is then refused |
| Approval | None: a banner changes nothing on the Mac. Leave the tool out of a conversation with `--tool` or `tools` if it should not notify |
| Audit | Every request, posted or refused, is a `notification` event with the title, body, source (`model`, `user`, or `watch` for `wisp watch`), and outcome ([logging.md](../logging.md)) |

## How it is posted

Apple's notification framework needs an app bundle and aborts in a command-line binary (probed on this
Mac, 2026-09-23), so wisp runs `/usr/bin/osascript` with `display notification`. The script is fixed;
the title, subtitle, and message are passed as arguments and read from `argv`, so nothing the model
writes is ever parsed as AppleScript. macOS shows the banner as coming from Script Editor, and the
first one may ask you to allow notifications for it.

If notifications collect in Notification Center without popping up, Script Editor's alert style is set
to deliver quietly, or a Focus mode is on: in System Settings, Notifications, Script Editor, choose
Banners or Alerts. Seen on this Mac on 2026-09-23: both test notifications arrived in the stack and
neither showed a banner.

A helper app posting through Apple's `UserNotifications`, so banners come from Wisp itself, is planned
for when wisp can be signed ([backlog.md](../backlog.md), "When wisp can be signed").

## Implementation

`Notifier` in `harness/Sources/WispCore/Support/Notifier.swift`, one per session so the rate limit covers
every conversation, tested in `NotifierTests` with an injected runner and clock; `NotifyTool` is the
model-facing wrapper.
