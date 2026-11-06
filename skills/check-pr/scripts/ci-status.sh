#!/bin/bash
# Usage: ci-status.sh [-R OWNER/REPO] PR_NUMBER
#
# Summarises CI on the PR's head commit: every check run (GitHub Actions
# jobs and third-party apps such as Socket Security) and every commit status.
# A check that ran more than once on the same commit counts only by its
# latest run. Copilot's code review also shows up as a check run; it is
# reported on its own as copilotCheck instead of as CI.
#
# Prints JSON:
#   {headOid, total, counts: {STATE: n},
#    failing: [check], pending: [check], copilotCheck: check | null, truncated}
# where check = {kind, name, workflow, app, state, url, jobId, runId}.
# state is the check's conclusion (SUCCESS, FAILURE, SKIPPED, ...) or PENDING
# while it hasn't finished. jobId is set for GitHub Actions jobs only, and is
# what job-log.sh takes. truncated means there were over 100 checks and some
# were not read.
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "$0")/lib.sh"

ensure_gh_token
parse_repo_args "$@"
PR=${ARGS[0]:-}
require_pr_number "$PR"

# shellcheck disable=SC2016 # GraphQL variables, not shell ones
QUERY='query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      headRefOid
      commits(last: 1) {
        nodes {
          commit {
            statusCheckRollup {
              contexts(first: 100) {
                pageInfo { hasNextPage }
                nodes {
                  __typename
                  ... on CheckRun {
                    databaseId name status conclusion detailsUrl startedAt
                    checkSuite { app { slug } workflowRun { databaseId workflow { name } } }
                  }
                  ... on StatusContext { context state targetUrl createdAt }
                }
              }
            }
          }
        }
      }
    }
  }
}'

gh api graphql -f query="$QUERY" -f owner="$OWNER" -f name="$NAME" -F number="$PR" |
  jq --arg copilot "$COPILOT_LOGIN_RE" '
    .data.repository.pullRequest as $pr
    | ($pr.commits.nodes[0].commit.statusCheckRollup.contexts // {nodes: [], pageInfo: {hasNextPage: false}}) as $ctx
    | [ $ctx.nodes[]
        | if .__typename == "CheckRun" then {
            kind: "check",
            name,
            workflow: (.checkSuite.workflowRun.workflow.name // null),
            app: (.checkSuite.app.slug // null),
            state: (if .status == "COMPLETED" then .conclusion else "PENDING" end),
            url: .detailsUrl,
            jobId: (if .checkSuite.app.slug == "github-actions" then .databaseId else null end),
            runId: (.checkSuite.workflowRun.databaseId // null),
            at: (.startedAt // "")
          } else {
            kind: "status",
            name: .context,
            workflow: null,
            app: null,
            state: (if .state == "EXPECTED" then "PENDING" else .state end),
            url: .targetUrl,
            jobId: null,
            runId: null,
            at: (.createdAt // "")
          } end ]
    # Latest run per check.
    | group_by([.kind, .app, .workflow, .name]) | map(sort_by(.at) | last | del(.at))
    | (map(select(.kind == "check" and (.name | test($copilot)))) | last) as $copilotCheck
    | map(select((.kind == "check" and (.name | test($copilot))) | not)) as $ci
    | {
        headOid: $pr.headRefOid,
        total: ($ci | length),
        counts: ($ci | group_by(.state) | map({key: .[0].state, value: length}) | from_entries),
        failing: [$ci[] | select(.state | IN("FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE"))],
        pending: [$ci[] | select(.state | IN("PENDING", "QUEUED", "IN_PROGRESS", "WAITING", "REQUESTED"))],
        copilotCheck: $copilotCheck,
        truncated: $ctx.pageInfo.hasNextPage
      }'
