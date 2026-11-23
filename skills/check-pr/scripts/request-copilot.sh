#!/bin/bash
# Usage: request-copilot.sh [-R OWNER/REPO] PR_NUMBER...
#
# Requests a Copilot review on each PR, then checks that each request was
# accepted. When Copilot's monthly credits have run out, GitHub still accepts
# `gh pr edit --add-reviewer @copilot`, but no request event for Copilot
# reaches the PR's timeline and no review ever comes. So the Copilot
# ReviewRequestedEvents already on each timeline are noted first, and a
# request counts as accepted only once a new one shows up: an event from an
# earlier request, however recent, never counts. After the requests, the
# timeline is read up to CHECK_PR_REQUEST_READS times (default 6),
# CHECK_PR_REQUEST_DELAY seconds apart (default 5), in case the event lags.
# Every request is made first, so all PRs share one window.
#
# Prints JSON: [{pr, accepted, requestedAt}]
# requestedAt is when the requests were made.
# Exit codes: 0 once every request was made, accepted or not; 2 bad usage, a
# failed request or a failed timeline lookup.
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "$0")/lib.sh"

ensure_gh_token
parse_repo_args "$@"
[ "${#ARGS[@]}" -gt 0 ] || die "usage: request-copilot.sh [-R OWNER/REPO] PR_NUMBER..."
for pr in "${ARGS[@]}"; do require_pr_number "$pr"; done

READS=${CHECK_PR_REQUEST_READS:-6}
DELAY=${CHECK_PR_REQUEST_DELAY:-5}

# shellcheck disable=SC2016 # GraphQL variables, not shell ones
QUERY='query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      timelineItems(last: 20, itemTypes: [REVIEW_REQUESTED_EVENT]) {
        nodes { ... on ReviewRequestedEvent { id createdAt requestedReviewer { __typename ... on Bot { login } ... on User { login } } } }
      }
    }
  }
}'

# copilot_events PR: the ids of the Copilot request events on its timeline,
# as a JSON array. A failed lookup stops the script: reporting it as a
# decline would send the agent to a fallback review while Copilot may still
# be coming.
copilot_events() {
  local json
  json=$(gh api graphql -f query="$QUERY" -f owner="$OWNER" -f name="$NAME" -F number="$1") ||
    die "reading PR #$1's timeline failed"
  printf '%s' "$json" | jq -c --arg copilot "$COPILOT_LOGIN_RE" '
    [.data.repository.pullRequest.timelineItems.nodes[]
      | select((.requestedReviewer.login // "") | test($copilot)) | .id]'
}

SNAP=$(mktemp -d)
trap 'rm -rf "$SNAP"' EXIT
for pr in "${ARGS[@]}"; do copilot_events "$pr" >"$SNAP/$pr"; done

REQUESTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
for pr in "${ARGS[@]}"; do
  gh pr edit -R "$REPO" "$pr" --add-reviewer @copilot >/dev/null || die "requesting Copilot on #$pr failed"
done

# accepted PR: true when a Copilot request event not in the snapshot is there.
accepted() {
  local now
  # die only leaves the $(...) subshell, and set -e is off inside `if`.
  now=$(copilot_events "$1") || die "reading PR #$1's timeline failed"
  jq -n -e --argjson before "$(cat "$SNAP/$1")" --argjson now "$now" '$now - $before | length > 0' >/dev/null
}

PENDING=" ${ARGS[*]} "
ACCEPTED=" "
i=1
while [ "$i" -le "$READS" ] && [ -n "${PENDING// /}" ]; do
  [ "$i" -gt 1 ] && sleep "$DELAY"
  for pr in $PENDING; do
    if accepted "$pr"; then
      ACCEPTED="$ACCEPTED$pr "
      PENDING=${PENDING/ $pr / }
    fi
  done
  i=$((i + 1))
done

for pr in "${ARGS[@]}"; do
  case "$ACCEPTED" in *" $pr "*) a=true ;; *) a=false ;; esac
  jq -n --argjson pr "$pr" --argjson a "$a" --arg at "$REQUESTED_AT" '{pr: $pr, accepted: $a, requestedAt: $at}'
done | jq -s .
