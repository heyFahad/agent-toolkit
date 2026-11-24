# shellcheck shell=bash
# Shared helpers for verify and the verify-gate hook. Sourced, never run on
# its own. Keep it bash 3.2 compatible: it runs under macOS's /bin/bash.
#
# A repo's checks come from, in order:
#   1. An override in ${XDG_CONFIG_HOME:-$HOME/.config}/agent-toolkit/verify.local.json:
#        {"repos": {"<owner/name>": {"checks": [{"name": "...", "run": "..."}],
#                                    "related": "... {files} ..."}}}
#      "checks": [] turns the gate off for that repo. In "related", {files}
#      becomes the changed files, shell-quoted; without it, the related level
#      runs the full list. "related" can also be an object,
#        {"run": "... {files} ...", "paths": {"<glob>": "<command>", ...}},
#      where each command whose glob matches a changed file runs once, with
#      {files} as the files its glob matched ({file}: once per file), and
#      "run" (optional) runs on every changed file. A glob can name a list
#      of commands; the same command picked twice runs once.
#   2. What CI runs: the root package.json scripts that a workflow triggered
#      by pull_request invokes, with the arguments CI passes after `--`. CI
#      is green on the default branch, so these pass before a change and a
#      failure is the change's fault; a script CI doesn't run, or runs with
#      `|| true`, may already be failing. No such script: the gate is off.
#      The related level is the format, lint and type scripts plus jest or
#      vitest on the tests related to the changed files. Jest and vitest run
#      with at most half the cores (--maxWorkers=50%), so one run leaves room
#      for the other sessions on the machine.

# Install-time scripts are build steps, not checks.
VF_SKIP_SCRIPTS=" prepare preinstall install postinstall prepublishOnly "
# Package-manager commands that share a name with a script: `npm ci` installs,
# it doesn't run a "ci" script. Those count only through `<pm> run <name>`.
VF_PM_BUILTINS=" ci install i add audit update upgrade outdated exec dlx init publish pack link rebuild prune dedupe version create remove rm uninstall why list ls config "

vf_die() { # code message
  local code=$1
  shift
  echo "verify: $*" >&2
  exit "$code"
}

vf_config_file() { echo "${XDG_CONFIG_HOME:-$HOME/.config}/agent-toolkit/verify.local.json"; }
vf_state_dir() { echo "${AGENT_TOOLKIT_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/agent-toolkit}/verify"; }

# vf_repo_key ROOT: lowercase owner/name from origin's URL (the same key
# resolve-preprod-branch.sh uses), or nothing without an origin.
vf_repo_key() {
  local url
  url=$(git -C "$1" remote get-url origin 2>/dev/null) || return 0
  printf '%s' "$url" | sed -E 's#\.git/?$##; s#/$##; s#^[^:]+:(//[^/]+/)?##' |
    awk -F/ '{ if (NF >= 2) print $(NF-1) "/" $NF; else print $NF }' | tr '[:upper:]' '[:lower:]'
}

# vf_override ROOT: this repo's override object, or nothing.
vf_override() {
  local key cfg
  key=$(vf_repo_key "$1")
  cfg=$(vf_config_file)
  [ -n "$key" ] && [ -s "$cfg" ] || return 0
  jq -c --arg k "$key" '.repos[$k] // empty' "$cfg" 2>/dev/null || true
}

# vf_pm ROOT: the package manager whose lockfile is committed at the root.
vf_pm() {
  local files
  files=$(git -C "$1" ls-tree --name-only HEAD 2>/dev/null || true)
  if printf '%s\n' "$files" | grep -qx 'pnpm-lock.yaml'; then echo pnpm
  elif printf '%s\n' "$files" | grep -qx 'yarn.lock'; then echo yarn
  elif printf '%s\n' "$files" | grep -qx 'package-lock.json'; then echo npm
  elif printf '%s\n' "$files" | grep -qxE 'bun\.lockb?'; then echo bun
  else echo npm
  fi
}

