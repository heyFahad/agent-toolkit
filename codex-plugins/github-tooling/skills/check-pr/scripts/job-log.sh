#!/bin/bash
# Usage: job-log.sh [-R OWNER/REPO] JOB_ID [LINES]
#
# Prints the last LINES (default 150) lines of a GitHub Actions job's log,
# with the timestamp GitHub puts on every line removed. JOB_ID is the jobId
# ci-status.sh reports for a failing check.
#
# Only GitHub Actions jobs have logs here. A third-party check (an app such
# as Socket Security) has none; open its url from ci-status.sh instead.
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "$0")/lib.sh"

ensure_gh_token
parse_repo_args "$@"
JOB=${ARGS[0]:-}
LINES=${ARGS[1]:-150}
case "$JOB" in '' | *[!0-9]*) die "expected a numeric job id, got '$JOB'" ;; esac
case "$LINES" in '' | *[!0-9]*) die "LINES must be a number, got '$LINES'" ;; esac

# The endpoint answers with a redirect to the plain-text log, which gh follows.
gh api "repos/$REPO/actions/jobs/$JOB/logs" |
  sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z //' |
  tail -n "$LINES"
