#!/bin/bash
# PreToolUse hook (Bash): blocks committing or pushing a tree that hasn't
# passed the repo's checks. See the verify skill for the checks, the levels
# and the records this reads.
#
#   git commit                        the working tree needs a passing
#                                     `verify --related` (or --full) record
#   git push, gh pr create,           every branch tree being pushed needs a
#   gh stack push, gh stack submit    passing `verify --full` record
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

# need TREE LEVEL ROOT WHAT: block unless TREE has a passing record at LEVEL.
need() {
  local tree=$1 level=$2 root=$3 what=$4 f detail=""
  vf_record_ok "$tree" "$level" && return 0
  f=$(vf_record_file "$tree")
  if [ -f "$f" ]; then
    detail=$(jq -r 'if .passed then "Its last run was only --\(.level)."
      else "Its last run failed at \([.commands[] | select(.exit != 0) | .name][0] // "a check that changed tracked files")." end' "$f" 2>/dev/null)
  fi
  block "verify-gate: $what needs a passing \`verify --$level\` of the tree it would take (${tree:0:7}). ${detail:+$detail }Run, from $root: bash $VERIFY --$level"
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
    refs=(HEAD)
  fi
  for t in "${refs[@]}"; do
    t=${t#+}
    src=${t%%:*}
    [ -n "$src" ] || continue # :dst deletes dst
    case "$src" in refs/tags/*) continue ;; esac
    git -C "$root" show-ref -q --verify "refs/tags/$src" 2>/dev/null && continue
    tree=$(tree_of "$root" "$src") || continue # unknown ref: git push fails on its own
    need "$tree" full "$root" "git push of $src"
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
  tree=$(tree_of "$root" "$head") || return 0
  need "$tree" full "$root" "gh pr create from $head"
}

# Heredoc bodies aren't commands: drop them.
CLEAN=$(printf '%s\n' "$COMMAND" | awk -v q="'" '
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

DIR=$CWD
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
  while [ "$i" -lt "${#words[@]}" ] && printf '%s' "${words[$i]}" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*='; do i=$((i + 1)); done
  [ "$i" -lt "${#words[@]}" ] || continue
  cmd=${words[$i]}
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
        commit) check_commit "$gdir" ;;
        push)
          rest=()
          [ $((i + 1)) -ge "${#words[@]}" ] || rest=("${words[@]:$((i + 1))}")
          check_push "$gdir" ${rest[@]+"${rest[@]}"}
          ;;
      esac
      ;;
    gh)
      sub="${words[$((i + 1))]:-} ${words[$((i + 2))]:-}"
      case "$sub" in
        "pr create")
          rest=()
          [ $((i + 3)) -ge "${#words[@]}" ] || rest=("${words[@]:$((i + 3))}")
          check_pr_create "$DIR" ${rest[@]+"${rest[@]}"}
          ;;
      esac
      ;;
  esac
done <<<"$SEGMENTS"

if [ -n "$REASONS" ]; then
  printf '%s' "$REASONS" >&2
  exit 2
fi
exit 0
