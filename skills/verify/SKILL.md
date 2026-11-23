---
name: verify
description: Run a repo's checks before committing or pushing, and record that they passed. Use before every git commit (`--related`), before pushing or opening PRs (`--full`), when the verify-gate hook blocks a commit, push or PR, after `gh stack sync` rebases a stack, and when a repo's checks need setting by hand.
metadata:
  category: git-workflow
---

# Verify a change before committing or pushing it

`scripts/verify` runs a repo's checks and records the result against the exact tree it ran on. The `verify-gate` hook (`git-workflow` plugin) reads those records and blocks a commit, push or PR whose tree hasn't passed. So nothing unchecked leaves your machine, and full suites still run only once per push, not on every turn.

## The two levels

| Command | Runs | When |
| --- | --- | --- |
| `verify --related` | The repo's lint and format checks, plus the tests related to the changed files (`jest --findRelatedTests`, `vitest related`) | Before each `git commit` |
| `verify --full` | Every check | Once, when the work is ready to push or open PRs |

Run it from anywhere in the repo, as `bash <this skill>/scripts/verify --related`. It prints `PASS` or `FAIL` per check, and the tail of a failing check's output. The full log path is in the record (`verify --status`).

`verify --related <files>` checks only the files you name. That's handy while working, but it writes no record, since it didn't cover every change.

A passing `--related` run never replaces a passing `--full` one, so running `--related` before a commit doesn't cost you the full run you already did.

Never run the full suite on every turn or every small edit. That's what `--related` is for.

## What the gate needs

| Command | Needs |
| --- | --- |
| `git commit` | a passing `--related` (or `--full`) run of the current working tree |
| `git push`, `gh pr create` | a passing `--full` run of each branch being pushed |
| `gh stack push`, `gh stack submit` | a passing `--full` run of every open branch in the stack |
| `gh stack sync` | blocked: it rebases and pushes in one go, so use `gh stack rebase`, verify each changed branch, then `gh stack push` |

Run a push, `gh pr create` or `gh stack push` in its own Bash call. Chained after a commit, merge or rebase (`git commit -m x && git push`), it's blocked: the hook runs before the call, so it can't see the commit the push would send.

To verify a branch that isn't checked out, check it out (or open a worktree of it) and run `verify --full` there. The hook's message says which branch.

The record belongs to a tree, so any edit after a run means running again. Committing doesn't count as an edit: verify once, then commit by path as many times as you like. A fixup rebase doesn't change the tree either. A `conflicts/...` branch has a tree of its own, which is what the pre-prod PR deploys, so it needs its own `--full`. So does each branch `gh stack rebase` changed.

An untracked file you or the user keep around doesn't block a push: a record also matches the tracked files alone. That cuts both ways. If the change needs a new file and you forget to commit it, the push still goes through. So `verify` lists the untracked files each run included: commit the ones the change needs.

A check that changes tracked files fails the run. A `format` script that writes, or a generated file that was out of date, are the usual causes. Review the changes, commit them, and run again.

## Where the checks come from

By default, from what CI runs: the root `package.json` scripts that a workflow triggered by `pull_request` invokes, with the arguments CI passes after `--`. Install-time scripts like `prepare` are left out, and so is a step CI ignores (`|| true`). `npm ci` installs; it doesn't count as running a `ci` script. They run with `CI=true`, through the package manager whose lockfile is committed, under the Node version `.nvmrc` names. CI is green on the default branch, so those checks pass before your change, and a failure is yours. A script CI never runs may already be failing, so it isn't used.

`verify --list` prints what it would run, and `verify --list --related <files>` does the same for the quick level.

A repo whose CI runs none of its scripts has the gate off. `verify` says so, and the hook lets everything through. In such a repo, ask the user before pushing or opening PRs: nothing checked the code. When the repo does have `pull_request` workflows, just not package scripts `verify` can read (a shell test suite, a Makefile), `verify` says that instead: ask the user to set the repo's checks by hand (below).

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

`{files}` becomes the changed files, shell-quoted. Without `related`, `--related` runs the full list. `"checks": []` turns the gate off for that repo.

Never edit this file to get past a failing check. If a check fails for a reason that isn't your change, tell the user and let them decide.
