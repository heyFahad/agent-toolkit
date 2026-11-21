#!/bin/bash
# Removes the local worktrees and branches of the current repo that hold
# nothing that exists only on this machine, and fast-forwards the local
# default branch. Nothing on the remote is touched.
#
# Usage, from any checkout of the repo:
#   branch-cleanup.sh [--dry-run] [--no-fetch] [--default BRANCH]
#
# A linked worktree is removed only when every check passes:
#   - it isn't the worktree this script runs in, isn't locked, and has no
#     other worktree inside it
#   - no rebase, merge, cherry-pick, revert, bisect or `git am` is in progress
#   - no process has its working directory inside it (lsof), so no running
#     session or dev server loses its folder mid-task. Without lsof, a
#     worktree whose index changed in the last hour is kept instead.
#   - `git status` succeeds and shows no changes, tracked or untracked
#   - it has no ignored files other than ones that can be rebuilt or are
#     disposable (see REBUILDABLE_* below) and symlinks: `git worktree remove`
#     deletes ignored files without asking, and a .env or a local database
#     can't be rebuilt
#   - every commit on its branch (or its detached HEAD) is on a remote
# A worktree whose folder is gone is pruned, unless its folder looks like it
# is on an unmounted volume (then nothing is pruned: plug it back in, or
# `git worktree lock` it).
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

# Ignored entries a worktree may hold and still be removed. `git ls-files
# --directory` reports a wholly ignored folder once, as `path/name/`:
#   - REBUILDABLE_DIRS: such a folder, matched on its own name only, so
#     `apps/web/node_modules/` matches but a file inside a tracked `build/`
#     folder doesn't. Dependency and build output, and caches.
#   - REBUILDABLE_FILES: a file matched on its name: generated lockfiles in
#     repos that ignore them, and Finder litter.
#   - REBUILDABLE_PATHS: exact paths, for generated folders with generic names.
#   - HARNESS_DIRS: top-level harness folders, matched with everything below
#     them (`.claude/settings.local.json` holds the session's local
#     permission grants, which a resumed session asks for again).
REBUILDABLE_DIRS=" node_modules bower_components vendor dist build out target coverage .nyc_output
.next .nuxt .svelte-kit .turbo .cache .parcel-cache .vite .expo .gradle Pods DerivedData
__pycache__ .pytest_cache .mypy_cache .ruff_cache .venv venv .tox "
REBUILDABLE_FILES=" package-lock.json yarn.lock pnpm-lock.yaml .DS_Store "
REBUILDABLE_PATHS=" .husky/_ "
HARNESS_DIRS=" .claude .codex "
# shellcheck disable=SC2086 # split on whitespace on purpose: one line of names
REBUILDABLE_DIRS=" $(printf '%s ' $REBUILDABLE_DIRS)"

DRY_RUN=0
FETCH=1
DEFAULT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --no-fetch) FETCH=0 ;;
    --default)
      # Never take the next option as the value: `--default --dry-run` would
      # otherwise turn a requested preview into a real cleanup.
      case "${2:-}" in
        "" | -*) echo "branch-cleanup: --default needs a branch name" >&2; exit 1 ;;
      esac
      DEFAULT="$2"; shift ;;
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
PROC_PID_CWDS=""
if [ -n "$LSOF" ]; then
  # "pid<TAB>cwd" per process, from lsof's p<pid> and n<path> field lines.
  PROC_PID_CWDS=$("$LSOF" -a -d cwd -Fpn 2>/dev/null | awk '/^p/{pid=substr($0,2)} /^n/{print pid "\t" substr($0,2)}')
  PROC_CWDS=$(printf '%s\n' "$PROC_PID_CWDS" | cut -f2- | sed '/^$/d' | sort -u)
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

rebuildable() { # relative path as ls-files --directory prints it
  local entry="$1" p="${1%/}" name first
  name=${p##*/}
  first=${p%%/*}
  case "$HARNESS_DIRS" in *" $first "*) return 0 ;; esac
  case "$REBUILDABLE_PATHS" in *" $p "*) return 0 ;; esac
  case "$entry" in
    */) case "$REBUILDABLE_DIRS" in *" $name "*) return 0 ;; esac ;;
    *) case "$REBUILDABLE_FILES" in *" $name "*) return 0 ;; esac ;;
  esac
  return 1
}

