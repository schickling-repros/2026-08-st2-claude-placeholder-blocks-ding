# st2 — a DING is never transported when Claude's composer shows a context-derived placeholder

`st2 ding` classifies the target's live composer before it pastes. Claude Code renders a dim,
context-derived suggestion into an otherwise-unused composer, and that suggestion does not match the
`Try "<example>"` grammar `is_claude_idle_placeholder` recognizes. The adapter therefore reads the
placeholder as a human draft, `classify_composer` returns `Changed`, `observed_poke_with_window`
returns `Deferred` before any paste, and `flush_pending` breaks. Nothing is staged, nothing is
logged, and the notice is retried on the same code path every `DELIVERY_RETRY_BACKOFF` for as long
as the placeholder is on screen.

The observable result is a seat holding unread mail while its sidecar, its pty session and its
provider are all healthy, and while its sidecar log contains only its two lifetime lines.

## Reproduction

```sh
nix run github:schickling-repros/2026-08-st2-claude-placeholder-blocks-ding
```

Takes about a minute. Everything runs against a private `PTY_ROOT`, a private bus root and a private
`XDG_STATE_HOME` under `$TMPDIR`, and is removed on exit.

## What it runs

A synthetic provider fixture renders one Claude-shaped pane: a `❯` composer row between two
full-width rules, with the `⏵⏵ … permissions on` footer below it. The pane is never in an active
turn and never shows a modal. **Only the composer row differs between cases.** One uniquely nonced
message is sent to a sidecar that started against an empty inbox, and a `pty` shim on `PATH` records
every `send` and `peek` the sidecar makes.

| case | composer row | expected |
| --- | --- | --- |
| `suggestion` | `❯ <dim>refactor the parser to use a lookup table` | RED — never transported |
| control (same run) | `❯ ` — emptied in place via `SIGUSR1` | GREEN — transported once |
| `try-placeholder` | `❯ <dim>Try "add a test for the parser"` | GREEN — transported once |

The in-run control is the isolating one: same sidecar, same pty session, same still-unread message,
same 15-second retry loop. Only the composer row changes, and the notice that had not moved for two
retry cycles is transported within one.

The `try-placeholder` case is there to separate two readings. Refusing to type into a composer that
holds a human draft is deliberate and correct. That case shows the adapter already intends to treat
a placeholder as an empty composer — it just does not recognize this variant of one.

## Expected

A notice queued for a healthy, idle Claude pane is eventually transported, or the sidecar records
why it was not.

## Actual

```
BASELINE_COMPOSER_OBSERVATIONS=3
BASELINE_NOTICE_TRANSPORTS=0
BASELINE_MESSAGE_STILL_UNREAD=yes
BASELINE_SIDECAR_LOG_LINES=2
BASELINE_SIDECAR_ALIVE=yes
BASELINE_TARGET_ALIVE=yes
BASELINE_RESULT=RED
CONTROL_EMPTY_COMPOSER_NOTICE_TRANSPORTS=1
CONTROL_EMPTY_COMPOSER_RESULT=GREEN
```

## Fail-closed guards

The run exits `RUN_RESULT=INCONCLUSIVE` rather than claiming a reproduction when it cannot prove its
own preconditions:

- the realized `st2` is not the pinned revision;
- the sidecar never reported ready, or did not start against an empty inbox;
- the sidecar made fewer than two composer observations during the baseline window, so it was not
  actually looking;
- the sidecar log contains any error line, which would mean the run took some other path — a `pty`
  command timeout, say — rather than the silent pre-transport defer this reproduction is about.

## What this does not show

- The fixture does not read its stdin, so it never renders a pasted notice and never accepts one.
  The assertion is on **transport** — whether st2 pastes at all — not on end-to-end delivery.
- It does not identify a first-bad commit, and it does not test any proposed fix.
- It reproduces the classification input, not Claude's rendering. That Claude renders these
  suggestions dim, and renders typed input undimmed, is an observation about one Claude Code
  version, not something this reproduction proves.

## Versions

- st2: `3e0129434ac214d46fc4cace94c7086ec486302f`
- pty: `504ac7332895fe1fa3767b530dcd99f091f56cda`
- platform: `x86_64-linux`

## Related issue

<!-- filled in after filing -->
