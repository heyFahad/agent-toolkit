#!/bin/bash
# Removes the local worktrees and branches of the current repo that hold
# nothing that exists only on this machine, and fast-forwards the local
# default branch. Nothing on the remote is touched.
#
# Usage, from any checkout of the repo:
#   branch-cleanup.sh [--dry-run] [--no-fetch] [--default BRANCH]
#
# A linked worktree is removed only when every check passes:
#   - it isn't the worktree this script runs in, and isn't locked
#   - no process has its working directory inside it (lsof), so no running
#     session or dev server loses its folder mid-task. Without lsof, a
#     worktree whose index changed in the last hour is kept instead.
#   - `git status` shows no changes, tracked or untracked
#   - it has no ignored files other than ones that can be rebuilt or are
#     disposable (see REBUILDABLE below) and symlinks: `git worktree remove`
#     deletes ignored files without asking, and a .env or a local database
#     can't be rebuilt
#   - every commit on its branch (or its detached HEAD) is on a remote
# A local branch other than the default branch is deleted only when it's
# checked out in no remaining worktree and every commit on it is on a
# remote. A branch whose remote copy was deleted after its PR merged counts
# as pushed when `gh` shows a merged PR whose head is the branch's tip.
#
# Prints one JSON object:
#   {default, dryRun,
#    worktrees: [{path, branch, action, reason, files}],
#    branches:  [{name, action, reason}],
#    defaultBranch: {action, reason}}
# action is "removed", "kept" or, with --dry-run, "would-remove". Exit 0
# when it ran (kept items are not errors), 1 when it couldn't run at all.
#
# Keep this bash 3.2 compatible: it runs under macOS's /bin/bash.
set -uo pipefail

# Ignored paths a worktree may hold and still be removed: matched against
# every path component, so `apps/web/node_modules` and `ios/Pods` match.
# Dependency and build output, caches, generated lockfiles in repos that
# ignore them, and harness-local folders (`.claude/` holds the session's
# local permission grants, which a resumed session asks for again).
REBUILDABLE="node_modules bower_components vendor dist build out target coverage .nyc_output
.next .nuxt .svelte-kit .turbo .cache .parcel-cache .vite .expo .gradle Pods DerivedData
__pycache__ .pytest_cache .mypy_cache .ruff_cache .venv venv .tox
package-lock.json yarn.lock pnpm-lock.yaml .DS_Store .claude .codex .husky"
# shellcheck disable=SC2086 # split on whitespace on purpose: one line of names
REBUILDABLE_FLAT=" $(printf '%s ' $REBUILDABLE)"

DRY_RUN=0
FETCH=1
DEFAULT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --no-fetch) FETCH=0 ;;
    --default) DEFAULT="${2:-}"; shift ;;
    *) echo "usage: $0 [--dry-run] [--no-fetch] [--default BRANCH]" >&2; exit 1 ;;
  esac
  shift
done

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "branch-cleanup: not inside a git repository" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "branch-cleanup: needs jq" >&2
  exit 1
fi

HERE_TOP=$(git rev-parse --show-toplevel)
HERE_TOP=$(cd "$HERE_TOP" && pwd -P)

# Plain fetch, not --prune: a merged PR's deleted remote branch keeps its
# local origin/<branch> ref, which is what proves the branch was pushed.
if [ "$FETCH" -eq 1 ] && git remote get-url origin >/dev/null 2>&1; then
  git fetch --quiet origin 2>/dev/null || echo "branch-cleanup: git fetch origin failed; using the refs already here" >&2
fi

# The default branch: ask GitHub first, since origin/HEAD is set at clone
# time and goes stale.
if [ -z "$DEFAULT" ]; then
  DEFAULT=$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || true)
fi
if [ -z "$DEFAULT" ]; then
  DEFAULT=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed -E 's@^refs/remotes/origin/@@' || true)
