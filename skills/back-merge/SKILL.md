---
name: back-merge
description: Back-merge the default branch into the pre-prod branch (dev, develop, staging, ...), or into a long-running feature, epic or version branch (an epic trunk, a 2.0 branch), after a release or hotfix, and reconcile the drift so the target is the default branch plus its own unreleased work and nothing else. Use when asked for a back-merge or to sync a long-lived branch with main, after a release ships, when the preprod-pr-check hook reports a noisy back-merge, when QA's build seems to be missing a fix that is live in production, or when a long-running branch keeps conflicting with main.
metadata:
  category: git-workflow
---

# Back-merging the default branch into the pre-prod branch

The goal is not only a merge commit. When the back-merge lands, the pre-prod branch should be **the default branch plus unreleased work, and nothing else**. QA tests the pre-prod branch, so every difference that isn't unreleased work means QA tests something production doesn't run.

Below, `<pre-prod>` is the branch `branching-pr-workflow`'s `scripts/resolve-preprod-branch.sh` prints (never assume a name), `main` is the repo's default branch, and `<release>` is the release name or date (e.g. `2025.01.15`).

The steps are written for the pre-prod branch. Back-merging into a long-running feature, epic or version branch works the same way, with the differences listed in "Into a long-running feature branch" near the end.

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

`main` is the source of truth: the pre-prod branch should come out of the merge identical to `main`, except where unreleased work changed it.

**Never resolve a whole file with `--ours`, `--theirs` or `git checkout <side> -- <file>`.** Resolve hunk by hunk. Taking `main`'s whole copy of a form component, say, would also delete the pre-prod branch's unreleased import and the three props that use it; taking the pre-prod copy would drop `main`'s fixes for good.

Work is **unreleased** when its commit, in `origin/main..origin/<pre-prod>`, carries at least one ticket key that never appears in `git log origin/main --format=%B`. At least one, not all: an epic's key shows up on both sides as soon as one of its sub-tasks ships, so a commit tagged with the epic and an unshipped sub-task is still unreleased. If the repo's commits carry no ticket keys, ask the user which work is unreleased.

For each hunk, find out where each side's lines came from (`git log -L`, `git log -S` or `git blame` on both branches), then:

| The hunk | Resolve to |
| --- | --- |
| The same code on both sides, only moved, reordered, reformatted, with different comments, or with imports in another order | `main`'s version |
| A change only `main` has (a hotfix, a release-time fix) | `main`'s version |
| A change only the pre-prod side has, from unreleased work | Keep it, applied to `main`'s layout |
| A change only the pre-prod side has, from a ticket that already shipped | `main`'s version: it holds what production runs. Keep the pre-prod side only if it's plainly a later fix to the same code, and say so in the PR |
| Deleted by unreleased pre-prod work, modified on `main` | Keep it deleted, and say in the PR what `main` changed there, in case the unreleased replacement needs it too |
| Deleted on `main` (shipped), modified on the pre-prod side | Delete it. If the pre-prod change is unreleased work, stop and ask the user where it should go now |
| The same logic changed differently on each side | `main`'s behaviour plus the unreleased additions. If they can't be combined safely, stop and ask the user |
| An import block | Exactly the imports the merged code uses, in `main`'s order. Check each name against the file's body |

Resolving a hunk toward the pre-prod side when the table says `main` doesn't postpone the difference, it makes it permanent. Once this merge lands, the merge base moves to `main`'s tip, so every later merge sees the pre-prod version as a change the pre-prod branch made on its own and keeps it without a conflict. Only a manual edit removes it. A dropped fix works the same way (see above).

After resolving a file, `git diff origin/main -- <file>` should show only unreleased work, and `git diff origin/<pre-prod> -- <file>` only `main`'s changes that belong in it.

Finish with `git merge --continue`. This merge commit is commit 1 of the PR, and it stays a pure merge: everything from step 4 goes in commits after it.

## 4. Audit the drift

```bash
GH_TOKEN=$(gh auth token) bash <this skill>/scripts/backmerge-drift-audit.sh \
  --merged HEAD --since <date of the last audited back-merge>
```

