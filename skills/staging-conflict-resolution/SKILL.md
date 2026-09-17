---
name: staging-conflict-resolution
description: Resolving merge conflicts when opening or re-opening a PR against staging. Use whenever a staging PR is blocked by conflicts from an unrelated ticket that merged into staging first.
metadata:
  category: git-workflow
---

# Resolving conflicts against `staging`

`staging` accumulates every ticket's merged work, while `main` only gets a ticket once it ships. This means a `staging` PR can end up blocked by conflicts from an unrelated ticket that merged into `staging` first and touched the same code, even though the corresponding `main` PR for your ticket is unaffected.

(As elsewhere in this plugin, `main`/`staging` are shorthand: see `branching-pr-workflow`'s naming note. The `pre-staging-conflict-check` hook already resolves the repo's actual branch names dynamically instead of hardcoding these.)

## Always pre-check first

Before opening (or re-opening) any PR against `staging`, always pre-check for conflicts first. Don't create a `conflicts/...` branch reflexively for every round. (This plugin's `pre-staging-conflict-check` hook automates this step automatically when it detects a `gh pr create ... --base staging` command; run it manually if the hook isn't available.)

```bash
git fetch origin staging
git merge-tree --write-tree origin/staging <your-feature-branch>
```

If this reports no `CONFLICT` lines, there's nothing to resolve. Open the `staging` PR directly from your feature branch as usual. Only proceed to the steps below when a real conflict is reported.

## When there is a conflict

- **Never** merge `staging` into your feature branch, and **never** merge your feature branch directly into `staging` outside of a PR. Both pollute the feature branch's history (which still needs to merge cleanly into `main` later) and bypass review.
- Instead, branch a new `conflicts/<ticket>-<short-slug>` branch off the **latest `staging`**, merge your feature branch into it, and resolve the conflicts there:

  ```bash
  git checkout -b conflicts/<ticket>-<short-slug> origin/staging
  git merge <your-feature-branch>
  # resolve conflicts, then: git add <files> && git merge --continue
  ```

  Use `git merge --continue` to complete the merge, not a plain `git commit -m ...`: it's the correct command for finishing a conflicted merge and fills in the default merge commit message.
- Open the `staging` PR from this `conflicts/...` branch instead of the original feature branch, closing out any prior conflicting `staging` PR for the same round (same as any other superseded staging-round PR).
- The original feature branch stays untouched and conflict-free, so the `main` PR is unaffected and keeps tracking the feature branch directly.
- If a later QA round conflicts again (another ticket merged into `staging` meanwhile), re-run the pre-check against the new latest `staging` tip. Only spin up a fresh `conflicts/...` branch if it actually reports a conflict.

## Epics

The same pre-check and `conflicts/...` recipe apply when deploying a stacked-epic trunk to staging. See the `stacked-epics` skill.
