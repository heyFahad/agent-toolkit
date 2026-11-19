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
#     (not inside quotes or comments, where they separate nothing), and only
#     what each one *executes* is looked at: `bash X` / `sh X` / `zsh X`,
#     `python3 X` / `node X` / `ruby X` / `perl X`, and a path or `*.sh` at
#     command position (`./X`, `dir/X`, `X.sh`). Scripts passed to cat, find,
#     grep, sed, ls, chmod, git and the like, or to `bash -n`, are not
#     executed and are ignored. `cd DIR` earlier in the command moves the
#     directory scripts are resolved against (the hook input's `cwd`).
#   - A heredoc body is the reader's stdin, not part of the command. It is
#     checked as code only when the reader runs it: `bash <<EOF`, `sh -s
#     <<EOF` or `cat <<EOF | bash` run it as shell, so its lines are checked
#     like the command's own; `python3 <<EOF` or `python3 - "$f" <<EOF` run
#     it as a script, so it is checked like a Python/Node/... script file.
#     For any other reader (cat, tee, git commit -F-, `bash x.sh`, `bash -n`)
#     the body is data and skipped, except that with an unquoted delimiter
#     (<<EOF, not <<'EOF') the `$(...)` and backticks inside it run first
#     and are checked.
#   - A script written earlier in the same command does not exist yet when
#     this hook runs, so what goes into it is checked instead: a heredoc
#     body written by `cat > f` or `tee f`, or the source of `cp`/`mv`/
#     `install`/`ln` (for a copied directory, the same file inside the
#     source) as it was when copied. An append (`>>`, `tee -a`, `touch`)
#     checks what the file held before as well as what was added. A file
#     replaced some other way (`printf ... > f`, `sed ... > f`) is let
#     through unchecked, since its content can't be known before the
#     command runs.
#   - Each executed script is read, and the command is denied only if the
#     script calls `gh` or `gh-stack`. In a shell script that means at
#     command position (start of line, after ; & | ( or $(, or after
#     if/then/do/xargs/...), so comments and quoted strings that mention gh
#     do not count. In a Python/Node/Ruby/Perl script any `gh ` or `"gh",`
#     counts, to catch subprocess argument lists.
#   - A script path with a variable in it is resolved from `name=value`
#     assignments made earlier in the same command (`t=./x.sh; bash "$t"`)
#     and from $HOME. A path that still has a `$` or backtick left in it
#     (`bash "$f"` inside a for loop, `"$TMPDIR/x.py"`, `$(mktemp)`) is let
#     through unchecked. That is a trade-off: denying it made the hook deny
#     most loops and temp-file scripts, and the only way past such a deny
#     was adding GH_TOKEN= to the command anyway, which turns the check off
#     for the whole command. A literal path that cannot be found or read
#     is still denied, because it cannot be ruled out.
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

# Variables assigned earlier in this command (`name=value`), newest last,
# with their values already expanded. A value that can't be expanded is
# stored as a lone backtick, which no path resolves through.
VAR_NAMES=(HOME)
VAR_VALS=("$HOME")
# Files written earlier in this command, newest last: absolute path, how
# (body | alias | unknown) and the heredoc body or the source path.
WR_PATHS=()
WR_KINDS=()
WR_DATA=()
# Heredoc bodies by index, from blank_quoted_separators.
HD_BODY=()

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
  esac
  printf '%s' "$p"
}