fi
if [ -z "$DEFAULT" ]; then
  echo "branch-cleanup: can't tell the default branch; pass --default" >&2
  exit 1
fi

WT_JSON="[]"
BR_JSON="[]"
add_wt() { # path branch action reason [files-newline-separated]
  WT_JSON=$(jq -c --arg p "$1" --arg b "$2" --arg a "$3" --arg r "$4" --arg f "${5:-}" \
    '. + [{path: $p, branch: (if $b == "" then null else $b end), action: $a, reason: $r,
           files: ($f | split("\n") | map(select(. != "")))}]' <<<"$WT_JSON")
}
add_br() { # name action reason
  BR_JSON=$(jq -c --arg n "$1" --arg a "$2" --arg r "$3" '. + [{name: $n, action: $a, reason: $r}]' <<<"$BR_JSON")
}

# Every process's working directory, once. Empty when lsof isn't there.
# BRANCH_CLEANUP_LSOF picks the binary; set it empty to act as if there's
# none (the tests use that).
LSOF=${BRANCH_CLEANUP_LSOF-$(command -v lsof 2>/dev/null || true)}
HAVE_LSOF=0
PROC_CWDS=""
if [ -n "$LSOF" ]; then
  PROC_CWDS=$("$LSOF" -a -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | sort -u)
  # This script's own shell has a working directory, so a scan that lists
  # none failed (lsof exits non-zero for unreadable processes even when the
  # rest of its output is fine, so its exit status can't tell). Fall back to
  # the index check rather than treat every worktree as unused.
  if [ -n "$PROC_CWDS" ]; then
    HAVE_LSOF=1
  else
    echo "branch-cleanup: lsof listed no working directories; using the recent-index check instead" >&2
  fi
fi

