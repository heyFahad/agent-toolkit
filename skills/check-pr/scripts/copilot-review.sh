#!/bin/bash
# Usage: copilot-review.sh [-R OWNER/REPO] PR_NUMBER
#
# Reports on Copilot's latest review of a PR:
#   - whether a Copilot review is currently requested (still to come)
#   - whether the latest review is stale: made on a commit older than the
#     PR's head, so pushes since then have not been reviewed
#   - the findings Copilot put only in the review body, which have no review
#     thread, so review-threads.sh never lists them:
#       - previously missed issues (the review body format that starts with
#         "<!-- ccr-overview-v2 -->"): a <details> section whose summary says
#         "N previously missed issues", holding one nested <details> block
#         per finding. Each block's <summary> has a severity image
#         (alt="High severity") and a title; its body is a backticked
#         `path:line`, then the description.
#       - low-confidence comments (the older format): a <details> block whose
#         summary mentions "low confidence", as "**path:line**" headings
#         followed by "* comment" bullets.
#   - whether the missed issues have been answered: a PR comment carrying
#     missedIssuesMarker, which check-pr posts once it has assessed them.
#     Only comments by the gh user running this, or by the repo's owner,
#     members and collaborators, count: on a public repo anyone else could
#     post the marker.
#
# Prints JSON:
#   {headOid, requested,
#    review: {id, state, submittedAt, commit, url, body} | null,
#    stale,
#    missedIssues: [{severity, path, line, title, body}], missedIssuesUnparsed,
#    missedIssuesMarker, missedIssuesAnswered,
#    lowConfidence: [{path, line, body}], lowConfidenceUnparsed}
# severity is "High", "Medium" or "Low" as Copilot wrote it, or null.
# missedIssuesUnparsed is true when the body has that section but fewer
# findings could be parsed out of it than it announces, and
# lowConfidenceUnparsed when it has that section and nothing could be parsed
# out of it. Either means GitHub changed the format: read the body by hand.
# missedIssuesMarker is null without a review.
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
      comments(last: 100) { nodes { body viewerDidAuthor authorAssociation } }
    }
  }
}'

gh api graphql -f query="$QUERY" -f owner="$OWNER" -f name="$NAME" -F number="$PR" |
  jq --arg copilot "$COPILOT_LOGIN_RE" '
    def trim_ws: sub("^\\s+"; "") | sub("\\s+$"; "");
    # Copilot puts zero-width spaces in paths so GitHub does not autolink them.
    def strip_zw: gsub("[​‌‍﻿]"; "");
    def decode_html: gsub("&#39;|&#x27;"; [39] | implode) | gsub("&quot;"; "\"") | gsub("&lt;"; "<") | gsub("&gt;"; ">") | gsub("&amp;"; "&");

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

    # The findings under the "N previously missed issues" summary. depth
    # counts open <details> blocks from the section itself (1) down; each
    # finding is a block at depth 2. Only tags that start a line count, so a
    # description that mentions `<details>` in prose leaves depth alone.
    # Lines inside ``` fences are body text.
    def missed_items:
      reduce (split("\n")[] | sub("\r$"; "")) as $l ({items: [], in: false, done: false, depth: 0, cur: false, fence: false};
        if .done then .
        elif (.in | not) then
          if ($l | test("<summary>(?:(?!</summary>).)*previously missed issue"; "i")) then .in = true | .depth = 1 else . end
        elif .fence then
          .items[-1].lines += [$l] | .fence = ($l | test("^\\s*```") | not)
        else
          (if $l | test("^\\s*<details\\b") then 1 else 0 end) as $o
          | ([$l | match("</details>\\s*"; "g")] | length) as $c0
          | (if $l | test("^\\s*(</details>\\s*)+$") then $c0 elif $l | test("</details>\\s*$") and $o == 1 then 1 else 0 end) as $c
          | .depth += $o
          | if .depth == 2 and (.cur | not) and ($l | test("<summary>")) then
              .cur = true
              | .items += [{
                  severity: (($l | capture("alt=\"(?<s>[A-Za-z]+) severity\"").s) // null),
                  title: ($l | capture("<summary>(?<t>.*?)(?:</summary>|$)").t
                    | gsub("<picture>.*?</picture>"; "") | gsub("<[^>]*>"; "") | decode_html | trim_ws),
                  path: null, line: null, lines: []}]
            elif .cur and .depth == 2 and ($l | test("^\\s*</?details\\b") | not) then
              if .items[-1].path == null and all(.items[-1].lines[]; test("^\\s*$"))
                and ($l | test("^\\s*`[^`]+`\\s*$")) then
                ($l | strip_zw | capture("`(?<loc>[^`]+)`").loc | trim_ws) as $loc
                | (($loc | capture("^(?<p>.+?):(?<n>[0-9]+)(?:-[0-9]+)?$")) // {p: $loc, n: null}) as $m
                | .items[-1].path = $m.p
                | .items[-1].line = ($m.n | if . == null then null else tonumber end)
                | .items[-1].lines = []
              else
                .items[-1].lines += [$l] | .fence = ($l | test("^\\s*```"))
              end
            else . end
          | .depth -= $c
          | if .depth < 2 then .cur = false else . end
          | if .depth < 1 then .done = true else . end
        end)
      | [.items[] | {severity, path, line, title,
          body: (.lines | join("\n") | strip_zw | decode_html | trim_ws)}];

    # How many findings a section heading announces ("7 previously missed
    # issues"), or 1 when it gives no number: there is at least one.
    def announced($re):
      ((capture("(?<n>[0-9]+)\\s*" + $re; "i").n | tonumber) // 1);

    .data.repository.pullRequest as $pr
    | ([$pr.reviews.nodes[] | select((.author.login // "") | test($copilot)) | select(.submittedAt != null)]
       | sort_by(.submittedAt) | last) as $r
    | ($r.body // "") as $body
    | ($body | lowconf_section | lowconf_items) as $items
    | ($body | missed_items) as $missed
    | (if $r == null then null else "<!-- check-pr: answered missed issues of review \($r.id) -->" end) as $marker
    | {
        headOid: $pr.headRefOid,
        requested: any($pr.reviewRequests.nodes[]; (.requestedReviewer.login // "") | test($copilot)),
        review: (if $r == null then null else {id: $r.id, state: $r.state, submittedAt: $r.submittedAt, commit: $r.commit.oid, url: $r.url, body: $body} end),
        stale: ($r != null and $r.commit.oid != $pr.headRefOid),
        missedIssues: $missed,
        missedIssuesUnparsed: (($body | test("previously missed issue"; "i"))
          and ($missed | length) < ($body | announced("previously missed issue"))),
        missedIssuesMarker: $marker,
        missedIssuesAnswered: ($marker != null and any(($pr.comments.nodes // [])[]
          | select(.viewerDidAuthor or (.authorAssociation | IN("OWNER", "MEMBER", "COLLABORATOR")));
          (.body // "") | contains($marker))),
        lowConfidence: $items,
        lowConfidenceUnparsed: (($items | length) == 0 and ($body | test("<summary>[^\n]*low confidence|suppressed due to low confidence"; "i")))
      }'
