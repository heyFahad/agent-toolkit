#!/bin/bash
# Usage: review-threads.sh [-R OWNER/REPO] PR_NUMBER [--all]
#
# Lists a PR's unresolved review threads (all threads with --all), from any
# author: Copilot, other bots and humans. Each thread's id is the node id
# that reply-thread.sh takes.
#
# Prints a JSON array:
#   [{id, isResolved, isOutdated, path, line, startLine,
#     author, authorType, isCopilot, url,
#     comments: [{author, authorType, body, createdAt, url}]}]
# author/authorType come from the thread's first comment. authorType is
# "Bot" or "User" (GitHub's own __typename), so a human's thread is any
# thread whose authorType is not "Bot".
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "$0")/lib.sh"

ensure_gh_token
parse_repo_args "$@"
PR=${ARGS[0]:-}
require_pr_number "$PR"
ALL=false
[ "${ARGS[1]:-}" = --all ] && ALL=true

# shellcheck disable=SC2016 # GraphQL variables, not shell ones
QUERY='query($owner: String!, $name: String!, $number: Int!, $endCursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      reviewThreads(first: 50, after: $endCursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id isResolved isOutdated path line startLine
          comments(first: 50) {
            nodes { author { login __typename } body createdAt url }
          }
        }
      }
    }
  }
}'

gh api graphql --paginate -f query="$QUERY" -f owner="$OWNER" -f name="$NAME" -F number="$PR" |
  jq -s --argjson all "$ALL" --arg copilot "$COPILOT_LOGIN_RE" '
    [ .[].data.repository.pullRequest.reviewThreads.nodes[]
      | select($all or (.isResolved | not))
      | .comments.nodes as $c
      | {
          id, isResolved, isOutdated, path, line, startLine,
          author: ($c[0].author.login // "ghost"),
          authorType: ($c[0].author.__typename // "User"),
          isCopilot: (($c[0].author.login // "") | test($copilot)),
          url: $c[0].url,
          comments: [$c[] | {author: (.author.login // "ghost"), authorType: (.author.__typename // "User"), body, createdAt, url}]
        } ]'
