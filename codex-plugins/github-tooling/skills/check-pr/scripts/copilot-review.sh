#!/bin/bash
# Usage: copilot-review.sh [-R OWNER/REPO] PR_NUMBER
#
# Reports on Copilot's latest review of a PR:
#   - whether a Copilot review is currently requested (still to come): Copilot
#     is in the PR's review requests AND a request event for it reached the
#     timeline after its latest review (any request event, without a review).
#     When Copilot's monthly credits run out, GitHub accepts the request but
#     no event appears, so a declined request never counts as pending.
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
#   - whether the missed issues have been answered: a PR comment whose last
#     line is missedIssuesMarker, which check-pr posts once it has assessed
#     them. A comment that only quotes the marker elsewhere doesn't count,
#     and only comments by the gh user running this, or by the repo's owner,
#     members and collaborators, count: on a public repo anyone else could
#     post the marker. All of the PR's comments are searched, and only when
#     there is something to answer.
#   - whether a fallback review covered the head: when Copilot declines,
#     check-pr reviews with Codex or diff-review and answers in a PR comment
#     whose last line is "<!-- check-pr: fallback review by <codex|diff-review>
#     of <40-hex head sha> -->", trusted on the same terms as the missed-issues
#     marker. Comments are read for this when there is no Copilot review or
#     it is stale.
#
# Prints JSON:
#   {headOid, requested,
#    review: {id, state, submittedAt, commit, url, body} | null,
#    stale,
#    missedIssues: [{severity, path, line, title, body, url}], missedIssuesUnparsed,
#    missedIssuesMarker, missedIssuesAnswered,
#    lowConfidence: [{path, line, body}], lowConfidenceUnparsed,
#    fallbackReviewedHead, fallbackLastHead, fallbackReviewer}
# fallbackLastHead and fallbackReviewer come from the latest trusted fallback
# marker (null without one); fallbackReviewedHead is true when it names
# headOid. All three are false/null when the comments weren't read.
# severity is "High", "Medium" or "Low" as Copilot wrote it, or null. url is
# a permalink to path at line, pinned to the commit Copilot reviewed (the
# version its line numbers refer to), or null without a path.
# missedIssuesUnparsed is true when the body has that section (a <summary>
# saying "previously missed issues", not the words anywhere in the body) but
# fewer findings could be parsed out of it than its summary announces, and
# when a parsed finding has no title or path, and
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
      timelineItems(last: 100, itemTypes: [REVIEW_REQUESTED_EVENT]) {
        nodes { ... on ReviewRequestedEvent { createdAt requestedReviewer { __typename ... on Bot { login } ... on User { login } } } }
      }
      reviews(last: 100) {
        nodes { id state submittedAt url body author { login } commit { oid } }
      }
    }
  }
}'

# shellcheck disable=SC2016 # GraphQL variables, not shell ones
COMMENTS_QUERY='query($owner: String!, $name: String!, $number: Int!, $endCursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      comments(first: 100, after: $endCursor) {
        pageInfo { hasNextPage endCursor }
        nodes { body viewerDidAuthor authorAssociation }
      }
    }
  }
}'

