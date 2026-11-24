---
name: branching-pr-workflow
description: Standard branching and dual-PR workflow (one PR against the default branch, one against the pre-prod branch) for a standalone ticket or fix. Use when starting a new branch, reviewing your own diff before opening its PRs, opening a PR, handling a round of QA or review feedback, finding out which branch is a repo's pre-prod branch, or deciding whether a change needs the dual-PR treatment at all.
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

## Review your own diff before opening PRs

Once the change is complete, the repo's checks pass and the work is committed, have a reviewer that hasn't seen this session read the whole branch diff before the branch's PRs are opened. Pushing the branch earlier, to keep the work safe on the remote, is fine: nobody reviews a branch that has no PR. Copilot reviews each changed line on its own. A reviewer reading the whole diff catches what Copilot doesn't: docs that say one thing while the code does another, an edge case the tests never reach, a script that still relies on something another file just changed. Every such finding caught here is one Copilot round fewer later.

1. **Run the `diff-review` skill** (`pr-conventions` plugin) on the branch, from the merge base with a freshly fetched default branch to `HEAD`. It dispatches a fresh-context reviewer, checks every finding and hands back the confirmed and unverified ones. Without that plugin, dispatch a fresh subagent yourself with the range, the ticket, the repo's instruction files and the instruction to find bugs, not to summarise or praise, giving each one a severity: High (must not reach the pre-prod branch or production), Medium (fix it, but not a blocker) or Low (minor). Then check each finding against the code yourself: confirmed, not applicable (with the evidence), out of scope, or unverified (with what would settle it).
2. **Act on its verdicts.** Fix every confirmed High and Medium finding, and the Low ones when the fix is quick. Show the user each unverified finding with what would settle it, since it may still be serious. Tell the user about out-of-scope findings and offer a follow-up ticket. Nothing has been posted yet, so there are no threads to reply to.
3. **Fold each fix into the commit that caused it**, unless one of these holds, in which case commit the fixes on top instead:
   - The range holds a merge commit (`git log --merges <base>..HEAD` prints one), such as a back-merge of `main`: the rebase would drop it.
   - Another local branch is built on this one: `git branch --contains <oldest-commit-of-this-branch>` lists more than this branch. Rewriting would leave that branch on the old commits.
   - The branch is already pushed and folding is no longer safe (the paragraph after this list), or the user says no when asked.

   Every commit on the branch ends up in the default branch's history whenever PRs are merged with a merge commit. A bug in one commit with its fix in a later one leaves `git bisect` a commit that is known to be broken, and `git revert` a half-fixed state. Make and commit one fix at a time, as a fixup of the commit that introduced the bug, then fold them all in one rebase. One at a time matters: `--fixup -- <paths>` commits the whole file, so two fixes in one file would land in the same fixup. Before each commit, check `git diff --cached --name-only` for a checkpoint the user staged in those files, and ask first if there is one. It needs no editor on git 2.44 or later; on older git, prefix the rebase with `GIT_SEQUENCE_EDITOR=:` and add `-i`.

   ```bash
   git commit --fixup=<sha-that-introduced-the-bug> -- <paths>
   git rev-parse HEAD   # note this SHA: it is <before> below
   git rebase --autosquash "$(git merge-base origin/<default-branch> HEAD)"
   git diff --quiet <before> HEAD && echo "tree unchanged"
   ```

   Write `<before>` out as the literal SHA, not a shell variable: a rebase that stops on a conflict carries on over several commands, and a variable set in one shell is gone in the next.

   - The rebase needs a clean working tree. If the user has a checkpoint staged, ask before rebasing.
   - For a subtask in a `stacked-epics` stack, rebase onto `$(git merge-base <branch-below> HEAD)` instead, so the rebase never rewrites the commits of the branch below. Rebasing onto that branch's tip would also pull in anything it gained since, and the tree check would fail every time.
   - If a later commit touched the same lines, the rebase stops on a conflict. Resolve it, `git add` the files and `git rebase --continue`. If the conflict spreads over many commits, `git rebase --abort` and keep that fix as a commit of its own.
   - The tree check must print "tree unchanged". A fixup rebase only moves changes between commits, so the final tree is identical to the one before it. If it isn't, a conflict was resolved wrongly: `git reset --hard <before>` (safe here, since the tree was clean) and try again.
   - The tree check proves only the final state. A fix that uses something a later commit adds (a helper, a config key) breaks its target commit once folded: fold it into that later commit instead, or keep it on top. When the repo has a quick check, `git rebase --exec '<check>' <base>` runs it on every rewritten commit. In a linked worktree the check runs with `GIT_DIR` set to the real repository, so a test that builds its own git repos must unset `GIT_DIR` (and `GIT_WORK_TREE`, `GIT_INDEX_FILE`) first, or its `git init` and commits land in the real one.

   Then run the checks again. Review at most once more, and only if the fixes changed behaviour beyond the lines the findings named.

