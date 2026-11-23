#!/bin/bash
# Tests for the check-pr scripts. No dependencies beyond bash and jq: `gh` is
# replaced by a stub on PATH that answers from fixture files and logs every
# call. Runs under macOS's bash 3.2.
# Run: bash skills/check-pr/scripts/tests/check-pr.test.sh
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
S="$HERE/.."

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
export FX="$TMP/fx" GH_CALLS="$TMP/calls.log"
mkdir -p "$FX"
# The scripts must find a token on their own, so start without one.
unset GH_TOKEN GITHUB_TOKEN
# `git rebase --exec` and git hooks export GIT_DIR. Left set, the git
# commands below that build a throwaway repo would write to the real one.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_PREFIX

# Stub gh. The GraphQL query text picks the fixture; --jq is applied like gh
# does; every call is logged with the GH_TOKEN it saw.
cat >"$TMP/bin/gh" <<'EOF'
#!/bin/bash
# One line per call, so grep -c counts calls.
echo "GH_TOKEN=${GH_TOKEN:-unset} $*" | tr '\n' ' ' >>"$GH_CALLS"
echo >>"$GH_CALLS"
all="$*"
jqf="" prev=""
for a in "$@"; do
  [ "$prev" = --jq ] && jqf=$a
  prev=$a
done
out() {
  [ -f "$1" ] || { echo "stub: missing fixture $1" >&2; exit 1; }
  if [ -n "$jqf" ]; then jq -r "$jqf" "$1"; else cat "$1"; fi
}
case "$1 ${2:-}" in
  "auth token") echo "${GH_TOKEN:-${GITHUB_TOKEN:-stub-token}}"; exit 0 ;;
  "repo view")
    case "$all" in *defaultBranchRef*) echo main ;; *) echo o/r ;; esac
    exit 0
    ;;
  "pr edit") exit 0 ;;
  "pr view") cat "$FX/base-ref" 2>/dev/null || echo main; exit 0 ;;
esac
case "$all" in
  *addPullRequestReviewThreadReply*) out "$FX/reply.json" ;;
  *resolveReviewThread*) out "$FX/resolve.json" ;;
  *"node(id:"*) out "$FX/node.json" ;;
  *reviewThreads*) cat "$FX"/threads-*.json ;;
  *viewerDidAuthor*) cat "$FX"/comments-*.json ;;
  *latestOpinionatedReviews*) out "$FX/prinfo.json" ;;
  *statusCheckRollup*) out "$FX/checks.json" ;;
  *reviewRequests*) out "$FX/copilot.json" ;;
  *timelineItems*)
    # The Nth read answers from timeline-N.json, or timeline.json without one,
    # so a test can make an event show up late.
    n=$(($(cat "$FX/timeline.count" 2>/dev/null || echo 0) + 1))
    echo "$n" >"$FX/timeline.count"
    if [ -f "$FX/timeline-$n.json" ]; then out "$FX/timeline-$n.json"; else out "$FX/timeline.json"; fi
    ;;
  *defaultBranchRef*) out "$FX/pulls.json" ;;
  *"/compare/"*)
    range=${all#*/compare/}
    range=${range%% *}
    status=$(awk -F'\t' -v r="$range" '$1 == r { print $2 }' "$FX/compare.tsv" 2>/dev/null)
    [ -n "$status" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    printf '{"status":"%s"}' "$status" >"$FX/compare.json"
    out "$FX/compare.json"
    ;;
  *"/actions/jobs/"*"/logs"*) cat "$FX/job.log" ;;
  *) echo "stub: unexpected gh call: $all" >&2; exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

pass=0 fail=0
OUT="" CODE=0

# run SCRIPT ARGS...: stdout to $OUT, exit code to $CODE.
run() {
  local script=$1
  shift
  : >"$GH_CALLS"
  OUT=$(bash "$S/$script" "$@" 2>"$TMP/stderr")
  CODE=$?
}

# check NAME EXPECTED ACTUAL
check() {
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $1"
    echo "      expected: $2"
    echo "      actual:   $3"
    [ -s "$TMP/stderr" ] && sed 's/^/      stderr: /' "$TMP/stderr" | head -5
  fi
}

# q FILTER: jq -c over the last output.
q() { printf '%s' "$OUT" | jq -c "$1" 2>/dev/null || echo "not-json"; }
calls() { grep -c "$1" "$GH_CALLS" || true; }

# ---------------------------------------------------------------- find-pr-pair
cat >"$FX/pulls.json" <<'EOF'
{"data":{"repository":{"defaultBranchRef":{"name":"main"},"pullRequests":{"nodes":[
 {"number":1,"url":"u1","title":"t","isDraft":true,"headRefName":"feat/PROJ-1-thing","baseRefName":"main","headRefOid":"a1"},
 {"number":2,"url":"u2","title":"t","isDraft":false,"headRefName":"feat/PROJ-1-thing","baseRefName":"develop","headRefOid":"a1"},
 {"number":3,"url":"u3","title":"t","isDraft":false,"headRefName":"conflicts/PROJ-1-thing","baseRefName":"staging","headRefOid":"c3"},
 {"number":4,"url":"u4","title":"t","isDraft":false,"headRefName":"conflicts/fix-PROJ-1","baseRefName":"dev","headRefOid":"c4"},
 {"number":5,"url":"u5","title":"t","isDraft":false,"headRefName":"conflicts/renamed","baseRefName":"dev","headRefOid":"c5"},
 {"number":6,"url":"u6","title":"t","isDraft":false,"headRefName":"conflicts/unrelated","baseRefName":"dev","headRefOid":"c6"},
 {"number":7,"url":"u7","title":"t","isDraft":false,"headRefName":"conflicts/PROJ-10-other","baseRefName":"dev","headRefOid":"c7"},
 {"number":8,"url":"u8","title":"t","isDraft":false,"headRefName":"feat/PROJ-10-other","baseRefName":"main","headRefOid":"a8"},
 {"number":9,"url":"u9","title":"t","isDraft":false,"headRefName":"conflicts/feat/PROJ-1-thing","baseRefName":"main","headRefOid":"c9"}
]}}}}
EOF
# base...head -> what GitHub's compare endpoint says; anything else is a 404.
printf 'feat%%2FPROJ-1-thing...conflicts%%2Frenamed\tahead\nfeat%%2FPROJ-1-thing...conflicts%%2Funrelated\tdiverged\n' >"$FX/compare.tsv"

run find-pr-pair.sh -R o/r feat/PROJ-1-thing
check "pair: exit 0" 0 "$CODE"
check "pair: default branch" '"main"' "$(q .defaultBranch)"
check "pair: main PR" 1 "$(q .main.number)"
check "pair: preprod PRs and how they matched" \
  '[[2,"head"],[3,"conflicts-name"],[4,"conflicts-ticket"],[5,"conflicts-ancestry"]]' \
  "$(q '[.preprod[] | [.number, .matchedBy]]')"
check "pair: compare only for name/ticket misses" 3 "$(calls /compare/)"

run find-pr-pair.sh -R o/r feat/PROJ-10-other
check "pair: PROJ-10 does not pick up PROJ-1" '[8,[7]]' "$(q '[.main.number, [.preprod[].number]]')"

run find-pr-pair.sh -R o/r feat/nothing-open
check "pair: no PRs" '[null,[]]' "$(q '[.main, .preprod]')"

run find-pr-pair.sh -R o/r conflicts/PROJ-1-thing
check "pair: refuses a conflicts branch" 2 "$CODE"

