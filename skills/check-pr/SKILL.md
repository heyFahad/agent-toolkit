---
name: check-pr
description: Use when checking your own PR's CI and review feedback, getting a ticket's PRs clean, fixing a failing build, or triaging Copilot or human review comments, across both the main PR and its pre-prod PR. Requests Copilot reviews, assesses every finding, fixes on the feature branch, replies, gives one clean/not-clean answer, and parks the branch once every PR is clean. Not for reviewing someone else's PR (see give-pr-review).
metadata:
  category: github-tooling
---

# Check a ticket's PRs

One pass over a ticket's PRs: request Copilot, read CI and every unresolved review thread on both PRs, fix what is real, answer the rest, and say whether each PR is clean. Once they all are, park the branch. For repeated passes, wrap this skill in `/loop`.

## Scripts

All in this skill's `scripts/` directory, all print JSON. Run each one as `GH_TOKEN=$(gh auth token) bash scripts/<name>.sh ...` (the `gh-token-export` hook in this plugin denies the call otherwise). `-R OWNER/REPO` is optional; without it the repo is the current checkout's.

| Script | Gives you |
| --- | --- |
| `find-pr-pair.sh [BRANCH]` | The ticket's PRs from its feature branch: `main` and `preprod[]` |
| `review-threads.sh PR [--all]` | Unresolved threads with ids, from Copilot, other bots and humans |
| `copilot-review.sh PR` | Copilot's latest review: `requested`, `stale`, `lowConfidence[]` |
| `ci-status.sh PR` | Checks on the head commit: `failing[]`, `pending[]`, with `jobId` for Actions jobs |
| `job-log.sh JOB_ID [LINES]` | The tail of a GitHub Actions job's log |
| `reply-thread.sh THREAD_ID --body TEXT [--resolve]` | Posts a reply, and resolves a bot's thread. Refuses to resolve a human's (exit 3) |
| `pr-gate.sh PR` | `clean`, `blocking[]`, `warnings[]`; exit 0 only when clean |

## 1. Find the PRs

Run `find-pr-pair.sh` from the feature branch (not a `conflicts/...` branch). Never assume `dev`, `develop` or `staging`; the script reads the repo's default branch and matches PRs by head:

- `main` is the PR from the feature branch into the default branch.
- `preprod` is every PR into any other branch whose head is the feature branch or one of its `conflicts/...` branches.

If `preprod` has more than one entry, don't guess. If git-workflow's `resolve-preprod-branch.sh` is installed, keep the entry whose base it names; otherwise ask the user. Either PR may be missing: check whichever exist and say which one you didn't find.

## 2. Request Copilot on both PRs at once

Unless `copilot-review.sh` already shows `requested: true`, or a review that isn't `stale`, request one on every PR from step 1 in a single command:

```bash
gh pr edit 101 --add-reviewer @copilot && gh pr edit 102 --add-reviewer @copilot
```

Drafts are fine. Copilot usually answers within about five minutes, so read CI while you wait instead of polling.

## 3. Gather everything from both PRs

For each PR run `pr-gate.sh` for the overview, then `review-threads.sh`, `copilot-review.sh` and `ci-status.sh`.

- **CI failures.** For a failing check with a `jobId`, run `job-log.sh` and find the first real error, not the last line. A check without one (Socket Security, any other app) has no log here: open its `url`, or read that app's PR comment.
- **Copilot's low-confidence comments** live only in its review body, so they have no thread. Assess them like the rest. If `lowConfidenceUnparsed` is true, GitHub changed the format: read `review.body` yourself.
- **A stale Copilot review** (`stale: true`) covers an older commit. That is a warning, not a blocker.
- **Human reviews.** A human's `CHANGES_REQUESTED` blocks the PR until they change it. Their threads are in `review-threads.sh` with `authorType: "User"`.

The two PRs carry the same commits, so the same finding often shows up on both. Assess each finding once and answer it on every PR where it appears.

## 4. Assess every finding

Read the code each finding points at before deciding, and check the claim rather than trusting it. Each one gets exactly one verdict:

- **Fix.** It's real and belongs in this ticket.
- **Not applicable.** It's wrong, already handled, or a matter of taste. Reply with the reason, specific enough that the reviewer could check it.
- **Out of scope.** It's real but not this ticket's job. Reply saying so, and offer the user a follow-up ticket. Don't create one without their OK.

Human findings get the same verdicts and the same fixes as Copilot's. Never resolve or dismiss a human's review or thread, though: resolving is the reviewer's call once they've checked your answer. Before telling a human their finding is not applicable or out of scope, show the user your reply and post it once they agree.

## 5. Fix on the feature branch

1. Make the fixes on the feature branch, never on a `conflicts/...` branch, and run the repo's own checks.
2. Commit with Conventional Commits, the ticket number as scope and the type that matches the change: `fix(ATC-1530): skip placeholder avatars`, `test(ATC-1530): cover the empty-list case`, `refactor(...)`, `docs(...)`. Follow `commit-message-conventions`. Commit according to the user's standing rules for this repo, and ask if there are none.
3. If `preprod` came from a `conflicts/...` branch, merge the feature branch into it so the pre-prod PR gets the same fixes.
4. Ask before pushing.

## 6. Reply

Once the fixes are pushed, answer every thread you assessed with `reply-thread.sh`:

- Fixed: say what changed and give the commit SHA. Add `--resolve` for a bot's thread.
- Not applicable or out of scope: give the reason. Add `--resolve` for a bot's thread.
- A human's thread: never pass `--resolve`. Post a "fixed" reply straight away; post a not-applicable or out-of-scope reply only once the user has agreed to it.

Write replies by the `github-native-writing` and `humanize` skills: bare URLs and SHAs, short, no filler.

## 7. Re-review, at most once

After a round that produced real fixes, request Copilot again on both PRs (step 2's command), once per run of this skill. When the new review arrives, do one more pass. Stop as soon as a round brings only false alarms or nitpicks: answer those and finish, without requesting again.

## 8. Report

Run `pr-gate.sh` on each PR and tell the user, per PR: clean or not, every `blocking` reason, and any `warnings` worth knowing. Name anything waiting on a human: requested changes, threads only they can resolve, follow-up tickets you offered.

## 9. Park the branch

When `pr-gate.sh` says every PR is clean, the ticket's feedback is done, so run the `park-branch` skill (`git-workflow` plugin). It removes the branch's worktree, switches back to the default branch, updates it, and deletes the local feature and `conflicts/...` branches. Those branches stay on the remote, and the PRs don't need to be merged first. If a reviewer comments later, `git switch <branch>` brings the branch back.

Run it without asking only when all of these hold:

- **Every PR is clean.** If any PR still has a `blocking` reason, the branch has more work coming. Don't park and don't offer.
- **No PR is a draft.** `pr-gate.sh` reports a draft only as a warning, but a draft usually means the author is still working on it.
- **The working tree has no changes**: `git status --porcelain` prints nothing, in the checkout you're in and in the branch's worktree if it has one. Staged changes may be a review checkpoint the user keeps on purpose, and `park-branch`'s stash would bring them back unstaged.

If every PR is clean but a draft or local changes stop you, don't park. Offer it instead, name what stopped you, and wait for the user's yes.

Park at most once per ticket. Under `/loop`, do it on the first pass that comes back clean and end the loop there, since there is nothing left to check. Report what `park-branch` removed along with step 8's report. If `park-branch` isn't available (the `git-workflow` plugin isn't installed), skip this step.

## What this covers

Built from a survey of recent PRs in the org this was written for:

- **Review feedback:** Copilot's review threads and low-confidence comments, and every human's threads and reviews.
- **CI:** GitHub Actions check runs (lint, tests, typecheck, coverage, the Gitleaks, Semgrep and Trivy security jobs) with their logs; Socket Security's check runs, without logs; plain commit statuses.

Out of scope, because none showed up: Sentry, CodeRabbit, SonarCloud, Codecov and other review bots. The `github-actions[bot]` summary comments (coverage report, security scan summary) repeat what their checks already say, so read the checks instead.