# vf_pr_workflows ROOT: the text of every workflow triggered by pull_request.
vf_pr_workflows() {
  local f
  for f in "$1"/.github/workflows/*.yml "$1"/.github/workflows/*.yaml; do
    [ -f "$f" ] && grep -q 'pull_request' "$f" && cat "$f" && echo
  done
  return 0
}

# vf_ci_scripts ROOT: the package.json scripts a pull_request workflow runs,
# one per line as "name<TAB>args", where args is what CI passes after `--`
# (empty without). Ordered: format/lint, type, the rest, test, build.
vf_ci_scripts() {
  local root=$1 text n re runre line rest seg args found cat
  [ -f "$root/package.json" ] || return 0
  text=$(vf_pr_workflows "$root")
  [ -n "$text" ] || return 0
  jq -r '.scripts // {} | keys[]' "$root/package.json" | while IFS= read -r n; do
    case "$VF_SKIP_SCRIPTS" in *" $n "*) continue ;; esac
    re=$(printf '%s' "$n" | sed 's/[][\.*^$+?(){}|/]/\\&/g')
    case "$VF_PM_BUILTINS" in *" $n "*) runre=" run" ;; *) runre="( run)?" ;; esac
    found="" args=""
    while IFS= read -r line; do
      rest=$(printf '%s' "$line" | sed -E "s/.*(pnpm|npm|yarn|bun)$runre $re//")
      seg=$(printf '%s' "$rest" | sed -E 's/(&&|;).*//')
      # CI ignores this step's result: not a check.
      printf '%s' "$seg" | grep -qE '\|\|[[:space:]]*(true|:|exit 0)' && continue
      args=$(printf '%s' "$seg" | sed -nE 's/^[[:space:]]+--[[:space:]]+(.*)$/\1/p' |
        sed -E "s/[[:space:]]*(\|.*|[\"'].*)$//")
      # A GitHub expression can't be reproduced locally.
      # shellcheck disable=SC2016 # a literal ${{, not a shell expansion
      case "$args" in *'${{'*) args="" ;; esac
      found=1
      break
    done < <(printf '%s\n' "$text" | grep -vE '^[[:space:]]*#' |
      sed -E 's/(^|[[:space:]])(echo|printf)[[:space:]]+[^;&|]*//g' |
      grep -E "(pnpm|npm|yarn|bun)$runre $re([[:space:]\"']|$)")
    [ -n "$found" ] || continue
    case "$n" in
      format* | lint*) cat=0 ;;
      type*) cat=1 ;;
      test*) cat=3 ;;
      build*) cat=4 ;;
      *) cat=2 ;;
    esac
    printf '%s\t%s\t%s\n' "$cat" "$n" "$args"
  done | sort -t "$(printf '\t')" -k1,1n -k2,2 | cut -f2-
}

# vf_quote FILES...: the files shell-quoted, space-separated.
vf_quote() {
  [ "$#" -gt 0 ] || return 0
  printf '%q ' "$@" | sed 's/ $//'
}

# The worker cap for jest and vitest: half the cores, so one run doesn't
# starve the other sessions on the machine.
VF_WORKERS="--maxWorkers=50%"

# vf_dep_major ROOT NAME: the major version a dependency's range names, or
# nothing when it doesn't name one (workspace:, catalog:, a URL).
vf_dep_major() {
  jq -r --arg n "$2" '((.dependencies // {}) + (.devDependencies // {}))[$n] // ""' "$1/package.json" |
    sed -nE 's/^[^0-9]*([0-9]+).*/\1/p'
}

# vf_capped ROOT RUNNER: exit 0 when RUNNER (jest or vitest) takes the worker
# cap. Vitest 0.x has no --maxWorkers.
vf_capped() {
  case "$2" in
    jest) return 0 ;;
    vitest) [ "$(vf_dep_major "$1" vitest)" != 0 ] ;;
    *) return 1 ;;
  esac
}

# vf_script_runner ROOT SCRIPT ARGS: jest or vitest when the script's body is
# one call of it that sets no worker count of its own (nor do CI's ARGS),
# else nothing. A body that chains commands is left alone: an appended flag
# would reach only the last one.
vf_script_runner() {
  local root=$1 body k=0 w=()
  body=$(jq -r --arg n "$2" '.scripts[$n] // ""' "$root/package.json")
  case "$body" in *'&&'* | *'||'* | *';'* | *'|'* | *'>'* | *'<'*) return 0 ;; esac
  case " $body $3 " in
    *' --maxWorkers'* | *' -w'* | *' --runInBand'* | *' -i '* | *' --pool'* | *' --no-file-parallelism'* | *' --threads'*) return 0 ;;
  esac
  read -ra w <<<"$body" || true
  while [ "$k" -lt "${#w[@]}" ]; do
    case "${w[$k]}" in
      -*) ;;
      *=*) ;;
      cross-env | npx | bunx | exec | pnpm | yarn) ;;
      *) break ;;
    esac
    k=$((k + 1))
  done
  case "${w[$k]:-}" in
    jest | vitest) vf_capped "$root" "${w[$k]}" && echo "${w[$k]}" ;;
  esac
  return 0
}

