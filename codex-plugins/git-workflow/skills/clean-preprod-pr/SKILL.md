---
name: clean-preprod-pr
description: Opening a PR against the repo's pre-prod branch (dev, develop, staging, ...) when a PR straight from the feature branch would conflict or would list unrelated files from tickets the pre-prod branch already has. Use before opening or re-opening any pre-prod PR for a ticket or an epic, and whenever the preprod-pr-check hook denies one. A back-merge of the default branch into the pre-prod branch has its own skill, back-merge.
metadata:
  category: git-workflow
---

# Opening a clean PR against the pre-prod branch

Find the pre-prod branch first with the `branching-pr-workflow` skill's `scripts/resolve-preprod-branch.sh`; never assume it's called `staging`. Below, `<pre-prod>` is that branch and `main` is the repo's default branch.

A PR from the feature branch into the pre-prod branch can go wrong in two ways that the `main` PR never shows:

- **Conflicts.** The pre-prod branch accumulates every ticket's merged work, while `main` only gets a ticket once it ships. A ticket that reached the pre-prod branch first and touched the same code can conflict with yours.
- **Unrelated files.** Each ticket reaches the pre-prod branch and `main` through different commits: its own merge commit on each branch, or on `main` a squash commit. Unless someone back-merges `main` into the pre-prod branch, `main`'s commits never reach it, so the two branches share no recent commit that holds all the tickets both already have. There are often several merge bases, and GitHub diffs your PR against one of them. Your feature branch, cut from `main`, then lists other tickets' files too, even though the pre-prod branch already has that content. A hotfix that went only to `main` shows up as well, but that's a real difference, not noise: the pre-prod branch doesn't have it, so it still shows from the `conflicts/...` branch below and stops showing once the back-merge lands. (Real case: one ticket's PR into `main` changed 2 files, and its PR into `staging` showed 14.)

The fix for both is the same deliberate `conflicts/...` branch.

## Always pre-check first

Before opening (or re-opening) any PR against the pre-prod branch, check both. A back-merge PR from `main` is no exception, but its second check is different: the `back-merge` skill has it. Don't create a `conflicts/...` branch reflexively when neither applies. This plugin's `preprod-pr-check` hook runs these checks on every `gh pr create --base <pre-prod>` and denies the command when either fails; run them by hand where the hook isn't available.

```bash
git fetch origin <pre-prod> main

# 1. Conflicts: any CONFLICT line means yes.
git merge-tree --write-tree origin/<pre-prod> <feature-branch>

# 2. Unrelated files: the first list should be the second list, nothing more.
git diff --name-only $(git merge-base origin/<pre-prod> <feature-branch>) <feature-branch>
git diff --name-only origin/main...<feature-branch>
```

If there's no conflict and no extra file, open the pre-prod PR directly from the feature branch as usual.

## The `conflicts/...` branch

- **Never** merge the pre-prod branch into your feature branch, and **never** merge your feature branch directly into the pre-prod branch outside of a PR. Both pollute the feature branch's history (which still needs to merge cleanly into `main` later) and bypass review.
- **Never cherry-pick** the feature's commits onto a branch off the pre-prod branch either. Cherry-picks are new commits with different hashes, so the same change ends up in history twice.
- Instead, branch `conflicts/<ticket>-<short-slug>` off the **latest** pre-prod branch and merge the feature branch into it:

  ```bash
  git switch -c conflicts/<ticket>-<short-slug> origin/<pre-prod>
  git merge <feature-branch>
  # on conflicts: resolve, git add <files>, then git merge --continue
  git push -u origin conflicts/<ticket>-<short-slug>
  ```

  Use `git merge --continue` to finish a conflicted merge, not a plain `git commit -m ...`: it's the right command for the job and fills in the default merge message.
- Open the pre-prod PR from this branch instead of the feature branch, and close any earlier pre-prod PR for the same round that it replaces. Its files tab shows only your feature's changes, plus any hotfix from `main` the pre-prod branch hasn't had yet. Its commits tab still lists `main`'s commits that the pre-prod branch lacks; that's expected and harmless.
- The feature branch stays untouched, so the `main` PR keeps tracking it directly.

## Later rounds of feedback

Fixes always go on the feature branch first. Then bring them over by merging the feature branch into the same `conflicts/...` branch again and pushing; the open pre-prod PR picks them up. Never commit a fix straight onto the `conflicts/...` branch, or the `main` PR won't get it.

If the pre-prod PR has already merged and another round is needed, re-run the pre-check against the latest pre-prod tip. Cut a fresh `conflicts/...` branch only if it still reports a conflict or extra files.

## Fixing the cause: a back-merge

The unrelated files keep coming back for every ticket until `main` is merged back into the pre-prod branch with a merge commit. That merge makes `main`'s own commits part of the pre-prod branch's history, so the two branches get one recent merge base and GitHub stops diffing against an old one. When the check reports extra files, look for an open back-merge PR, and if there's none, offer the user one. The `back-merge` skill has the whole procedure, including the back-merge PR's own pre-check (straight from `main` it's usually noisy too) and resolving its conflicts without dropping released fixes.

A back-merge fixes future tickets. It doesn't change the decision for the current one: if the check fails now, use the `conflicts/...` branch now.

## Epics

The same pre-check and `conflicts/...` recipe apply when deploying a stacked-epic trunk to the pre-prod branch. See the `stacked-epics` skill.
