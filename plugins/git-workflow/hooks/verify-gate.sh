#!/bin/bash
# PreToolUse hook (Bash): blocks committing or pushing a tree that hasn't
# passed the repo's checks. See the verify skill for the checks, the levels
# and the records this reads.
#
#   git commit                        the working tree needs a passing
#                                     `verify --related` (or --full) record
#   git push, gh pr create,           every branch tree being pushed needs a
#   gh stack push, gh stack submit    passing `verify --full` record
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
# which is local too. Exit 2 blocks the call, with the reason on stderr.
# Keep this bash 3.2 compatible: it runs under macOS's /bin/bash.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPTS="$HERE/../skills/verify/scripts"
[ -f "$SCRIPTS/lib.sh" ] || exit 0
# shellcheck source-path=SCRIPTDIR source=../skills/verify/scripts/lib.sh
. "$SCRIPTS/lib.sh"
VERIFY=$(cd "$SCRIPTS" && pwd)/verify

INPUT=$(cat)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // "."')
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')

# Fast path: most Bash calls mention none of these.
printf '%s' "$COMMAND" | grep -qE '(^|[^[:alnum:]_-])(git|gh)[[:space:]]' || exit 0

REASONS=""
block() { REASONS="$REASONS$1"$'\n'; }

# A path from a cd or -C argument, against the current directory.
resolve() { # dir base
  local d=${1/#\~/$HOME}
  case "$d" in /*) ;; *) d="$2/$d" ;; esac
  (cd "$d" 2>/dev/null && pwd) || printf '%s' "$d"
}

# gate_root DIR: the repo root, when DIR is in a repo whose gate is on.
gate_root() {
  local root
  root=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || return 1
  [ "$(vf_checks "$root" full 2>/dev/null)" != "[]" ] || return 1
  printf '%s' "$root"
}

# need TREE LEVEL ROOT WHAT [BRANCH]: block unless TREE has a passing record
# at LEVEL. BRANCH, when it isn't the checked-out one, is named in the fix.
need() {
  local tree=$1 level=$2 root=$3 what=$4 branch=${5:-} f detail="" where cur
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
  block "verify-gate: $what needs a passing \`verify --$level\` of the tree it would take (${tree:0:7}). ${detail:+$detail }Run, $where: bash $VERIFY --$level"
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

check_push() { # dir args...
  local dir=$1 root remote="" delete=false tags=false skip=false t src tree
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
        block "verify-gate: git push $t pushes branches nobody verified. Push each branch by name (git push origin <branch>) after verify --full on it."
        return 0
        ;;
      --tags) tags=true ;;
      -o | --push-option | --repo | --receive-pack | --exec) skip=true ;;
      -*) ;;
      *) if [ -z "$remote" ]; then remote=$t; else refs+=("$t"); fi ;;
    esac
  done
  [ "$delete" = false ] || return 0
  if [ "${#refs[@]}" -eq 0 ]; then
    [ "$tags" = false ] || return 0
    if [ "$(git -C "$root" config push.default 2>/dev/null)" = matching ]; then
      block "verify-gate: git push with push.default=matching pushes every matching branch, verified or not. Push each branch by name (git push origin <branch>) after verify --full on it."
      return 0
    fi
    refs=(HEAD)
  fi
  for t in "${refs[@]}"; do
    t=${t#+}
    if [ "$t" = : ]; then
      block "verify-gate: git push $remote : pushes every matching branch, verified or not. Push each branch by name (git push origin <branch>) after verify --full on it."
      continue
    fi
    src=${t%%:*}
    [ -n "$src" ] || continue # :dst deletes dst
    case "$src" in refs/tags/*) continue ;; esac
    git -C "$root" show-ref -q --verify "refs/tags/$src" 2>/dev/null && continue
    tree=$(tree_of "$root" "$src") || continue # unknown ref: git push fails on its own
    need "$tree" full "$root" "git push of $src" "$src"
  done
}

check_pr_create() { # dir args...
  local dir=$1 root head="" next=false t tree
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
    esac
  done
  head=${head#*:}
  [ -n "$head" ] || head=$(git -C "$root" symbolic-ref -q --short HEAD) || return 0
  # The PR shows the branch as it is on GitHub: origin's copy first.
  tree=$(git -C "$root" rev-parse -q --verify "origin/$head^{tree}" 2>/dev/null ||
    git -C "$root" rev-parse -q --verify "$head^{tree}" 2>/dev/null) || {
    block "verify-gate: gh pr create from $head, but $head isn't a branch here or on origin (fetch it, or push it first), so its tree can't be checked."
    return 0
  }
  need "$tree" full "$root" "gh pr create from $head" "$head"
}

# check_stack DIR SUB: every branch gh stack would push that isn't merged or
# queued needs a full record. sync is blocked outright.
check_stack() {
  local root json err b tree
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
    need "$tree" full "$root" "gh stack $2 of $b" "$b"
  done
}

# A backslash at the end of a line continues the command: join first. Then
# drop heredoc bodies, which aren't commands.
CLEAN=$(printf '%s\n' "$COMMAND" | awk '
  { line = (pending == "" ? $0 : pending " " $0); pending = "" }
  /\\$/ { pending = substr(line, 1, length(line) - 1); next }
  { print line }
  END { if (pending != "") print pending }' | awk -v q="'" '
  skip { if ($0 ~ "^[[:space:]]*" term "[[:space:]]*$") skip = 0; next }
  {
    print
    if (match($0, "<<-?[[:space:]]*[\"" q "]?[A-Za-z_][A-Za-z0-9_]*")) {
      term = substr($0, RSTART, RLENGTH)
      gsub("<<-?[[:space:]]*[\"" q "]?", "", term)
      skip = 1
    }
  }')

# One command per line: split on ; && || | & ( ) and newlines.
SEGMENTS=$(printf '%s\n' "$CLEAN" | awk '{ gsub(/&&|\|\||[;|&()]/, "\n"); print }')

# Shell keywords and wrappers that run the command after them.
skip_wrappers() { # sets i past them
  while [ "$i" -lt "${#words[@]}" ]; do
    case "${words[$i]}" in
      if | then | else | elif | do | while | until | ! | time | command | exec | nohup | builtin) i=$((i + 1)) ;;
      env)
        i=$((i + 1))
        while [ "$i" -lt "${#words[@]}" ] && printf '%s' "${words[$i]}" | grep -qE '^(-|[A-Za-z_][A-Za-z0-9_]*=)'; do i=$((i + 1)); done
        ;;
      timeout)
        i=$((i + 1))
        while [ "$i" -lt "${#words[@]}" ] && [ "${words[$i]#-}" != "${words[$i]}" ]; do i=$((i + 1)); done
        i=$((i + 1)) # the duration
        ;;
      *)
        if printf '%s' "${words[$i]}" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*='; then i=$((i + 1)); else return 0; fi
        ;;
    esac
  done
}

# Pushes that come after a branch-moving command in the same call.
moved_then() { # what
  block "verify-gate: $1 runs in the same Bash call as a command that moves the branch ($MOVED), so this hook can't see what it would push. Run the push in its own Bash call, after verify --full."
}

DIR=$CWD MOVED=""
while IFS= read -r seg; do
  read -ra toks <<<"$seg" || true
  [ "${#toks[@]}" -gt 0 ] || continue
  # Strip quotes around each word, and VAR=value prefixes.
  words=()
  for t in "${toks[@]}"; do
    t=${t#[\"\']}
    t=${t%[\"\']}
    words+=("$t")
  done
  i=0
  skip_wrappers
  [ "$i" -lt "${#words[@]}" ] || continue
  cmd=${words[$i]##*/}
  case "$cmd" in
    cd)
      [ $((i + 1)) -lt "${#words[@]}" ] && DIR=$(resolve "${words[$((i + 1))]}" "$DIR")
      ;;
    git)
      gdir=$DIR
      i=$((i + 1))
      while [ "$i" -lt "${#words[@]}" ]; do
        case "${words[$i]}" in
          -C)
            gdir=$(resolve "${words[$((i + 1))]:-.}" "$gdir")
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
          if [ -n "$MOVED" ]; then
            moved_then "git push"
          else
            rest=()
            [ $((i + 1)) -ge "${#words[@]}" ] || rest=("${words[@]:$((i + 1))}")
            check_push "$gdir" ${rest[@]+"${rest[@]}"}
          fi
          ;;
        merge | rebase | cherry-pick | revert | reset | pull | am | switch | checkout | stash) MOVED="git ${words[$i]}" ;;
      esac
      ;;
    gh)
      sub="${words[$((i + 1))]:-} ${words[$((i + 2))]:-}"
      [ "$sub" != "pr new" ] || sub="pr create"
      if [ -n "$MOVED" ]; then
        case "$sub" in "pr create" | "stack push" | "stack submit")
          moved_then "gh $sub"
          continue
          ;;
        esac
      fi
      case "$sub" in
        "pr create")
          rest=()
          [ $((i + 3)) -ge "${#words[@]}" ] || rest=("${words[@]:$((i + 3))}")
          check_pr_create "$DIR" ${rest[@]+"${rest[@]}"}
          ;;
        "stack push" | "stack submit" | "stack sync") check_stack "$DIR" "${words[$((i + 2))]}" ;;
      esac
      ;;
  esac
done <<<"$SEGMENTS"

if [ -n "$REASONS" ]; then
  printf '%s' "$REASONS" >&2
  exit 2
fi
exit 0
