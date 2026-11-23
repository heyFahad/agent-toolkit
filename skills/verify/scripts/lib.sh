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
#      by pull_request invokes. CI is green on the default branch, so these
#      pass before a change and a failure is the change's fault; a script CI
#      doesn't run may already be failing. No such script: the gate is off.

# Install-time scripts are build steps, not checks.
VF_SKIP_SCRIPTS=" prepare preinstall install postinstall prepublishOnly "

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

# vf_ci_scripts ROOT: the package.json scripts a pull_request workflow runs,
# one per line, ordered: format/lint, type, the rest, test, build.
vf_ci_scripts() {
  local root=$1 text="" f n re
  [ -f "$root/package.json" ] || return 0
  for f in "$root"/.github/workflows/*.yml "$root"/.github/workflows/*.yaml; do
    [ -f "$f" ] && grep -q 'pull_request' "$f" && text="$text$(cat "$f")"$'\n'
  done
  [ -n "$text" ] || return 0
  jq -r '.scripts // {} | keys[]' "$root/package.json" | while IFS= read -r n; do
    case "$VF_SKIP_SCRIPTS" in *" $n "*) continue ;; esac
    re=$(printf '%s' "$n" | sed 's/[][\.*^$+?(){}|/]/\\&/g')
    if printf '%s' "$text" | grep -qE "(pnpm|npm|yarn|bun)( run)? $re([[:space:]\"']|$)"; then
      case "$n" in
        format* | lint*) printf '0\t%s\n' "$n" ;;
        type*) printf '1\t%s\n' "$n" ;;
        test*) printf '3\t%s\n' "$n" ;;
        build*) printf '4\t%s\n' "$n" ;;
        *) printf '2\t%s\n' "$n" ;;
      esac
    fi
  done | sort -t "$(printf '\t')" -k1,1n -k2,2 | cut -f2
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
    [ -z "$names" ] || printf '%s\n' "$names" | while IFS= read -r n; do
      jq -n --arg n "$n" --arg r "CI=true $pm run $n" '{name: $n, run: $r}'
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
