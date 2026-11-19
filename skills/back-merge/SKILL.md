---
name: back-merge
description: Back-merge the default branch into the pre-prod branch (dev, develop, staging, ...) after a release or hotfix, and reconcile the drift between them so the pre-prod branch is the default branch plus unreleased work and nothing else. Use when asked for a back-merge or to sync the pre-prod branch with main, after a release ships, when the preprod-pr-check hook reports a noisy back-merge, or when QA's build seems to be missing a fix that is live in production.
metadata:
  category: git-workflow
---

# Back-merging the default branch into the pre-prod branch

The goal is not only a merge commit. When the back-merge lands, the pre-prod branch should be **the default branch plus unreleased work, and nothing else**. QA tests the pre-prod branch, so every difference that isn't unreleased work means QA tests something production doesn't run.

Below, `<pre-prod>` is the branch `branching-pr-workflow`'s `scripts/resolve-preprod-branch.sh` prints (never assume a name), `main` is the repo's default branch, and `<release>` is the release name or date (e.g. `2025.01.15`).

## Why the two drift apart

Each ticket reaches the two branches by different routes: the pre-prod branch through a `conflicts/<ticket>` branch cut from the pre-prod branch, and `main` through a release branch cut from `main`. Each route resolves its conflicts against a different base, so the same ticket can end up with different code on each side.

The damaging case is a merge from `main` into the pre-prod branch that resolves a file in the pre-prod branch's favour. Production fixes in that file vanish from the pre-prod branch, but git now counts their commits as merged, so **no later back-merge brings them back**. Only an explicit restore does. (Real case: a feature's `conflicts/` merges pulled in `main`'s history and kept the pre-prod side. A month later the pre-prod branch was still missing a dozen shipped fixes, and three back-merges had gone through without a single conflict on them.)

## 1. Is a back-merge due?

A back-merge is due after every release or hotfix to `main`, and whenever the `clean-preprod-pr` pre-check reports unrelated files on a ticket's pre-prod PR. First look for one that's already open, whose head is `main` or a `conflicts/backmerge-...` branch:

```bash
git fetch origin <pre-prod> main
gh pr list --base <pre-prod> --state open --json number,headRefName
```

If there's none, offer the user to open one. Ask first, like any PR.

## 2. Pre-check: straight from `main`, or from a branch?

A back-merge PR straight from `main` is usually noisy: it lists every squash commit since the last back-merge, even though the pre-prod branch already has almost all of that content from the original ticket commits. (Real case: a back-merge PR from `main` listed 14 files and the merge changed none of them.) There's no "own change" to compare against, so compare what the PR would list with what the merge would really change:

```bash
# 1. Conflicts: any CONFLICT line means yes.
git merge-tree --write-tree origin/<pre-prod> origin/main

# 2. Noise: the first list should be the second list, nothing more.
#    What GitHub's files tab would list:
git diff --name-only $(git merge-base origin/<pre-prod> origin/main) origin/main
#    What the merge would really change in the pre-prod branch:
git diff --name-only origin/<pre-prod> $(git merge-tree --write-tree origin/<pre-prod> origin/main | head -n1)
```

- If `git merge-tree` reports nothing to merge (the pre-prod branch already contains `main`), there's no back-merge to do.
- Open it straight from `main` only when there's no conflict and both lists match. That happens when `main` got something the pre-prod branch never saw, such as a hotfix, and nothing else since the last back-merge. Still run the drift audit (step 4) on the merged result.
- Otherwise, and with squash-merged releases that's nearly always, it goes out from a `conflicts/backmerge-<release>` branch cut from the pre-prod branch. Its files tab shows only what the merge really changes.

The `preprod-pr-check` hook runs this check on `gh pr create --base <pre-prod> --head main` and denies the PR when the lists differ.

## 3. Merge in a separate worktree

Do the work in a separate worktree, so the user's checkout and its uncommitted changes stay untouched:

```bash
git worktree add -b conflicts/backmerge-<release> <scratch-dir>/backmerge origin/<pre-prod>
cd <scratch-dir>/backmerge
git merge --no-ff origin/main
```

`--no-ff` makes sure there's a merge commit even when the pre-prod branch could fast-forward. The merge commit is what makes `main`'s commits part of the pre-prod branch's history.

### Resolving conflicts

A resolution is permanent: whatever `main` content it drops stays dropped (see above). So:

