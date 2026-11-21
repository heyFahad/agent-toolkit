---
name: check-pr
description: Use when checking your own PR's CI and review feedback, getting a ticket's PRs clean, fixing a failing build, or triaging Copilot or human review comments, across both the main PR and its pre-prod PR. Requests Copilot reviews, assesses every finding, fixes on the feature branch, replies, gives one clean/not-clean answer, then marks the pre-prod PR ready for review and cleans up local branches once every PR is clean. Not for reviewing someone else's PR (see give-pr-review).
metadata:
  category: github-tooling
---

# Check a ticket's PRs

One pass over a ticket's PRs: request Copilot, read CI and every unresolved review thread on both PRs, fix what is real, answer the rest, and say whether each PR is clean. Once they all are, mark the pre-prod PR ready for review and clean up. For repeated passes, wrap this skill in `/loop`.

The first run on a ticket's new PRs waits for the user: `branching-pr-workflow` opens them as drafts and stops, and this skill starts once the user has looked at them and said go. Later runs (a human review, a CI break) need no new go-ahead.

## Scripts

All in this skill's `scripts/` directory, all print JSON. Run each one as `bash scripts/<name>.sh ...`. Each script uses your `gh` keyring login even when a `GITHUB_TOKEN` with fewer scopes is exported, so writes such as `reply-thread.sh` don't fail on it. `-R OWNER/REPO` is optional; without it the repo is the current checkout's.

| Script | Gives you |
| --- | --- |
| `find-pr-pair.sh [BRANCH]` | The ticket's PRs from its feature branch: `main` and `preprod[]` |
| `review-threads.sh PR [--all]` | Unresolved threads with ids, from Copilot, other bots and humans |
| `copilot-review.sh PR` | Copilot's latest review: `requested`, `stale`, and the findings only in its body, `missedIssues[]` and `lowConfidence[]` |
| `ci-status.sh PR` | Checks on the head commit: `failing[]`, `pending[]`, with `jobId` for Actions jobs |
| `job-log.sh JOB_ID [LINES]` | The tail of a GitHub Actions job's log |
| `reply-thread.sh THREAD_ID --body TEXT [--resolve]` | Posts a reply, and resolves a bot's thread. Refuses to resolve a human's (exit 3) |
| `pr-gate.sh PR` | `clean`, `blocking[]`, `warnings[]`; exit 0 only when clean |

## 1. Find the PRs

Run `find-pr-pair.sh` from the feature branch (not a `conflicts/...` branch). Never assume `dev`, `develop` or `staging`; the script reads the repo's default branch and matches PRs by head:

- `main` is the PR from the feature branch into the default branch.
- `preprod` is every PR into any other branch whose head is the feature branch or one of its `conflicts/...` branches.

If `preprod` has more than one entry, don't guess. If git-workflow's `resolve-preprod-branch.sh` is installed, keep the entry whose base it names; otherwise ask the user. Either PR may be missing: check whichever exist and say which one you didn't find.

## 2. Request Copilot on every PR that needs it

Copilot reviews the `main` PR and the pre-prod PR separately, and the two can bring different findings, so check each PR on its own. Request a review on a PR only when all three hold:

- **Nothing is pending**: `copilot-review.sh` shows `requested: false`.
- **Its last review is dealt with**: `review-threads.sh` lists no unresolved thread with `isCopilot: true`, every `missedIssues` finding of its latest review is assessed and answered (when `missedIssues` is non-empty or `missedIssuesUnparsed` is true, that means `missedIssuesAnswered: true`; with neither, there is nothing to answer), and so is every `lowConfidence` comment. A new review on top of open findings only repeats them.
- **There's something new to review**: the latest review is `stale` (made on an older commit), or there's no review yet.

If any one fails, don't request on that PR. Deal with what's already there first; step 7 asks again once the fixes are pushed. Request on every PR that passes in a single command:

```bash
gh pr edit 101 --add-reviewer @copilot && gh pr edit 102 --add-reviewer @copilot
```

Drafts are fine. Copilot usually answers within about five minutes, so read CI while you wait instead of polling.

## 3. Gather everything from both PRs

For each PR run `pr-gate.sh` for the overview, then `review-threads.sh`, `copilot-review.sh` and `ci-status.sh`.

- **CI failures.** For a failing check with a `jobId`, run `job-log.sh` and find the first real error, not the last line. A check without one (Socket Security, any other app) has no log here: open its `url`, or read that app's PR comment.
- **Copilot's previously missed issues** live only in its review body, under "N previously missed issues", so they have no thread and `review-threads.sh` never lists them. Each has a `severity` (`High`, `Medium`, `Low`), `path`, `line`, `title` and `body`; assess them exactly like threads, High ones first. A review that says "No open issues" is not clean while these remain: `pr-gate.sh` blocks with `missed-issues` until step 6 answers them. If `missedIssuesUnparsed` is true, GitHub changed the format: read `review.body` yourself.
- **Copilot's low-confidence comments** (an older body format) also live only in its review body. Assess them like the rest. If `lowConfidenceUnparsed` is true, read `review.body` yourself.
- **A stale Copilot review** (`stale: true`) covers an older commit. That is a warning, not a blocker.
- **Human reviews.** A human's `CHANGES_REQUESTED` blocks the PR until they change it. Their threads are in `review-threads.sh` with `authorType: "User"`.

The two PRs carry the same commits, so the same finding often shows up on both. Assess each finding once and answer it on every PR where it appears.

## 4. Assess every finding

Read the code each finding points at before deciding, and check the claim rather than trusting it. Each one gets exactly one verdict:

