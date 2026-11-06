#!/bin/bash
# Usage: copilot-review.sh [-R OWNER/REPO] PR_NUMBER
#
# Reports on Copilot's latest review of a PR:
#   - whether a Copilot review is currently requested (still to come)
#   - whether the latest review is stale: made on a commit older than the
#     PR's head, so pushes since then have not been reviewed
#   - the comments Copilot left out of the inline review because it had low
#     confidence in them. GitHub puts those only in the review body, inside a
#     <details> block whose summary mentions "low confidence", as
#     "**path:line**" headings followed by "* comment" bullets.
#
# Prints JSON:
#   {headOid, requested,
#    review: {id, state, submittedAt, commit, url, body} | null,
#    stale, lowConfidence: [{path, line, body}], lowConfidenceUnparsed}
# lowConfidenceUnparsed is true when the body has a low-confidence section
# but no comment could be parsed out of it (GitHub changed the format): read
# the body by hand then.
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
      reviewRequests(first: 50) {
        nodes { requestedReviewer { __typename ... on Bot { login } ... on User { login } } }
      }
      reviews(last: 100) {
        nodes { id state submittedAt url body author { login } commit { oid } }
      }
    }
  }
}'

gh api graphql -f query="$QUERY" -f owner="$OWNER" -f name="$NAME" -F number="$PR" |
  jq --arg copilot "$COPILOT_LOGIN_RE" '
    # The low-confidence <details> section of a review body, or "".
    def lowconf_section:
      (capture("(?s)<summary>(?:(?!</summary>).)*low confidence(?:(?!</summary>).)*</summary>(?<s>.*?)</details>"; "i").s) // "";

    # "**path:12**" or "**path:12-15**" headings, each followed by one or
    # more "* comment" bullets. Lines inside ``` fences never start a new
    # heading or bullet.
    def lowconf_items:
      reduce (split("\n")[]) as $l ({items: [], path: null, line: null, fence: false};
        if (.fence | not) and ($l | test("^\\*\\*[^*]+:[0-9]+(-[0-9]+)?\\*\\*\\s*$")) then
          ($l | capture("^\\*\\*(?<p>[^*]+):(?<n>[0-9]+)")) as $h
          | .path = $h.p | .line = ($h.n | tonumber)
        elif (.fence | not) and ($l | test("^\\* ")) and .path != null then
          .items += [{path: .path, line: .line, body: ($l | sub("^\\* "; ""))}]
        elif (.items | length) > 0 then
          .fence = (if ($l | test("^\\s*```")) then (.fence | not) else .fence end)
          | .items[-1].body += "\n" + $l
        else . end)
      | [.items[] | .body |= sub("\\s+$"; "")];

    .data.repository.pullRequest as $pr
    | ([$pr.reviews.nodes[] | select((.author.login // "") | test($copilot)) | select(.submittedAt != null)]
       | sort_by(.submittedAt) | last) as $r
    | ($r.body // "") as $body
    | ($body | lowconf_section | lowconf_items) as $items
    | {
        headOid: $pr.headRefOid,
        requested: any($pr.reviewRequests.nodes[]; (.requestedReviewer.login // "") | test($copilot)),
        review: (if $r == null then null else {id: $r.id, state: $r.state, submittedAt: $r.submittedAt, commit: $r.commit.oid, url: $r.url, body: $body} end),
        stale: ($r != null and $r.commit.oid != $pr.headRefOid),
        lowConfidence: $items,
        lowConfidenceUnparsed: (($items | length) == 0 and ($body | test("<summary>[^\n]*low confidence|suppressed due to low confidence"; "i")))
      }'