in_use() { # path
  local wt="$1" line
  if [ "$HAVE_LSOF" -eq 1 ]; then
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      case "$line/" in "$wt"/*) return 0 ;; esac
    done <<<"$PROC_CWDS"
    return 1
  fi
  # No lsof: treat a worktree whose index changed in the last hour as in use.
  local index mtime now
  index=$(git -C "$wt" rev-parse --git-path index 2>/dev/null) || return 1
  case "$index" in /*) ;; *) index="$wt/$index" ;; esac
  [ -f "$index" ] || return 1
  # GNU stat first: its -f means "file system" and would print junk here.
  if stat -c %Y "$index" >/dev/null 2>&1; then
    mtime=$(stat -c %Y "$index")
  else
    mtime=$(stat -f %m "$index" 2>/dev/null || echo 0)
  fi
  now=$(date +%s)
  [ $((now - mtime)) -lt 3600 ]
}

rebuildable() { # relative path, possibly ending in /
  local p="${1%/}" part
  local IFS=/
  for part in $p; do
    case "$REBUILDABLE_FLAT" in *" $part "*) return 0 ;; esac
  done
  return 1
}

# Ignored paths in a worktree that removing it would lose.
precious_ignored() { # path
  local wt="$1" f
  git -C "$wt" ls-files --others --ignored --exclude-standard --directory 2>/dev/null |
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      [ -L "$wt/${f%/}" ] && continue
      rebuildable "$f" && continue
      printf '%s\n' "$f"
    done
}

# Commits reachable from REF that no remote ref has. Empty means pushed. A
# ref that doesn't resolve prints a marker, so it never counts as pushed.
local_only() { # ref
  if ! git rev-parse -q --verify "$1^{commit}" >/dev/null; then
    echo "unresolvable"
    return
  fi
  git rev-list "$1" --not --remotes 2>/dev/null | head -n 1
}

merged_pr_head_matches() { # branch tip
  local heads
  heads=$(gh pr list --head "$1" --state merged --json headRefOid -q '.[].headRefOid' 2>/dev/null) || return 1
  printf '%s\n' "$heads" | grep -qx "$2"
}

pushed() { # ref [branch-name]
  [ -z "$(local_only "$1")" ] && return 0
  [ -n "${2:-}" ] && merged_pr_head_matches "$2" "$(git rev-parse "$1")" && return 0
  return 1
}

# --- Worktrees -------------------------------------------------------------

if [ "$DRY_RUN" -eq 1 ]; then
  while IFS= read -r p; do
    [ -n "$p" ] && add_wt "$p" "" would-remove "prunable: its folder is already gone"
  done < <(git worktree list --porcelain | awk '/^worktree /{p=substr($0,10)} /^prunable/{print p}')
else
  while IFS= read -r p; do
    [ -n "$p" ] && add_wt "$p" "" removed "prunable: its folder was already gone"
  done < <(git worktree list --porcelain | awk '/^worktree /{p=substr($0,10)} /^prunable/{print p}')
  git worktree prune
fi

# One record per linked worktree: path, branch (or empty), locked flag,
# prunable flag. The first entry is the main checkout, which is never removed.
# Fields are split on the ASCII unit separator, not a tab: `read` collapses
# runs of whitespace separators, so a detached worktree's empty branch field
# would vanish and the locked flag would be read as its branch.
SEP=$'\037'
WORKTREES=$(git worktree list --porcelain | awk -v s="$SEP" '
  /^worktree /{ if (p != "") print p s b s l s x; p=substr($0,10); b=""; l=0; x=0 }
  /^branch /{ b=substr($0,8); sub("^refs/heads/", "", b) }
  /^locked/{ l=1 }
  /^prunable/{ x=1 }
  END{ if (p != "") print p s b s l s x }' | tail -n +2)

while IFS="$SEP" read -r wt branch locked prunable; do
  [ -z "$wt" ] || [ "$prunable" = 1 ] && continue
  real=$(cd "$wt" 2>/dev/null && pwd -P) || real="$wt"
  case "$HERE_TOP/" in "$real"/*)
    add_wt "$wt" "$branch" kept "this is the worktree the cleanup runs in"; continue ;;
  esac
  if [ "$locked" = 1 ]; then
    add_wt "$wt" "$branch" kept "locked"; continue
  fi
  if in_use "$real"; then
    if [ "$HAVE_LSOF" -eq 1 ]; then
      add_wt "$wt" "$branch" kept "in use: a process is working inside it"
    else
      add_wt "$wt" "$branch" kept "in use: its index changed in the last hour (lsof isn't installed)"
    fi
    continue
  fi
  dirty=$(git -C "$wt" status --porcelain 2>/dev/null)
  if [ -n "$dirty" ]; then
    add_wt "$wt" "$branch" kept "uncommitted changes" "$(printf '%s\n' "$dirty" | cut -c4- | head -n 20)"
    continue
  fi
  precious=$(precious_ignored "$wt")
  if [ -n "$precious" ]; then
    add_wt "$wt" "$branch" kept "ignored files that can't be rebuilt" "$(printf '%s\n' "$precious" | head -n 20)"
    continue
  fi
  if [ -n "$branch" ]; then
    if ! pushed "refs/heads/$branch" "$branch"; then
      add_wt "$wt" "$branch" kept "commits that aren't on any remote"; continue
    fi
  else
    head=$(git -C "$wt" rev-parse HEAD 2>/dev/null)
    if [ -z "$head" ] || ! pushed "$head"; then
      add_wt "$wt" "" kept "detached HEAD with commits that aren't on any remote"; continue
    fi
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    add_wt "$wt" "$branch" would-remove "clean, and everything is pushed"
  elif err=$(git worktree remove "$wt" 2>&1); then
    add_wt "$wt" "$branch" removed "clean, and everything is pushed"
  else
    add_wt "$wt" "$branch" kept "git refused: $err"
  fi
done <<<"$WORKTREES"

# --- Branches --------------------------------------------------------------

# Branches still checked out somewhere, after the removals above. In a dry
# run, the worktrees that would go count as gone.
CHECKED_OUT=$(git worktree list --porcelain | sed -n 's@^branch refs/heads/@@p')
if [ "$DRY_RUN" -eq 1 ]; then
  WOULD_GO=$(jq -r '.[] | select(.action == "would-remove" and .branch != null) | .branch' <<<"$WT_JSON")
  CHECKED_OUT=$(printf '%s\n' "$CHECKED_OUT" | grep -vxF -f <(printf '%s\n' "$WOULD_GO") || true)
fi

while IFS= read -r b; do
  [ -z "$b" ] || [ "$b" = "$DEFAULT" ] && continue
  if printf '%s\n' "$CHECKED_OUT" | grep -qxF "$b"; then
    add_br "$b" kept "checked out in a worktree"; continue
  fi
  if ! pushed "refs/heads/$b" "$b"; then
    add_br "$b" kept "commits that aren't on any remote"; continue
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    add_br "$b" would-remove "every commit is on a remote"
  elif git branch -q -d "$b" 2>/dev/null; then
    add_br "$b" removed "every commit is on a remote"
  # -d only compares with the upstream or HEAD, so it refuses a branch with
  # no upstream, or a merged PR's branch whose remote copy is gone. The check
  # above already found every commit on a remote, which is the stronger test.
  elif git branch -q -D "$b" 2>/dev/null; then
    add_br "$b" removed "every commit is on a remote (deleted with -D: git branch -d only checks the upstream)"
  else
    add_br "$b" kept "git refused to delete it"
  fi
done < <(git for-each-ref --format='%(refname:short)' refs/heads)

# --- The default branch ----------------------------------------------------

DEF_ACTION=kept
DEF_REASON=""
if ! git rev-parse -q --verify "refs/remotes/origin/$DEFAULT" >/dev/null; then
  DEF_REASON="no origin/$DEFAULT to update from"
elif ! git rev-parse -q --verify "refs/heads/$DEFAULT" >/dev/null; then
  DEF_REASON="no local $DEFAULT branch"
elif [ "$(git rev-parse "refs/heads/$DEFAULT")" = "$(git rev-parse "refs/remotes/origin/$DEFAULT")" ]; then
  DEF_REASON="already up to date"
elif ! git merge-base --is-ancestor "refs/heads/$DEFAULT" "refs/remotes/origin/$DEFAULT"; then
  DEF_REASON="local $DEFAULT has commits origin/$DEFAULT doesn't: not fast-forwarding"
else
  where=$(git worktree list --porcelain | awk -v b="refs/heads/$DEFAULT" '/^worktree /{p=substr($0,10)} $0 == "branch " b {print p}')
  if [ "$DRY_RUN" -eq 1 ]; then
    DEF_ACTION=would-update; DEF_REASON="fast-forward to origin/$DEFAULT"
  elif [ -z "$where" ]; then
    git update-ref "refs/heads/$DEFAULT" "refs/remotes/origin/$DEFAULT" &&
      { DEF_ACTION=updated; DEF_REASON="fast-forwarded to origin/$DEFAULT"; }
  elif [ -n "$(git -C "$where" status --porcelain --untracked-files=no)" ]; then
    DEF_REASON="checked out at $where with uncommitted changes: not touching it"
  elif git -C "$where" merge --ff-only --quiet "refs/remotes/origin/$DEFAULT" >/dev/null 2>&1; then
    DEF_ACTION=updated; DEF_REASON="fast-forwarded to origin/$DEFAULT in $where"
  else
    DEF_REASON="the fast-forward in $where failed"
  fi
fi

jq -n --arg d "$DEFAULT" --argjson dry "$DRY_RUN" --argjson w "$WT_JSON" --argjson b "$BR_JSON" \
  --arg da "$DEF_ACTION" --arg dr "$DEF_REASON" \
  '{default: $d, dryRun: ($dry == 1), worktrees: $w, branches: $b,
    defaultBranch: {action: $da, reason: $dr}}'