# Record a `name=value` word so later $name / ${name} can be resolved. The
# value is expanded now, as the shell does: `s=$t; t=x; bash "$s"` runs
# the old $t.
remember() {
  [[ $1 =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || return 0
  local raw=${1#*=} val
  val=$(unquote "$raw")
  if [ -n "$val" ]; then
    case "$raw" in
      # Single-quoted: a literal, and a literal $ is no path to resolve.
      \'*) case "$val" in *'$'* | *'`'*) val='`' ;; esac ;;
      *) val=$(expand "$val"); [ -n "$val" ] || val='`' ;;
    esac
  fi
  VAR_NAMES+=("${1%%=*}")
  VAR_VALS+=("$val")
}

# Print $1 with every $name / ${name} replaced by its value from this
# command, or nothing if a variable is unknown or a $ or backtick is left.
expand() {
  local p=$1 m name val pre post j found guard=0
  local re='\$(\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))'
  while [[ $p =~ $re ]] && [ "$guard" -lt 20 ]; do
    m=${BASH_REMATCH[0]}
    name=${BASH_REMATCH[2]}${BASH_REMATCH[3]}
    found=0
    for ((j = ${#VAR_NAMES[@]} - 1; j >= 0; j--)); do
      if [ "${VAR_NAMES[$j]}" = "$name" ]; then
        val=${VAR_VALS[$j]} found=1
        break
      fi
    done
    [ "$found" -eq 1 ] || return 0
    pre=${p%%"$m"*}
    post=${p#*"$m"}
    p=$pre$val$post
    guard=$((guard + 1))
  done
  case "$p" in *'$'* | *'`'*) return 0 ;; esac
  printf '%s' "$p"
}

# Print the absolute path an expanded script path refers to, or nothing if
# it is a bare name that is not found.
resolve() {
  local p=$1
  case "$p" in
    /*) ;;
    */*) p="$DIR/$p" ;;
    *) if [ -f "$DIR/$p" ]; then p="$DIR/$p"; else p=$(command -v -- "$p" 2>/dev/null || true); fi ;;
  esac
  printf '%s' "$p"
}

# Print a token as an absolute, tidied path, or nothing if it has a
# variable this command does not set.
abspath() {
  local p part parts=() out=()
  p=$(expand "$(unquote "$1")")
  [ -n "$p" ] || return 0
  case "$p" in /*) ;; *) p="$DIR/$p" ;; esac
  IFS=/ read -ra parts <<<"$p"
  for part in ${parts[@]+"${parts[@]}"}; do
    case "$part" in
      '' | .) ;;
      ..) [ "${#out[@]}" -eq 0 ] || out=("${out[@]:0:${#out[@]}-1}") ;;
      *) out+=("$part") ;;
    esac
  done
  p=
  for part in ${out[@]+"${out[@]}"}; do p="$p/$part"; done
  printf '%s' "${p:-/}"
}

# $1 = path token written by this command, $2 = body | alias | unknown,
# $3 = the heredoc body, or the source path's token.
remember_write() {
  local a src=""
  a=$(abspath "$1")
  case "$a" in '' | /dev/*) return 0 ;; esac
  if [ "$2" = alias ]; then
    src=$(abspath "$3")
    # A source path this hook can't resolve leaves the copy unknown too.
    [ -n "$src" ] || { remember_write "$1" unknown ""; return 0; }
  fi
  WR_PATHS+=("$a")
  WR_KINDS+=("$2")
  WR_DATA+=("${src:-$3}")
}

# $1 = path token, $2 = w (replace) | a (append), $3 = body | unknown,
# $4 = the body. Appending what can't be known adds nothing to check, but
# what the file held before still runs.
write() {
  if [ "$2" = a ]; then
    if [ "$3" = body ]; then remember_write "$1" append "$4"; else remember_write "$1" append ""; fi
  else
    remember_write "$1" "$3" "$4"
  fi
}

# Remember the files the current simple command writes, from its name
# ($1), its heredoc's index ($2, if any) and split_redirects' ARGS and
# OUT_FILES.
note_writes() {
  local name=$1 hd=$2 how=unknown body="" t k m dest d
  local files=()
  if [ -n "$hd" ] && [ -n "${HD_BODY[$hd]+x}" ]; then
    how=body body=${HD_BODY[$hd]}
  fi
  local mode=w
  # Only cat with no file arguments copies its stdin as it is.
  if [ "$name" != cat ] || [ "${#ARGS[@]}" -ne 0 ]; then
    how=unknown body=""
  fi
  for ((k = 0; k < ${#OUT_FILES[@]}; k++)); do
    write "${OUT_FILES[$k]}" "${OUT_MODES[$k]}" "$how" "$body"
  done
  case "$name" in
    tee)
      how=unknown body=""
      if [ -n "$hd" ] && [ -n "${HD_BODY[$hd]+x}" ]; then
        how=body body=${HD_BODY[$hd]}
      fi
      for t in ${ARGS[@]+"${ARGS[@]}"}; do
        case "$t" in -a | --append) mode=a ;; esac
      done
      for t in ${ARGS[@]+"${ARGS[@]}"}; do
        case "$t" in -*) ;; *) write "$t" "$mode" "$how" "$body" ;; esac
      done
      ;;
    touch)
      # Makes a missing file empty and leaves an existing one as it was:
      # appending nothing does both.
      for t in ${ARGS[@]+"${ARGS[@]}"}; do
        case "$t" in -*) ;; *) remember_write "$t" append "" ;; esac
      done
      ;;
    cp | mv | install | ln)
      k=0 m=${#ARGS[@]}
      while [ "$k" -lt "$m" ]; do
        case "${ARGS[$k]}" in
          -m | -o | -g | -S) k=$((k + 1)) ;;
          -*) ;;
          *) files+=("${ARGS[$k]}") ;;
        esac
        k=$((k + 1))
      done
      m=${#files[@]}
      if [ "$m" -ge 2 ]; then
        dest=${files[$((m - 1))]}
        for ((k = 0; k < m - 1; k++)); do
          d=$dest
          if [ "$m" -gt 2 ] || [[ $dest == */ ]] || [ -d "$(abspath "$dest")" ]; then
            d="${dest%/}/$(basename -- "$(unquote "${files[$k]}")")"
          fi
          remember_write "$d" alias "${files[$k]}"
        done
      fi
      ;;
  esac
  return 0
}

# $1 = script token, $2 = shell | other | auto, $3 = the token as the
# command wrote it, $4 = only look at writes before this index (what the
# file held at that point), $5 = 1 if a missing file counts as empty.
check_script() {
  local tok=$1 kind=$2 shown=${3:-$1} limit=${4:-${#WR_PATHS[@]}} optional=${5:-0} p a f k w
  p=$(expand "$(unquote "$tok")")
  # Built from a variable this command does not set: see the header.
  [ -n "$p" ] || return 0
  # Written earlier in this command: check what went into it. A copied
  # directory (cp -r a b) maps b/x to a/x. Each step back looks only at
  # writes made before it, so this always ends.
  a=$(abspath "$p")
  for ((k = limit - 1; k >= 0; k--)); do
    w=${WR_PATHS[$k]}
    [ "$w" != "$a" ] || break
    if [ "${WR_KINDS[$k]}" = alias ] && [[ $a == "$w"/* ]]; then
      # Inside a copied directory: the same file in the source, as it was.
      check_script "${WR_DATA[$k]}${a#"$w"}" "$kind" "$shown" "$k" "$optional"
      return 0
    fi
  done
  if [ "$k" -ge 0 ]; then
    case "${WR_KINDS[$k]}" in
      body) check_text "$shown" "$kind" "$p" "${WR_DATA[$k]}" ;;
      # A copy holds what its source held when it was copied.
      alias) check_script "${WR_DATA[$k]}" "$kind" "$shown" "$k" "$optional" ;;
      # Appended to: what the file held before, then what was added.
      append)
        check_script "$a" "$kind" "$shown" "$k" 1
        check_text "$shown" "$kind" "$p" "${WR_DATA[$k]}"
        ;;
    esac
    return 0
  fi
  f=$(resolve "$p")
  if [ -z "$f" ] || [ ! -f "$f" ] || [ ! -r "$f" ]; then
    [ "$optional" -eq 0 ] || return 0
    deny "this command runs \`$shown\`, which could not be read to check whether it shells out to \`gh\` from its own subprocess."
  fi
  # A compiled binary at a path (./bin/tool, /usr/bin/git) is not text and
  # is not something this hook can judge.
  if [ -s "$f" ] && ! grep -qI '' "$f"; then
    return 0
  fi
  check_text "$shown" "$kind" "$f" "$(cat "$f")"
}

# $1 = script token, $2 = shell | other | auto, $3 = its path, $4 = its text
check_text() {
  local tok=$1 kind=$2 text=$4 first re
  if [ "$kind" = auto ]; then
    case "$3" in
      *.py | *.js | *.mjs | *.cjs | *.ts | *.rb | *.pl) kind=other ;;
      *)
        first=${text%%$'\n'*}
        case "$first" in
          '#!'*python* | '#!'*node* | '#!'*ruby* | '#!'*perl* | '#!'*deno* | '#!'*bun*) kind=other ;;
          *) kind=shell ;;
        esac
        ;;
    esac
  fi
  if [ "$kind" = shell ]; then
    text=$(strip_shell <<<"$text")
    re=$SHELL_GH_RE
  else
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

# Reduce the command to the text that runs as shell code, so the split
# below only cuts where the shell would. ; & | ( ) and backticks become
# spaces inside single quotes, inside double quotes with no $( or backtick,
# and in comments; text that runs stays as it is (a double-quoted string
# with $( or a backtick, a quoted argument to `-c` or `eval`). Heredoc
# bodies are handled as the header describes: kept as code for a shell
# reader, cut down to their $(...) and backticks for any other reader
# when the delimiter is unquoted, dropped otherwise. Bodies fed to a
# Python/Node/Ruby/Perl reader are printed after a \036 separator, to be
# checked as a script.
blank_quoted_separators() {
  awk '
    function blank(s) { gsub(/[;&|()`]/, " ", s); return s }
    function runs(s) { gsub(/\\./, "", s); return s ~ /\$\(|`/ }
    # Inside an unclosed $( ... in a double-quoted string.
    function insubst(s,   o, c) {
      gsub(/\\./, "", s)
      if (s !~ /\$\(/) return 0
      o = gsub(/\(/, "(", s); c = gsub(/\)/, ")", s)
      return o > c
    }
    # The $(...) and backtick contents of a line, one per line ($((...)) is
    # arithmetic, not a command).
    function substs(s,   out, k, n, c, d, j) {
      out = ""; n = length(s)
      for (k = 1; k <= n; k++) {
        c = substr(s, k, 1)
        if (c == "\\") { k++; continue }
        if (c == "`") {
          j = index(substr(s, k + 1), "`"); if (j == 0) j = n - k + 1
          out = out substr(s, k + 1, j - 1) "\n"; k += j; continue
        }
        if (c == "$" && substr(s, k + 1, 1) == "(" && substr(s, k + 2, 1) != "(") {
          d = 1
          for (j = k + 2; j <= n && d > 0; j++) { c = substr(s, j, 1); if (c == "(") d++; else if (c == ")") d-- }
          out = out substr(s, k + 2, j - k - 3) "\n"; k = j - 1
        }
      }
      return out
    }
    # How the simple command in s uses its stdin: "code" (a shell runs it),
    # "script" (an interpreter runs it) or "data". Sets rcmd to its name.
    function reader(s,   w, nw, i, a, shell, sflag, syn, endopts) {
      rcmd = ""
      nw = split(s, w, /[ \t\n]+/)
      for (i = 1; i <= nw; i++)
        if (w[i] != "" && w[i] !~ /^\037/ && w[i] !~ /^[A-Za-z_][A-Za-z0-9_]*=/ && w[i] !~ /^(then|do|else|if|elif|while|until|exec|command|time|nohup|env|sudo|nice|!|[{])$/) break
      if (i > nw) return "data"
      rcmd = w[i]; gsub(/[\047"]/, "", rcmd); sub(/.*\//, "", rcmd)
      if (rcmd ~ /^(ba|z|da|k)?sh$/) shell = 1
      else if (rcmd ~ /^(python[0-9.]*|node|ruby|perl)$/) shell = 0
      else return "data"
      sflag = syn = endopts = 0
      for (i++; i <= nw; i++) {
        a = w[i]
        if (a == "" || a ~ /^\037/) continue
        if (a ~ /^[0-9&]*[<>]+[&|]?$/) { i++; continue }
        if (a ~ /^[0-9&]*[<>]/) continue
        if (!endopts && a ~ /^[-+]/) {
          if (shell) {
            # For a shell, - and -- both end the options.
            if (a == "-" || a == "--") endopts = 1
            else if (a ~ /^[-+][oO]$/ || a == "--rcfile" || a == "--init-file") i++
            else if (a ~ /^--/) { }
            else if (a ~ /^-[A-Za-z]*c/) return "data"
            else {
              if (a ~ /^-[A-Za-z]*n/) syn = 1
              if (a ~ /^-[A-Za-z]*s/) sflag = 1
            }
          } else {
            # For an interpreter, a lone - is the script on stdin.
            if (a == "-") break
            if (a ~ /^(-c|-m|-e|-p|--eval|--print)$/) return "data"
            if (a ~ /^(-W|-X|-r|-I|--require|--import)$/) i++
          }
          continue
        }
        # An operand is the script file, unless bash -s reads stdin anyway.
        if (shell && sflag) break
        return "data"
      }
      # bash -n only parses its input.
      if (syn) return "data"
      return shell ? "code" : "script"
    }
    # How a heredoc body is used, from the command text before << (pre) and
    # the rest of the line (post). Piped on from cat or tee, it is what the
    # next command reads.
    function kind(pre, post,   k) {
      sub(/.*[;&|(`]/, "", pre)
      k = reader(pre)
      if (k == "data" && rcmd ~ /^(cat|tee)$/ && match(post, /[^|]\|[^;&|)]*/))
        k = reader(substr(post, RSTART + 2, RLENGTH - 2))
      return k
    }
    # Note a heredoc whose << is at position k of line.
    function heredoc(pre, line, k,   rest, tab) {
      rest = substr(line, k + 2)
      tab = (substr(rest, 1, 1) == "-")
      if (tab) rest = substr(rest, 2)
      sub(/^[ \t]+/, "", rest)
      if (match(rest, /^[\047"]?[A-Za-z0-9_.-]+[\047"]?/)) {
        pend = substr(rest, 1, RLENGTH); pendq = (pend ~ /[\047"]/); pendtab = tab
        gsub(/[\047"]/, "", pend)
        pendkind = kind(pre, substr(line, k))
        pendidx = ++hdn
      }
    }
    # A word that tells the main loop which heredoc (by index) this simple
    # command reads.
    function marker() { return pend != "" ? "\037" pendidx " " : "" }
    # Scan the code in a heredoc body on its own, without the quote state around
    # the heredoc, and add it to res on lines of its own.
    function emit(body,   sst, sbuf, scode) {
      if (body != "") {
        sst = st; sbuf = buf; scode = code; st = ""; buf = ""
        body = scan(body)
        if (st != "") body = body ((code || runs(buf)) ? buf : blank(buf))
        st = sst; buf = sbuf; code = scode; pend = ""
      }
      res = res "\n" body "\n"
    }
    # The end of the current heredoc: check the $(...) of an unquoted data
    # or script body as a whole, since one can span lines, and hand the body
    # to the main loop.
    function endhd() {
      if (hdkind != "code" && !hdq) emit(substs(hdbody))
      files = files hdidx "\037" hdbody "\035"
      hd = ""
    }
    # One line of code, with quote state (st, buf, code) carried across lines.
    function scan(line,   out, n, k, c) {
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
          if (c == "<" && substr(line, k, 2) == "<<" && substr(line, k, 3) != "<<<" && insubst(buf)) { heredoc(buf, line, k); buf = buf marker() }
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
        if (c == "<" && substr(line, k, 2) == "<<" && substr(line, k, 3) != "<<<") { heredoc(out, line, k); out = out marker() }
        out = out c
      }
      return out
    }
    BEGIN { st = ""; buf = ""; res = ""; hd = ""; pend = ""; bodies = ""; files = ""; hdn = 0 }
    {
      line = $0
      if (hd != "") {
        t = line
        if (hdtab) sub(/^\t+/, "", t)
        if (t == hd) { endhd(); next }
        hdbody = hdbody line "\n"
        if (hdkind == "script") bodies = bodies line "\n"
        if (hdkind == "code") emit(line)
        next
      }
      out = scan(line)
      if (st != "") { res = res out; buf = buf "\n" }
      else res = res out "\n"
      if (pend != "") { hd = pend; hdq = pendq; hdtab = pendtab; hdkind = pendkind; hdidx = pendidx; hdbody = ""; pend = "" }
    }
    END {
      if (hd != "") endhd()
      if (st != "") res = res buf
      printf "%s\036%s\036%s", res, bodies, files
    }'
}

# Split W[$1..] into ARGS, leaving out redirections. Set STDIN_FILE to the
# file a `< file` redirection reads, if any, and OUT_FILES to the files a
# `>` or `>>` redirection writes.
split_redirects() {
  local k=$1 a
  ARGS=()
  OUT_FILES=()
  OUT_MODES=()
  STDIN_FILE=
  while [ "$k" -lt "$n" ]; do
    a=${W[$k]}
    case "$a" in
      '<<' | '<<-' | '<<<') k=$((k + 1)) ;;
      '<<'*) ;;
      '<') k=$((k + 1)); STDIN_FILE=${W[$k]:-} ;;
      '<'*) STDIN_FILE=${a#<} ;;
      [0-9]'<') k=$((k + 1)) ;;
      [0-9]'<'*) ;;
      '>&'* | [0-9]'>&'*) ;;
      '>>' | '&>>' | [0-9]'>>')
        k=$((k + 1))
        [ "$k" -ge "$n" ] || { OUT_FILES+=("${W[$k]}"); OUT_MODES+=(a); }
        ;;
      '>' | '>|' | '&>' | [0-9]'>')
        k=$((k + 1))
        [ "$k" -ge "$n" ] || { OUT_FILES+=("${W[$k]}"); OUT_MODES+=(w); }
        ;;
      '>>'* | '&>>'* | [0-9]'>>'*) OUT_FILES+=("${a#*>>}"); OUT_MODES+=(a) ;;
      '>'* | '&>'* | [0-9]'>'*) OUT_FILES+=("${a#*>}"); OUT_MODES+=(w) ;;
      *) ARGS+=("$a") ;;
    esac
    k=$((k + 1))
  done
}

