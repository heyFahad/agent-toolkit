#!/bin/bash
# PreToolUse hook (Bash): blocks committing or pushing a tree that hasn't
# passed the repo's checks. See the verify skill for the checks, the levels
# and the records this reads.
#
#   git commit                        the working tree needs a passing
#                                     `verify --related` (or --full) record
#   git push, gh pr create,           every branch tree being pushed needs a
#   gh stack push, gh stack submit    passing `verify --related` record, or
#                                     `verify --full` when the push creates
#                                     the branch on the remote (there's no
#                                     remote-tracking ref for it here) or the
#                                     branch is a conflicts/... branch, whose
#                                     merged tree is new code
#   gh stack sync                     blocked: it rebases and pushes in one go,
#                                     so nothing can verify the rebased trees
#                                     first (use gh stack rebase, verify each
#                                     branch, then gh stack push)
#
# A push, PR or stack push in the same Bash call as a command that moves a
# branch (git commit, merge, rebase, ...) is blocked too: the hook runs
# before the call, so it can't see the commit that would be pushed.
#
# A record matches the working tree including untracked files, or the
# tracked files alone, so a scratch file the user keeps around doesn't block
# a push. Deleting a branch or pushing tags needs no record. A repo whose
# checks are off (CI runs none and there's no override) is never gated.
#
# Only a git or gh call at command position counts: `echo "git push"` and a
# commit message that mentions a command aren't gated, and heredoc bodies
# are skipped. Text inside quotes after a `;` or `&&` can still look like a
# command; that errs towards blocking, and the message says what it saw.
#
# It only reads local files and git objects, except `gh stack view --json`,
# which is local too. Whether a push creates the branch comes from the
# remote-tracking refs the last fetch left, never a network call: a branch
# someone else pushed since counts as new, which only asks for more. Exit 2 blocks the call, with the reason on stderr.
# Keep this bash 3.2 compatible: it runs under macOS's /bin/bash.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPTS="$HERE/../skills/verify/scripts"
[ -f "$SCRIPTS/lib.sh" ] || exit 0
# shellcheck source-path=SCRIPTDIR source=../skills/verify/scripts/lib.sh
. "$SCRIPTS/lib.sh"
# shellcheck source-path=SCRIPTDIR source=lib/commands.sh
. "$HERE/lib/commands.sh"
VERIFY=$(cd "$SCRIPTS" && pwd)/verify

INPUT=$(cat)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // "."')
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')

# Fast path: most Bash calls mention none of these.
printf '%s' "$COMMAND" | grep -qE '(^|[^[:alnum:]_-])(git|gh)[[:space:]]' || exit 0

REASONS=""
block() { REASONS="$REASONS$1"$'\n'; }

# gate_root DIR: the repo root, when DIR is in a repo whose gate is on.
gate_root() {
  local root
  root=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || return 1
  [ "$(vf_checks "$root" full 2>/dev/null)" != "[]" ] || return 1
  printf '%s' "$root"
}