- **Fix.** It's real and belongs in this ticket.
- **Not applicable.** It's wrong, already handled, or a matter of taste. Reply with the reason, specific enough that the reviewer could check it.
- **Out of scope.** It's real but not this ticket's job. Reply saying so, and offer the user a follow-up ticket. Don't create one without their OK.
- **Pre-prod PR only.** It's real, but only the pre-prod PR has it: a bad conflict resolution, or a line the `conflicts/...` branch got from the pre-prod branch. Fix it on the `conflicts/...` branch. This verdict exists only when the pre-prod PR comes from a `conflicts/...` branch; from the feature branch itself both PRs carry the same commits.

Human findings get the same verdicts and the same fixes as Copilot's. Never resolve or dismiss a human's review or thread, though: resolving is the reviewer's call once they've checked your answer. Before telling a human their finding is not applicable or out of scope, show the user your reply and post it once they agree.

## 5. Fix on the feature branch

1. Make the fixes on the feature branch, and run the repo's own checks. The one exception is a pre-prod-PR-only finding, which is fixed on its `conflicts/...` branch; nothing else ever goes there directly.
2. Commit with Conventional Commits, the ticket number as scope and the type that matches the change: `fix(PROJ-1530): skip placeholder avatars`, `test(PROJ-1530): cover the empty-list case`, `refactor(...)`, `docs(...)`. Follow `commit-message-conventions`. Commit according to the user's standing rules for this repo, and ask if there are none.
3. If `preprod` came from a `conflicts/...` branch, merge the feature branch into it so the pre-prod PR gets the same fixes.
4. Ask before pushing.

## 6. Reply

Once the fixes are pushed, answer every thread you assessed with `reply-thread.sh`:

- Fixed: say what changed and give the commit SHA. Add `--resolve` for a bot's thread.
- Not applicable or out of scope: give the reason. Add `--resolve` for a bot's thread.
- A human's thread: never pass `--resolve`. Post a "fixed" reply straight away; post a not-applicable or out-of-scope reply only once the user has agreed to it.

Missed issues have no thread to reply to. Answer all of a PR's missed issues in one PR comment: one line per finding with its `path:line`, title and verdict (and the commit SHA for a fix), and `missedIssuesMarker` from `copilot-review.sh` as the last line, copied exactly. The marker names the review, and it is how `pr-gate.sh` knows they've been answered:

```bash
gh pr comment 101 --body-file - <<'EOF'
Copilot's previously missed issues:
- `skills/a/SKILL.md:41` Commit fixes individually: fixed in abc1234.
- `skills/b/SKILL.md:24` Use verified SHAs: not applicable, step 4 already fetches both from the PR's repository.
<!-- check-pr: answered missed issues of review PRR_... -->
EOF
```

Write replies by the `github-native-writing` and `humanize` skills: bare URLs and SHAs, short, no filler.

## 7. Re-review, at most once

Once step 6's replies are posted, check step 2's three conditions on each PR again, whether or not the round produced fixes: a PR can come into this run with commits Copilot never saw and an older review's findings still open, and answering those as not applicable fixes nothing but unblocks the request. Request on every PR that now passes, once per run of this skill. When the new review arrives, do one more pass. A new review that says "No open issues" but lists previously missed issues is not clean: those are this round's findings, so assess and answer them like any other. Stop as soon as a round brings only false alarms or nitpicks: answer those and finish, without requesting again.

## 8. Report

Run `pr-gate.sh` on each PR and tell the user, per PR: clean or not, every `blocking` reason, and any `warnings` worth knowing. Name anything waiting on a human: requested changes, threads only they can resolve, follow-up tickets you offered.

## 9. Mark the pre-prod PR ready

When `pr-gate.sh` reports no `blocking` reason on any PR (a draft is only a warning), and no PR has a Copilot review pending or `stale` (step 7 requests one when it is), the ticket is ready for other developers. If the pre-prod PR is a draft, mark it ready:

```bash
gh pr ready <pre-prod-pr>
```

Never mark the `main` PR ready: it stays a draft until the ticket is released, so the user's list of PRs awaiting review holds only pre-prod PRs. The user's go-ahead for this run covers this step; don't ask again. If there's no pre-prod PR (a docs-only change, or a repo without one), leave the `main` PR as it is and say so. Tell the user which PR you marked ready.

## 10. Clean up

Once every PR is clean, the ticket's local work is done: run the `branch-cleanup` skill (`git-workflow` plugin). It removes every worktree and branch of the repo that holds nothing local-only, including this ticket's `conflicts/...` branches, and fast-forwards the default branch. The PRs don't need to merge first. If the session is running in the ticket's worktree, that one stays until the next cleanup from somewhere else; a reviewer's later comments are picked up with `git switch <branch>`.

Under `/loop`, clean up on the first pass that comes back clean and end the loop there. Add `branch-cleanup`'s table to step 8's report. If `branch-cleanup` isn't available (the `git-workflow` plugin isn't installed), skip this step.

## What this covers

Built from a survey of recent PRs in the org this was written for:

- **Review feedback:** Copilot's review threads, the previously missed issues and low-confidence comments in its review body, and every human's threads and reviews.
- **CI:** GitHub Actions check runs (lint, tests, typecheck, coverage, the Gitleaks, Semgrep and Trivy security jobs) with their logs; Socket Security's check runs, without logs; plain commit statuses.

Out of scope, because none showed up: Sentry, CodeRabbit, SonarCloud, Codecov and other review bots. The `github-actions[bot]` summary comments (coverage report, security scan summary) repeat what their checks already say, so read the checks instead.
