#!/bin/bash
# PreToolUse hook: macOS's Keychain-backed `gh` credential can fail to
# propagate through an extra process boundary when a script/skill/plugin
# shells out to `gh` from inside its own subprocess. That makes `gh`
# behave as effectively unauthenticated and GitHub returns 404 (not 401)
# for private-repo calls - a real auth-propagation bug that reads like a
# permissions or path bug. This denies a command that runs such a script
# unless GH_TOKEN is exported inline in the same command.
#
# How it decides (everything else passes):
#   - The command is split into simple commands at ; & | ( ) and backticks
#     (not inside quotes, comments or a <<'EOF' heredoc body, where they
#     separate nothing), and only what each one *executes* is looked at: `bash X` / `sh X` /
#     `zsh X`, `python3 X` / `node X` / `ruby X` / `perl X`, and a path or
#     `*.sh` at command position (`./X`, `dir/X`, `X.sh`). Scripts passed to
#     cat, find, grep, sed, ls, chmod, git and the like, or to `bash -n`, are
#     not executed and are ignored. `cd DIR` earlier in the command moves the
#     directory scripts are resolved against (the hook input's `cwd`).
#   - Each executed script is read, and the command is denied only if the
#     script calls `gh` or `gh-stack`. In a shell script that means at
#     command position (start of line, after ; & | ( or $(, or after
#     if/then/do/xargs/...), so comments and quoted strings that mention gh
#     do not count. In a Python/Node/Ruby/Perl script any `gh ` or `"gh",`
#     counts, to catch subprocess argument lists.
#   - A script it cannot find or read (a path built from a variable, a
#     missing file) is denied, as before, because it cannot be ruled out.
#   - `gh-stack` at command position is always denied: it is a known
#     wrapper that calls `gh` itself.
#   - A direct `gh ...` call and any command containing `GH_TOKEN=` pass.
#
# It only looks one level deep: a script that runs another script that calls
# `gh` is not caught. It is a guard against the common case, not a proof.
set -euo pipefail

INPUT=$(cat)
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')
DIR=$(printf '%s' "$INPUT" | jq -r '.cwd // ""')
[ -n "$DIR" ] || DIR=$PWD

# GH_TOKEN already exported inline for this command - fine as-is.
case "$COMMAND" in *GH_TOKEN=*) exit 0 ;; esac

# A gh/gh-stack call at command position inside a shell script.
POS='(^|[;&|(`]|\$\(|(^|[^A-Za-z0-9_])(then|do|else|if|elif|while|until|exec|command|time|xargs|!))[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*'
SHELL_GH_RE="${POS}(gh[[:space:]]|gh-stack([[:space:]]|\$))"
# Any gh/gh-stack invocation in another language's script, including the
# first element of an argument list such as ["gh", "api", ...].
OTHER_GH_RE='(^|[^A-Za-z0-9_.-])gh(-stack)?([[:space:]]|["'"'"'],)'

deny() {
  local reason="GH_TOKEN export check: $1 macOS Keychain-backed \`gh\` auth can silently fail to propagate through that extra process boundary, producing a \`404\` that reads like a permissions bug. Prefix this command with \`GH_TOKEN=\$(gh auth token)\` in the same shell invocation before retrying."
  jq -n --arg reason "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

unquote() {
  local p=$1
  p=${p#[\"\']}
  p=${p%[\"\']}
  case "$p" in
    "~/"*) p="$HOME/${p#\~/}" ;;
    '$HOME/'*) p="$HOME/${p#\$HOME/}" ;;
    '${HOME}/'*) p="$HOME/${p#\$\{HOME\}/}" ;;
  esac
  printf '%s' "$p"
}

# Print the absolute path a script token refers to, or nothing if it cannot
# be resolved (contains an unexpanded variable, or is not found).
resolve() {
  local p
  p=$(unquote "$1")
  case "$p" in *'$'* | *'`'*) return 0 ;; esac
  case "$p" in
    /*) ;;
    */*) p="$DIR/$p" ;;
    *) if [ -f "$DIR/$p" ]; then p="$DIR/$p"; else p=$(command -v -- "$p" 2>/dev/null || true); fi ;;
  esac
  printf '%s' "$p"
}

