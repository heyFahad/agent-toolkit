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

# Stub gh. The GraphQL query text picks the fixture; --jq is applied like gh
# does; every call is logged with the GH_TOKEN it saw.
cat >"$TMP/bin/gh" <<'EOF'
#!/bin/bash
# One line per call, so grep -c counts calls.
echo "GH_TOKEN=${GH_TOKEN:-unset} $*" | tr '\n' ' ' >>"$GH_CALLS"
echo >>"$GH_CALLS"
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
  "auth token") echo stub-token; exit 0 ;;
  "repo view") echo o/r; exit 0 ;;
esac
all="$*"
case "$all" in
  *addPullRequestReviewThreadReply*) out "$FX/reply.json" ;;
  *resolveReviewThread*) out "$FX/resolve.json" ;;
  *"node(id:"*) out "$FX/node.json" ;;
  *reviewThreads*) cat "$FX"/threads-*.json ;;
  *latestOpinionatedReviews*) out "$FX/prinfo.json" ;;
  *statusCheckRollup*) out "$FX/checks.json" ;;
  *reviewRequests*) out "$FX/copilot.json" ;;
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
 {"number":1,"url":"u1","title":"t","isDraft":true,"headRefName":"feat/ATC-1-thing","baseRefName":"main","headRefOid":"a1"},
 {"number":2,"url":"u2","title":"t","isDraft":false,"headRefName":"feat/ATC-1-thing","baseRefName":"develop","headRefOid":"a1"},
 {"number":3,"url":"u3","title":"t","isDraft":false,"headRefName":"conflicts/ATC-1-thing","baseRefName":"staging","headRefOid":"c3"},
 {"number":4,"url":"u4","title":"t","isDraft":false,"headRefName":"conflicts/fix-ATC-1","baseRefName":"dev","headRefOid":"c4"},
 {"number":5,"url":"u5","title":"t","isDraft":false,"headRefName":"conflicts/renamed","baseRefName":"dev","headRefOid":"c5"},
 {"number":6,"url":"u6","title":"t","isDraft":false,"headRefName":"conflicts/unrelated","baseRefName":"dev","headRefOid":"c6"},
 {"number":7,"url":"u7","title":"t","isDraft":false,"headRefName":"conflicts/ATC-10-other","baseRefName":"dev","headRefOid":"c7"},
 {"number":8,"url":"u8","title":"t","isDraft":false,"headRefName":"feat/ATC-10-other","baseRefName":"main","headRefOid":"a8"},
 {"number":9,"url":"u9","title":"t","isDraft":false,"headRefName":"conflicts/feat/ATC-1-thing","baseRefName":"main","headRefOid":"c9"}
]}}}}
EOF
# base...head -> what GitHub's compare endpoint says; anything else is a 404.
printf 'feat%%2FATC-1-thing...conflicts%%2Frenamed\tahead\nfeat%%2FATC-1-thing...conflicts%%2Funrelated\tdiverged\n' >"$FX/compare.tsv"

run find-pr-pair.sh -R o/r feat/ATC-1-thing
check "pair: exit 0" 0 "$CODE"
check "pair: default branch" '"main"' "$(q .defaultBranch)"
check "pair: main PR" 1 "$(q .main.number)"
check "pair: preprod PRs and how they matched" \
  '[[2,"head"],[3,"conflicts-name"],[4,"conflicts-ticket"],[5,"conflicts-ancestry"]]' \
  "$(q '[.preprod[] | [.number, .matchedBy]]')"
check "pair: compare only for name/ticket misses" 3 "$(calls /compare/)"

run find-pr-pair.sh -R o/r feat/ATC-10-other
check "pair: ATC-10 does not pick up ATC-1" '[8,[7]]' "$(q '[.main.number, [.preprod[].number]]')"

run find-pr-pair.sh -R o/r feat/nothing-open
check "pair: no PRs" '[null,[]]' "$(q '[.main, .preprod]')"

run find-pr-pair.sh -R o/r conflicts/ATC-1-thing
check "pair: refuses a conflicts branch" 2 "$CODE"

run find-pr-pair.sh feat/ATC-1-thing
check "pair: repo from gh repo view" '"o/r"' "$(q .repo)"
check "pair: exported the token itself" 0 "$(calls 'GH_TOKEN=unset api')"

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
  | .data.repository.pullRequest.reviews.nodes[1].body = "<details>\n<summary>Comments suppressed due to low confidence (1)</summary>\nsomething new\n</details>"' \
  "$FX/copilot.json" >"$FX/c2.json" && mv "$FX/c2.json" "$FX/copilot.json"
run copilot-review.sh -R o/r 12
check "copilot: current review is not stale" false "$(q .stale)"
check "copilot: re-requested" true "$(q .requested)"
check "copilot: unknown low-confidence format flagged" '[[],true]' "$(q '[.lowConfidence, .lowConfidenceUnparsed]')"

echo '{"data":{"repository":{"pullRequest":{"headRefOid":"h","reviewRequests":{"nodes":[]},"reviews":{"nodes":[]}}}}}' >"$FX/copilot.json"
run copilot-review.sh -R o/r 12
check "copilot: no review yet" '[null,false,[]]' "$(q '[.review, .stale, .lowConfidence]')"

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
jq '.data.repository.pullRequest.reviewRequests.nodes = [{"requestedReviewer":{"__typename":"Bot","login":"copilot-pull-request-reviewer"}}]' "$FX/copilot.json" >"$FX/c2.json" && mv "$FX/c2.json" "$FX/copilot.json"
jq '.data.repository.pullRequest.mergeable = "CONFLICTING"' "$FX/prinfo.json" >"$FX/p2.json" && mv "$FX/p2.json" "$FX/prinfo.json"
run pr-gate.sh -R o/r 12
check "gate: copilot pending and conflicts block" '["copilot-pending","merge-conflict"]' "$(q '[.blocking[].reason]')"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