The review happens once per PR, before the PRs are opened. Folding rewrites commits, so a branch that's already pushed needs a force-push afterwards. That's safe while nothing is built on the old commits: nobody else has the branch and no stacked branch sits on top of it. If the PRs are already open (the review came late), one more condition applies: no review has been requested or posted on any of them, by Copilot or a human. Check each PR (`gh pr view <N> --json reviews,reviewRequests`, and `check-pr`'s `copilot-review.sh <N>` for Copilot, whose request doesn't always show there). Not having run `check-pr` proves nothing, since repo automation can request Copilot too. Ask the user before force-pushing (`AGENTS.md`), and push only this branch: `git push --force-with-lease --force-if-includes origin <branch>`. Without `--force-if-includes`, the lease checks against whatever the last `git fetch` saw, so it protects nothing right after one. Then rebuild any `conflicts/...` branch from the pre-prod branch, because it merged the old commits. Once any of those no longer holds, fixes go in new commits on top.

Later pushes (a `check-pr` fix round, a QA finding under "Handling feedback") don't repeat the review: Copilot's re-review covers those. The exception is a fix big enough to be a change in its own right, a rewrite rather than a patch.

If the pre-prod PR goes out from a `conflicts/...` branch (see `clean-preprod-pr`) whose merge needed conflicts resolved by hand, review the resolution the same way before opening that PR. Give `diff-review` the range `<merge-commit>^1..<merge-commit>`, and as `{FOCUS}` the hunks `git show --remerge-diff <merge-commit>` prints: those are exactly what the resolution changed. Fix its findings with a new commit on that `conflicts/...` branch, never with step 3: rebasing a merge drops it. If the resolution is wrong throughout, redo the merge on a fresh branch from the pre-prod branch.

Skip the review only when there's no behaviour to get wrong: a typo, a version bump, a comment. Skill text and prompts in a repo like this toolkit count as behaviour, so they get reviewed.

The same review applies to a single-PR change that skips the dual-PR process, and to each subtask PR in a `stacked-epics` stack, against the branch below it (see that skill).

## Opening PRs

Once local changes are complete, verified (`verify --full` from the `verify` skill passes on the branch) and self-reviewed (above), push the branch and open **two PRs**, both as **drafts** unless told otherwise. Don't ask first: a passing `verify --full` is what makes this safe. The one exception is a repo where `verify` reports the gate off: nothing checked the code, so ask the user before pushing.

That first push is the one that needs `--full`, so the PRs open green and no review is spent on broken code. Later pushes of the branch need only `verify --related`: CI runs everything on each push, and `check-pr` fixes what it finds. A `conflicts/...` branch is the exception, needing `--full` on every push, since each merge into it is new code.

1. One against **`main`**: this is the PR that will eventually ship the change to production. It stays open for the lifetime of the ticket.
2. One against **the pre-prod branch**: this deploys the change to the pre-prod environment for QA.

Before opening the pre-prod PR, run the pre-check in the `clean-preprod-pr` skill (this plugin's `preprod-pr-check` hook enforces it). The pre-prod branch accumulates every ticket's merged work, so a PR into it can be blocked by conflicts unrelated to your change. It can also list files your branch never touched: each ticket reaches `main` and the pre-prod branch through different commits (a merge commit on each, or a squash commit on `main`), so when nobody has back-merged `main` into the pre-prod branch, your branch carries `main`'s commits for tickets the pre-prod branch already has in another form. Either way the PR goes out from a `conflicts/<ticket>-<slug>` branch instead, as that skill describes.

Give both PRs the same title (see `pr-title-conventions`). Apply a **`production`** label (or the repo's equivalent) to the `main` PR only, never to the pre-prod PR, for easy tracking of what's queued to ship.

### Then run `check-pr`

As soon as both drafts are open, run the `check-pr` skill (in `github-tooling`) on them, without stopping to ask. It requests reviews and waits for them, triages Copilot, human and CI feedback, and then asks the user to test the running app. The user's approval there is the one place the chain stops for them: only then does the pre-prod PR get `manually-verified` and leave draft, and the local branches get cleaned up. The `main` PR stays a draft until the ticket is released.

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

Once the PRs are clean and the user has approved the change (or, for a single-PR change, once it's clean), the local branches and worktree have nothing left that isn't on the remote. `check-pr` runs the `branch-cleanup` skill at that point; run it yourself if the PRs got there some other way. This is the last step for every ticket.

## Skipping the dual-PR process

Docs-only or otherwise low-risk changes that don't need QA can skip the dual-PR process: a single PR against `main` is enough. So can any repo where the resolver reports no pre-prod branch. With no pre-prod PR there's nothing for the user to test before it goes out: `check-pr` cleans up as soon as the PR is clean, without waiting for an approval.