- **Never resolve a whole file with `--ours`, `--theirs` or `git checkout <side> -- <file>`.** Resolve hunk by hunk.
- For each hunk, find out where each side's lines came from (`git log -L` or `git log -S` on both branches):
  - The pre-prod side is unreleased work (a ticket not in `main`'s history): keep it, and fold in `main`'s change if it's still relevant.
  - The pre-prod side belongs to a ticket that already shipped: `main` holds what production runs. Take `main`'s side unless the pre-prod side is plainly a later fix to the same code.
  - Import blocks: keep exactly the imports the merged code uses, and check each name against the file's body.
- After resolving, `git diff origin/<pre-prod> -- <file>` should show only `main`'s changes that belong in the file.

Finish with `git merge --continue`. This merge commit is commit 1 of the PR, and it stays a pure merge: everything from step 4 goes in commits after it.

## 4. Audit the drift

```bash
GH_TOKEN=$(gh auth token) bash <this skill>/scripts/backmerge-drift-audit.sh \
  --merged HEAD --since <date of the last clean back-merge, or 90 days>
```

Without `--default` it audits against `origin/HEAD`, or the default branch `gh` reports, and stops with an error if neither works. It prints two reports:

1. **Released changes missing from the merged state**: commits on `main` whose change is still on `main` but not in the merge, with the lines that are missing.
2. **Differences no unreleased ticket explains**: files that differ, where no commit touching them on the pre-prod side names a ticket `main` hasn't shipped. The pre-prod side's commits include the merges that brought work in, since a ticket's key is sometimes only in its branch name or PR title.

The heuristics behind them, so you know what they can miss:

- Ticket keys are Jira-style (`ABC-123`) by default. Pass `--ticket <regex>` for another format. GitHub `#123` references are PR or issue numbers, not ticket keys. When either side has no keys at all, report 2 says it can't tell unreleased work from drift and lists every differing file, for you to sort by hand.
- A ticket counts as shipped once its key appears anywhere in `main`'s history.
- Report 1 skips binary changes.
- Report 1 compares lines with their surrounding whitespace trimmed, so reformatted code (rewrapped, quotes or trailing commas changed) can look like missing lines.

Both reports are leads. Classify each one before acting, by comparing the two versions (`git diff origin/main HEAD -- <file>`) and grepping the merged tree for the missing lines:

| Finding | What to do |
| --- | --- |
| Belongs to an unreleased ticket | Keep it. It reaches `main` when the ticket ships. |
| A released fix that was lost | Restore it. Take `main`'s whole file when the file has no unreleased work in it (`git checkout origin/main -- <file>`), otherwise merge the fix in by hand. Bring its tests along. |
| A released fix that moved, or was superseded by unreleased work | Keep the pre-prod version. Grep for the fix's key lines in the merged tree to confirm it's really there. |
| Merge leftovers: import order, comment wrapping, rule order, dead code `main` removed | Take `main`'s copy, so the next back-merge doesn't conflict on it again. |
| On the pre-prod branch only, with no unreleased ticket (CI, tooling, docs, small untracked fixes) | Don't decide alone. List it in the PR for the user: ship it to `main`, or remove it from the pre-prod branch. |
| `main` itself is broken (an import of something that doesn't exist, a removed declaration still in use) | Keep the pre-prod version, and report the `main` bug for its own fix there. Don't copy the breakage over. |

A deliberate change on an unreleased ticket can look like drift: a renamed label, reworded copy, a restyled screen. It stays. QA should see the build that will ship, and the change reaches `main` with its ticket. If QA expects that change in production, the gap is a release-planning question (has the ticket shipped yet?), not something to fix by reverting the pre-prod branch to `main`.

Don't overwrite the pre-prod branch with `main` wholesale to "make them equal". That removes every unreleased ticket from QA's build.

## 5. Verify against the pre-prod baseline

A repo's checks may already fail on the pre-prod branch, so compare instead of expecting a clean run. One example, for a TypeScript repo's type check; the same before-and-after comparison works for any linter or checker whose output lists one problem per line:

```bash
# List errors with and without the reconciliation, ignoring line numbers.
npx tsc --noEmit | grep 'error TS' | sed -E 's/\([0-9]+,[0-9]+\)//' | sort > /tmp/branch.txt
git stash; npx tsc --noEmit | grep 'error TS' | sed -E 's/\([0-9]+,[0-9]+\)//' | sort > /tmp/base.txt; git stash pop
comm -13 /tmp/base.txt /tmp/branch.txt   # new errors: each one needs a look
```

A new error is often the "`main` itself is broken" row from the table above. Run lint on the changed files and the full test suite too. The worktree needs its own dependency install (check the committed lockfile first, see `package-manager-safety`).

## 6. Commit and open the PR

Commit order on `conflicts/backmerge-<release>`:

1. The merge commit from step 3.
2. One commit per restored ticket, e.g. `fix(<ticket>): restore <the fix> that <pre-prod> lost`. Say in the body which merge dropped it and link the original `main` commit.
3. One `chore:` commit for the merge leftovers.

Separate commits mean any one of them can be reverted without touching the others. Never revert the merge commit itself: git would go on treating `main` as merged while its content was gone, which is the problem this skill exists to fix.

Push, then open the PR against `<pre-prod>` (title per `pr-title-conventions`, e.g. `🔀 Back-merge the <release> release into <pre-prod> and reconcile drift`). The description covers:

- the release and the commits, one line each
- how each conflict was resolved and why
- what was restored, and which merge had dropped it
- what was deliberately left as it is: unreleased tickets, and pre-prod-only items waiting for the user's ship-or-remove decision
- any bugs found on `main`, for their own fix there
- the verification results, measured against the baseline

It must be merged with a merge commit (`gh pr merge <n> --merge`), never squashed: a squash leaves the merge base where it was, and the noise and drift come back. Close any back-merge PR already open straight from `main`.

## Afterwards

Run the audit again once the PR has merged (`--merged origin/<pre-prod>`). Report 1 should be empty apart from fixes you confirmed had moved, and report 2 should list only the pre-prod-only items the user still has to decide on.