# vf_glob_re GLOB: GLOB as an anchored ERE over repo-relative paths. `**/`
# matches any number of directories, `**` anything, `*` and `?` stay within
# one directory.
vf_glob_re() {
  printf '%s' "$1" | sed -E 's/[].^$+(){}|\\[]/\\&/g
    s#\*\*/#<DS>#g; s#\*\*#<DD>#g; s#\*#[^/]*#g; s#\?#[^/]#g
    s#<DS>#(.*/)?#g; s#<DD>#.*#g; s#^#^#; s#$#$#'
}

# vf_related_map OVERRIDE FILES...: the checks an override's object-form
# "related" picks for FILES, as JSON objects, one per line. "run" runs on
# every file. A "paths" value is a command or a list of them; each runs once
# on the files its glob matched ({files}), or once per file ({file}). The
# same command picked twice runs once.
vf_related_map() {
  local ov=$1 run n j g re f m q c cmds k nc
  shift
  run=$(printf '%s' "$ov" | jq -r '.related.run // empty')
  {
    [ -z "$run" ] || jq -n --arg r "${run//\{files\}/$(vf_quote "$@")}" '{name: "related", run: $r}'
    n=$(printf '%s' "$ov" | jq '.related.paths // {} | length')
    j=0
    while [ "$j" -lt "$n" ]; do
      g=$(printf '%s' "$ov" | jq -r --argjson j "$j" '.related.paths | keys_unsorted[$j]')
      cmds=$(printf '%s' "$ov" | jq -c --argjson j "$j" '.related.paths | .[keys_unsorted[$j]] | if type == "array" then . else [.] end')
      re=$(vf_glob_re "$g")
      m=()
      for f in "$@"; do
        [[ $f =~ $re ]] && m+=("$f")
      done
      j=$((j + 1))
      [ "${#m[@]}" -gt 0 ] || continue
      q=$(vf_quote "${m[@]}")
      nc=$(printf '%s' "$cmds" | jq length)
      k=0
      while [ "$k" -lt "$nc" ]; do
        c=$(printf '%s' "$cmds" | jq -r --argjson k "$k" '.[$k]')
        k=$((k + 1))
        case "$c" in
          *'{file}'*)
            for f in "${m[@]}"; do
              jq -n --arg n "related $g" --arg r "${c//\{file\}/$(vf_quote "$f")}" '{name: $n, run: $r}'
            done
            ;;
          *) jq -n --arg n "related $g" --arg r "${c//\{files\}/$q}" '{name: $n, run: $r}' ;;
        esac
      done
    done
  } | jq -s -c 'reduce .[] as $c ([]; if any(.[]; .run == $c.run) then . else . + [$c] end) | .[]'
}

# vf_checks ROOT LEVEL [FILES...]: the checks to run, as a JSON array of
# {name, run}. LEVEL is full or related; FILES are the changed files for the
# related level. [] means the gate is off.
vf_checks() {
  local root=$1 level=$2 ov pm x names related rtype tests_ci dev runner flag
  shift 2
  ov=$(vf_override "$root")
  if [ -n "$ov" ]; then
    rtype=$(printf '%s' "$ov" | jq -r '.related | type')
    if [ "$level" = related ] && [ "$rtype" = string ]; then
      related=$(printf '%s' "$ov" | jq -r '.related')
      jq -n --arg r "${related//\{files\}/$(vf_quote "$@")}" '[{name: "related", run: $r}]'
    elif [ "$level" = related ] && [ "$rtype" = object ]; then
      vf_related_map "$ov" "$@" | jq -s -c .
    else
      printf '%s' "$ov" | jq -c '.checks // []'
    fi
    return 0
  fi
  names=$(vf_ci_scripts "$root")
  if [ -z "$names" ]; then
    echo '[]'
    return 0
  fi
  pm=$(vf_pm "$root")
  if [ "$level" = related ]; then
    tests_ci=$(printf '%s\n' "$names" | grep -E '^test' || true)
    names=$(printf '%s\n' "$names" | grep -E '^(format|lint|type)' || true)
  fi
  {
    [ -z "$names" ] || printf '%s\n' "$names" | while IFS=$(printf '\t') read -r n a; do
      runner=$(vf_script_runner "$root" "$n" "$a")
      flag=""
      if [ -n "$runner" ]; then
        # npm needs `--` to pass a flag on to the script; the others pass it
        # as is. After CI's own `--`, every manager passes it on.
        if [ -n "$a" ]; then flag=" $VF_WORKERS"
        elif [ "$pm" = npm ]; then flag=" -- $VF_WORKERS"
        else flag=" $VF_WORKERS"
        fi
      fi
      jq -n --arg n "$n" --arg r "CI=true $pm run $n${a:+ -- $a}$flag" '{name: $n, run: $r}'
    done
    if [ "$level" = related ] && [ -n "${tests_ci:-}" ] && [ "$#" -gt 0 ]; then
      case "$pm" in
        pnpm) x="pnpm exec" ;;
        yarn) x="yarn" ;;
        bun) x="bunx" ;;
        *) x="npx --no-install" ;;
      esac
      dev=$(jq -r '(.dependencies // {}) + (.devDependencies // {}) | keys[]' "$root/package.json")
      if printf '%s\n' "$dev" | grep -qx jest; then
        jq -n --arg r "CI=true $x jest $VF_WORKERS --findRelatedTests --passWithNoTests $(vf_quote "$@")" '{name: "related-tests", run: $r}'
      elif printf '%s\n' "$dev" | grep -qx vitest; then
        flag=""
        vf_capped "$root" vitest && flag=" $VF_WORKERS"
        jq -n --arg r "CI=true $x vitest related --run --passWithNoTests$flag $(vf_quote "$@")" '{name: "related-tests", run: $r}'
      fi
    fi
  } | jq -s -c .
}

