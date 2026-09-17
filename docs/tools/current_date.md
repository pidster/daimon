# current_date

Returns the current local date and time. The on-device model has no clock and will guess otherwise.

## Arguments

| Name | Type | Required | Meaning |
| --- | --- | --- | --- |
| `timeZone` | string | no | IANA identifier such as `Europe/London`. Default: the process's local zone. An unknown identifier falls back to the local zone. |

## Result

One line: an ISO 8601 timestamp with offset, then the zone identifier.

```
2026-09-17T13:41:02+01:00 (Europe/London)
```

## Limits

None needed; the result is a single line.

## Implementation

`harness/Sources/DaimonCore/Tools/CurrentDateTool.swift`. Formatting is a pure static function, tested in
`CurrentDateToolTests`.