# res \036 stdin scripts \036 heredoc bodies (index \037 body \035 ...)
SCANNED=$(printf '%s\n' "$COMMAND" | blank_quoted_separators)
HEREDOCS=${SCANNED##*$'\036'}
SCANNED=${SCANNED%$'\036'*}
STDIN_SCRIPTS=${SCANNED#*$'\036'}
SCANNED=${SCANNED%%$'\036'*}
while :; do
  case "$HEREDOCS" in *$'\035'*) ;; *) break ;; esac
  rec=${HEREDOCS%%$'\035'*}
  HEREDOCS=${HEREDOCS#*$'\035'}
  HD_BODY[${rec%%$'\037'*}]=${rec#*$'\037'}
done

while IFS= read -r seg; do
  W=()
  read -ra W <<<"$seg" || true
  # Take out the heredoc marker, if any (see marker() above).
  hd=
  case "$seg" in
    *$'\037'*)
      V=()
      for w in ${W[@]+"${W[@]}"}; do
        case "$w" in $'\037'*) hd=${w#$'\037'} ;; *) V+=("$w") ;; esac
      done
      W=(${V[@]+"${V[@]}"})
      ;;
  esac
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
  if [ "$i" -ge "$n" ]; then
    # Nothing but assignments (`t=./x.sh`): they last for the rest of the command.
    for w in ${W[@]+"${W[@]}"}; do remember "$w"; done
    continue
  fi
  cmd=${W[$i]}
  case "$cmd" in
    *'$'*)
      e=$(expand "$(unquote "$cmd")")
      [ -z "$e" ] || cmd=$e
      ;;
    \"* | \'* | '~/'*) cmd=$(unquote "$cmd") ;;
  esac
  i=$((i + 1))
  # The files this writes, in case a later command in this one runs them.
  split_redirects "$i"
  note_writes "${cmd##*/}" "$hd"

  case "${cmd##*/}" in
    gh)
      ;;
    gh-stack)
      deny "this command runs \`gh-stack\`, a wrapper that shells out to \`gh\` from its own subprocess."
      ;;
    export | local | declare | typeset | readonly)
      while [ "$i" -lt "$n" ]; do remember "${W[$i]}"; i=$((i + 1)); done
      ;;
    cd)
      if [ "$i" -lt "$n" ]; then
        d=$(expand "$(unquote "${W[$i]}")")
        case "$d" in
          '' | -) ;;
          /*) DIR=$d ;;
          *) DIR="$DIR/$d" ;;
        esac
      fi
      ;;
    bash | sh | zsh | dash | ksh)
      split_redirects "$i"
      syntax_only=0 inline=0 from_stdin=0 j=0 m=${#ARGS[@]}
      while [ "$j" -lt "$m" ]; do
        a=${ARGS[$j]}
        case "$a" in
          --) j=$((j + 1)); break ;;
          -o | +o | -O | +O | --rcfile | --init-file) j=$((j + 2)); continue ;;
          --*) ;;
          # Like --, a lone - ends the options: `bash - x.sh` runs x.sh.
          -) j=$((j + 1)); break ;;
          -* | +*)
            case "$a" in -*n*) syntax_only=1 ;; esac
            case "$a" in -*c*) inline=1 ;; esac
            case "$a" in -*s*) from_stdin=1 ;; esac
            ;;
          *) break ;;
        esac
        j=$((j + 1))
      done
      # -n only parses the script; -c code is itself part of this command,
      # so any gh in it is a direct call, checked segment by segment. A
      # script read from stdin is a heredoc (checked as code above) or a
      # `< file`.
      if [ "$syntax_only" -eq 1 ]; then
        :
      elif [ "$inline" -eq 1 ]; then
        if [ "$j" -lt "$m" ]; then
          # `bash -c './x.sh ...'`: the first word of the code may be a script.
          code=$(unquote "${ARGS[$j]}")
          case "$code" in */* | *.sh) check_script "$code" auto ;; esac
        fi
      elif [ "$from_stdin" -eq 0 ] && [ "$j" -lt "$m" ]; then
        check_script "${ARGS[$j]}" shell
      elif [ -n "$STDIN_FILE" ]; then
        check_script "$STDIN_FILE" shell
      fi
      ;;
    python* | node | ruby | perl)
      split_redirects "$i"
      inline=0 j=0 m=${#ARGS[@]}
      while [ "$j" -lt "$m" ]; do
        a=${ARGS[$j]}
        case "$a" in
          -c | -e | -m | -p | --eval | --print) inline=1; break ;;
          -W | -X | -r | -I | --require) j=$((j + 2)); continue ;;
          # A lone - reads the script from stdin; what follows are its arguments.
          -) j=$m; break ;;
          -*) ;;
          *) break ;;
        esac
        j=$((j + 1))
      done
      if [ "$inline" -eq 0 ]; then
        if [ "$j" -lt "$m" ]; then
          check_script "${ARGS[$j]}" other
        elif [ -n "$STDIN_FILE" ]; then
          check_script "$STDIN_FILE" other
        fi
      fi
      ;;
    *)
      case "$cmd" in
        */* | *.sh) check_script "$cmd" auto ;;
      esac
      ;;
  esac
done < <(printf '%s\n' "$SCANNED" | tr ';&|()`' '\n\n\n\n\n\n')

# A script fed to an interpreter through a heredoc.
if [ -n "$STDIN_SCRIPTS" ] && grep -qE -- "$OTHER_GH_RE" <<<"$STDIN_SCRIPTS"; then
  deny "this command feeds a script to an interpreter on stdin (a heredoc) that shells out to \`gh\` from its own subprocess."
fi

exit 0