run find-pr-pair.sh feat/PROJ-1-thing
check "pair: repo from gh repo view" '"o/r"' "$(q .repo)"
check "pair: exported the token itself" 0 "$(calls 'GH_TOKEN=unset api')"

# An exported GITHUB_TOKEN can have fewer scopes than the keyring login, and
# `gh auth token` would echo it back; the scripts must skip it.
GITHUB_TOKEN=env-token run find-pr-pair.sh feat/ATC-1-thing
check "pair: ignores an exported GITHUB_TOKEN" 0 "$(calls 'GH_TOKEN=env-token')"
check "pair: used the keyring token" 0 "$(grep -v '^GH_TOKEN=stub-token ' "$GH_CALLS" | grep -vc ' auth token' || true)"

# --------------------------------------------------------------- review-threads
cat >"$FX/threads-1.json" <<'EOF'
{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":true,"endCursor":"x"},"nodes":[
 {"id":"T1","isResolved":false,"isOutdated":false,"path":"a.ts","line":3,"startLine":null,
  "comments":{"nodes":[{"author":{"login":"copilot-pull-request-reviewer","__typename":"Bot"},"body":"bug","createdAt":"2026-01-01T00:00:00Z","url":"c1"}]}},
 {"id":"T2","isResolved":true,"isOutdated":false,"path":"b.ts","line":4,"startLine":null,
  "comments":{"nodes":[{"author":{"login":"copilot-pull-request-reviewer","__typename":"Bot"},"body":"done","createdAt":"2026-01-01T00:00:00Z","url":"c2"}]}}
]}}}}}
EOF
cat >"$FX/threads-2.json" <<'EOF'
{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
 {"id":"T3","isResolved":false,"isOutdated":true,"path":"c.ts","line":null,"startLine":null,
  "comments":{"nodes":[
   {"author":{"login":"alice","__typename":"User"},"body":"why?","createdAt":"2026-01-02T00:00:00Z","url":"c3"},
   {"author":{"login":"heyFahad","__typename":"User"},"body":"because","createdAt":"2026-01-03T00:00:00Z","url":"c4"}]}},
 {"id":"T4","isResolved":false,"isOutdated":false,"path":"d.ts","line":9,"startLine":7,
  "comments":{"nodes":[{"author":null,"body":"from a deleted account","createdAt":"2026-01-02T00:00:00Z","url":"c5"}]}}
]}}}}}
EOF

run review-threads.sh -R o/r 12
check "threads: unresolved across pages" '["T1","T3","T4"]' "$(q '[.[].id]')"
check "threads: copilot flagged" '[true,false,false]' "$(q '[.[].isCopilot]')"
check "threads: author types" '["Bot","User","User"]' "$(q '[.[].authorType]')"
check "threads: deleted author" '"ghost"' "$(q '.[2].author')"
check "threads: whole conversation kept" '["alice","heyFahad"]' "$(q '[.[1].comments[].author]')"
check "threads: paginated" 1 "$(calls 'graphql --paginate')"

run review-threads.sh -R o/r 12 --all
check "threads: --all keeps resolved" 4 "$(q length)"

run review-threads.sh -R o/r abc
check "threads: bad PR number" 2 "$CODE"

# --------------------------------------------------------------- copilot-review
# shellcheck disable=SC2016 # literal backticks: a Markdown code fence
LOWCONF='Copilot reviewed 3 files.\n\n<details>\n<summary>Comments suppressed due to low confidence (3)</summary>\n\n**src/a.ts:10**\n* First thought.\n```ts\n* not a bullet\n**src/x.ts:1**\n```\n* Second thought on the same line.\n\n**src/b.ts:20-24**\n* Range comment\nspanning two lines.\n</details>\n\n<details><summary>Show a summary per file</summary>\n\n**not/a/finding.ts:1**\n* table text\n</details>'
# A stale review or none means the comments get read for a fallback marker.
echo '{"data":{"repository":{"pullRequest":{"comments":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}' >"$FX/comments-1.json"
cat >"$FX/copilot.json" <<EOF
{"data":{"repository":{"pullRequest":{"headRefOid":"head2",
 "reviewRequests":{"nodes":[{"requestedReviewer":{"__typename":"User","login":"alice"}}]},
 "reviews":{"nodes":[
  {"id":"R1","state":"COMMENTED","submittedAt":"2026-01-01T00:00:00Z","url":"r1","body":"old","author":{"login":"copilot-pull-request-reviewer"},"commit":{"oid":"head0"}},
  {"id":"R2","state":"COMMENTED","submittedAt":"2026-01-02T00:00:00Z","url":"r2","body":"$LOWCONF","author":{"login":"copilot-pull-request-reviewer"},"commit":{"oid":"head1"}},
  {"id":"R3","state":"APPROVED","submittedAt":"2026-01-03T00:00:00Z","url":"r3","body":"lgtm","author":{"login":"alice"},"commit":{"oid":"head2"}},
  {"id":"R4","state":"PENDING","submittedAt":null,"url":"r4","body":"","author":{"login":"copilot-pull-request-reviewer"},"commit":{"oid":"head2"}}
 ]}}}}}
EOF

run copilot-review.sh -R o/r 12
check "copilot: latest submitted Copilot review" '"R2"' "$(q .review.id)"
check "copilot: stale against head" true "$(q .stale)"
check "copilot: not requested" false "$(q .requested)"
check "copilot: low-confidence locations" '[["src/a.ts",10],["src/a.ts",10],["src/b.ts",20]]' \
  "$(q '[.lowConfidence[] | [.path, .line]]')"
check "copilot: fenced lines stay in the comment" true \
  "$(q '.lowConfidence[0].body | test("not a bullet") and test("src/x.ts:1")')"
check "copilot: multi-line comment" '"Range comment\nspanning two lines."' "$(q '.lowConfidence[2].body')"
check "copilot: parsed, so not unparsed" false "$(q .lowConfidenceUnparsed)"

jq '.data.repository.pullRequest.headRefOid = "head1"
  | .data.repository.pullRequest.reviewRequests.nodes += [{"requestedReviewer":{"__typename":"Bot","login":"Copilot"}}]
  | .data.repository.pullRequest.timelineItems.nodes = [{"createdAt":"2026-01-03T00:00:00Z","requestedReviewer":{"__typename":"Bot","login":"copilot-pull-request-reviewer"}}]
  | .data.repository.pullRequest.reviews.nodes[1].body = "<details>\n<summary>Comments suppressed due to low confidence (1)</summary>\nsomething new\n</details>"' \
  "$FX/copilot.json" >"$FX/c2.json" && mv "$FX/c2.json" "$FX/copilot.json"
run copilot-review.sh -R o/r 12
check "copilot: current review is not stale" false "$(q .stale)"
check "copilot: re-requested" true "$(q .requested)"
check "copilot: unknown low-confidence format flagged" '[[],true]' "$(q '[.lowConfidence, .lowConfidenceUnparsed]')"

echo '{"data":{"repository":{"pullRequest":{"headRefOid":"h","reviewRequests":{"nodes":[]},"reviews":{"nodes":[]}}}}}' >"$FX/copilot.json"
run copilot-review.sh -R o/r 12
check "copilot: no review yet" '[null,false,[]]' "$(q '[.review, .stale, .lowConfidence]')"
check "copilot: no review, no missed issues" '[[],false,null,false]' \
  "$(q '[.missedIssues, .missedIssuesUnparsed, .missedIssuesMarker, .missedIssuesAnswered]')"

