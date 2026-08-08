#!/usr/bin/env bash
# Reproduction: st2's Claude adapter reads a context-derived composer placeholder as a human draft,
# so `st2 ding` defers before ever pasting and the seat's mail is never transported.
#
# Three composer rows are exercised at one pinned st2 revision. Only that row differs.
set -euo pipefail

NBSP=$'\u00a0'  # Claude renders its composer prompt as U+276F + U+00A0
RULE="$(printf '─%.0s' {1..80})"

composer_row_for() {
  case "$1" in
    # A context-derived suggestion, as Claude renders it on an idle pane: dim, and not the
    # `Try "<example>"` grammar that st2's adapter recognizes.
    suggestion) printf '\033[2mrefactor the parser to use a lookup table' ;;
    # The one placeholder grammar st2's adapter does recognize.
    try-placeholder) printf '\033[2mTry "add a test for the parser"' ;;
    empty) printf '' ;;
    *) printf 'unknown composer variant: %s\n' "$1" >&2; return 1 ;;
  esac
}

monotonic_ms() { awk '{ printf "%.0f\n", $1 * 1000 }' /proc/uptime; }

log_count() {
  awk -v pattern="$1" 'index($0, pattern) { count += 1 } END { print count + 0 }' "$REPRO_PTY_LOG"
}

wait_for_count() {
  local pattern="$1" minimum="$2" timeout_ms="$3" label="$4"
  local deadline count
  deadline=$(( $(monotonic_ms) + timeout_ms ))
  while true; do
    count="$(log_count "$pattern")"
    if (( count >= minimum )); then return 0; fi
    if (( $(monotonic_ms) >= deadline )); then
      printf 'FAIL: collected %s %s; expected at least %s\n' "$count" "$label" "$minimum" >&2
      return 1
    fi
    sleep 0.1
  done
}

# ---------------------------------------------------------------------------
# Synthetic provider fixture: renders one Claude-shaped pane and nothing else.
#
# It deliberately does not read stdin, so a bracketed paste never changes the screen. This
# reproduction asserts only on whether st2 transports the notice, so the fixture does not have to
# model Claude's staging or acceptance rendering.
# ---------------------------------------------------------------------------
fixture_main() {
  local variant="$1" composer_row state='INITIAL'
  composer_row="$(composer_row_for "$variant")"
  printf '%s\n' "$$" > "$REPRO_FIXTURE_PID"
  stty -echo -icanon 2>/dev/null || true

  render() {
    printf '\033[2J\033[H'
    printf 'Synthetic Claude-shaped provider fixture\n'
    printf 'FIXTURE_STATE=%s\n' "$state"
    printf '%s\n' "$RULE"
    printf '❯%s%s\n' "$NBSP" "$composer_row"
    printf '%s\n' "$RULE"
    printf '  synthetic.seat | model | 20%%\n'
    printf '  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents\n'
  }

  # The in-run control: empty the composer, changing nothing else about the pane.
  release_to_empty() { composer_row="$(composer_row_for empty)"; state='RELEASED'; render; }

  trap release_to_empty USR1
  state='READY'
  render
  while true; do sleep 0.2; done
}

# ---------------------------------------------------------------------------
# `pty` shim: records every send/peek the sidecar makes, then execs the real binary.
# ---------------------------------------------------------------------------
shim_main() {
  local operation="${1:-unknown}" kind='other' has_return='no' argument status
  if [[ "$*" == *"$REPRO_NONCE"* ]]; then kind='notice'; fi
  for argument in "$@"; do
    if [[ "$argument" == 'key:return' ]]; then has_return='yes'; fi
  done
  case "$operation" in
    send|peek)
      printf '%s op=%s phase=%s kind=%s has_return=%s\n' \
        "$(monotonic_ms)" "$operation" "$(<"$REPRO_PHASE_FILE")" "$kind" "$has_return" \
        >> "$REPRO_PTY_LOG"
      ;;
  esac
  set +e
  "$REPRO_REAL_PTY" "$@"
  status=$?
  set -e
  return "$status"
}

cleanup() {
  local status=$?
  if [[ -n "${REPRO_SIDECAR_PID:-}" ]]; then
    kill "$REPRO_SIDECAR_PID" >/dev/null 2>&1 || true
    wait "$REPRO_SIDECAR_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "${REPRO_REAL_PTY:-}" && -n "${REPRO_SESSION:-}" ]]; then
    PTY_ROOT="${REPRO_PTY_ROOT:-}" "$REPRO_REAL_PTY" kill "$REPRO_SESSION" >/dev/null 2>&1 || true
    PTY_ROOT="${REPRO_PTY_ROOT:-}" "$REPRO_REAL_PTY" rm "$REPRO_SESSION" >/dev/null 2>&1 || true
  fi
  if [[ -n "${REPRO_ROOT:-}" ]]; then
    case "$REPRO_ROOT" in
      "${TMPDIR:-/tmp}"/st2-claude-placeholder.*) rm -rf -- "${REPRO_ROOT:?}" ;;
      *) printf 'REFUSING cleanup outside reproduction prefix: %s\n' "$REPRO_ROOT" >&2; status=1 ;;
    esac
  fi
  if (( status != 0 )); then printf 'RUN_RESULT=INCONCLUSIVE\n' >&2; fi
  exit "$status"
}

