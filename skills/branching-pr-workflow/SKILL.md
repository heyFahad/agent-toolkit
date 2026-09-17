---
name: branching-pr-workflow
description: Standard branching and dual-PR (main + staging) workflow for a standalone ticket or fix. Use when starting a new branch, opening a PR, handling a round of QA feedback on staging, or deciding whether a change needs the dual-PR treatment at all.
metadata:
  category: git-workflow
---

# Branching and PR workflow

This is the default workflow for a standalone ticket or fix in a repo that has both a production branch and a long-lived pre-prod branch. It does not apply to subtasks of a multi-subtask epic: see the `stacked-epics` skill for that case instead.

**A note on naming:** `main` and `staging` below are shorthand, not a claim about what a given repo actually calls these branches. Production is often `main` or `master`; pre-prod shows up as `staging`, `stage`, `develop`, `dev`, `preprod`, or similar. Before applying this skill, confirm the repo's actual names: `gh repo view --json defaultBranchRef -q .defaultBranchRef.name` gives the production branch, and the pre-prod branch is usually visible as another long-lived branch in `git branch -r` or the repo's own docs. This plugin's `pre-staging-conflict-check` hook already resolves the real names dynamically rather than hardcoding `main`/`staging`, so it works regardless of what this repo calls them.

## Branching

- Every new branch (feature, fix, or hotfix) is created off **`main`**. `main` is the source of truth, not `staging`.

## Opening PRs

Once local changes are complete and verified (lint, tests, build all passing), push the branch and open **two PRs**:

1. One against **`main`**: this is the PR that will eventually ship the change to production. It stays open for the lifetime of the ticket.
2. One against **`staging`**: this deploys the branch to the staging environment for QA.

Before opening the `staging` PR, run the pre-check described in the `staging-conflict-resolution` skill (also mechanically enforced by the `pre-staging-conflict-check` hook in this plugin). `staging` accumulates every ticket's merged work, so it can be blocked by conflicts unrelated to your change.

Default new PRs to **draft** mode unless told otherwise. Apply a **`production`** label (or whatever the repo's equivalent is) to the PR targeting `main` only, never on the `staging` PR, for easy tracking of what's queued to ship.

## Handling QA feedback

If QA finds issues on staging:

1. Commit the fix to the **same branch**: this automatically updates the already-open `main` PR.
2. Open **another new PR** against `staging` to redeploy that fix for re-verification (after re-running the conflict pre-check).

Repeat per round of QA feedback. Each staging round gets its own PR, but there's only ever one `main` PR per ticket.

## Shipping

Once QA signs off, merge the original `main` PR. That's what ships to production.

Periodically, after a release, merge `main` back into `staging` to keep the two branches' history close and minimize merge conflicts for the next feature branch.

## Skipping the dual-PR process

Docs-only or otherwise low-risk changes that don't need QA can skip the dual-PR process: a single PR against `main` is enough.