How far back `--since` reaches matters. Report 1 below checks `main`'s commits one by one, so it only finds fixes lost inside that window (90 days if you leave it out). Reports 2 and 3 have no window. The first audit on a repo, or the first after a long gap, needs a long window: back to when the pre-prod branch was created, or `--since "2 years ago"`. It runs slower, but a fix lost long ago, in a file that unreleased work also touches, isn't found by anything else. Once a back-merge has been audited and reconciled, later audits only need to reach back to it.

Without `--default` it audits against the default branch `gh` reports, or `origin/HEAD` when `gh` can't tell, and stops with an error if neither works. It prints three reports:

1. **Released changes missing from the merged state**: commits on `main` whose change is still on `main` but not in the merge: lines they added that are missing, and lines they removed (or files they deleted) that are back. Each commit is checked line by line, so one whose change was later edited on `main` still counts for the parts that are left.
2. **Differences no unreleased ticket explains**: files that differ, where no commit touching them on the pre-prod side names a ticket `main` hasn't shipped. The pre-prod side's commits include the merges that brought work in, since a ticket's key is sometimes only in its branch name or PR title.
3. **Drift in the back-merge's conflicted files**: for each file that conflicted, how many lines differ from `main`'s side before and after the merge, flagged when there are more after. It also lists lines that only moved and hunks that only changed whitespace or comments, each traced with `git blame` to its commit: `unreleased work (KEY)` stays, `DRIFT` goes back to `main`'s version (the first rows of step 3's table). It finds the back-merge commit itself, past any reconciliation commits; pass `--merge <commit>` if it can't. Report 2 can't see this drift when an unreleased ticket also touched the file, which is common in conflicted files.

The heuristics behind them, so you know what they can miss:

- Ticket keys are Jira-style (`ABC-123`) by default. Pass `--ticket <regex>` for another format. GitHub `#123` references are PR or issue numbers, not ticket keys. When either side has no keys at all, report 2 says it can't tell unreleased work from drift and lists every differing file, for you to sort by hand.
- A ticket counts as shipped once its key appears anywhere in `main`'s history.
- Report 1 skips binary changes.
- Report 1 compares lines with their surrounding whitespace trimmed, so reformatted code (rewrapped, quotes or trailing commas changed) can look like missing lines.
- Report 3 counts a line as moved when, without whitespace, it has at least 8 characters, isn't only punctuation, and is both removed and added against `main`'s side. A comment line starts with `//`, `#`, `/*`, `*`, `<!--` or `{/*`. An unreleased refactor that moves code shows up too, attributed to its ticket.

All three reports are leads. Classify each one before acting, by comparing the two versions (`git diff origin/main HEAD -- <file>`) and grepping the merged tree for the missing lines:

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

## 5. Verify the merged tree

What needs checking is what the back-merge changes in the pre-prod branch:

```bash
git diff --stat origin/<pre-prod> HEAD
```

If that's empty, CI has already passed this exact tree on the pre-prod branch. Skip the local checks and say so in the PR.

Otherwise run the repo's own CI steps, read from its CI config (e.g. `.github/workflows/*.yml`), never assumed. Match CI's environment, or failures that have nothing to do with the merge get blamed on it:

- The runtime version CI pins (e.g. `node-version-file: .nvmrc`, run through `nvm use`).
- CI's timezone and locale. GitHub's runners use UTC, so set `TZ=UTC` unless the workflow sets something else.
- A frozen-lockfile install in the worktree, with the package manager whose lockfile is committed (see `package-manager-safety`).

(Real case: a newer Node major than the pinned one failed eight tests on a back-merge, and the local timezone one more. CI passed all nine.)

A repo's checks may already fail on the pre-prod branch, so before blaming the merge for a failure, run the same check on the pre-prod tip's exact tree. If it fails there too, it isn't the merge's fault: say so in the PR, and propose fixing it separately. One example, for a TypeScript repo's type check; the same before-and-after comparison works for any linter or checker whose output lists one problem per line:

```bash
# One error per line, line numbers dropped: in the back-merge worktree...
npx tsc --noEmit | grep 'error TS' | sed -E 's/\([0-9]+,[0-9]+\)//' | sort > <scratch-dir>/branch.txt
# ...and in a worktree at the pre-prod tip, after its own install.
git worktree add <scratch-dir>/base origin/<pre-prod>
(cd <scratch-dir>/base && npx tsc --noEmit) | grep 'error TS' | sed -E 's/\([0-9]+,[0-9]+\)//' | sort > <scratch-dir>/base.txt
comm -13 <scratch-dir>/base.txt <scratch-dir>/branch.txt   # new errors: each one needs a look
```

