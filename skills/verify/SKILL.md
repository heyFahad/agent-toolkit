---
name: verify
description: Run a repo's checks before committing or pushing, and record that they passed. Use before every git commit and push (`--related`), before the first push of a branch (`--branch`), before pushing a `conflicts/...` branch (`--full`), when the verify-gate hook blocks a commit, push or PR, after `gh stack sync` rebases a stack, and when a repo's checks need setting by hand.
metadata:
  category: git-workflow
---

# Verify a change before committing or pushing it

`scripts/verify` runs a repo's checks and records the result against the exact tree it ran on. The `verify-gate` hook (`git-workflow` plugin) reads those records and blocks a commit, push or PR whose tree hasn't passed. So nothing unchecked leaves your machine, while the full suite runs on CI rather than here. CI runs everything on every push, and `check-pr` waits for it and fixes what fails. Locally, a branch's checks cover the code it changed.

## The levels

| Command | Runs | When |
| --- | --- | --- |
| `verify --related` | The repo's format, lint and typecheck scripts, plus the tests related to the changed files (`jest --findRelatedTests`, `vitest related`) | Before each `git commit` and each later push |
| `verify --branch` | The same quick checks, on every file the branch changes since it left the default branch (committed, uncommitted and untracked) | Once per branch, before the push that creates it on the remote, so its PRs open green |
| `verify --full` | Every check | Before each push of a `conflicts/...` branch, and wherever the repo's settings ask for it on the first push (`firstPush`, below) |

Run it from anywhere in the repo, as `bash <this skill>/scripts/verify --related`. It prints `PASS` or `FAIL` per check, and the tail of a failing check's output. The full log path is in the record (`verify --status`).

On a clean tree, after a rebase say, `--related` has nothing to diff against `HEAD`, so it checks what the branch changes against its copy on the remote (`origin/<branch>`) instead: those commits hold code no run saw.

Deleted files count as changed: they pick their `relatedPaths` suites, but no command is handed a file that's gone.

`verify --related <files>` checks only the files you name. That's handy while working, but it writes no record, since it didn't cover every change.

A passing run never replaces a passing one at a higher level (`--full` over `--branch` over `--related`), so running `--related` before a commit doesn't cost you the bigger run you already did.

`--branch` finds where the branch started from `origin/HEAD` (else `origin/main` or `origin/master`). With none of those, it says so and runs every check instead. So does a branch (or a `--related` run) with more than 500 changed files, whose file list could outgrow a command line.

Never run the full suite on every turn, every small edit or every push. That's what `--related` and `--branch` are for.

### One run at a time

Only one `verify` run checks at a time on the machine, across every repo and session. Jest, vitest and eslint each take every core they're given, and a few sessions running them at once can fill memory and swap. A second run prints that it's queued behind another repo's run and waits for it, so give `verify` a long timeout (or run it in the background) rather than starting it again. The lock is a directory in the verify state dir; a run whose holder has died takes it over on its own.

Jest and vitest run with `--maxWorkers=50%` too, so even one run leaves cores free. A script that already sets a worker count, or chains several commands, is left as it is.

## What the gate needs

| Command | Needs |
| --- | --- |
| `git commit` | a passing `--related` (or higher) run of the current working tree |
| `git push`, `gh pr create` | a passing `--related` run of each branch tree being pushed; `--branch` when the push creates the branch on the remote; `--full` when the branch is a `conflicts/...` one |
| `gh stack push`, `gh stack submit` | the same, for every open branch in the stack |
| `gh stack sync` | blocked: it rebases and pushes in one go, so use `gh stack rebase`, verify each changed branch, then `gh stack push` |

Whether a push creates the branch comes from the remote-tracking refs (`origin/<branch>`) the last fetch left, with no network call. `gh stack push --remote <name>` is checked against that remote. A repo with `remote.<name>.push` set has to name the destination of a branch push (`git push origin feat:feat`), since that setting can send a branch under another name. A branch someone else pushed since your last fetch counts as new, which only asks for the bigger run. A `conflicts/...` branch always needs `--full`: its merge of the feature branch into the pre-prod branch is new code that no earlier run saw.

Run a push, `gh pr create` or `gh stack push` in its own Bash call. Chained after a commit, merge or rebase (`git commit -m x && git push`), it's blocked: the hook runs before the call, so it can't see the commit the push would send.

To verify a branch that isn't checked out, check it out (or open a worktree of it) and run `verify` there. The hook's message says which branch.