# push_level ROOT REMOTE BRANCH [SRC]: sets `level` to what a push of SRC
# (by default BRANCH) to BRANCH on REMOTE needs, and `why` to the reason when
# that's full: a conflicts/... branch, or no remote-tracking ref for BRANCH,
# so the push creates it.
push_level() {
  local b
  level=related why=""
  for b in "$3" "${4:-}"; do
    case "$b" in conflicts/*)
      level=full why="$b is a conflicts/ branch, whose merged tree is new code"
      return 0
      ;;
    esac
  done
  if ! git -C "$1" rev-parse -q --verify "refs/remotes/$2/$3" >/dev/null 2>&1; then
    level=full why="it creates $2/$3"
  fi
}

# need TREE LEVEL ROOT WHAT [BRANCH] [WHY]: block unless TREE has a passing
# record at LEVEL. BRANCH, when it isn't the checked-out one, is named in the
# fix. WHY says why the level is full.
need() {
  local tree=$1 level=$2 root=$3 what=$4 branch=${5:-} why=${6:-} f detail="" where cur
  vf_record_ok "$tree" "$level" && return 0
  f=$(vf_record_file "$tree")
  if [ -f "$f" ]; then
    detail=$(jq -r 'if .passed then "Its last run was only --\(.level)."
      else "Its last run failed at \([.commands[] | select(.exit != 0) | .name][0] // "a check that changed tracked files")." end' "$f" 2>/dev/null)
  fi
  where="from $root"
  cur=$(git -C "$root" symbolic-ref -q --short HEAD 2>/dev/null || true)
  if [ -n "$branch" ] && [ "$branch" != "$cur" ] && [ "$branch" != HEAD ]; then
    where="after you check out $branch (or in a worktree of it)"
  fi
  block "verify-gate: $what needs a passing \`verify --$level\` of the tree it would take (${tree:0:7})${why:+, since $why}. ${detail:+$detail }Run, $where: bash $VERIFY --$level"
}

check_commit() { # dir
  local root tree
  root=$(gate_root "$1") || return 0
  tree=$(vf_tree "$root") || return 0
  need "$tree" related "$root" "git commit"
}

# tree_of ROOT REF: the tree of a local ref, or of origin/REF.
tree_of() {
  git -C "$1" rev-parse -q --verify "$2^{tree}" 2>/dev/null ||
    git -C "$1" rev-parse -q --verify "origin/$2^{tree}" 2>/dev/null
}

# push_remote ROOT: where a `git push` that names no remote goes.
push_remote() {
  local cur r
  cur=$(git -C "$1" symbolic-ref -q --short HEAD 2>/dev/null || true)
  for r in ${cur:+"branch.$cur.pushRemote"} remote.pushDefault ${cur:+"branch.$cur.remote"}; do
    git -C "$1" config --get "$r" 2>/dev/null && return 0
  done
  echo origin
}

# push_dst ROOT REMOTE SRC: the branch a push of SRC with no destination
# updates. HEAD is the current branch, pushed to its upstream when that's on
# REMOTE.
push_dst() {
  local cur merge
  case "$3" in
    HEAD)
      cur=$(git -C "$1" symbolic-ref -q --short HEAD 2>/dev/null) || {
        echo HEAD
        return 0
      }
      merge=$(git -C "$1" config --get "branch.$cur.merge" 2>/dev/null || true)
      if [ -n "$merge" ] && [ "$(git -C "$1" config --get "branch.$cur.remote" 2>/dev/null)" = "$2" ]; then
        echo "${merge#refs/heads/}"
      else
        echo "$cur"
      fi
      ;;
    *) echo "${3#refs/heads/}" ;;
  esac
}

check_push() { # dir args...
  local dir=$1 root remote="" delete=false tags=false skip=false t src dst tree level why
  local refs=()
  shift
  root=$(gate_root "$dir") || return 0
  for t in "$@"; do
    if [ "$skip" = true ]; then
      skip=false
      continue
    fi
    case "$t" in
      --delete | -d) delete=true ;;
      --all | --mirror | --branches)
        block "verify-gate: git push $t pushes branches nobody verified. Push each branch by name (git push origin <branch>) after verifying it."
        return 0
        ;;
      --tags) tags=true ;;
      -o | --push-option | --repo | --receive-pack | --exec) skip=true ;;
      -*) ;;
      *) if [ -z "$remote" ]; then remote=$t; else refs+=("$t"); fi ;;
    esac
  done
  [ "$delete" = false ] || return 0
  [ -n "$remote" ] || remote=$(push_remote "$root")
  if [ "${#refs[@]}" -eq 0 ]; then
    [ "$tags" = false ] || return 0
    if git -C "$root" config --get "remote.$remote.push" >/dev/null 2>&1; then
      block "verify-gate: git push with no branch named follows this repo's remote.<name>.push setting, which can push branches nobody verified. Push each branch by name (git push origin <branch>) after verifying it."
      return 0
    fi
    if [ "$(git -C "$root" config push.default 2>/dev/null)" = matching ]; then
      block "verify-gate: git push with push.default=matching pushes every matching branch, verified or not. Push each branch by name (git push origin <branch>) after verifying it."
      return 0
    fi
    refs=(HEAD)
  fi
  for t in "${refs[@]}"; do
    t=${t#+}
    if [ "$t" = : ]; then
      block "verify-gate: git push $remote : pushes every matching branch, verified or not. Push each branch by name (git push origin <branch>) after verifying it."
      continue
    fi
    src=${t%%:*}
    [ -n "$src" ] || continue # :dst deletes dst
    case "$src" in refs/tags/*) continue ;; esac
    case "$src" in *'*'*)
      block "verify-gate: git push $src expands to branches the hook can't check one by one. Push each branch by name after verifying it."
      continue
      ;;
    esac
    case "$src" in refs/tags/*) continue ;; esac
    git -C "$root" show-ref -q --verify "refs/tags/$src" 2>/dev/null && continue
    tree=$(tree_of "$root" "$src") || continue # unknown ref: git push fails on its own
    case "$t" in
      *:*)
        dst=${t#*:}
        dst=${dst#refs/heads/}
        ;;
      *) dst=$(push_dst "$root" "$remote" "$src") ;;
    esac
    push_level "$root" "$remote" "$dst" "${src#refs/heads/}"
    need "$tree" "$level" "$root" "git push of $src" "$src" "$why"
  done
}

# A PR opens on a branch already on origin, or one gh pushes there first: the
# same levels as a push of it to origin.
check_pr_create() { # dir args...
  local dir=$1 root head="" next=false t tree level why
  shift
  root=$(gate_root "$dir") || return 0
  for t in "$@"; do
    if [ "$next" = true ]; then
      head=$t
      next=false
      continue
    fi
    case "$t" in
      --head | -H) next=true ;;
      --head=*) head=${t#--head=} ;;
      -H?*) head=${t#-H} ;;
    esac
  done
  head=${head#*:}
  if [ -z "$head" ]; then
    head=$(git -C "$root" symbolic-ref -q --short HEAD) || return 0
    push_level "$root" origin "$head"
    # With no --head, gh may push the local branch first: its tip counts too.
    tree=$(git -C "$root" rev-parse -q --verify "$head^{tree}" 2>/dev/null) &&
      need "$tree" "$level" "$root" "gh pr create from $head (its local tip, which gh may push)" "$head" "$why"
    # Not on origin yet: the local tip is all there is.
    git -C "$root" rev-parse -q --verify "refs/remotes/origin/$head" >/dev/null 2>&1 || return 0
  fi
  push_level "$root" origin "$head"
  # The PR shows the branch as it is on GitHub: origin's copy first.
  tree=$(git -C "$root" rev-parse -q --verify "origin/$head^{tree}" 2>/dev/null ||
    git -C "$root" rev-parse -q --verify "$head^{tree}" 2>/dev/null) || {
    block "verify-gate: gh pr create from $head, but $head isn't a branch here or on origin (fetch it, or push it first), so its tree can't be checked."
    return 0
  }
  need "$tree" "$level" "$root" "gh pr create from $head" "$head" "$why"
}

# check_stack DIR SUB: every branch gh stack would push that isn't merged or
# queued needs a record, at the level a push of it to origin would. sync is
# blocked outright.
check_stack() {
  local root json err b tree level why
  root=$(gate_root "$1") || return 0
  if [ "$2" = sync ]; then
    block "verify-gate: gh stack sync rebases the stack and pushes it in one go, so the rebased branches can't be verified first. Run gh stack rebase, then verify --full on each branch it changed, then gh stack push."
    return 0
  fi
  err=$(mktemp "${TMPDIR:-/tmp}/verify-gate.XXXXXX")
  json=$(cd "$root" && gh stack view --json 2>"$err") || {
    block "verify-gate: gh stack $2 needs every branch in the stack verified, but gh stack view --json failed: $(cat "$err")"
    rm -f "$err"
    return 0
  }
  rm -f "$err"
  if ! printf '%s' "$json" | jq -e '.branches | type == "array"' >/dev/null 2>&1; then
    block "verify-gate: gh stack $2 needs every branch in the stack verified, but gh stack view --json didn't list them."
    return 0
  fi
  for b in $(printf '%s' "$json" | jq -r '.branches[] | select((.isMerged or .isQueued) | not) | .name'); do
    tree=$(tree_of "$root" "$b") || continue
    push_level "$root" origin "$b"
    need "$tree" "$level" "$root" "gh stack $2 of $b" "$b" "$why"
  done
}

# Pushes that come after a branch-moving command in the same call.
moved_then() { # what
  block "verify-gate: $1 runs in the same Bash call as a command that moves the branch ($MOVED), so this hook can't see what it would push. Run the push in its own Bash call, after verify."
}

DIR=$CWD MOVED="" SWITCHED=false
while IFS= read -r seg; do
  hc_words "$seg"
  [ "$i" -lt "${#words[@]}" ] || continue
  cmd=${words[$i]##*/}
  case "$cmd" in
    cd)
      [ $((i + 1)) -lt "${#words[@]}" ] && DIR=$(hc_resolve "${words[$((i + 1))]}" "$DIR")
      ;;
    git)
      gdir=$DIR
      i=$((i + 1))
      while [ "$i" -lt "${#words[@]}" ]; do
        case "${words[$i]}" in
          -C)
            gdir=$(hc_resolve "${words[$((i + 1))]:-.}" "$gdir")
            i=$((i + 2))
            ;;
          -c) i=$((i + 2)) ;;
          -*) i=$((i + 1)) ;;
          *) break ;;
        esac
      done
      case "${words[$i]:-}" in
        commit)
          check_commit "$gdir"
          MOVED="git commit"
          ;;
        push)
          # After a switch or checkout, the branch being pushed may have
          # checks the current one doesn't: block whatever the gate says now.
          if [ -n "$MOVED" ] && { [ "$SWITCHED" = true ] || gate_root "$gdir" >/dev/null; }; then
            moved_then "git push"
          else
            rest=()
            [ $((i + 1)) -ge "${#words[@]}" ] || rest=("${words[@]:$((i + 1))}")
            check_push "$gdir" ${rest[@]+"${rest[@]}"}
          fi
          ;;
        merge | rebase | cherry-pick | revert | reset | pull | am | stash) MOVED="git ${words[$i]}" ;;
        switch | checkout)
          MOVED="git ${words[$i]}"
          SWITCHED=true
          ;;
      esac
      ;;
    gh)
      # -R between pr and the verb (gh pr -R o/r create) still makes a PR.
      hc_gh_command
      sub=$gh_sub
      [ "$sub" != "pr new" ] || sub="pr create"
      if [ -n "$MOVED" ] && { [ "$SWITCHED" = true ] || gate_root "$DIR" >/dev/null; }; then
        case "$sub" in "pr create" | "stack push" | "stack submit")
          moved_then "gh $sub"
          continue
          ;;
        esac
      fi
      case "$sub" in
        "pr create")
          rest=()
          [ "$gh_args" -ge "${#words[@]}" ] || rest=("${words[@]:$gh_args}")
          check_pr_create "$DIR" ${rest[@]+"${rest[@]}"}
          ;;
        "stack push" | "stack submit" | "stack sync") check_stack "$DIR" "${sub#* }" ;;
      esac
      ;;
  esac
done < <(hc_segments "$COMMAND")

if [ -n "$REASONS" ]; then
  printf '%s' "$REASONS" >&2
  exit 2
fi
exit 0
