#!/bin/bash
# Usage: pr-gate.sh [-R OWNER/REPO] PR_NUMBER
#
# One clean / not-clean answer for a PR. It is not clean while any of these
# hold (each becomes an entry in "blocking"):
#   ci-failing         a CI check on the head commit failed
#   ci-pending         a CI check on the head commit hasn't finished
#   unresolved-threads a review thread (bot or human) is still unresolved
#   changes-requested  a human's latest review requests changes
#   copilot-pending    a Copilot review is requested and hasn't arrived
#   missed-issues      Copilot's latest review body lists previously missed
#                      issues (or has that section and it couldn't be
#                      parsed), and no PR comment answers them yet
#   merge-conflict     GitHub reports the PR can't merge cleanly
#   head-moved         the head changed between the lookups (a push landed),
#                      so the review and CI results describe different
#                      commits; run it again
# These are reported as "warnings" and never block on their own:
#   copilot-stale      Copilot's latest review predates the head commit,
#                      and no fallback review (Codex or diff-review, when
#                      Copilot declined) covers the head either
#   low-confidence     Copilot's review body has suppressed comments to read
#   draft              the PR is still a draft
#
# Prints JSON: {repo, pr, headOid, clean, reviewer, blocking: [{reason, detail}], warnings: [{reason, detail}]}
# reviewer says who reviewed the head commit: "copilot", "codex" or
# "diff-review" (a fallback review's marker comment), or null for nobody yet,
# and null when the head moved between lookups.
# Exit codes: 0 clean, 1 not clean, 2 bad usage or a failed lookup.
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "$0")/lib.sh"

# The scripts below run gh in their own processes, so the token has to be
# in the environment before they start.
ensure_gh_token
parse_repo_args "$@"
PR=${ARGS[0]:-}
require_pr_number "$PR"
HERE=$(cd "$(dirname "$0")" && pwd)

THREADS=$(bash "$HERE/review-threads.sh" -R "$REPO" "$PR") || die "review-threads.sh failed"
COPILOT=$(bash "$HERE/copilot-review.sh" -R "$REPO" "$PR") || die "copilot-review.sh failed"
CI=$(bash "$HERE/ci-status.sh" -R "$REPO" "$PR") || die "ci-status.sh failed"

# shellcheck disable=SC2016 # GraphQL variables, not shell ones
QUERY='query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      isDraft mergeable
      latestOpinionatedReviews(first: 100) {
        nodes { state author { login __typename } }
      }
    }
  }
}'
PRINFO=$(gh api graphql -f query="$QUERY" -f owner="$OWNER" -f name="$NAME" -F number="$PR") || die "PR lookup failed"

RESULT=$(jq -n --arg repo "$REPO" --argjson pr "$PR" \
  --argjson threads "$THREADS" --argjson copilot "$COPILOT" --argjson ci "$CI" --argjson info "$PRINFO" '
  $info.data.repository.pullRequest as $p
  | [$p.latestOpinionatedReviews.nodes[]
      | select(.state == "CHANGES_REQUESTED" and (.author.__typename // "User") != "Bot")
      | .author.login // "ghost"] as $requesters
  | ($threads | map(select(.isCopilot)) | length) as $tc
  | ($threads | map(select(.authorType != "Bot")) | length) as $th
  | ($threads | length) as $tall
  | [
      (if ($ci.failing | length) > 0 then {reason: "ci-failing", detail: ($ci.failing | map(.name) | join(", "))} else empty end),
      (if ($ci.pending | length) > 0 then {reason: "ci-pending", detail: ($ci.pending | map(.name) | join(", "))} else empty end),
      (if $tall > 0 then {reason: "unresolved-threads",
        detail: "\($tall) unresolved: \($tc) from Copilot, \($th) from humans, \($tall - $tc - $th) from other bots"} else empty end),
      (if ($requesters | length) > 0 then {reason: "changes-requested", detail: ($requesters | join(", "))} else empty end),
      (if (($copilot.missedIssues | length) > 0 or $copilot.missedIssuesUnparsed) and ($copilot.missedIssuesAnswered | not) then
        {reason: "missed-issues", detail: (
          if ($copilot.missedIssues | length) == 0 then "the Copilot review body has previously missed issues that could not be parsed; read it by hand"
          else "the Copilot review body lists \($copilot.missedIssues | length) previously missed issue(s) with no thread: "
            + ($copilot.missedIssues as $m | ["High", "Medium", "Low", null]
              | map(. as $s | ($m | map(select(.severity == $s)) | length) as $n
                | if $n > 0 then "\($n) \($s // "unknown severity")" else empty end)
              | join(", "))
            + (if $copilot.missedIssuesUnparsed then "; the section announces more than could be parsed, so read the review body for the rest" else "" end)
          end)} else empty end),
      (if $copilot.requested then {reason: "copilot-pending", detail: "a Copilot review is requested and has not arrived yet"} else empty end),
      (if $p.mergeable == "CONFLICTING" then {reason: "merge-conflict", detail: "the PR has merge conflicts with its base branch"} else empty end),
      (if $copilot.headOid != $ci.headOid then {reason: "head-moved",
        detail: "the head moved from \($copilot.headOid[0:7]) to \($ci.headOid[0:7]) between lookups; run pr-gate.sh again"} else empty end)
    ] as $blocking
  | [
      (if $copilot.stale and ($copilot.requested | not) and ($copilot.fallbackReviewedHead | not) then {reason: "copilot-stale",
        detail: "Copilot last reviewed \($copilot.review.commit[0:7]); head is \($copilot.headOid[0:7])"} else empty end),
      (if ($copilot.lowConfidence | length) > 0 or $copilot.lowConfidenceUnparsed then {reason: "low-confidence",
        detail: "Copilot suppressed \($copilot.lowConfidence | length) low-confidence comment(s) in its review body"} else empty end),
      (if $p.isDraft then {reason: "draft", detail: "the PR is a draft"} else empty end)
    ] as $warnings
  | (if $copilot.headOid != $ci.headOid then null
     elif $copilot.review != null and ($copilot.stale | not) then "copilot"
     elif $copilot.fallbackReviewedHead then $copilot.fallbackReviewer
     else null end) as $reviewer
  | {repo: $repo, pr: $pr, headOid: $ci.headOid, clean: (($blocking | length) == 0), reviewer: $reviewer, blocking: $blocking, warnings: $warnings}')

printf '%s\n' "$RESULT"
[ "$(printf '%s' "$RESULT" | jq -r .clean)" = true ]
