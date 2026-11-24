#!/bin/bash
# Usage: wait-for-review.sh [-R OWNER/REPO] [--timeout DURATION] PR...
#
# Waits until every PR has settled: no CI check still running, no Copilot
# review still requested, and the head didn't move between pr-gate.sh's
# lookups. Use it after requesting reviews or pushing fixes, instead of
# polling by hand. In Claude Code run it in the background: you're woken when
# it exits. Elsewhere run it in the foreground.
#
# DURATION is N, Ns or Nm (default 15m). It reads every 30 seconds, starting
# one interval after launch, so a push whose CI hasn't registered yet doesn't
# look settled. Each read runs pr-gate.sh on every PR.
#
# Prints a JSON array of each PR's last pr-gate.sh output (null for a PR whose
# every read failed).
# Exit codes: 0 every PR settled (clean or not: read "blocking"); 124 timed
# out; 2 bad usage, or three failed reads in a row of one PR.
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "$0")/lib.sh"

HERE=$(cd "$(dirname "$0")" && pwd)
GATE=${CHECK_PR_GATE:-$HERE/pr-gate.sh}
INTERVAL=${CHECK_PR_WAIT_INTERVAL:-30}
TIMEOUT=900 REPO_ARGS=() PRS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -R | --repo)
      [ "$#" -ge 2 ] || die "$1 needs OWNER/REPO"
      REPO_ARGS=(-R "$2")
      shift
      ;;
    --repo=*) REPO_ARGS=(-R "${1#--repo=}") ;;
    --timeout)
      [ "$#" -ge 2 ] || die "--timeout needs a duration"
      TIMEOUT=$2
      shift
      ;;
    --timeout=*) TIMEOUT=${1#--timeout=} ;;
    *)
      require_pr_number "$1"
      PRS+=("$1")
      ;;
  esac
  shift
done
[ "${#PRS[@]}" -gt 0 ] || die "usage: wait-for-review.sh [-R OWNER/REPO] [--timeout DURATION] PR..."
case "$TIMEOUT" in
  *[0-9]m) N=${TIMEOUT%m} MULT=60 ;;
  *[0-9]s) N=${TIMEOUT%s} MULT=1 ;;
  *) N=$TIMEOUT MULT=1 ;;
esac
case "$N" in '' | *[!0-9]*) die "bad duration '$TIMEOUT': use N, Ns or Nm" ;; esac
TIMEOUT=$((N * MULT))

# Per PR, in PRS order: the last gate output and the failed reads in a row.
LAST=() FAILS=()
for _ in "${PRS[@]}"; do
  LAST+=(null)
  FAILS+=(0)
done

report() { printf '%s\n' "${LAST[@]}" | jq -s .; }

START=$SECONDS
while :; do
  sleep "$INTERVAL"
  settled=true
  k=0
  for pr in "${PRS[@]}"; do
    rc=0
    out=$(bash "$GATE" ${REPO_ARGS[@]+"${REPO_ARGS[@]}"} "$pr" 2>/dev/null) || rc=$?
    if [ "$rc" -le 1 ] && printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
      LAST[k]=$(printf '%s' "$out" | jq -c .)
      FAILS[k]=0
      printf '%s' "$out" | jq -e '[.blocking[]?.reason] | any(. == "ci-pending" or . == "copilot-pending" or . == "head-moved") | not' >/dev/null || settled=false
    else
      FAILS[k]=$((FAILS[k] + 1))
      settled=false
      if [ "${FAILS[k]}" -ge 3 ]; then
        report
        die "pr-gate.sh failed three times in a row on PR $pr"
      fi
    fi
    k=$((k + 1))
  done
  if [ "$settled" = true ]; then
    report
    exit 0
  fi
  if [ $((SECONDS - START)) -ge "$TIMEOUT" ]; then
    report
    exit 124
  fi
done