# Ignored paths in a worktree that removing it would lose. Returns 1 when
# git can't list them, so a failure never reads as "nothing to lose".
precious_ignored() { # path
  local wt="$1" f listing
  listing=$(git -C "$wt" ls-files --others --ignored --exclude-standard --directory 2>/dev/null) || return 1
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    [ -L "$wt/${f%/}" ] && continue
    rebuildable "$f" && continue
    printf '%s\n' "$f"
  done <<<"$listing"
}

# The git operation in progress in a worktree, or nothing.
operation_in_progress() { # path
  local gd
  gd=$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null) || { echo "unknown (its git dir can't be read)"; return; }
  if [ -d "$gd/rebase-merge" ] || [ -d "$gd/rebase-apply" ]; then echo "a rebase or git am"
  elif [ -f "$gd/MERGE_HEAD" ]; then echo "a merge"
  elif [ -f "$gd/CHERRY_PICK_HEAD" ]; then echo "a cherry-pick"
  elif [ -f "$gd/REVERT_HEAD" ]; then echo "a revert"
  elif [ -f "$gd/BISECT_LOG" ]; then echo "a bisect"
  elif [ -d "$gd/sequencer" ]; then echo "a cherry-pick or revert sequence"
  fi
}

# Commits reachable from REF that no remote ref has. Empty means pushed. A
# ref that doesn't resolve prints a marker, so it never counts as pushed.
local_only() { # ref
  if ! git rev-parse -q --verify "$1^{commit}" >/dev/null; then
    echo "unresolvable"
    return
  fi
  # A walk that fails (a remote-tracking ref pointing at a missing object,
  # say) prints nothing, which would read as "pushed": print a marker.
  local out
  out=$(git rev-list --max-count=1 "$1" --not --remotes 2>/dev/null) || { echo "walk-failed"; return; }
  printf '%s' "$out"
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

# A missing folder whose nearest existing parent is a volume mount point
# (/Volumes, /mnt, /media, /run/media/<user>) is probably on a drive that
# isn't plugged in, not deleted. Pruning would drop its index and HEAD record
# for good, and `git worktree repair` couldn't reattach it later.
on_unmounted_volume() { # path
  local d="$1"
  while [ -n "$d" ] && [ "$d" != / ] && [ ! -e "$d" ]; do d=${d%/*}; done
  case "$d" in /Volumes | /mnt | /media | /media/* | /run/media | /run/media/*) return 0 ;; esac
  return 1
}

PRUNABLE=$(git worktree list --porcelain | awk '/^worktree /{p=substr($0,10)} /^prunable/{print p}')
OFFLINE=""
while IFS= read -r p; do
  [ -n "$p" ] && on_unmounted_volume "$p" && OFFLINE="$OFFLINE$p
"
done <<<"$PRUNABLE"
while IFS= read -r p; do
  [ -z "$p" ] && continue
  if [ -n "$OFFLINE" ]; then
    if printf '%s' "$OFFLINE" | grep -qxF -- "$p"; then
      add_wt "$p" "" kept "folder missing, probably on an unmounted volume: plug it back in, or lock it with git worktree lock"
    else
      add_wt "$p" "" kept "folder already gone, but not pruned: git worktree prune is all-or-nothing, and another missing worktree looks like it's on an unmounted volume"
    fi
  elif [ "$DRY_RUN" -eq 1 ]; then
    add_wt "$p" "" would-remove "prunable: its folder is already gone"
  else
    add_wt "$p" "" removed "prunable: its folder was already gone"
  fi
done <<<"$PRUNABLE"
if [ "$DRY_RUN" -eq 0 ] && [ -n "$PRUNABLE" ] && [ -z "$OFFLINE" ]; then
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
  END{ if (p != "") print p s b s l s x }' | tail -n +2 | sort -r)
# Sorted in reverse so a worktree nested inside another comes before it: the
# nested one is checked, and maybe removed, first.

# Canonical paths of every registered worktree right now, one per line.
registered_paths() {
  local p
  git worktree list --porcelain | sed -n 's/^worktree //p' | while IFS= read -r p; do
    (cd "$p" 2>/dev/null && pwd -P) || printf '%s\n' "$p"
  done
}

# Registered worktrees strictly inside PATH. A function rather than inline in
# $(...): bash 3.2 takes a case pattern's ")" there as the closing paren.
# In a dry run, the nested worktrees already marked would-remove count as
# gone, so the preview matches what a real run removes.
WOULD_GO_PATHS=""
nested_in() { # canonical path
  local p
  registered_paths | while IFS= read -r p; do
    [ "$p" = "$1" ] && continue
    printf '%s\n' "$WOULD_GO_PATHS" | grep -qxF -- "$p" && continue
    case "$p/" in "$1"/*) printf '%s\n' "$p" ;; esac
  done
}

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
  op=$(operation_in_progress "$wt")
  if [ -n "$op" ]; then
    add_wt "$wt" "$branch" kept "$op is in progress"; continue
  fi
  if ! dirty=$(git -C "$wt" status --porcelain 2>/dev/null); then
    add_wt "$wt" "$branch" kept "git status failed in it, so its state can't be checked"; continue
  fi
  if [ -n "$dirty" ]; then
    add_wt "$wt" "$branch" kept "uncommitted changes" "$(printf '%s\n' "$dirty" | cut -c4- | head -n 20)"
    continue
  fi
  if ! precious=$(precious_ignored "$wt"); then
    add_wt "$wt" "$branch" kept "git couldn't list its ignored files"; continue
  fi
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
  # Removing a folder removes every worktree inside it (say, one in its
  # ignored .claude/worktrees/), whatever that one holds.
  nested=$(nested_in "$real")
  if [ -n "$nested" ]; then
    add_wt "$wt" "$branch" kept "another worktree is inside it" "$nested"; continue
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    WOULD_GO_PATHS="$WOULD_GO_PATHS$real
"
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

# This script and the processes that started it (the agent's shell, the
# agent itself), up to but not including init.
ANCESTORS=" "
pid=$$
while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null; do
  ANCESTORS="$ANCESTORS$pid "
  pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
done

# Whether a process other than this script and its ancestors works in the
# checkout at PATH itself, not in a worktree nested inside it (session
# worktrees often live in the main checkout's .claude/worktrees/). Without
# lsof this can't be told, so it says no.
others_in() { # canonical path
  local pid cwd inner
  [ "$HAVE_LSOF" -eq 1 ] || return 1
  inner=$(nested_in "$1")
  while IFS="$(printf '\t')" read -r pid cwd; do
    [ -z "$cwd" ] && continue
    case "$ANCESTORS" in *" $pid "*) continue ;; esac
    case "$cwd/" in "$1"/*) ;; *) continue ;; esac
    inside_any "$cwd" "$inner" && continue
    return 0
  done <<<"$PROC_PID_CWDS"
  return 1
}

inside_any() { # path, newline-separated list of folders
  local d
  while IFS= read -r d; do
    [ -z "$d" ] && continue
    case "$1/" in "$d"/*) return 0 ;; esac
  done <<<"$2"
  return 1
}

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
    # With the old value, so an update made meanwhile isn't overwritten.
    git update-ref "refs/heads/$DEFAULT" "refs/remotes/origin/$DEFAULT" "$(git rev-parse "refs/heads/$DEFAULT")" 2>/dev/null &&
      { DEF_ACTION=updated; DEF_REASON="fast-forwarded to origin/$DEFAULT"; } ||
      DEF_REASON="$DEFAULT changed while the cleanup ran: not updating it"
  elif others_in "$(cd "$where" && pwd -P)"; then
    DEF_REASON="checked out at $where, where another process is working: not updating it under them"
  elif [ -n "$(git -C "$where" status --porcelain --untracked-files=no)" ]; then
    DEF_REASON="checked out at $where with uncommitted changes: not touching it"
  elif git -C "$where" merge --ff-only --no-overwrite-ignore --quiet "refs/remotes/origin/$DEFAULT" >/dev/null 2>&1; then
    DEF_ACTION=updated; DEF_REASON="fast-forwarded to origin/$DEFAULT in $where"
  else
    DEF_REASON="the fast-forward in $where failed (it never overwrites ignored local files)"
  fi
fi

jq -n --arg d "$DEFAULT" --argjson dry "$DRY_RUN" --argjson w "$WT_JSON" --argjson b "$BR_JSON" \
  --arg da "$DEF_ACTION" --arg dr "$DEF_REASON" \
  '{default: $d, dryRun: ($dry == 1), worktrees: $w, branches: $b,
    defaultBranch: {action: $da, reason: $dr}}'
