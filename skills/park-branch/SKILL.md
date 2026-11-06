---
name: park-branch
description: Put a finished feature branch away once it's pushed, its PRs are open and their feedback is resolved, whether or not they've merged - switch back to the default branch, update it, and delete the local feature and conflicts/... branches (they stay on the remote). Use as the last step of a ticket, or when the user says to park, shelve, or clean up the current branch.
metadata:
  category: git-workflow
---

# Parking a finished branch

A branch is ready to park once it's pushed, its PRs are open (see `branching-pr-workflow`) and their review and QA feedback is resolved. The PRs don't need to be merged: everything lives on the remote, and the local copy can be recreated at any time. Parking keeps the local branch list down to work that's actually in progress.

Below, `<branch>` is the feature branch, `<default>` is the repo's default branch (`gh repo view --json defaultBranchRef -q .defaultBranchRef.name`), and the `conflicts/...` branches are any made for its pre-prod PRs (`git branch --list 'conflicts/<ticket>-*'`).

## 1. Make sure nothing is only local

```bash
git fetch origin
git log --oneline @{u}..HEAD
```

Use a plain `git fetch`, not `--prune`: if a merged PR's remote branch was deleted, the kept `origin/<branch>` ref is what lets `git branch -d` confirm the branch was pushed.

Stop and tell the user if:

- `@{u}` doesn't exist: the branch was never pushed.
- the log lists any commit: it was committed but not pushed.
- the same check fails for a `conflicts/...` branch (`git log --oneline origin/<c>..<c>`).

Don't push on the user's behalf here; pushing is their call.

## 2. Leave the branch

**If `<branch>` is checked out in a linked worktree** (`git worktree list` shows it at a path other than the main checkout), remove that worktree rather than switching inside it:

```bash
git worktree remove <path>
```

Never with `--force`, and never the main checkout (the first entry in `git worktree list`). If git refuses because the worktree has changes, stop and show the user what's there. If the current session is running inside that worktree, don't remove it; tell the user instead. Then continue from the main checkout.

**Otherwise**, switch with a plain:

```bash
git switch <default>
```

Uncommitted changes that don't clash come along, as git always does. Only if git refuses (local changes would be overwritten), set them aside with a tagged stash and apply it back by SHA. The stash list is shared by every worktree of the repo and by any other agent session working in it, so never use a bare `git stash` or `git stash pop`, which act on whatever entry is on top:

```bash
msg="park-<branch>-$(date +%Y%m%d%H%M%S)"
git stash push -u -m "$msg"
sha=$(git stash list --format='%H %gs' | grep -F "$msg" | head -n1 | cut -d' ' -f1)
git switch <default>
git stash apply "$sha"
```

- If the apply is clean, drop the entry, found again by its message (its `stash@{n}` position may have moved): `git stash drop "$(git stash list --format='%gd %gs' | grep -F "$msg" | head -n1 | cut -d' ' -f1)"`.
- If the apply conflicts, stop. Resolve the conflicts with the user, and only once that's done drop the entry the same way. Until then it's the only safe copy of those changes.

## 3. Update the default branch

```bash
git pull --ff-only
```

If it refuses, the local default branch has commits of its own; stop and ask rather than merging or rebasing. When `<default>` is checked out in a different worktree than the one you're in, update it there, or with `git fetch origin <default>:<default>` (fast-forward only) if it isn't checked out anywhere.

## 4. Delete the local branches

```bash
git branch -d <branch>
git branch -d conflicts/<ticket>-<slug>   # each one from step 1
```

Always `-d`, never `-D`. `-d` accepts a branch that's fully pushed to its upstream even if the PR hasn't merged, and refuses one that has anything unpushed, which is exactly the safety net wanted here. If it refuses, report why and leave the branch; don't force it. A `conflicts/...` branch pushed without `-u` has no upstream, so `-d` compares it with `HEAD` instead and refuses; after confirming `git log origin/<c>..<c>` is empty, `git branch --set-upstream-to=origin/<c> <c>` and retry.

## 5. Tell the user

Say which branches and worktree were removed and that the default branch is up to date. Also tell them that `git switch <branch>` recreates the branch from `origin/<branch>` whenever it's needed again, for example for another round of feedback.