The record belongs to a tree, so any edit after a run means running again. Committing doesn't count as an edit: verify once, then commit by path as many times as you like. A fixup rebase doesn't change the tree either. A `conflicts/...` branch has a tree of its own, which is what the pre-prod PR deploys, so it needs its own `--full`. Each branch `gh stack rebase` changed needs its own run too: `--related` is what the gate asks for once the branch is on the remote.

An untracked file you or the user keep around doesn't block a push: a record also matches the tracked files alone. That cuts both ways. If the change needs a new file and you forget to commit it, the push still goes through. So `verify` lists the untracked files each run included: commit the ones the change needs.

A check that changes tracked files fails the run. A `format` script that writes, or a generated file that was out of date, are the usual causes. Review the changes, commit them, and run again.

## Where the checks come from

By default, from what CI runs: the root `package.json` scripts that a workflow triggered by `pull_request` invokes, with the arguments CI passes after `--`. `--full` runs all of them; `--related` runs those whose names start with `format`, `lint` or `type`, plus jest or vitest on the changed files when CI runs a `test` script. Install-time scripts like `prepare` are left out, and so is a step CI ignores: one run with `|| true`, or a step or job with `continue-on-error: true`. `npm ci` installs; it doesn't count as running a `ci` script. They run with `CI=true`, through the package manager whose lockfile is committed, under the Node version `.nvmrc` names. CI is green on the default branch, so those checks pass before your change, and a failure is yours. A script CI never runs may already be failing, so it isn't used.

`verify --list` prints what it would run, and `verify --list --related <files>` does the same for the quick level.

A repo whose CI runs none of its scripts has the gate off. `verify` says so, and the hook lets everything through. In such a repo, ask the user before pushing or opening PRs: nothing checked the code. When the repo does have `pull_request` workflows, just not package scripts `verify` can read (a shell test suite, a Makefile, tools called through `pnpm exec` or `npx`), `verify` says that instead: ask the user to set the repo's checks by hand (below).

## Setting a repo's checks by hand

When inference gets it wrong (a monorepo, checks in a shared workflow, tests that need `doppler run`), the user can override it in `${XDG_CONFIG_HOME:-~/.config}/agent-toolkit/verify.local.json`, keyed by the repo's lowercase `owner/name`:

```json
{
  "repos": {
    "acme/api": {
      "checks": [
        { "name": "lint", "run": "pnpm lint" },
        { "name": "test", "run": "doppler run -- pnpm test" }
      ],
      "related": "pnpm exec vitest related --run {files}"
    }
  }
}
```

`{files}` becomes the changed files, shell-quoted. Without `related`, `--related` and `--branch` run the full list. `"checks": []` turns the gate off for that repo.

`"firstPush": "full"` makes the push that creates a branch need `--full` instead of `--branch`. Set it in a repo's entry, or at the top of the file for every repo; a repo's own setting wins. It suits a repo whose related level misses a lot, so that PRs still open green.

A repo without an import graph for `vitest related` to follow (a shell-test repo, say) can map changed paths to the suites that cover them, under `relatedPaths`:

```json
"related": "shellcheck {files}",
"relatedPaths": {
  "skills/check-pr/**": "bash skills/check-pr/scripts/tests/check-pr.test.sh",
  "skills/*/SKILL.md": "markdownlint {files}"
}
```

Each command whose glob matches a changed file runs once, with `{files}` as the files that glob matched, or once per matched file when it says `{file}` instead. A glob can name a list of commands rather than one. The same command picked twice runs once, so `"**/*.test.sh": "bash {file}"` next to `"src/lib.sh": "bash tests/lib.test.sh"` runs that suite once when both files change. `related`, if set too, still runs on every changed file. Globs are matched against paths from the repo root: `**/` matches any number of directories, `**` anything, and `*` and `?` stay within one directory, so `*.sh` matches only at the root and `**/*.sh` matches anywhere. A change no glob matches runs nothing beyond `related`.

With no changed files (a clean tree after a rebase, say), a command that takes `{files}` doesn't run, in `related` or `relatedPaths`; one without `{files}` still does.

`relatedPaths` is a key of its own, not part of `related`, because older versions of `verify` read `related` only as a string. They ignore `relatedPaths`, so sessions still running an older copy keep working from the same file.

Never edit this file to get past a failing check. If a check fails for a reason that isn't your change, tell the user and let them decide.