# Copilot's newer body format ("<!-- ccr-overview-v2 -->") reports some
# findings only in the body, under "N previously missed issues", with no
# thread. The fixtures are real review bodies from heyFahad/agent-toolkit#26:
# 6007775440 says "No open issues" and has 7 of them, 6007724043 has 2 open
# issues (with threads) and 6 missed ones.
# copilot_fixture BODY_FILE [COMMENT_BODY [AUTHOR_ASSOCIATION]]: one Copilot
# review with that body. The PR's comments come in two pages: an unrelated
# one first, then COMMENT_BODY from someone else (a collaborator unless
# AUTHOR_ASSOCIATION says otherwise), so an answer is only found by reading
# every page.
copilot_fixture() {
  jq -n --rawfile body "$1" '{data: {repository: {pullRequest: {headRefOid: "head1",
    reviewRequests: {nodes: []}, timelineItems: {nodes: []},
    reviews: {nodes: [{id: "R9", state: "COMMENTED", submittedAt: "2026-01-04T00:00:00Z", url: "https://github.com/o/r/pull/12#pullrequestreview-9", body: $body,
      author: {login: "copilot-pull-request-reviewer"}, commit: {oid: "head1"}}]}}}}}' >"$FX/copilot.json"
  echo '{"data":{"repository":{"pullRequest":{"comments":{"pageInfo":{"hasNextPage":true,"endCursor":"c"},"nodes":[
    {"body":"unrelated","viewerDidAuthor":true,"authorAssociation":"OWNER"}]}}}}}' >"$FX/comments-1.json"
  comments_page2 "${2:-}" "${3:-COLLABORATOR}" false
}
# comments_page2 BODY ASSOCIATION VIEWER_DID_AUTHOR: the second page of PR
# comments, empty when BODY is.
comments_page2() {
  jq -n --arg b "$1" --arg a "$2" --argjson v "$3" '{data: {repository: {pullRequest: {comments: {
    pageInfo: {hasNextPage: false, endCursor: null},
    nodes: (if $b == "" then [] else [{body: $b, viewerDidAuthor: $v, authorAssociation: $a}] end)}}}}}' >"$FX/comments-2.json"
}

copilot_fixture "$HERE/fixtures/copilot-review-missed-only.txt"
run copilot-review.sh -R o/r 12
check "missed: all seven parsed" 7 "$(q '.missedIssues | length')"
check "missed: severities" '["High","High","High","High","High","Medium","Medium"]' "$(q '[.missedIssues[].severity]')"
check "missed: zero-width spaces stripped from paths" \
  '[["skills/branching-pr-workflow/SKILL.md",41],["skills/give-pr-review/SKILL.md",24]]' \
  "$(q '[.missedIssues[0,4] | [.path, .line]]')"
check "missed: no zero-width space left anywhere" false "$(q '[.missedIssues[] | .path, .body, .title] | any(test("​"))')"
check "missed: title without the severity image" '"Commit fixes individually and protect staged changes"' "$(q '.missedIssues[0].title')"
check "missed: permalink pinned to the reviewed commit" '"https://github.com/o/r/blob/head1/skills/branching-pr-workflow/SKILL.md#L41"' \
  "$(q '.missedIssues[0].url')"
check "missed: body is the description only" true \
  "$(q '.missedIssues[0].body | startswith("A path-based commit includes") and endswith("user-staged changes.")')"
check "missed: resolved section not counted" false "$(q '[.missedIssues[].title] | any(test("Check rewrite safety"))')"
check "missed: parsed, so not unparsed" false "$(q .missedIssuesUnparsed)"
check "missed: not answered yet" '["<!-- check-pr: answered missed issues of review R9 -->",false]' \
  "$(q '[.missedIssuesMarker, .missedIssuesAnswered]')"
check "missed: no low-confidence section in this format" '[[],false]' "$(q '[.lowConfidence, .lowConfidenceUnparsed]')"

copilot_fixture "$HERE/fixtures/copilot-review-open-and-missed.txt" \
  "$(printf 'Answered.\n<!-- check-pr: answered missed issues of review R9 -->')"
run copilot-review.sh -R o/r 12
check "missed: open issues (threads) not counted" 6 "$(q '.missedIssues | length')"
check "missed: all medium" '["Medium"]' "$(q '[.missedIssues[].severity] | unique')"
check "missed: HTML entities decoded" '"Isolate each finding'"'"'s changes before creating fixup commits"' "$(q '.missedIssues[1].title')"
check "missed: last finding" '["skills/give-pr-review/SKILL.md",24]' "$(q '.missedIssues[-1] | [.path, .line]')"
check "missed: answered by a PR comment with the marker, on a later page" true "$(q .missedIssuesAnswered)"
check "missed: comments read page by page" 1 "$(calls 'graphql --paginate')"

# The marker counts only as the last line: quoting it in instructions is not
# an answer.
copilot_fixture "$HERE/fixtures/copilot-review-open-and-missed.txt" \
  "$(printf 'Append <!-- check-pr: answered missed issues of review R9 --> once you have assessed these.\nThanks.')"
run copilot-review.sh -R o/r 12
check "missed: a quoted marker does not count" false "$(q .missedIssuesAnswered)"
copilot_fixture "$HERE/fixtures/copilot-review-open-and-missed.txt" \
  "$(printf 'Answered.\n  <!-- check-pr: answered missed issues of review R9 -->  \n\n')"
run copilot-review.sh -R o/r 12
check "missed: trailing whitespace around the marker is fine" true "$(q .missedIssuesAnswered)"

# A marker for some other review does not answer this one.
copilot_fixture "$HERE/fixtures/copilot-review-open-and-missed.txt" '<!-- check-pr: answered missed issues of review R1 -->'
run copilot-review.sh -R o/r 12
check "missed: another review's marker does not count" false "$(q .missedIssuesAnswered)"

# On a public repo anyone can comment; only the viewer or a collaborator's
# marker counts.
copilot_fixture "$HERE/fixtures/copilot-review-open-and-missed.txt" '<!-- check-pr: answered missed issues of review R9 -->' NONE
run copilot-review.sh -R o/r 12
check "missed: an outsider's marker does not count" false "$(q .missedIssuesAnswered)"

# A description that mentions the tags in prose must not throw the nesting
# off: the second finding still parses, and the resolved section after the
# missed one is still left out.
# shellcheck disable=SC2016 # literal backticks: code spans
printf '%s\n' '<!-- ccr-overview-v2 -->' '' '**No open issues**' '' '<details>' \
  '<summary><strong>2 previously missed issues</strong></summary>' '' '<details>' \
  '<summary><img alt="High severity"> Count only structural tags</summary>' '' '`a.sh:10`' '' \
  'The parser treats every `<details>` tag as a block opener, and <details> too.' '</details>' \
  '<details>' '<summary><img alt="Low severity"> Second</summary>' '' '`b.sh:20`' '' 'Closing `</details>` in prose.' \
  '</details>' '</details>' '' '<details>' '<summary><strong>1 resolved since last review</strong></summary>' '' \
  '- [x](https://example.test)' '</details>' >"$FX/body.txt"
copilot_fixture "$FX/body.txt"
run copilot-review.sh -R o/r 12
check "missed: tags quoted in a description" \
  '[[["High","a.sh",10,"Count only structural tags"],["Low","b.sh",20,"Second"]],false]' \
  "$(q '[[.missedIssues[] | [.severity, .path, .line, .title]], .missedIssuesUnparsed]')"
# shellcheck disable=SC2016 # literal backticks
check "missed: quoted tags kept in the body" '"Closing `</details>` in prose."' "$(q '.missedIssues[1].body')"