# vf_node_path ROOT: the nvm bin directory for the Node version in ROOT's
# .nvmrc, or nothing without one. Exits 3 when that version isn't installed.
# Resolves nvm aliases and partial versions like dev-stack's ds_node_bin.
vf_node_path() {
  local root=$1 v spec nvm best _
  [ -f "$root/.nvmrc" ] || return 0
  v=$(tr -d '[:space:]' <"$root/.nvmrc")
  spec=$v
  nvm=${NVM_DIR:-$HOME/.nvm}
  for _ in 1 2 3; do [ -f "$nvm/alias/$v" ] && v=$(tr -d '[:space:]' <"$nvm/alias/$v"); done
  v=${v#v}
  if [ ! -d "$nvm/versions/node/v$v/bin" ] && printf '%s' "$v" | grep -qE '^[0-9]+(\.[0-9]+)?$'; then
    # shellcheck disable=SC2012 # nvm's own folder names: vX.Y.Z only
    best=$(ls "$nvm/versions/node" 2>/dev/null | sed -n "s/^v\($v\.[0-9.]*\)$/\1/p" |
      sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
    [ -n "$best" ] && v=$best
  fi
  [ -d "$nvm/versions/node/v$v/bin" ] || vf_die 3 "Node $spec (from .nvmrc) isn't installed: run nvm install $spec"
  echo "$nvm/versions/node/v$v/bin"
}

# vf_tree ROOT / vf_tracked_tree ROOT: the hash of the working tree as git
# would commit it with `git add -A` (untracked files that aren't ignored
# included) or `git add -u` (tracked files only). Built in a copy of the
# index, never the real one, which may hold a checkpoint the user staged. The
# copy keeps git's stat cache, so unchanged files aren't read again.
vf_tree() { _vf_tree_with "$1" -A; }
vf_tracked_tree() { _vf_tree_with "$1" -u; }
_vf_tree_with() {
  local root=$1 flag=$2 idx tmp tree
  idx=$(git -C "$root" rev-parse --path-format=absolute --git-path index)
  tmp=$(mktemp "${TMPDIR:-/tmp}/verify-index.XXXXXX")
  if [ -f "$idx" ]; then cp "$idx" "$tmp"; else rm -f "$tmp"; fi
  tree=$(GIT_INDEX_FILE=$tmp git -C "$root" add "$flag" . >/dev/null 2>&1 &&
    GIT_INDEX_FILE=$tmp git -C "$root" write-tree) || {
    rm -f "$tmp"
    return 1
  }
  rm -f "$tmp"
  echo "$tree"
}

# vf_record_file TREE: where the record for TREE lives.
vf_record_file() { echo "$(vf_state_dir)/$1.json"; }

# vf_record_ok TREE LEVEL: exit 0 when TREE has a passing record at LEVEL or
# above (a full run satisfies related).
vf_record_ok() {
  local f
  f=$(vf_record_file "$1")
  [ -f "$f" ] || return 1
  jq -e --arg want "$2" '.passed == true and (.level == "full" or .level == $want)' "$f" >/dev/null 2>&1
}

# vf_changed_files ROOT: files changed against HEAD, plus untracked files that
# aren't ignored, that still exist. One per line, relative to ROOT.
vf_changed_files() {
  (
    cd "$1" || exit 0
    { git diff --name-only HEAD 2>/dev/null; git ls-files --others --exclude-standard; } |
      sort -u | while IFS= read -r f; do [ -e "$f" ] && printf '%s\n' "$f"; done
  )
}

# One verify run at a time on this machine, across every repo and session:
# jest, vitest and eslint each take every core they're given, and a few at
# once can fill memory and swap. The lock is a directory in the state dir
# (mkdir is atomic), with an owner file naming the holder's PID, its process
# start time and its repo. A holder that has died, or whose PID now belongs
# to another process, has left a stale lock, which the next run takes over.
# It's best effort: in a narrow race two runs can overlap, which is slow but
# harmless.
vf_lock_dir() { echo "$(vf_state_dir)/run.lock"; }

# _vf_proc_start PID: when PID started, as ps prints it, or nothing when ps
# can't tell (no ps, as in a minimal container).
_vf_proc_start() { { LC_ALL=C TZ=UTC ps -o lstart= -p "$1" 2>/dev/null || true; } | sed 's/^ *//; s/ *$//'; }

# _vf_owner FILE KEY: one field of a lock's owner file.
_vf_owner() { { sed -n "s/^$2=//p" "$1" 2>/dev/null || true; } | head -1; }

# _vf_lock_alive OWNERFILE: exit 0 when the process that wrote it still runs.
_vf_lock_alive() {
  local pid start now
  pid=$(_vf_owner "$1" pid)
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 1
  start=$(_vf_owner "$1" start)
  [ -n "$start" ] || return 0
  now=$(_vf_proc_start "$pid")
  [ -z "$now" ] || [ "$now" = "$start" ]
}

# _vf_lock_break LOCK: take a stale lock away. Renaming it is atomic, so only
# one waiter wins; if what it renamed turns out to be a live lock another
# waiter took in between, it goes back.
_vf_lock_break() {
  local lock=$1 stale="$1.stale.$$" pid repo
  mv "$lock" "$stale" 2>/dev/null || return 0
  if [ -f "$stale/owner" ] && _vf_lock_alive "$stale/owner"; then
    [ -e "$lock" ] || mv "$stale" "$lock" 2>/dev/null || true
    rm -rf "$stale"
    return 0
  fi
  pid=$(_vf_owner "$stale/owner" pid) repo=$(_vf_owner "$stale/owner" repo)
  echo "verify: took over a stale lock${pid:+ left by pid $pid}${repo:+ ($repo)}"
  rm -rf "$stale"
}

# vf_lock_acquire REPO: wait until no other verify run holds the lock, then
# take it. A run started by a check of the run holding it (a test suite that
# runs verify) shares it rather than waiting on itself.
vf_lock_acquire() {
  local lock said="" f
  lock=$(vf_lock_dir)
  [ "${VF_LOCK_HELD:-}" != "$lock" ] || return 0
  mkdir -p "$(dirname "$lock")"
  while ! mkdir "$lock" 2>/dev/null; do
    f="$lock/owner"
    if [ -f "$f" ] && ! _vf_lock_alive "$f"; then
      _vf_lock_break "$lock"
      continue
    fi
    if [ ! -f "$f" ]; then
      [ -d "$lock" ] || continue
      # Just made, its owner not written yet; a minute without one is stale.
      if [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
        _vf_lock_break "$lock"
        continue
      fi
    fi
    if [ -z "$said" ] && [ -f "$f" ]; then
      echo "verify: queued behind the verify run for $(_vf_owner "$f" repo) (pid $(_vf_owner "$f" pid), since $(_vf_owner "$f" at)); one run at a time on this machine, so this waits for it to finish"
      said=1
    fi
    sleep "${VF_LOCK_POLL:-2}"
  done
  printf 'pid=%s\nstart=%s\nrepo=%s\nat=%s\n' "$$" "$(_vf_proc_start $$)" "$1" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$lock/owner.tmp"
  mv "$lock/owner.tmp" "$lock/owner"
  VF_LOCK_HELD=$lock VF_LOCK_MINE=1
  export VF_LOCK_HELD
  [ -z "$said" ] || echo "verify: the other run finished; starting"
}

# vf_lock_release: drop the lock, if this process took it.
vf_lock_release() {
  local lock
  [ "${VF_LOCK_MINE:-}" = 1 ] || return 0
  lock=$(vf_lock_dir)
  [ "$(_vf_owner "$lock/owner" pid)" = "$$" ] && rm -rf "$lock"
  VF_LOCK_MINE=""
  return 0
}