A new error is often the "`main` itself is broken" row from step 4's table.

CI must then pass on the PR's final head before it merges. A green run on an earlier head doesn't count.

## 6. Commit and open the PR

Commit order on `conflicts/backmerge-<release>`:

1. The merge commit from step 3.
2. One commit per restored ticket, e.g. `fix(<ticket>): restore <the fix> that <pre-prod> lost`. Say in the body which merge dropped it and link the original `main` commit.
3. One `chore:` commit for the merge leftovers.

Separate commits mean any one of them can be reverted without touching the others. Never revert the merge commit itself: git would go on treating `main` as merged while its content was gone, which is the problem this skill exists to fix.

Push, then open the PR against `<pre-prod>` (title per `pr-title-conventions`, e.g. `🔀 Back-merge the <release> release into <pre-prod> and reconcile drift`). The description covers:

- the release and the commits, one line each
- each conflicted file, which row of the resolution table applied, and why
- what was restored, and which merge had dropped it
- what was deliberately left as it is: unreleased tickets, deletions kept from unreleased work, and pre-prod-only items waiting for the user's ship-or-remove decision
- any bugs found on `main`, for their own fix there
- the verification results, measured against the pre-prod tip, or why the checks were skipped

Its files tab shows what the merge and the reconciliation change in the pre-prod branch. An empty tab is fine only when nothing conflicted, or every conflict was unreleased work. Resolving toward `main` normally makes the PR change the conflicted files, and that's what it's for.

It must be merged with a merge commit (`gh pr merge <n> --merge`), never squashed: a squash leaves the merge base where it was, and the noise and drift come back. Close any back-merge PR already open straight from `main`.

### Updating an open back-merge PR

- If `main` got more commits since, merge `origin/main` into the same branch again in the worktree, resolve as in step 3, rerun steps 4 and 5, and push. Ask first, like any push.
- If an earlier resolution was wrong, or the branch now conflicts with the pre-prod branch, redo the merge on a fresh branch from `origin/<pre-prod>`, rerun steps 4 and 5, then ask the user before force-pushing it over the PR's branch.

## Into a long-running feature branch

A branch that lives through several releases (an epic trunk from `stacked-epics`, a `2.0` version branch) needs `main` merged into it too, or it meets every release's conflicts at once when it finally ships. Drift gets in the same way: a conflict resolved toward the feature side drops `main`'s fix, and later merges count it as merged. So the goal is the same, with the feature branch as the target: **`main` plus the branch's own work, and nothing else**.

What carries over unchanged:

- Step 3: merge `--no-ff` in a separate worktree, and resolve with the same table. "Unreleased work" is the branch's own commits, `origin/main..origin/<branch>`, with the same ticket-key test, since parts of the branch may already have shipped to `main` as squash commits.
- Step 4: the audit, with `--merged` on the merged feature branch.
- Steps 5 and 6: verification against the branch's tip, and the commit layout.

What differs:

- Skip steps 1 and 2. There's no pre-prod branch to resolve and no noise check: that check is about a PR's files tab on the pre-prod branch.
- Where the merge lands follows the repo's rules for that branch. If it's protected or shared, open a PR into it from a `backmerge/<release>-into-<branch>` branch cut from it. Otherwise merge in the worktree and push to it, after asking the user, like any push.
- Do it after every release, not only before the branch ships. Each release you skip adds its conflicts and its chances of drift to the next merge.
- Never rebase a shared feature branch onto `main` instead: that rewrites history everyone else has.

## Afterwards

Run the audit again once the PR has merged (`--merged origin/<pre-prod>`). Report 3 then finds the back-merge commit through the PR's merge commit. If it says it skipped, pass `--merge` with the merge commit from step 3 (`git rev-list --first-parent --merges -n1 origin/conflicts/backmerge-<release>`). Report 1 should be empty apart from fixes you confirmed had moved, and report 2 should list only the pre-prod-only items the user still has to decide on.
