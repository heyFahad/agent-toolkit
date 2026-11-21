---
name: branch-cleanup
description: Remove every local worktree and branch of a repo that holds nothing that exists only on this machine, and fast-forward the default branch. Nothing on the remote is touched, and open PRs don't need to merge first. Use as the last step of a ticket (check-pr runs it once the PRs are clean), when the user asks to clean up, park, or shelve branches or worktrees, when worktrees pile up or take too much disk, and before making an extra worktree.
metadata:
  category: git-workflow
---

# Cleaning up branches and worktrees

Everything a finished branch holds is on the remote: its commits, and its PRs whether they merged or not. Its local copy and worktree only take up space and bury the branch actually being worked on. This skill removes them, safely, for the whole repo at once: the current ticket's branch, other sessions' leftovers, and worktrees agents made and forgot.

## The rule

A **worktree** is removed only when all of these hold:

- It isn't the one the cleanup runs in, isn't locked (`git worktree lock`), and has no other worktree inside it.
- **No git operation is in progress**: no rebase, merge, cherry-pick, revert, bisect or `git am`. A paused rebase can have a clean tree, and removing the worktree would lose its progress.
- **No process is working inside it.** A clean worktree can still be in use: a session waiting on a review, a running dev server. Git can't tell, so the script asks the OS with `lsof`. Without `lsof`, it keeps any worktree whose index changed in the last hour.
- **No changes**: `git status` succeeds and shows nothing, tracked or untracked. If it fails (a corrupt index, an ownership error), the worktree is kept, since its state can't be checked.
- **No ignored files that can't be rebuilt.** `git worktree remove` deletes ignored files without asking. A wholly ignored dependency or build folder (`node_modules/`, `dist/`, ...), generated lockfiles, symlinks and the top-level harness folders `.claude/` and `.codex/` are fine. A folder's name only counts when the whole folder is ignored, so an ignored file inside a tracked `build/` folder still keeps the worktree; a `.env`, a local database, or anything else ignored keeps the worktree, and the report names the file.
- **Every commit is on a remote**, for its branch or its detached HEAD.

A worktree whose folder is already gone is pruned, unless its folder looks like it was on a drive that isn't mounted (under `/Volumes`, `/mnt` or `/media`). Then nothing is pruned, since `git worktree prune` is all-or-nothing: plug the drive back in, or lock that worktree.

A **branch** other than the default branch is deleted only when it's checked out in no remaining worktree and every commit on it is on a remote. That includes the `claude/<name>` branches desktop sessions start on and then leave behind, and `conflicts/...` branches pushed without an upstream. A merged PR's branch whose remote copy was deleted counts as pushed when `gh` shows that PR's head is the branch's tip.

Stashes belong to the whole repo, not to a worktree or branch, so they survive the cleanup. Remote branches are never deleted.

## Run it

From any checkout of the repo:

```bash
bash scripts/branch-cleanup.sh
```

The script is in this skill's `scripts/` directory. It fetches `origin` (a plain fetch, no `--prune`, so a merged PR's `origin/<branch>` ref still proves it was pushed), cleans up, fast-forwards the local default branch, and prints JSON. Flags: `--dry-run` reports without changing anything, `--no-fetch` skips the fetch, `--default BRANCH` names the default branch when neither `gh` nor `origin/HEAD` can tell.

Run it without asking: everything it removes passed the rule above, so no work can be lost. Use `--dry-run` first only when the user asks what it would do.

## Report

Tell the user, as a table, what was removed and what was kept, with each kept item's reason from the JSON (`in use`, `uncommitted changes`, `ignored files that can't be rebuilt` with the files, `commits that aren't on any remote`, `locked`, the worktree it ran in). Say whether the default branch was updated. Add that `git switch <branch>` brings any deleted branch back from the remote.

Don't act on what was kept: removing a dirty worktree, deleting a `.env`, or pushing a local-only branch is the user's call. The worktree the cleanup ran in goes the next time it runs from somewhere else.

## Resuming after a cleanup

A session whose worktree was removed while it was idle keeps its conversation. When it resumes, its harness may give it a fresh worktree on a stale branch, or put it in the repo's main checkout on the default branch. Either way, before changing anything:

```bash
git status -sb        # where am I?
git switch <branch>   # recreated from origin/<branch> if it was deleted
```

If that puts you in the repo's main checkout, don't switch branches there: other sessions share it, and a clean `git status` doesn't mean nobody else is working in it. Their next edit or commit would land on your branch. Make a worktree for the branch instead, as below, and work there.

## Making an extra worktree

A skill that needs another branch checked out (a back-merge, a `conflicts/...` branch) may switch branches in the session's own checkout only when that checkout is a linked worktree the session runs in (`git rev-parse --git-dir` differs from `git rev-parse --git-common-dir`) and `git status` is clean; switch back afterwards. Never switch branches in the repo's main checkout: other sessions share it, and a clean tree doesn't mean nobody else is working there. Otherwise make a worktree:

1. Use the harness's own worktree feature and location, if it has one.
2. Otherwise use `<repo>/.worktrees/<name>`. Check that it's ignored (`git check-ignore -q .worktrees/x`), and if it isn't, add `.worktrees/` to the repo's shared exclude file, which needs no commit: `echo .worktrees/ >> "$(git rev-parse --git-path info/exclude)"`. Don't write to `.git/info/exclude` directly: in a linked worktree `.git` is a file, not a folder.

Never put a worktree in a scratch or temp directory: it lands outside the folders the harness has permission for, the folder may be wiped while git still lists it, and repo-pinned tool setup (`mise trust`, hooks) has to be repeated there. This cleanup removes extra worktrees wherever they are once they're pushed.
