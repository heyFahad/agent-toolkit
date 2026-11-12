---
name: clean-preprod-pr
description: Opening a PR against the repo's pre-prod branch (dev, develop, staging, ...) when a PR straight from the feature branch, or a back-merge PR straight from the default branch, would conflict or would list unrelated files left over from squash merges. Use before opening or re-opening any pre-prod PR, including a back-merge from main after a release, and whenever the preprod-pr-check hook denies one.
metadata:
  category: git-workflow
---

# Opening a clean PR against the pre-prod branch

Find the pre-prod branch first with the `branching-pr-workflow` skill's `scripts/resolve-preprod-branch.sh`; never assume it's called `staging`. Below, `<pre-prod>` is that branch and `main` is the repo's default branch.

A PR from the feature branch into the pre-prod branch can go wrong in two ways that the `main` PR never shows:

- **Conflicts.** The pre-prod branch accumulates every ticket's merged work, while `main` only gets a ticket once it ships. A ticket that reached the pre-prod branch first and touched the same code can conflict with yours.
- **Unrelated files.** `main` is squash-merged. Each ticket reaches the pre-prod branch as its original commits and reaches `main` as one new squash commit. Unless someone back-merges `main` into the pre-prod branch, those squash commits never reach it. Your feature branch, cut from `main`, carries them, so its pre-prod PR lists their files too, even though the pre-prod branch already has that content. (Real case: one ticket's PR into `main` changed 2 files, and its PR into `staging` showed 14.)

The fix for both is the same deliberate `conflicts/...` branch.

## Always pre-check first

Before opening (or re-opening) any PR against the pre-prod branch, check both. A back-merge PR from `main` is no exception, but its second check is different: see "The back-merge PR needs the same check" below. Don't create a `conflicts/...` branch reflexively when neither applies. This plugin's `preprod-pr-check` hook runs these checks on every `gh pr create --base <pre-prod>` and denies the command when either fails; run them by hand where the hook isn't available.

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
- Open the pre-prod PR from this branch instead of the feature branch, and close any earlier pre-prod PR for the same round that it replaces. Its files tab shows only your feature's changes. Its commits tab still lists the squash commits; that's expected and harmless.
- The feature branch stays untouched, so the `main` PR keeps tracking it directly.

## Later rounds of feedback

Fixes always go on the feature branch first. Then bring them over by merging the feature branch into the same `conflicts/...` branch again and pushing; the open pre-prod PR picks them up. Never commit a fix straight onto the `conflicts/...` branch, or the `main` PR won't get it.

If the pre-prod PR has already merged and another round is needed, re-run the pre-check against the latest pre-prod tip. Cut a fresh `conflicts/...` branch only if it still reports a conflict or extra files.

## Fixing the cause: a back-merge

The unrelated files keep coming back for every ticket until `main` is merged back into the pre-prod branch. When the check reports extra files, or after a release:

1. Look for an open back-merge PR, whose head is `main` or a `conflicts/backmerge-...` branch: `gh pr list --base <pre-prod> --state open --json number,headRefName`.
2. If there's none, offer to open one. Ask the user first, like any PR.
3. It must be merged with a merge commit (`gh pr merge <n> --merge`), never squashed. A squash copies `main`'s content without making `main`'s commits part of the pre-prod branch's history, so the merge base GitHub diffs against doesn't move and the noise stays.

A back-merge fixes future tickets. It doesn't change the decision for the current one: if the check fails now, use the `conflicts/...` branch now.

### The back-merge PR needs the same check

A back-merge PR straight from `main` is just as noisy as a feature branch's, usually more: it lists every squash commit since the last back-merge, even though the pre-prod branch already has almost all of that content from the original ticket commits. (Real case: a back-merge PR from `main` listed 14 files and the merge changed none of them.) There's no "own change" to compare against here, so compare what the PR would list with what the merge would really change:

```bash
git fetch origin <pre-prod> main

# 1. Conflicts: any CONFLICT line means yes.
git merge-tree --write-tree origin/<pre-prod> origin/main

# 2. Noise: the first list should be the second list, nothing more.
#    What GitHub's files tab would list:
git diff --name-only $(git merge-base origin/<pre-prod> origin/main) origin/main
#    What the merge would really change in the pre-prod branch:
git diff --name-only origin/<pre-prod> $(git merge-tree --write-tree origin/<pre-prod> origin/main | head -n1)
```

With squash merges, the first list nearly always has extra files, since every ticket reaches the pre-prod branch before `main`. Then open the back-merge from a `conflicts/backmerge-<release>` branch (the release name or date, e.g. `conflicts/backmerge-2026.11.12`) instead:

```bash
git switch -c conflicts/backmerge-<release> origin/<pre-prod>
git merge --no-ff origin/main
# on conflicts: resolve, git add <files>, then git merge --continue
git push -u origin conflicts/backmerge-<release>
gh pr create --base <pre-prod> --head conflicts/backmerge-<release> --title "..."
```

Its files tab shows only what the merge really changes, often nothing. That's fine: the PR's job is the merge commit, which makes `main`'s commits part of the pre-prod branch's history. `--no-ff` makes sure there is one. Merge it with `gh pr merge <n> --merge`, and close any back-merge PR already open straight from `main`.

Open it straight from `main` only when both lists match. That happens when `main` got something the pre-prod branch never saw, such as a hotfix, and nothing else since the last back-merge. If `git merge-tree` reports nothing to merge (the pre-prod branch already contains `main`), there's no back-merge to do.

The `preprod-pr-check` hook runs this check on `gh pr create --base <pre-prod> --head main` and denies it when the lists differ.

## Epics

The same pre-check and `conflicts/...` recipe apply when deploying a stacked-epic trunk to the pre-prod branch. See the `stacked-epics` skill.