RESULT=$(gh api graphql -f query="$QUERY" -f owner="$OWNER" -f name="$NAME" -F number="$PR" |
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
    # description that mentions `<details>` in prose leaves depth alone. A
    # block nested inside a description (depth 3 and up) stays in that
    # body of that finding, tags and all. Lines inside a code fence (``` or
    # ~~~, any length) are body text; only a bare fence of the same character
    # and at least the same length closes it, as in CommonMark.
    # Only the title is HTML-decoded: Copilot escapes summaries, not
    # descriptions, and decoding those would change their code spans.
    def missed_items:
      reduce (split("\n")[] | sub("\r$"; "")) as $l ({items: [], in: false, done: false, depth: 0, cur: false, fence: false};
        if .done then .
        elif (.in | not) then
          if ($l | test("<summary>(?:(?!</summary>).)*previously\\s+missed\\s+issue"; "i")) then .in = true | .depth = 1 else . end
        elif .fence then
          .items[-1].lines += [$l]
          | .fence as $f
          | .fence = (if $l | test("^\\s*" + $f[0:1] + "{" + ($f | length | tostring) + ",}\\s*$") then false else $f end)
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
            elif .cur and (.depth - $c) >= 2 then
              if .depth == 2 and .items[-1].path == null and all(.items[-1].lines[]; test("^\\s*$"))
                and ($l | test("^\\s*`[^`]+`\\s*$")) then
                ($l | strip_zw | capture("`(?<loc>[^`]+)`").loc | trim_ws) as $loc
                | (($loc | capture("^(?<p>.+?):(?<n>[0-9]+)(?:-[0-9]+)?$")) // {p: $loc, n: null}) as $m
                | .items[-1].path = $m.p
                | .items[-1].line = ($m.n | if . == null then null else tonumber end)
                | .items[-1].lines = []
              else
                .items[-1].lines += [$l] | .fence = (($l | capture("^\\s*(?<f>`{3,}|~{3,})").f) // false)
              end
            else . end
          | .depth -= $c
          | if .depth < 2 then .cur = false else . end
          | if .depth < 1 then .done = true else . end
        end)
      | [.items[] | {severity, path, line, title,
          body: (.lines | join("\n") | strip_zw | trim_ws)}];

    # The <summary> that opens the missed-issues section, or null. Prose
    # elsewhere in the body that mentions previously missed issues is not it.
    # It may span lines, which missed_items does not parse: then nothing is
    # parsed and missedIssuesUnparsed says to read the body.
    def missed_summary:
      first(capture("(?s)<summary>(?<s>(?:(?!</summary>).)*previously\\s+missed\\s+issue(?:(?!</summary>).)*)</summary>"; "i").s) // null;

    .data.repository.pullRequest as $pr
    | ([$pr.reviews.nodes[] | select((.author.login // "") | test($copilot)) | select(.submittedAt != null)]
       | sort_by(.submittedAt) | last) as $r
    | ($r.body // "") as $body
    | ($body | lowconf_section | lowconf_items) as $items
    | ($body | missed_items) as $missed
    | ($body | missed_summary) as $msum
    | (if $r == null then null else "<!-- check-pr: answered missed issues of review \($r.id) -->" end) as $marker
    | {
        headOid: $pr.headRefOid,
        requested: (any($pr.reviewRequests.nodes[]; (.requestedReviewer.login // "") | test($copilot))
          and any(($pr.timelineItems.nodes // [])[];
            ((.requestedReviewer.login // "") | test($copilot)) and (.createdAt // "") > ($r.submittedAt // ""))),
        review: (if $r == null then null else {id: $r.id, state: $r.state, submittedAt: $r.submittedAt, commit: $r.commit.oid, url: $r.url, body: $body} end),
        stale: ($r != null and $r.commit.oid != $pr.headRefOid),
        missedIssues: [($r.url // "" | capture("^(?<b>https?://[^/]+/[^/]+/[^/]+)/pull/").b) as $base
          | $missed[]
          | . + {url: (if .path == null or $base == null then null
              else "\($base)/blob/\($r.commit.oid)/\(.path | split("/") | map(@uri) | join("/"))"
                + (if .line == null then "" else "#L\(.line)" end) end)}],
        # The count in the summary ("7 previously missed issues"), or 1 when
        # it gives none: there is at least one.
        # A finding without a title or path (a summary that spans lines, say)
        # counts as unparsed too.
        missedIssuesUnparsed: ($msum != null
          and ((($missed | length) < (($msum | capture("(?<n>[0-9]+)").n | tonumber) // 1))
            or any($missed[]; .title == "" or .path == null))),
        missedIssuesMarker: $marker,
        missedIssuesAnswered: false,
        lowConfidence: $items,
        lowConfidenceUnparsed: (($items | length) == 0 and ($body | test("<summary>[^\n]*low confidence|suppressed due to low confidence"; "i"))),
        fallbackReviewedHead: false,
        fallbackLastHead: null,
        fallbackReviewer: null
      }')

# Only read the comments when there is something to answer, or when Copilot
# hasn't reviewed the head and a fallback review may have.
if printf '%s' "$RESULT" | jq -e '(.missedIssuesMarker != null and ((.missedIssues | length) > 0 or .missedIssuesUnparsed))
    or .review == null or .stale' >/dev/null; then
  RESULT=$(gh api graphql --paginate -f query="$COMMENTS_QUERY" -f owner="$OWNER" -f name="$NAME" -F number="$PR" |
    jq -s --argjson result "$RESULT" '
      ($result.missedIssuesMarker) as $marker
      | [.[].data.repository.pullRequest.comments.nodes[]
          | select(.viewerDidAuthor or (.authorAssociation | IN("OWNER", "MEMBER", "COLLABORATOR")))
          | (.body // "") | sub("\\s+$"; "") | split("\n") | last // "" | sub("^\\s+"; "")] as $lasts
      | ([$lasts[] | capture("^<!-- check-pr: fallback review by (?<by>codex|diff-review) of (?<sha>[0-9a-f]{40}) -->$")] | last) as $fb
      | $result
      | .missedIssuesAnswered = ($marker != null and any($lasts[]; . == $marker))
      | .fallbackLastHead = ($fb.sha // null)
      | .fallbackReviewer = ($fb.by // null)
      | .fallbackReviewedHead = ($fb != null and $fb.sha == $result.headOid)')
fi
printf '%s\n' "$RESULT"