# $1 = script token as written, $2 = shell | other | auto
check_script() {
  local tok=$1 kind=$2 f first="" re
  f=$(resolve "$tok")
  if [ -z "$f" ] || [ ! -f "$f" ] || [ ! -r "$f" ]; then
    deny "this command runs \`$tok\`, which could not be read to check whether it shells out to \`gh\` from its own subprocess."
  fi
  if [ "$kind" = auto ]; then
    case "$f" in
      *.py | *.js | *.mjs | *.cjs | *.ts | *.rb | *.pl) kind=other ;;
      *)
        IFS= read -r first <"$f" || true
        case "$first" in
          '#!'*python* | '#!'*node* | '#!'*ruby* | '#!'*perl* | '#!'*deno* | '#!'*bun*) kind=other ;;
          *) kind=shell ;;
        esac
        ;;
    esac
  fi
  # A compiled binary at a path (./bin/tool, /usr/bin/git) is not text and
  # is not something this hook can judge.
  if [ -s "$f" ] && ! grep -qI '' "$f"; then
    return 0
  fi
  if [ "$kind" = shell ]; then
    text=$(strip_shell <"$f")
    re=$SHELL_GH_RE
  else
    text=$(cat "$f")
    re=$OTHER_GH_RE
  fi
  if grep -qE -- "$re" <<<"$text"; then
    deny "this command runs \`$tok\`, which shells out to \`gh\` from its own subprocess."
  fi
}

