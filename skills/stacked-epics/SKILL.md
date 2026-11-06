---
name: stacked-epics
description: Managing a long-running epic made of several related subtasks/tickets using a trunk branch and gh-stack. Use when starting work on a subtask that belongs to a multi-ticket epic, when deciding whether two subtasks should stack, or when deploying an epic's current progress to the pre-prod branch.
metadata:
  category: git-workflow
---

# Multi-subtask epics and stacked PRs

This applies to a long-running epic or feature made of several related subtasks/tickets, not a standalone ticket, which uses the `branching-pr-workflow` skill as-is.

As in that skill, `main` below is short for the repo's default branch, and "the pre-prod branch" is whatever `branching-pr-workflow`'s `scripts/resolve-preprod-branch.sh` reports for this repo (`dev`, `develop`, `staging`, ...). Never assume either name.

## Trunk branch

Create a parent/trunk branch for the epic off `main`, named `feature/<EPIC-TICKET>-<slug>`. Open one draft PR from it against `main`. It stays open for the epic's lifetime as a tracking/integration PR, not something reviewed line-by-line (the subtask PRs are the real review surface). Apply the `production` label here only, never on subtask PRs.

## Subtask branches never get the standalone dual-PR treatment

Regardless of how large or behavior-changing a given subtask is (not even the docs-only carve-out from `branching-pr-workflow` applies here), it does not get its own `main` PR or its own pre-prod PR. Every subtask PR targets only the branch immediately below it in the `gh-stack` chain (an earlier subtask branch, or the trunk for the first one in a stack), never `main` or the pre-prod branch directly. The trunk's PR against `main` is the *only* PR in the whole epic that ever points at `main`.

## Managing the stack

Use the `gh-stack` CLI extension, rooted at the parent branch as the stack's trunk: `gh stack init --base <parent> <first-subtask-branch>`.

- **Stack a subtask branch on top of another only when it has a genuine code dependency on that branch's not-yet-merged work.** `gh-stack` is strictly linear (one parent, one child per branch). Don't chain independent subtasks together just because they're part of the same epic: that creates a false dependency where a later one can't cleanly land until an earlier, unrelated one merges.
- When subtasks are independent of each other, give each its own branch off the trunk (its own single-link stack) rather than linking them in a chain.
- Before starting a new subtask, run `gh stack sync`. It fetches, detects any subtask PRs merged since the last sync, fast-forwards the trunk, and cascades a rebase through every branch above the merge point (handles both regular and squash merges). This replaces manually checking whether the parent has gone stale.
- Branch each new subtask off the current top of the relevant stack via `gh stack add`, not a fresh `git checkout -b` off the parent directly. The latter is what silently goes stale the moment an earlier subtask's PR merges.

## Deploying to the pre-prod branch

Deploying the epic's current state for QA happens at the trunk level only, never per subtask. Whenever the work merged into the trunk so far needs QA, open a PR from the trunk branch against the pre-prod branch. This carries everything merged into the trunk up to that point.

Run the same pre-check as a standalone ticket first, with the trunk as the feature branch: conflicts and unrelated squash-merge files, as described in the `clean-preprod-pr` skill (the `preprod-pr-check` hook enforces it). Fall through to that skill's `conflicts/...` branch recipe only if the check fails. Repeat as needed across the epic's lifetime: each pre-prod round is its own PR from the trunk, or from a `conflicts/...` branch the trunk is merged into.

## Merging the epic

Merge the trunk's `main` PR only once every subtask that belongs in this release has merged into the trunk and the trunk has been validated on the pre-prod environment. That merge is what ships the whole epic to production. Treat it as the real deploy gate, not a rubber-stamp just because the individual subtask PRs were already reviewed.

Once that's done, the `park-branch` skill cleans up the local trunk and `conflicts/...` branches.

## Known limits

Merging a stacked PR still requires the GitHub web UI (no CLI merge support yet), and the target repo/org needs GitHub's stacked-PRs feature enabled. Verify this on a new repo (a `submit`/`link` failure is the signal) before assuming it's available; the branches and PRs still work as plain sequential PRs even without it.