# A collapsed block inside a description stays in the body, and the
# description's entities stay as written (only titles are escaped).
# shellcheck disable=SC2016 # literal backticks: code spans
printf '%s\n' '<details>' '<summary><strong>1 previously missed issue</strong></summary>' '' '<details>' \
  '<summary><img alt="Medium severity"> Don&#39;t drop it</summary>' '' '`c.sh:5`' '' 'Use `a &lt; b`.' \
  '<details>' '<summary>Repro</summary>' '' 'steps' '</details>' 'After.' '</details>' '</details>' >"$FX/body.txt"
copilot_fixture "$FX/body.txt"
run copilot-review.sh -R o/r 12
check "missed: nested block kept, entities only decoded in the title" \
  "$(jq -nc '["Don'"'"'t drop it", "c.sh", 5, "Use `a &lt; b`.\n<details>\n<summary>Repro</summary>\n\nsteps\n</details>\nAfter.", false]')" \
  "$(q '[(.missedIssues[0] | .title, .path, .line, .body), .missedIssuesUnparsed]')"

# A longer or tilde fence only closes on a bare fence of the same kind, so
# a shorter fence or a </details> inside it stays in the body.
# shellcheck disable=SC2016 # literal backticks: code fences
printf '%s\n' '<details>' '<summary><strong>2 previously missed issues</strong></summary>' '' \
  '<details>' '<summary>Four</summary>' '' '`a.md:1`' '' '````md' '```sh' '</details>' '```' '````' 'After four.' '</details>' \
  '<details>' '<summary>Tilde</summary>' '' '`b.md:2`' '' '~~~' '</details>' '~~~~' 'After tilde.' '</details>' \
  '</details>' >"$FX/body.txt"
copilot_fixture "$FX/body.txt"
run copilot-review.sh -R o/r 12
check "missed: long and tilde fences" \
  "$(jq -nc '[["Four","````md\n```sh\n</details>\n```\n````\nAfter four."],["Tilde","~~~\n</details>\n~~~~\nAfter tilde."],false]')" \
  "$(q '[(.missedIssues[] | [.title, .body]), .missedIssuesUnparsed]')"

# shellcheck disable=SC2016 # literal backticks: a code span
# A finding summary wrapped across lines leaves its title and path empty:
# counted, but flagged.
printf '%s\n' '<details>' '<summary><strong>1 previously missed issue</strong></summary>' '' \
  '<details>' '<summary>' 'Wrapped title' '</summary>' '' '`a.md:1`' '' 'Text.' '</details>' '</details>' >"$FX/body.txt"
copilot_fixture "$FX/body.txt"
run copilot-review.sh -R o/r 12
check "missed: finding without a title flagged" '[1,true]' "$(q '[(.missedIssues | length), .missedIssuesUnparsed]')"
check "missed: no path, no permalink" null "$(q '.missedIssues[0].url')"

# A summary wrapped across lines isn't parsed, so it must be flagged.
# shellcheck disable=SC2016 # literal backticks: a code span
printf '%s\n' '<details>' '<summary>' '<strong>2 previously missed issues</strong>' '</summary>' '' '<details>' \
  '<summary>One</summary>' '' '`a.ts:1`' '' 'Text.' '</details>' '</details>' >"$FX/body.txt"
copilot_fixture "$FX/body.txt"
run copilot-review.sh -R o/r 12
check "missed: wrapped section summary flagged" true "$(q .missedIssuesUnparsed)"

# The section is there, but its findings are in a shape the parser does not
# know: flag it rather than report nothing.
printf '<!-- ccr-overview-v2 -->\n\n**No open issues**\n\n<details>\n<summary><strong>2 previously missed issues</strong></summary>\n\n- **a.ts:1** something\n- **b.ts:2** else\n</details>\n' >"$FX/body.txt"
copilot_fixture "$FX/body.txt"
run copilot-review.sh -R o/r 12
check "missed: unknown format flagged" '[[],true]' "$(q '[.missedIssues, .missedIssuesUnparsed]')"

# Prose that mentions previously missed issues is not the section (Copilot's
# own "What changed" summary of PR 27 did), and nothing needs answering, so
# the PR's comments aren't read.
printf '<!-- ccr-overview-v2 -->\n\n<details>\n<summary><strong>What changed in this PR</strong></summary>\n\n- Parses 3 previously missed issues and tracks them.\n</details>\n' >"$FX/body.txt"
copilot_fixture "$FX/body.txt"
run copilot-review.sh -R o/r 12
check "missed: prose mention is not a section" '[[],false,false]' "$(q '[.missedIssues, .missedIssuesUnparsed, .missedIssuesAnswered]')"
check "missed: no comments read when nothing needs answering" 0 "$(calls viewerDidAuthor)"

# Fewer parsed than announced also counts as unparsed.
# shellcheck disable=SC2016 # literal backticks: a code span
printf '<details>\n<summary><strong>2 previously missed issues</strong></summary>\n\n<details>\n<summary>Only one</summary>\n\n`a.ts:3`\n\nText.\n</details>\n</details>\n' >"$FX/body.txt"
copilot_fixture "$FX/body.txt"
run copilot-review.sh -R o/r 12
check "missed: partial parse flagged" '[[null,"a.ts",3,"Only one","Text."],true]' \
  "$(q '[(.missedIssues[0] | [.severity, .path, .line, .title, .body]), .missedIssuesUnparsed]')"

# ------------------------------------------------- copilot-review: requests
# A request counts as pending only when Copilot is listed AND a request event
# for it reached the timeline after its latest review. When its credits run
# out, GitHub accepts the request but no event appears.
# copilot_request LISTED EVENT_AT: Copilot listed in reviewRequests or not
# (true/false), and one request event at EVENT_AT ("" for none). The fixture
# review was submitted 2026-01-04.
copilot_request() {
  jq --argjson listed "$1" --arg at "$2" '
    .data.repository.pullRequest.reviewRequests.nodes = (if $listed then [{requestedReviewer: {__typename: "Bot", login: "Copilot"}}] else [] end)
    | .data.repository.pullRequest.timelineItems.nodes = (if $at == "" then [] else
        [{createdAt: $at, requestedReviewer: {__typename: "Bot", login: "copilot-pull-request-reviewer"}}] end)' \
    "$FX/copilot.json" >"$FX/c2.json" && mv "$FX/c2.json" "$FX/copilot.json"
}
: >"$FX/empty.txt"
copilot_fixture "$FX/empty.txt"
copilot_request true 2026-01-05T00:00:00Z
run copilot-review.sh -R o/r 12
check "requested: listed and an event after the last review" true "$(q .requested)"
copilot_request true 2026-01-03T00:00:00Z
run copilot-review.sh -R o/r 12
check "requested: listed but no event since the last review (declined)" false "$(q .requested)"
copilot_request false 2026-01-05T00:00:00Z
run copilot-review.sh -R o/r 12
check "requested: event but not listed" false "$(q .requested)"
jq '.data.repository.pullRequest.reviews.nodes = []' "$FX/copilot.json" >"$FX/c2.json" && mv "$FX/c2.json" "$FX/copilot.json"
copilot_request true 2000-01-01T00:00:00Z
run copilot-review.sh -R o/r 12
check "requested: no review yet, any event counts" true "$(q .requested)"