# ---------------------------------------------------------------------------
# One case: boot a sidecar against a pane whose composer holds `variant`, send one uniquely
# nonced message, and count how often st2 transports the resulting notice.
# ---------------------------------------------------------------------------
run_case() {
  local variant="$1"
  local self st2_version sidecar_log bus_root state_root shim_dir inbox
  local peeks notice_transports unread

  self="$(readlink -f "$0")"
  st2_version="$("$REPRO_ST2" --version)"
  REPRO_REAL_PTY="$(command -v pty)"
  REPRO_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/st2-claude-placeholder.XXXXXX")"
  REPRO_PTY_ROOT="$REPRO_ROOT/pty"
  REPRO_SESSION='repro.recipient'
  REPRO_NONCE="nonce$(monotonic_ms)x$$"
  REPRO_PTY_LOG="$REPRO_ROOT/pty-invocations.log"
  REPRO_PHASE_FILE="$REPRO_ROOT/phase"
  REPRO_FIXTURE_PID="$REPRO_ROOT/fixture.pid"
  bus_root="$REPRO_ROOT/bus"
  state_root="$REPRO_ROOT/state"
  shim_dir="$REPRO_ROOT/shim"
  sidecar_log="$REPRO_ROOT/sidecar.log"
  export REPRO_REAL_PTY REPRO_ROOT REPRO_PTY_ROOT REPRO_SESSION REPRO_NONCE
  export REPRO_PTY_LOG REPRO_PHASE_FILE REPRO_FIXTURE_PID NBSP RULE
  mkdir -p "$REPRO_PTY_ROOT" "$bus_root" "$state_root" "$shim_dir"
  : > "$REPRO_PTY_LOG"
  printf 'boot\n' > "$REPRO_PHASE_FILE"
  ln -s "$self" "$shim_dir/pty"
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  # Fail closed unless the realized binary is the pinned revision.
  case "$st2_version" in
    *"+$REPRO_ST2_SHORT_REV"*) ;;
    *) printf 'FAIL: realized st2 is not the pinned revision: %s\n' "$st2_version" >&2; return 1 ;;
  esac

  PTY_ROOT="$REPRO_PTY_ROOT" "$REPRO_REAL_PTY" run -d \
    --id "$REPRO_SESSION" --name 'Synthetic Claude-shaped pane' --tag keep=true \
    -- bash "$self" --fixture "$variant" >/dev/null
  PTY_ROOT="$REPRO_PTY_ROOT" "$REPRO_REAL_PTY" peek \
    --wait 'FIXTURE_STATE=READY' -t 10 --plain "$REPRO_SESSION" >/dev/null

  # The sidecar starts against an EMPTY inbox, so the message below is an ordinary queued notice
  # rather than the coalesced startup recovery notice.
  PATH="$shim_dir:$PATH" PTY_ROOT="$REPRO_PTY_ROOT" XDG_STATE_HOME="$state_root" \
    "$REPRO_ST2" ding "$REPRO_SESSION" --identity "$REPRO_SESSION" \
      --root "$bus_root" --host repro --interval 200 > "$sidecar_log" 2>&1 &
  REPRO_SIDECAR_PID=$!

  local deadline
  deadline=$(( $(monotonic_ms) + 15000 ))
  until grep -q 'ready — found' "$sidecar_log" 2>/dev/null; do
    if (( $(monotonic_ms) >= deadline )); then
      printf 'FAIL: sidecar never reported ready\n' >&2
      sed 's/^/  sidecar| /' "$sidecar_log" >&2
      return 1
    fi
    sleep 0.1
  done
  if ! grep -q 'found 0 existing unread' "$sidecar_log"; then
    printf 'FAIL: sidecar did not start against an empty inbox\n' >&2
    return 1
  fi
  # The inbox directory is created by the first `message send`, so resolve the path now and
  # assert on its contents later.
  inbox="$(sed -n 's/.*inbox (\([^)]*\)).*/\1/p' "$sidecar_log" | sed -n '1p')"
  if [[ -z "$inbox" ]]; then
    printf 'FAIL: could not resolve the sidecar inbox from its log\n' >&2
    return 1
  fi

  printf '%s\n' "$variant" > "$REPRO_PHASE_FILE"
  printf 'synthetic payload\n' | "$REPRO_ST2" message send "$REPRO_SESSION" \
    --root "$bus_root" --host repro --as repro.sender --subject "$REPRO_NONCE" >/dev/null

  printf 'CASE=%s\n' "$variant"
  printf 'CASE_ST2_VERSION=%s\n' "$st2_version"

  if [[ "$variant" != 'suggestion' ]]; then
    wait_for_count "op=send phase=$variant kind=notice" 1 30000 "$variant transports"
    notice_transports="$(log_count "op=send phase=$variant kind=notice")"
    if [[ "$notice_transports" != 1 ]]; then
      printf 'FAIL: expected exactly one %s transport, got %s\n' "$variant" "$notice_transports" >&2
      return 1
    fi
    printf 'CONTROL_TRY_PLACEHOLDER_NOTICE_TRANSPORTS=%s\n' "$notice_transports"
    printf 'CONTROL_TRY_PLACEHOLDER_RESULT=GREEN\n'
    return 0
  fi

  # Two delivery-retry cycles at DELIVERY_RETRY_BACKOFF = 15s, plus slack.
  sleep 33
  peeks="$(log_count "op=peek phase=$variant")"
  notice_transports="$(log_count "op=send phase=$variant kind=notice")"
  shopt -s nullglob
  local remaining=("$inbox"/*.md)
  unread="${#remaining[@]}"

  # Fail closed: a sidecar that never observed the composer proves nothing about what it decided.
  if (( peeks < 2 )); then
    printf 'FAIL: sidecar made %s composer observations; expected at least 2\n' "$peeks" >&2
    return 1
  fi
  # Fail closed: any logged error means this run took some other path (a pty timeout, say),
  # not the silent pre-transport defer this reproduction is about.
  if grep -qE 'st2 ding: (timed out|.*failed|.*ambiguous)' "$sidecar_log"; then
    printf 'FAIL: sidecar log contains an error, so this run is not the silent-defer path\n' >&2
    sed 's/^/  sidecar| /' "$sidecar_log" >&2
    return 1
  fi
  if [[ "$notice_transports" != 0 ]]; then
    printf 'FAIL: baseline unexpectedly transported the notice %s time(s)\n' "$notice_transports" >&2
    return 1
  fi
  if [[ "$unread" != 1 ]]; then
    printf 'FAIL: expected the message to still be unread, found %s\n' "$unread" >&2
    return 1
  fi
  kill -0 "$REPRO_SIDECAR_PID"
  PTY_ROOT="$REPRO_PTY_ROOT" "$REPRO_REAL_PTY" list --json |
    jq -e --arg id "$REPRO_SESSION" 'any(.name == $id and .status == "running")' >/dev/null

  printf 'BASELINE_COMPOSER_OBSERVATIONS=%s\n' "$peeks"
  printf 'BASELINE_NOTICE_TRANSPORTS=%s\n' "$notice_transports"
  printf 'BASELINE_MESSAGE_STILL_UNREAD=yes\n'
  printf 'BASELINE_SIDECAR_LOG_LINES=%s\n' "$(wc -l < "$sidecar_log")"
  printf 'BASELINE_SIDECAR_ALIVE=yes\n'
  printf 'BASELINE_TARGET_ALIVE=yes\n'
  printf 'BASELINE_RESULT=RED\n'

  # In-run control: same sidecar, same message, same pane. Only the composer row changes.
  printf 'control-empty\n' > "$REPRO_PHASE_FILE"
  kill -USR1 "$(<"$REPRO_FIXTURE_PID")"
  PTY_ROOT="$REPRO_PTY_ROOT" "$REPRO_REAL_PTY" peek \
    --wait 'FIXTURE_STATE=RELEASED' -t 10 --plain "$REPRO_SESSION" >/dev/null
  wait_for_count 'op=send phase=control-empty kind=notice' 1 30000 'control transports'
  notice_transports="$(log_count 'op=send phase=control-empty kind=notice')"
  if [[ "$notice_transports" != 1 ]]; then
    printf 'FAIL: expected exactly one control transport, got %s\n' "$notice_transports" >&2
    return 1
  fi
  printf 'CONTROL_EMPTY_COMPOSER_NOTICE_TRANSPORTS=%s\n' "$notice_transports"
  printf 'CONTROL_EMPTY_COMPOSER_RESULT=GREEN\n'
}

repro_main() {
  local self
  self="$(readlink -f "$0")"
  printf 'ST2_PIN=%s\n' "$REPRO_ST2_REV"
  printf 'PTY_PIN=%s\n' "$REPRO_PTY_REV"
  "$self" --case suggestion
  "$self" --case try-placeholder
  printf 'RUN_RESULT=REPRODUCED\n'
}

case "${1:-}" in
  --fixture) shift; fixture_main "$@" ;;
  --case) shift; run_case "$@" ;;
  *)
    if [[ "$(basename "$0")" == 'pty' ]]; then shim_main "$@"; else repro_main; fi
    ;;
esac
