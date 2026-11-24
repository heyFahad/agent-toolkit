#!/bin/bash
# Usage: reply-thread.sh THREAD_ID (--body TEXT | --body-file FILE) [--resolve]
#
# Replies to a PR review thread (THREAD_ID is the node id review-threads.sh
# prints), and with --resolve also marks the thread resolved.
#
# --resolve is refused, before anything is posted, when the thread was
# started by a human: their threads are theirs to resolve. Reply without
# --resolve instead. --body-file - reads the body from stdin.
#
# Prints JSON: {threadId, replyUrl, resolved}
# Exit codes: 0 done, 2 bad usage, 3 refused (human thread).
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "$0")/lib.sh"

THREAD="" BODY="" HAVE_BODY=false RESOLVE=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --body)
      [ "$#" -ge 2 ] || die "--body needs text"
      BODY=$2 HAVE_BODY=true
      shift 2
      ;;
    --body-file)
      [ "$#" -ge 2 ] || die "--body-file needs a path"
      if [ "$2" = - ]; then BODY=$(cat); else BODY=$(cat -- "$2"); fi
      HAVE_BODY=true
      shift 2
      ;;
    --resolve) RESOLVE=true; shift ;;
    -*) die "unknown option $1" ;;
    *)
      [ -z "$THREAD" ] || die "unexpected argument $1"
      THREAD=$1
      shift
      ;;
  esac
done
[ -n "$THREAD" ] || die "usage: reply-thread.sh THREAD_ID (--body TEXT | --body-file FILE) [--resolve]"
$HAVE_BODY || die "a reply body is required (--body or --body-file)"
[ -n "$(printf '%s' "$BODY" | tr -d '[:space:]')" ] || die "the reply body is empty"

ensure_gh_token

# shellcheck disable=SC2016 # GraphQL variables, not shell ones
THREAD_QUERY='query($id: ID!) {
  node(id: $id) {
    ... on PullRequestReviewThread {
      isResolved
      comments(first: 1) { nodes { author { login __typename } } }
    }
  }
}'
INFO=$(gh api graphql -f query="$THREAD_QUERY" -f id="$THREAD")
AUTHOR_TYPE=$(printf '%s' "$INFO" | jq -r '.data.node.comments.nodes[0].author.__typename // empty')
AUTHOR=$(printf '%s' "$INFO" | jq -r '.data.node.comments.nodes[0].author.login // "ghost"')
[ -n "$(printf '%s' "$INFO" | jq -r '.data.node // empty')" ] || die "no review thread with id $THREAD"

if $RESOLVE && [ "$AUTHOR_TYPE" != Bot ]; then
  echo "reply-thread.sh: refusing to resolve thread $THREAD: it was started by $AUTHOR, a human. Reply without --resolve and leave resolving to them." >&2
  exit 3
fi

# shellcheck disable=SC2016
REPLY_MUTATION='mutation($thread: ID!, $body: String!) {
  addPullRequestReviewThreadReply(input: {pullRequestReviewThreadId: $thread, body: $body}) {
    comment { url }
  }
}'
REPLY_URL=$(gh api graphql -f query="$REPLY_MUTATION" -f thread="$THREAD" -f body="$BODY" \
  --jq '.data.addPullRequestReviewThreadReply.comment.url')

RESOLVED=$(printf '%s' "$INFO" | jq '.data.node.isResolved // false')
if $RESOLVE; then
  # shellcheck disable=SC2016
  RESOLVE_MUTATION='mutation($thread: ID!) {
    resolveReviewThread(input: {threadId: $thread}) { thread { isResolved } }
  }'
  RESOLVED=$(gh api graphql -f query="$RESOLVE_MUTATION" -f thread="$THREAD" \
    --jq '.data.resolveReviewThread.thread.isResolved')
fi

jq -n --arg id "$THREAD" --arg url "$REPLY_URL" --argjson resolved "$RESOLVED" \
  '{threadId: $id, replyUrl: $url, resolved: $resolved}'