# ------------------------------------------ copilot-review: fallback markers
# When Copilot declines, check-pr reviews with Codex or diff-review and
# answers in a PR comment whose last line names the head it reviewed.
H40=0123456789abcdef0123456789abcdef01234567
OLD40=fedcba9876543210fedcba9876543210fedcba98
# fallback_fixture COMMENT [ASSOCIATION]: a Copilot review of an older commit
# (so stale), no missed issues, head H40, and COMMENT on page 2.
fallback_fixture() {
  copilot_fixture "$FX/empty.txt" "$1" "${2:-COLLABORATOR}"
  jq --arg h "$H40" '.data.repository.pullRequest.headRefOid = $h' "$FX/copilot.json" >"$FX/c2.json" && mv "$FX/c2.json" "$FX/copilot.json"
}
fallback_fixture "$(printf 'Reviewed.\n<!-- check-pr: fallback review by codex of %s -->' "$H40")"
run copilot-review.sh -R o/r 12
check "fallback: marker for the head counts" "[true,\"$H40\",\"codex\"]" \
  "$(q '[.fallbackReviewedHead, .fallbackLastHead, .fallbackReviewer]')"
check "fallback: comments read when the review is stale even with no missed issues" 1 "$(calls 'graphql --paginate')"
fallback_fixture "$(printf 'Reviewed.\n<!-- check-pr: fallback review by diff-review of %s -->' "$OLD40")"
run copilot-review.sh -R o/r 12
check "fallback: marker for an older head" "[false,\"$OLD40\",\"diff-review\"]" \
  "$(q '[.fallbackReviewedHead, .fallbackLastHead, .fallbackReviewer]')"
fallback_fixture "<!-- check-pr: fallback review by codex of $H40 -->" NONE
run copilot-review.sh -R o/r 12
check "fallback: an outsider's marker does not count" '[false,null,null]' \
  "$(q '[.fallbackReviewedHead, .fallbackLastHead, .fallbackReviewer]')"
fallback_fixture "Run the fallback, then end with <!-- check-pr: fallback review by codex of $H40 --> please."
run copilot-review.sh -R o/r 12
check "fallback: a quoted marker does not count" '[false,null,null]' \
  "$(q '[.fallbackReviewedHead, .fallbackLastHead, .fallbackReviewer]')"
copilot_fixture "$FX/empty.txt"
run copilot-review.sh -R o/r 12
check "fallback: current review, nothing to answer, comments not read" 0 "$(calls 'graphql --paginate')"
check "fallback: no comments read, no marker" '[false,null,null]' \
  "$(q '[.fallbackReviewedHead, .fallbackLastHead, .fallbackReviewer]')"

# -------------------------------------------------------------- request-copilot
# request-copilot.sh notes the Copilot request events already on each PR's
# timeline, requests Copilot, then reads the timeline until a new one shows
# up, or gives up: Copilot declined. The first read of each PR is the
# snapshot.
export CHECK_PR_REQUEST_DELAY=0
# timeline_fixture FILE [EVENT_ID]: a timeline with one Copilot request event
# with that id, or none.
timeline_fixture() {
  jq -n --arg id "${2:-}" '{data: {repository: {pullRequest: {timelineItems: {nodes:
    (if $id == "" then [] else [{id: $id, createdAt: "2026-01-05T00:00:00Z", requestedReviewer: {__typename: "Bot", login: "copilot-pull-request-reviewer"}}] end)}}}}}' >"$1"
}
reset_timeline() { rm -f "$FX"/timeline*.json "$FX/timeline.count"; }

reset_timeline
timeline_fixture "$FX/timeline-1.json"
timeline_fixture "$FX/timeline.json" E1
run request-copilot.sh -R o/r 12
check "request: new event on the first read after the request" '[[12,true]]' "$(q '[.[] | [.pr, .accepted]]')"
check "request: one request with @copilot" 1 "$(calls 'pr edit -R o/r 12 --add-reviewer @copilot')"
check "request: snapshot plus one read" 2 "$(calls timelineItems)"

reset_timeline
for n in 1 2 3; do timeline_fixture "$FX/timeline-$n.json"; done
timeline_fixture "$FX/timeline.json" E1
run request-copilot.sh -R o/r 12
check "request: event lags to the third read" '[[12,true],4]' "$(printf '[%s,%s]' "$(q '[.[] | [.pr, .accepted]][0]')" "$(calls timelineItems)")"

reset_timeline
timeline_fixture "$FX/timeline.json"
run request-copilot.sh -R o/r 12
check "request: no new event within the window (declined)" '[[12,false],7]' "$(printf '[%s,%s]' "$(q '[.[] | [.pr, .accepted]][0]')" "$(calls timelineItems)")"
check "request: requestedAt is an ISO time" true "$(q '.[0].requestedAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")')"

# An event from an earlier request, however recent, is not this one.
reset_timeline
timeline_fixture "$FX/timeline.json" E0
run request-copilot.sh -R o/r 12
check "request: an event already there before the request does not count" '[[12,false]]' "$(q '[.[] | [.pr, .accepted]]')"

reset_timeline
timeline_fixture "$FX/timeline-1.json"
timeline_fixture "$FX/timeline-2.json"
timeline_fixture "$FX/timeline.json" E1
run request-copilot.sh -R o/r 12 13
check "request: two PRs, one entry each" '[[12,true],[13,true]]' "$(q '[.[] | [.pr, .accepted]]')"
check "request: two PRs, one call each" 2 "$(calls 'pr edit')"

reset_timeline
run request-copilot.sh -R o/r 12
check "request: a failed timeline lookup exits 2, not declined" 2 "$CODE"
reset_timeline
timeline_fixture "$FX/timeline-1.json"
run request-copilot.sh -R o/r 12
check "request: a lookup failing after the snapshot exits 2, not declined" 2 "$CODE"

run request-copilot.sh -R o/r 12 x
check "request: non-number PR exits 2" 2 "$CODE"
check "request: nothing requested on bad usage" 0 "$(calls 'pr edit')"
unset CHECK_PR_REQUEST_DELAY

# -------------------------------------------------------------- fallback-review
# fallback-review.sh picks the reviewer (Codex when usable, else diff-review)
# and the range, and runs Codex. It runs in a checkout at the PR's head.
REPO_DIR="$TMP/repo"
git init -q "$REPO_DIR"
for c in c0 c1 c2; do
  git -C "$REPO_DIR" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "$c"
done
C0=$(git -C "$REPO_DIR" rev-parse HEAD~2) C1=$(git -C "$REPO_DIR" rev-parse HEAD~1) C2=$(git -C "$REPO_DIR" rev-parse HEAD)
git -C "$REPO_DIR" update-ref refs/remotes/origin/main "$C1"

mkdir -p "$TMP/codexbin"
export CODEX_LOG="$TMP/codex.log"
cat >"$TMP/codexbin/codex" <<'EOF'
#!/bin/bash
echo "$*" >>"$CODEX_LOG"
if [ "$1 ${2:-}" = "login status" ]; then exit "$(cat "$FX/codex-login" 2>/dev/null || echo 0)"; fi
if [ "$1" = review ]; then
  echo "GIT_DIR=${GIT_DIR:-unset} GIT_WORK_TREE=${GIT_WORK_TREE:-unset}" >>"$CODEX_LOG"
  # Real codex, after an error, prints it and then hangs instead of exiting.
  if [ -f "$FX/codex-error" ]; then echo "ERROR: $(cat "$FX/codex-error")"; sleep 30; fi
  [ -f "$FX/codex-hang" ] && sleep 30
  echo "codex review text"
  exit "$(cat "$FX/codex-review" 2>/dev/null || echo 0)"
fi
exit 0
EOF
chmod +x "$TMP/codexbin/codex"
export XDG_CONFIG_HOME="$TMP/config"