# Drop comments and quoted strings from a shell script, so a mention like
# '# needs gh' or "run gh pr view" is not read as a call. A double-quoted
# string that contains $( or a backtick is kept, since "$(gh api ...)" runs.
# Quote state resets at each line: an apostrophe in a heredoc then cannot
# swallow the rest of the file, at the cost of treating the inside of a
# multi-line string as code (which errs towards denying).
strip_shell() {
  awk '{
    out = ""; buf = ""; st = ""; n = length($0)
    for (k = 1; k <= n; k++) {
      c = substr($0, k, 1)
      if (st == "sq") { if (c == "\047") st = ""; continue }
      if (st == "dq") {
        if (c == "\\") { buf = buf c substr($0, k + 1, 1); k++; continue }
        if (c == "\"") { st = ""; if (runs(buf)) out = out " " buf " "; buf = ""; continue }
        buf = buf c; continue
      }
      if (c == "\\") { out = out c substr($0, k + 1, 1); k++; continue }
      if (c == "\047") { st = "sq"; continue }
      if (c == "\"") { st = "dq"; buf = ""; continue }
      if (c == "#" && (k == 1 || substr($0, k - 1, 1) ~ /[ \t;&|(]/)) break
      out = out c
    }
    if (st == "dq" && runs(buf)) out = out " " buf
    print out
  }
  # A string runs code if it has an unescaped $( or backtick.
  function runs(s) { gsub(/\\./, "", s); return s ~ /\$\(|`/ }'
}

# Replace ; & | ( ) and backticks with spaces wherever they can't separate
# commands, so the split below only cuts where the shell would: inside
# single quotes, inside double quotes with no $( or backtick, in comments,
# and in the body of a heredoc with a quoted delimiter (<<'EOF'). Text that
# runs as code stays as it is: a double-quoted string with $( or a backtick,
# an unquoted heredoc body, and a quoted argument to `-c` or `eval`.
blank_quoted_separators() {
  awk '
    function blank(s) { gsub(/[;&|()`]/, " ", s); return s }
    function runs(s) { gsub(/\\./, "", s); return s ~ /\$\(|`/ }
    BEGIN { st = ""; buf = ""; res = ""; hd = ""; pend = "" }
    {
      line = $0
      if (hd != "") {
        t = line
        if (hdtab) sub(/^\t+/, "", t)
        if (t == hd) hd = ""
        res = res (hdq ? blank(line) : line) "\n"
        next
      }
      out = ""; n = length(line)
      for (k = 1; k <= n; k++) {
        c = substr(line, k, 1)
        if (st == "sq") {
          if (c == "\047") { out = out (code ? buf : blank(buf)) c; buf = ""; st = "" } else buf = buf c
          continue
        }
        if (st == "dq") {
          if (c == "\\") { buf = buf c substr(line, k + 1, 1); k++; continue }
          if (c == "\"") { out = out ((code || runs(buf)) ? buf : blank(buf)) c; buf = ""; st = ""; continue }
          buf = buf c
          continue
        }
        if (c == "\\") { out = out c substr(line, k + 1, 1); k++; continue }
        if (c == "\047" || c == "\"") {
          code = (out ~ /(^|[ \t;&|(\/])(ba|z|da|k)?sh([ \t]+-[A-Za-z]+)*[ \t]+-[A-Za-z]*c[ \t]+$/ || out ~ /(^|[ \t;&|(])eval[ \t]+$/)
          st = (c == "\047") ? "sq" : "dq"
          out = out c; buf = ""
          continue
        }
        if (c == "#" && (k == 1 || substr(line, k - 1, 1) ~ /[ \t;&|(]/)) { out = out blank(substr(line, k)); break }
        if (c == "<" && substr(line, k, 2) == "<<" && substr(line, k, 3) != "<<<") {
          rest = substr(line, k + 2)
          tab = (substr(rest, 1, 1) == "-")
          if (tab) rest = substr(rest, 2)
          sub(/^[ \t]+/, "", rest)
          if (match(rest, /^[\047"]?[A-Za-z0-9_.-]+[\047"]?/)) {
            pend = substr(rest, 1, RLENGTH); pendq = (pend ~ /[\047"]/); pendtab = tab
            gsub(/[\047"]/, "", pend)
          }
        }
        out = out c
      }
      if (st != "") { res = res out; buf = buf "\n" }
      else res = res out "\n"
      if (st == "" && pend != "") { hd = pend; hdq = pendq; hdtab = pendtab; pend = "" }
    }
    END { if (st != "") res = res buf; printf "%s", res }'
}

while IFS= read -r seg; do
  W=()
  read -ra W <<<"$seg" || true
  n=${#W[@]}
  i=0
  # Skip env assignments, shell keywords and transparent wrappers.
  while [ "$i" -lt "$n" ]; do
    case "${W[$i]}" in
      [A-Za-z_]*=*) ;;
      then | do | else | if | elif | while | until | exec | command | time | nohup | env | sudo | nice | '!' | '{' | '$') ;;
      *) break ;;
    esac
    i=$((i + 1))
  done
  [ "$i" -lt "$n" ] || continue
  cmd=$(unquote "${W[$i]}")
  i=$((i + 1))

  case "${cmd##*/}" in
    gh)
      ;;
    gh-stack)
      deny "this command runs \`gh-stack\`, a wrapper that shells out to \`gh\` from its own subprocess."
      ;;
    cd)
      if [ "$i" -lt "$n" ]; then
        d=$(unquote "${W[$i]}")
        case "$d" in
          - | *'$'* | *'`'*) ;;
          /*) DIR=$d ;;
          *) DIR="$DIR/$d" ;;
        esac
      fi
      ;;
    bash | sh | zsh | dash | ksh)
      syntax_only=0 inline=0
      while [ "$i" -lt "$n" ]; do
        a=${W[$i]}
        case "$a" in
          --) i=$((i + 1)); break ;;
          -o | +o | -O | +O | --rcfile | --init-file) i=$((i + 2)); continue ;;
          --*) ;;
          -* | +*)
            case "$a" in -*n*) syntax_only=1 ;; esac
            case "$a" in -*c*) inline=1 ;; esac
            ;;
          *) break ;;
        esac
        i=$((i + 1))
      done
      # -n only parses the script; -c code is itself part of this command,
      # so any gh in it is a direct call, checked segment by segment.
      if [ "$syntax_only" -eq 0 ] && [ "$i" -lt "$n" ]; then
        if [ "$inline" -eq 0 ]; then
          check_script "${W[$i]}" shell
        else
          # `bash -c './x.sh ...'`: the first word of the code may be a script.
          code=$(unquote "${W[$i]}")
          case "$code" in */* | *.sh) check_script "$code" auto ;; esac
        fi
      fi
      ;;
    python* | node | ruby | perl)
      while [ "$i" -lt "$n" ]; do
        a=${W[$i]}
        case "$a" in
          -c | -e | -m | -p | --eval | --print) i=$n; break ;;
          -W | -X | -r | -I | --require) i=$((i + 2)); continue ;;
          -*) ;;
          *) break ;;
        esac
        i=$((i + 1))
      done
      if [ "$i" -lt "$n" ]; then
        check_script "${W[$i]}" other
      fi
      ;;
    *)
      case "$cmd" in
        */* | *.sh) check_script "$cmd" auto ;;
      esac
      ;;
  esac
done < <(printf '%s\n' "$COMMAND" | blank_quoted_separators | tr ';&|()`' '\n\n\n\n\n\n')

exit 0
