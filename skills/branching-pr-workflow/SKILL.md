---
name: branching-pr-workflow
description: Standard branching and dual-PR workflow (one PR against the default branch, one against the pre-prod branch) for a standalone ticket or fix. Use when starting a new branch, opening a PR, handling a round of QA or review feedback, finding out which branch is a repo's pre-prod branch, or deciding whether a change needs the dual-PR treatment at all.
metadata:
  category: git-workflow
---

# Branching and PR workflow

This is the default workflow for a standalone ticket or fix in a repo that has both a production branch and a long-lived pre-prod branch. It does not apply to subtasks of a multi-subtask epic: see the `stacked-epics` skill for that case instead.

## Find the branch names first

Never assume a name. The two branches this workflow uses are:

- **The default branch** (production): `gh repo view --json defaultBranchRef -q .defaultBranchRef.name`. Usually `main` or `master`. Below it's written as `main` for short. Ask GitHub rather than reading `origin/HEAD`, which is set at clone time and goes stale.
- **The pre-prod branch** (where QA deploys go): run this skill's `scripts/resolve-preprod-branch.sh` from inside the repo. Repos call it `dev`, `develop`, `staging`, and so on, and some have more than one of those, only one of which is in use. Below it's written as "the pre-prod branch".

The resolver tries, in order:

1. A per-repo override in `${XDG_CONFIG_HOME:-$HOME/.config}/agent-toolkit/preprod-branches.local.json`, outside the plugin folder so it survives plugin updates.
2. A cached earlier answer (kept for 7 days; `--refresh` skips it).
3. Inference: among the remote's long-lived branches with a pre-prod-style name (`dev`, `develop`, `staging`, `stage`, `preprod`, `qa`, ...; never `release/`, `feature/`, `fix/`, `conflicts/` or `chore/` branches), the one that received the most of the last 200 merged PRs. A repo with both `dev` and `staging` where every recent PR merged into `dev` gets `dev`.

It prints the branch and exits 0. Other exit codes:

- **2, ambiguous** (a tie, no merged PRs into any candidate, or `gh` unavailable): the candidates are on stderr. Ask the user which branch QA PRs go to, then save the answer with `scripts/resolve-preprod-branch.sh --set <branch>` so nobody asks again.
- **3, none**: the repo has no pre-prod branch, so the dual-PR process doesn't apply. If a repo has a pre-prod-looking branch that isn't one, `--set none` records that.

Without the script (a tool that only installed this skill's text), do the same by hand: list `git ls-remote --heads origin`, then count `gh pr list --state merged --limit 200 --json baseRefName` per candidate.

## Branching

- Every new branch (feature, fix, or hotfix) is created off **`main`**. `main` is the source of truth, not the pre-prod branch.

## Opening PRs

Once local changes are complete and verified (lint, tests, build all passing), push the branch and open **two PRs**, both as **drafts** unless told otherwise:

1. One against **`main`**: this is the PR that will eventually ship the change to production. It stays open for the lifetime of the ticket.
2. One against **the pre-prod branch**: this deploys the change to the pre-prod environment for QA.

Before opening the pre-prod PR, run the pre-check in the `clean-preprod-pr` skill (this plugin's `preprod-pr-check` hook enforces it). The pre-prod branch accumulates every ticket's merged work, so a PR into it can be blocked by conflicts unrelated to your change. It can also list files your branch never touched: each ticket reaches `main` and the pre-prod branch through different commits (a merge commit on each, or a squash commit on `main`), so when nobody has back-merged `main` into the pre-prod branch, your branch carries `main`'s commits for tickets the pre-prod branch already has in another form. Either way the PR goes out from a `conflicts/<ticket>-<slug>` branch instead, as that skill describes.

Give both PRs the same title (see `pr-title-conventions`). Apply a **`production`** label (or the repo's equivalent) to the `main` PR only, never to the pre-prod PR, for easy tracking of what's queued to ship.

### Then stop and wait for the user

Drafts exist so that a PR opened by mistake does no harm, so don't build on them yet: don't request reviewers, mark anything ready, or run `check-pr`. Give the user both PR links and ask whether they look right and whether to go ahead with `check-pr`, using the harness's question prompt if it has one (the question box in the Claude desktop app, `AskUserQuestion` in Claude Code), otherwise a plain question at the end of the turn. End the turn there.

On the user's go-ahead, run the `check-pr` skill (in `github-tooling`). It requests Copilot on both PRs, triages Copilot, human and CI feedback, marks the pre-prod PR ready for review once everything is clean, and cleans up. The `main` PR stays a draft until the ticket is released.

## Handling feedback

Review feedback on either PR and QA findings on the pre-prod environment are handled the same way:

1. Commit the fix to the **feature branch**, never to the `conflicts/...` branch and never to the pre-prod branch. This updates the `main` PR.
2. Get the fix to the pre-prod PR:
   - If that PR is from a `conflicts/...` branch, merge the feature branch into it again (`git switch conflicts/<ticket>-<slug> && git merge <feature-branch>`) and push. The open pre-prod PR updates itself.
   - If it is from the feature branch itself, the push already updated it.
   - If the earlier pre-prod PR has already merged, open a new one for this round, after the pre-check again.

Each pre-prod round that merges gets a new PR for the next round, but there's only ever one `main` PR per ticket.

## Shipping

Once QA signs off, merge the `main` PR. That's what ships to production.

After a release, `main` should be merged back into the pre-prod branch with a merge commit, never squashed, or the next feature branch's pre-prod PR shows the same unrelated files again. The `back-merge` skill has the whole procedure.

## Cleaning up

Once both PRs are open and their feedback is resolved, merged or not, the local branches and worktree have nothing left that isn't on the remote. `check-pr` runs the `branch-cleanup` skill at that point; run it yourself if the PRs got clean some other way. This is the last step for every ticket.

## Skipping the dual-PR process

Docs-only or otherwise low-risk changes that don't need QA can skip the dual-PR process: a single PR against `main` is enough. So can any repo where the resolver reports no pre-prod branch.