# review_fixture REVIEW_COMMIT [MARKER_SHA]: head C2, a Copilot review of
# REVIEW_COMMIT ("" for no review), and a fallback marker naming MARKER_SHA.
review_fixture() {
  jq -n --arg h "$C2" --arg rc "$1" '{data: {repository: {pullRequest: {headRefOid: $h,
    reviewRequests: {nodes: []}, timelineItems: {nodes: []},
    reviews: {nodes: (if $rc == "" then [] else [{id: "R9", state: "COMMENTED", submittedAt: "2026-01-04T00:00:00Z",
      url: "https://github.com/o/r/pull/12#pullrequestreview-9", body: "", author: {login: "copilot-pull-request-reviewer"}, commit: {oid: $rc}}] end)}}}}}' >"$FX/copilot.json"
  echo '{"data":{"repository":{"pullRequest":{"comments":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}' >"$FX/comments-1.json"
  if [ -n "${2:-}" ]; then
    comments_page2 "<!-- check-pr: fallback review by codex of $2 -->" OWNER true
  else
    comments_page2 "" OWNER true
  fi
  : >"$CODEX_LOG"
  rm -f "$FX/codex-login" "$FX/codex-review" "$FX/codex-error" "$FX/codex-hang"
}
# PATH without any directory that holds a real codex, so tests never run it.
NOCODEX_PATH=$(printf '%s' "$PATH" | tr ':' '\n' | while IFS= read -r d; do
  [ -x "$d/codex" ] || printf '%s:' "$d"
done)
NOCODEX_PATH=${NOCODEX_PATH%:}
# fallback: run fallback-review.sh from the repo, with or without the codex
# stub on PATH.
fallback() {
  local path=$NOCODEX_PATH
  [ "${NO_CODEX:-}" = 1 ] || path="$TMP/codexbin:$NOCODEX_PATH"
  cd "$REPO_DIR" || exit 1
  PATH=$path run fallback-review.sh -R o/r 12
  cd - >/dev/null || exit 1
}

review_fixture ""
fallback
check "fallback: codex when logged in" "[\"codex\",\"$C1\",\"$C2\"]" "$(q '[.reviewer, .base, .head]')"
check "fallback: codex output saved" "codex review text" "$(cat "$(printf '%s' "$OUT" | jq -r .output)" 2>/dev/null)"
check "fallback: codex reviews against the base" "review --base $C1" "$(grep '^review' "$CODEX_LOG")"

check "fallback: codex is pointed at the repo explicitly (it can't read a worktree on its own)" \
  "GIT_DIR=$(git -C "$REPO_DIR" rev-parse --absolute-git-dir) GIT_WORK_TREE=$(cd "$REPO_DIR" && pwd -P)" \
  "$(grep '^GIT_DIR' "$CODEX_LOG")"

export CHECK_PR_CODEX_POLL=0.2
review_fixture ""
echo '"/x" is not a git repository' >"$FX/codex-error"
SECONDS=0
fallback
check "fallback: codex prints an error and hangs, stopped at once" '["diff-review",true]' \
  "$(q '[.reviewer, (.reason | test("is not a git repository"))]')"
check "fallback: the error is caught without waiting out the hang" true "$([ "$SECONDS" -lt 10 ] && echo true || echo false)"

review_fixture ""
touch "$FX/codex-hang"
SECONDS=0
CHECK_PR_CODEX_TIMEOUT=1 fallback
check "fallback: codex past its time limit" '["diff-review",true]' "$(q '[.reviewer, (.reason | test("time limit"))]')"
check "fallback: the time limit is kept" true "$([ "$SECONDS" -lt 10 ] && echo true || echo false)"
unset CHECK_PR_CODEX_POLL

review_fixture "$C0"
fallback
check "fallback: base is Copilot's last reviewed commit" "\"$C0\"" "$(q .base)"

review_fixture "$C0" "$C1"
fallback
check "fallback: base is the last fallback-reviewed head first" "\"$C1\"" "$(q .base)"

review_fixture "$C0" "$C2"
fallback
check "fallback: head already reviewed, nothing to do" '[null,0]' "$(printf '[%s,%s]' "$(q .reviewer)" "$(grep -c '^review' "$CODEX_LOG")")"

# After a rebase and force-push, the old reviewed commit is still in this
# checkout but no longer an ancestor of the head: it must not be the base.
git -C "$REPO_DIR" -c user.email=t@t -c user.name=t commit-tree "$C1^{tree}" -p "$C0" -m orphan >"$TMP/orphan"
ORPHAN=$(cat "$TMP/orphan")
review_fixture "$ORPHAN" "$ORPHAN"
fallback
check "fallback: a commit that isn't an ancestor of the head is skipped" "\"$C1\"" "$(q .base)"

# The first fallback review of a pre-prod PR starts from its own base
# branch, not the default branch.
review_fixture ""
echo staging >"$FX/base-ref"
git -C "$REPO_DIR" update-ref refs/remotes/origin/staging "$C0"
fallback
check "fallback: merge base with the PR's own base branch" "\"$C0\"" "$(q .base)"
rm -f "$FX/base-ref"

review_fixture ""
mkdir -p "$XDG_CONFIG_HOME/agent-toolkit"
echo '{"codexModel":"m-1"}' >"$XDG_CONFIG_HOME/agent-toolkit/verify.local.json"
fallback
check "fallback: model from config" "review --base $C1 -c model=\"m-1\"" "$(grep '^review' "$CODEX_LOG")"
rm "$XDG_CONFIG_HOME/agent-toolkit/verify.local.json"

review_fixture ""
echo 1 >"$FX/codex-login"
fallback
check "fallback: codex logged out" '["diff-review",true,null]' "$(q '[.reviewer, (.reason | test("codex login status")), .output]')"
check "fallback: logged out, codex review never runs" 0 "$(grep -c '^review' "$CODEX_LOG")"

review_fixture ""
NO_CODEX=1 fallback
check "fallback: codex not installed" '["diff-review",true]' "$(q '[.reviewer, (.reason | test("not on PATH"))]')"

review_fixture ""
echo 1 >"$FX/codex-review"
fallback
check "fallback: codex review fails, still exits 0" 0 "$CODE"
check "fallback: codex review fails" '["diff-review",true,null]' "$(q '[.reviewer, (.reason | test("exited 1")), .output]')"

# Codex's --base review diffs the working tree, so local edits would be
# reviewed instead of the PR.
review_fixture ""
echo edit >"$REPO_DIR/tracked.txt"
git -C "$REPO_DIR" add tracked.txt
fallback
check "fallback: uncommitted changes exit 2" 2 "$CODE"
check "fallback: uncommitted changes, codex never runs" 0 "$(grep -c '^review' "$CODEX_LOG")"
git -C "$REPO_DIR" rm -q --cached tracked.txt && rm "$REPO_DIR/tracked.txt"

review_fixture ""
jq '.data.repository.pullRequest.headRefOid = "1111111111111111111111111111111111111111"' "$FX/copilot.json" >"$FX/c2.json" && mv "$FX/c2.json" "$FX/copilot.json"
fallback
check "fallback: wrong checkout exits 2" 2 "$CODE"
check "fallback: wrong checkout names the expected head" true "$(grep -q 1111111111111111111111111111111111111111 "$TMP/stderr" && echo true || echo false)"

