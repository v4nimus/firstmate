#!/usr/bin/env bash
# Pi-primary PreToolUse guard against long manual sleep/poll waits.
#
# The Pi watcher extension owns ordinary supervision and wakes the primary on
# meaningful changes. While any direct report is recorded in this home, a Pi
# primary must not occupy its only turn with a static sleep at or above
# FM_PI_PRIMARY_MAX_SLEEP_SECS (default 15). Short UI-settle sleeps remain
# available. The Node policy owner parses executed shell positions without
# evaluating the submitted command.
#
# Usage: fm-pi-primary-wait-check.sh --command '<cmd>'
# Exit 0 silently to allow. Exit 2 with a stable reason on stderr to deny.
# Missing state or classifier dependencies fail open.
set -u

CMD=
CMD_SET=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --command)
      [ "$#" -gt 1 ] || { echo "error: --command requires a value" >&2; exit 2; }
      CMD=$2
      CMD_SET=1
      shift 2
      ;;
    --command=*)
      CMD=${1#--command=}
      CMD_SET=1
      shift
      ;;
    -h|--help)
      sed -n '2,13p' "$0"
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

[ "$CMD_SET" -eq 1 ] && [ -n "$CMD" ] || exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
POLICY="$FM_ROOT/bin/fm-pi-primary-wait-command-policy.mjs"
MAX_SECONDS=${FM_PI_PRIMARY_MAX_SLEEP_SECS:-15}

shopt -s nullglob
META_FILES=("$STATE"/*.meta)
shopt -u nullglob
[ "${#META_FILES[@]}" -gt 0 ] || exit 0
command -v node >/dev/null 2>&1 || exit 0
[ -f "$POLICY" ] || exit 0

RESULT=$(node "$POLICY" --command "$CMD" --max-seconds "$MAX_SECONDS" 2>/dev/null) || exit 0
case "$RESULT" in
  allow) exit 0 ;;
  deny$'\t'pi-primary-long-wait$'\t'*)
    duration=${RESULT##*$'\t'}
    printf '%s\n' \
      "[pi-primary-long-wait] blocked a ${duration}s sleep while Pi is supervising live work; return control and let the native watcher deliver the next meaningful notification" >&2
    exit 2
    ;;
  *) exit 0 ;;
esac
