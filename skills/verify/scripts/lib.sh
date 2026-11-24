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
#      runs the full list.
#   2. What CI runs: the root package.json scripts that a workflow triggered
#      by pull_request invokes, with the arguments CI passes after `--`. CI
#      is green on the default branch, so these pass before a change and a
#      failure is the change's fault; a script CI doesn't run, or runs with
#      `|| true`, may already be failing. No such script: the gate is off.

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

# vf_checks ROOT LEVEL [FILES...]: the checks to run, as a JSON array of
# {name, run}. LEVEL is full or related; FILES are the changed files for the
# related level. [] means the gate is off.
vf_checks() {
  local root=$1 level=$2 ov pm x names related tests_ci dev
  shift 2
  ov=$(vf_override "$root")
  if [ -n "$ov" ]; then
    related=$(printf '%s' "$ov" | jq -r '.related // empty')
    if [ "$level" = related ] && [ -n "$related" ]; then
      local q
      q=$(vf_quote "$@")
      jq -n --arg r "${related//\{files\}/$q}" '[{name: "related", run: $r}]'
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
    names=$(printf '%s\n' "$names" | grep -E '^(format|lint)' || true)
  fi
  {
    [ -z "$names" ] || printf '%s\n' "$names" | while IFS=$(printf '\t') read -r n a; do
      jq -n --arg n "$n" --arg r "CI=true $pm run $n${a:+ -- $a}" '{name: $n, run: $r}'
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
        jq -n --arg r "CI=true $x jest --findRelatedTests --passWithNoTests $(vf_quote "$@")" '{name: "related-tests", run: $r}'
      elif printf '%s\n' "$dev" | grep -qx vitest; then
        jq -n --arg r "CI=true $x vitest related --run --passWithNoTests $(vf_quote "$@")" '{name: "related-tests", run: $r}'
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