# ----------------------------------------------------------------- reply-thread
echo '{"data":{"addPullRequestReviewThreadReply":{"comment":{"url":"https://example.test/reply"}}}}' >"$FX/reply.json"
echo '{"data":{"resolveReviewThread":{"thread":{"isResolved":true}}}}' >"$FX/resolve.json"
BOT_NODE='{"data":{"node":{"isResolved":false,"comments":{"nodes":[{"author":{"login":"copilot-pull-request-reviewer","__typename":"Bot"}}]}}}}'
HUMAN_NODE='{"data":{"node":{"isResolved":false,"comments":{"nodes":[{"author":{"login":"alice","__typename":"User"}}]}}}}'

echo "$BOT_NODE" >"$FX/node.json"
run reply-thread.sh T1 --body "Fixed in abc1234." --resolve
check "reply: bot thread replied and resolved" '["https://example.test/reply",true]' "$(q '[.replyUrl, .resolved]')"
check "reply: one reply" 1 "$(calls addPullRequestReviewThreadReply)"
check "reply: one resolve" 1 "$(calls resolveReviewThread)"
check "reply: body sent as given" 1 "$(calls 'body=Fixed in abc1234.')"

echo "$HUMAN_NODE" >"$FX/node.json"
run reply-thread.sh T3 --body "Done." --resolve
check "reply: human thread refused" 3 "$CODE"
check "reply: nothing posted when refused" 0 "$(calls 'mutation')"

run reply-thread.sh T3 --body "Done, see abc1234."
check "reply: human thread reply only" '["https://example.test/reply",false]' "$(q '[.replyUrl, .resolved]')"
check "reply: never resolved" 0 "$(calls resolveReviewThread)"

echo "$BOT_NODE" >"$FX/node.json"
OUT=$(printf 'Not applicable: the value is validated upstream.\n' | bash "$S/reply-thread.sh" T1 --body-file - 2>/dev/null)
check "reply: body from stdin" 1 "$(calls 'body=Not applicable: the value is validated upstream.')"

run reply-thread.sh T1 --body "   "
check "reply: blank body rejected" 2 "$CODE"
run reply-thread.sh T1
check "reply: missing body rejected" 2 "$CODE"

echo '{"data":{"node":null}}' >"$FX/node.json"
run reply-thread.sh BAD --body "x"
check "reply: unknown thread" 2 "$CODE"

# -------------------------------------------------------------------- ci-status
cat >"$FX/checks.json" <<'EOF'
{"data":{"repository":{"pullRequest":{"headRefOid":"head2","commits":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"pageInfo":{"hasNextPage":false},"nodes":[
 {"__typename":"CheckRun","databaseId":101,"name":"Lint","status":"COMPLETED","conclusion":"SUCCESS","detailsUrl":"d101","startedAt":"2026-01-01T00:00:00Z","checkSuite":{"app":{"slug":"github-actions"},"workflowRun":{"databaseId":11,"workflow":{"name":"CI"}}}},
 {"__typename":"CheckRun","databaseId":102,"name":"Test","status":"COMPLETED","conclusion":"FAILURE","detailsUrl":"d102","startedAt":"2026-01-01T00:00:00Z","checkSuite":{"app":{"slug":"github-actions"},"workflowRun":{"databaseId":11,"workflow":{"name":"CI"}}}},
 {"__typename":"CheckRun","databaseId":103,"name":"Typecheck","status":"COMPLETED","conclusion":"FAILURE","detailsUrl":"d103","startedAt":"2026-01-01T00:00:00Z","checkSuite":{"app":{"slug":"github-actions"},"workflowRun":{"databaseId":11,"workflow":{"name":"CI"}}}},
 {"__typename":"CheckRun","databaseId":104,"name":"Typecheck","status":"COMPLETED","conclusion":"SUCCESS","detailsUrl":"d104","startedAt":"2026-01-01T01:00:00Z","checkSuite":{"app":{"slug":"github-actions"},"workflowRun":{"databaseId":12,"workflow":{"name":"CI"}}}},
 {"__typename":"CheckRun","databaseId":105,"name":"Socket Security: Pull Request Alerts","status":"COMPLETED","conclusion":"FAILURE","detailsUrl":"d105","startedAt":"2026-01-01T00:00:00Z","checkSuite":{"app":{"slug":"socket-security"},"workflowRun":null}},
 {"__typename":"CheckRun","databaseId":106,"name":"security / Gitleaks secret detection","status":"IN_PROGRESS","conclusion":null,"detailsUrl":"d106","startedAt":"2026-01-01T00:00:00Z","checkSuite":{"app":{"slug":"github-actions"},"workflowRun":{"databaseId":13,"workflow":{"name":"security"}}}},
 {"__typename":"CheckRun","databaseId":107,"name":"send-slack-message","status":"COMPLETED","conclusion":"SKIPPED","detailsUrl":"d107","startedAt":"2026-01-01T00:00:00Z","checkSuite":{"app":{"slug":"github-actions"},"workflowRun":{"databaseId":14,"workflow":{"name":"notify"}}}},
 {"__typename":"CheckRun","databaseId":108,"name":"copilot-pull-request-reviewer","status":"IN_PROGRESS","conclusion":null,"detailsUrl":"d108","startedAt":"2026-01-01T00:00:00Z","checkSuite":{"app":{"slug":"github-actions"},"workflowRun":{"databaseId":15,"workflow":{"name":"Copilot code review"}}}},
 {"__typename":"StatusContext","context":"ci/legacy","state":"EXPECTED","targetUrl":"s1","createdAt":"2026-01-01T00:00:00Z"}
]}}}}]}}}}}
EOF

run ci-status.sh -R o/r 12
check "ci: failing checks" '[["Socket Security: Pull Request Alerts",null],["Test",102]]' \
  "$(q '[.failing[] | [.name, .jobId]] | sort')"
check "ci: a re-run that passed is not failing" '"SUCCESS"' "$(q '.failing | map(.name) | if index("Typecheck") then "FAILURE" else "SUCCESS" end')"
check "ci: pending checks and statuses" '["ci/legacy","security / Gitleaks secret detection"]' "$(q '[.pending[].name] | sort')"
check "ci: copilot review is not CI" '["copilot-pull-request-reviewer","PENDING"]' "$(q '[.copilotCheck.name, .copilotCheck.state]')"
check "ci: counts" '{"FAILURE":2,"PENDING":2,"SKIPPED":1,"SUCCESS":2}' "$(q .counts)"
check "ci: total excludes copilot" 7 "$(q .total)"
check "ci: run id kept" 11 "$(q '.failing[] | select(.name == "Test") | .runId')"

echo '{"data":{"repository":{"pullRequest":{"headRefOid":"h","commits":{"nodes":[{"commit":{"statusCheckRollup":null}}]}}}}}' >"$FX/checks_none.json"
cp "$FX/checks.json" "$FX/checks_full.json"
cp "$FX/checks_none.json" "$FX/checks.json"
run ci-status.sh -R o/r 12
check "ci: no checks at all" '[0,[],[],null]' "$(q '[.total, .failing, .pending, .copilotCheck]')"
cp "$FX/checks_full.json" "$FX/checks.json"

# ---------------------------------------------------------------------- job-log
{
  printf '\xef\xbb\xbf2026-01-01T00:00:00.0000000Z ##[group]Run tests\n'
  for i in 1 2 3 4 5; do printf '2026-01-01T00:00:0%s.1234567Z line %s\n' "$i" "$i"; done
  printf '2026-01-01T00:00:09.0000000Z ##[error]Process completed with exit code 1.\n'
} >"$FX/job.log"
run job-log.sh -R o/r 102 3
check "log: tail without timestamps" "$(printf 'line 4\nline 5\n##[error]Process completed with exit code 1.')" "$OUT"
check "log: right endpoint" 1 "$(calls 'api repos/o/r/actions/jobs/102/logs')"
run job-log.sh -R o/r abc
check "log: bad job id" 2 "$CODE"

