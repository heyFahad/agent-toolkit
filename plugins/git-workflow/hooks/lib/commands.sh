# shellcheck shell=bash disable=SC2034 # words and i are read by the hooks that source this
# Splits a Bash tool command into simple commands, for the git-workflow hooks.
# Sourced, never run on its own. Keep it bash 3.2 compatible: it runs under
# macOS's /bin/bash.
#
#   hc_segments COMMAND   print one simple command per line
#   hc_words SEGMENT      set `words` (the segment's words, one pair of
#                         surrounding quotes stripped from each) and `i`, the
#                         index of the first word past wrappers like env,
#                         timeout and VAR=value
#   hc_resolve DIR BASE   a cd or -C argument as a path, against BASE
#
# Only a command at command position counts this way: `echo "git push"` is
# an echo, and heredoc bodies are dropped. Text inside quotes after a `;` or
# `&&` can still look like a command; callers err towards treating it as one.

hc_resolve() { # dir base
  local d=${1/#\~/$HOME}
  case "$d" in /*) ;; *) d="$2/$d" ;; esac
  (cd "$d" 2>/dev/null && pwd) || printf '%s' "$d"
}

hc_segments() { # command
  # A backslash at the end of a line continues the command: join first. Then
  # drop heredoc bodies, which aren't commands. Then split on ; && || | & ( )
  # and newlines.
  printf '%s\n' "$1" | awk '
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
    }' | awk '{ gsub(/&&|\|\||[;|&()]/, "\n"); print }'
}

# Shell keywords and wrappers that run the command after them.
hc_skip_wrappers() { # sets i past them
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

hc_words() { # segment
  local toks t
  words=()
  i=0
  read -ra toks <<<"$1" || true
  [ "${#toks[@]}" -gt 0 ] || return 0
  for t in "${toks[@]}"; do
    t=${t#[\"\']}
    t=${t%[\"\']}
    words+=("$t")
  done
  hc_skip_wrappers
}

# hc_gh_command: with words[i] being gh, sets
#   gh_sub    the command group and verb, e.g. "pr ready" or "label create"
#             (for gh api, "api <endpoint>")
#   gh_args   the index of the first word after the verb
#   gh_repo   a -R/--repo value given between the group and the verb, as in
#             `gh pr -R o/r ready 5`, which gh accepts
hc_gh_command() {
  local j=$((i + 2)) group=${words[$((i + 1))]:-}
  gh_repo=""
  while [ "$j" -lt "${#words[@]}" ]; do
    case "${words[$j]}" in
      -R | --repo)
        gh_repo=${words[$((j + 1))]:-}
        j=$((j + 2))
        ;;
      --repo=*)
        gh_repo=${words[$j]#--repo=}
        j=$((j + 1))
        ;;
      -R?*)
        gh_repo=${words[$j]#-R}
        j=$((j + 1))
        ;;
      *) break ;;
    esac
  done
  gh_sub="$group ${words[$j]:-}"
  gh_args=$((j + 1))
}