# ---------------------------------------------------------------------- pr-gate
# Not clean: the fixtures above have a failing check, a pending one,
# unresolved threads and (below) a human asking for changes.
cat >"$FX/copilot.json" <<'EOF'
{"data":{"repository":{"pullRequest":{"headRefOid":"head2","reviewRequests":{"nodes":[]},
 "reviews":{"nodes":[{"id":"R2","state":"COMMENTED","submittedAt":"2026-01-02T00:00:00Z","url":"r2","body":"ok","author":{"login":"copilot-pull-request-reviewer"},"commit":{"oid":"head1"}}]}}}}}
EOF
cat >"$FX/prinfo.json" <<'EOF'
{"data":{"repository":{"pullRequest":{"isDraft":true,"mergeable":"MERGEABLE","latestOpinionatedReviews":{"nodes":[
 {"state":"CHANGES_REQUESTED","author":{"login":"alice","__typename":"User"}},
 {"state":"APPROVED","author":{"login":"bob","__typename":"User"}},
 {"state":"CHANGES_REQUESTED","author":{"login":"some-bot","__typename":"Bot"}}
]}}}}}
EOF
run pr-gate.sh -R o/r 12
check "gate: not clean exits 1" 1 "$CODE"
check "gate: clean false" false "$(q .clean)"
check "gate: blocking reasons" '["ci-failing","ci-pending","unresolved-threads","changes-requested"]' "$(q '[.blocking[].reason]')"
check "gate: only humans count for changes requested" '"alice"' "$(q '.blocking[] | select(.reason == "changes-requested") | .detail')"
check "gate: thread breakdown" '"3 unresolved: 1 from Copilot, 2 from humans, 0 from other bots"' \
  "$(q '.blocking[] | select(.reason == "unresolved-threads") | .detail')"
check "gate: warnings" '["copilot-stale","draft"]' "$(q '[.warnings[].reason]')"
check "gate: nested gh calls all had the token" 0 "$(calls 'GH_TOKEN=unset api')"
check "gate: token was the one from gh auth token" 0 "$(grep -v '^GH_TOKEN=stub-token ' "$GH_CALLS" | grep -vc ' auth token' || true)"

# Clean: no threads, CI green, approvals only, Copilot current.
rm -f "$FX"/threads-*.json
echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}' >"$FX/threads-1.json"
echo '{"data":{"repository":{"pullRequest":{"headRefOid":"head2","commits":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"pageInfo":{"hasNextPage":false},"nodes":[
 {"__typename":"CheckRun","databaseId":1,"name":"Test","status":"COMPLETED","conclusion":"SUCCESS","detailsUrl":"d","startedAt":"2026-01-01T00:00:00Z","checkSuite":{"app":{"slug":"github-actions"},"workflowRun":{"databaseId":1,"workflow":{"name":"CI"}}}}
]}}}}]}}}}}' >"$FX/checks.json"
jq '.data.repository.pullRequest.reviews.nodes[0].commit.oid = "head2"' "$FX/copilot.json" >"$FX/c2.json" && mv "$FX/c2.json" "$FX/copilot.json"
echo '{"data":{"repository":{"pullRequest":{"isDraft":false,"mergeable":"MERGEABLE","latestOpinionatedReviews":{"nodes":[{"state":"APPROVED","author":{"login":"bob","__typename":"User"}}]}}}}}' >"$FX/prinfo.json"
run pr-gate.sh -R o/r 12
check "gate: clean exits 0" 0 "$CODE"
check "gate: clean, nothing to report" '[true,[],[]]' "$(q '[.clean, .blocking, .warnings]')"

# A requested Copilot review and a merge conflict each block on their own.
jq '.data.repository.pullRequest.reviewRequests.nodes = [{"requestedReviewer":{"__typename":"Bot","login":"copilot-pull-request-reviewer"}}]
  | .data.repository.pullRequest.timelineItems.nodes = [{"createdAt":"2026-01-03T00:00:00Z","requestedReviewer":{"__typename":"Bot","login":"copilot-pull-request-reviewer"}}]' "$FX/copilot.json" >"$FX/c2.json" && mv "$FX/c2.json" "$FX/copilot.json"
jq '.data.repository.pullRequest.mergeable = "CONFLICTING"' "$FX/prinfo.json" >"$FX/p2.json" && mv "$FX/p2.json" "$FX/prinfo.json"
run pr-gate.sh -R o/r 12
check "gate: copilot pending and conflicts block" '["copilot-pending","merge-conflict"]' "$(q '[.blocking[].reason]')"

# A review that says "No open issues" is still not clean while previously
# missed issues in its body are unanswered.
jq '.data.repository.pullRequest.mergeable = "MERGEABLE"' "$FX/prinfo.json" >"$FX/p2.json" && mv "$FX/p2.json" "$FX/prinfo.json"
copilot_fixture "$HERE/fixtures/copilot-review-missed-only.txt"
jq '.data.repository.pullRequest.headRefOid = "head2" | .data.repository.pullRequest.reviews.nodes[0].commit.oid = "head2"' \
  "$FX/copilot.json" >"$FX/c2.json" && mv "$FX/c2.json" "$FX/copilot.json"
run pr-gate.sh -R o/r 12
check "gate: missed issues block" '["missed-issues"]' "$(q '[.blocking[].reason]')"
check "gate: missed issues detail" '"the Copilot review body lists 7 previously missed issue(s) with no thread: 5 High, 2 Medium"' \
  "$(q '.blocking[0].detail')"

comments_page2 "$(printf 'Done.\n<!-- check-pr: answered missed issues of review R9 -->')" NONE true
run pr-gate.sh -R o/r 12
check "gate: answered missed issues no longer block" '[true,[]]' "$(q '[.clean, .blocking]')"

copilot_fixture "$FX/body.txt"
jq '.data.repository.pullRequest.headRefOid = "head2" | .data.repository.pullRequest.reviews.nodes[0].commit.oid = "head2"
  | .data.repository.pullRequest.reviews.nodes[0].body = "<details>\n<summary><strong>3 previously missed issues</strong></summary>\nnew shape\n</details>"' \
  "$FX/copilot.json" >"$FX/c2.json" && mv "$FX/c2.json" "$FX/copilot.json"
run pr-gate.sh -R o/r 12
check "gate: unparsed missed issues block" '["missed-issues"]' "$(q '[.blocking[].reason]')"

# A partial parse says there is more to read.
# shellcheck disable=SC2016 # literal backticks: a code span
printf '<details>\n<summary><strong>2 previously missed issues</strong></summary>\n\n<details>\n<summary><img alt="High severity"> Only one</summary>\n\n`a.ts:3`\n\nText.\n</details>\n</details>\n' >"$FX/body.txt"
copilot_fixture "$FX/body.txt"
jq '.data.repository.pullRequest.headRefOid = "head2" | .data.repository.pullRequest.reviews.nodes[0].commit.oid = "head2"' \
  "$FX/copilot.json" >"$FX/c2.json" && mv "$FX/c2.json" "$FX/copilot.json"
run pr-gate.sh -R o/r 12
check "gate: partial parse detail" '"the Copilot review body lists 1 previously missed issue(s) with no thread: 1 High; the section announces more than could be parsed, so read the review body for the rest"' \
  "$(q '.blocking[0].detail')"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
