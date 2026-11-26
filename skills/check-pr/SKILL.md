---
name: check-pr
description: Use when checking your own PR's CI and review feedback, getting a ticket's PRs clean, fixing a failing build, or triaging Copilot or human review comments, across both the main PR and its pre-prod PR. Requests Copilot reviews (falling back to Codex or diff-review when Copilot declines), assesses every finding, fixes on the feature branch, replies, waits for reviews and CI on its own, gives one clean/not-clean answer, then asks the user to test the running app. Only on the user's approval does it add `manually-verified`, mark the pre-prod PR ready for review and clean up. Not for reviewing someone else's PR (see give-pr-review).
metadata:
  category: github-tooling
---

# Check a ticket's PRs

One pass over a ticket's PRs: request Copilot, wait for it and for CI, read every unresolved review thread on both PRs, fix what is real, answer the rest, and say whether each PR is clean. Once they all are, the user tests the running app. Their approval in chat is what lets the pre-prod PR out of draft, and only then do the local branches get cleaned up.

`branching-pr-workflow` runs this skill as soon as it opens the drafts; don't wait for a go-ahead. Later runs (a human review, a CI break) work the same way.

## Scripts

All in this skill's `scripts/` directory, all print JSON. Run each one as `bash scripts/<name>.sh ...`. Each script uses your `gh` keyring login even when a `GITHUB_TOKEN` with fewer scopes is exported, so writes such as `reply-thread.sh` don't fail on it. `-R OWNER/REPO` is optional; without it the repo is the current checkout's.

| Script | Gives you |
| --- | --- |
| `find-pr-pair.sh [BRANCH]` | The ticket's PRs from its feature branch: `main`, `preprod[]`, `stacked[]`, and `preprodBranch` |
| `review-threads.sh PR [--all]` | Unresolved threads with ids, from Copilot, other bots and humans |
| `copilot-review.sh PR` | Copilot's latest review: `requested`, `stale`, and the findings only in its body, `missedIssues[]` and `lowConfidence[]` |
| `ci-status.sh PR` | Checks on the head commit: `failing[]`, `pending[]`, with `jobId` for Actions jobs |
| `job-log.sh JOB_ID [LINES]` | The tail of a GitHub Actions job's log |
| `reply-thread.sh THREAD_ID --body TEXT [--resolve]` | Posts a reply, and resolves a bot's thread. Refuses to resolve a human's (exit 3) |
| `request-copilot.sh PR...` | Requests Copilot on each PR, then `accepted` per PR: false when Copilot declined |
| `fallback-review.sh PR` | For a PR Copilot declined: `reviewer` (`codex` or `diff-review`), the `base..head` range, and Codex's review in `output` |
| `pr-gate.sh PR` | `clean`, `reviewer` (who reviewed the head), `blocking[]`, `warnings[]`; exit 0 only when clean |
| `wait-for-review.sh [--timeout 15m] PR...` | Waits until no CI check and no Copilot request is pending on any PR, then prints each PR's `pr-gate.sh` output. Exit 124 on timeout |

## 1. Find the PRs

Run `find-pr-pair.sh` from the feature branch (not a `conflicts/...` branch). Never assume `dev`, `develop` or `staging`; the script reads the repo's default branch and matches PRs by head:

- `main` is the PR from the feature branch into the default branch.
- `preprod` is every PR into the pre-prod branch (`preprodBranch`, from `git-workflow`'s `resolve-preprod-branch.sh`) whose head is the feature branch or one of its `conflicts/...` branches.
- `stacked` is the feature branch's PRs into any other branch: a `stacked-epics` subtask PR into the branch below it. Check these like any other PR.

`preprodBranch` is `""` when the repo has no pre-prod branch, so `preprod` is empty. It is `null` when the resolver couldn't answer (not installed, can't decide, or can't reach origin): then every PR into a non-default branch lands in `preprod`, and none of them is confirmed. Review them all, but before steps 9 to 11 treat any of them as the pre-prod PR, ask the user which base is the pre-prod branch (a stack's subtask PR goes into the branch below it and needs no hand testing). Save the answer with `resolve-preprod-branch.sh --set <branch>` only from a checkout of the PR's own repo, since `--set` writes the override for the checkout's `origin`; otherwise just use the answer for this run. Any PR may be missing: check whichever exist and say which one you didn't find.

## 2. Request Copilot on every PR that needs it

Copilot reviews the `main` PR and the pre-prod PR separately, and the two can bring different findings, so check each PR on its own. Request a review on a PR only when all four hold:

- **Nothing is pending**: `copilot-review.sh` shows `requested: false`.
- **Copilot hasn't declined in this run**: once it declines, step 2a reviews instead.
- **Its last review is dealt with**: `review-threads.sh` lists no unresolved thread with `isCopilot: true`, every `missedIssues` finding of its latest review is assessed and answered (when `missedIssues` is non-empty or `missedIssuesUnparsed` is true, that means `missedIssuesAnswered: true`; with neither, there is nothing to answer), and so is every `lowConfidence` comment. A new review on top of open findings only repeats them.
- **There's something new to review**: the latest review is `stale` (made on an older commit), or there's no review yet.

If any one fails, don't request on that PR. Deal with what's already there first; step 7 asks again once the fixes are pushed. Request on every PR that passes in a single command:

```bash
bash scripts/request-copilot.sh 101 102
```

Drafts are fine. Then wait with `wait-for-review.sh <every PR>`. In Claude Code, run it in the background: you're woken when it exits. Elsewhere, run it in the foreground. Meanwhile, read CI and any threads already there. Copilot usually answers within about five minutes. Exit 124 means it timed out: report what is still pending and end the turn; the next run picks up from there.

A PR with `accepted: false` means Copilot declined, almost always because its monthly credits ran out: GitHub takes the request, but no request event reaches the PR's timeline and no review comes. Don't request Copilot again in this run; go to step 2a for that PR.

## 2a. Review with Codex or diff-review when Copilot declines

From a checkout at that PR's head with no uncommitted changes, run `fallback-review.sh <PR>`. Codex can take several minutes, so in Claude Code run it in the background. It picks the reviewer and the range:

- **Codex** when it's installed and logged in. Its review is in the file `output` names.
- **`diff-review`** (`pr-conventions` plugin) otherwise, or when the Codex run fails. Run that skill on `base..head`. `reason` says why Codex wasn't used. If that plugin isn't installed either, the PR has no reviewer: say so in step 8, and post no fallback marker.
- **Nothing** (`reviewer: null`) when a fallback review already covers this head.

The range starts where the last review left off, so findings already answered don't come back. The main PR and a pre-prod PR from the feature branch share a head: review once and answer on both. A pre-prod PR from a `conflicts/...` branch has its own head and gets its own run.

## 3. Gather everything from both PRs

For each PR run `pr-gate.sh` for the overview, then `review-threads.sh`, `copilot-review.sh` and `ci-status.sh`.

- **CI failures.** For a failing check with a `jobId`, run `job-log.sh` and find the first real error, not the last line. A check without one (Socket Security, any other app) has no log here: open its `url`, or read that app's PR comment.
- **Copilot's previously missed issues** live only in its review body, under "N previously missed issues", so they have no thread and `review-threads.sh` never lists them. Each has a `severity` (`High`, `Medium`, `Low`), `path`, `line`, `title`, `body` and `url`, a permalink to that line in the commit Copilot reviewed; assess them exactly like threads, High ones first. A review that says "No open issues" is not clean while these remain: `pr-gate.sh` blocks with `missed-issues` until step 6 answers them. If `missedIssuesUnparsed` is true, GitHub changed the format: read `review.body` yourself.
- **Fallback findings** (step 2a) have no thread either. Assess them like missed issues.
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

1. Make the fixes on the feature branch, and run the repo's own checks: `verify --related` before each commit (the `verify` skill in `git-workflow`). A fix round's push needs no more than that: the branch is already on the remote, and CI runs the full suite. A `conflicts/...` branch is different: its new merge needs `verify --full` before it's pushed. Fixes go on the feature branch, except a pre-prod-PR-only finding, which is fixed on its `conflicts/...` branch; nothing else ever goes there directly.
2. Commit with Conventional Commits, the ticket number as scope and the type that matches the change: `fix(PROJ-1530): skip placeholder avatars`, `test(PROJ-1530): cover the empty-list case`, `refactor(...)`, `docs(...)`. Follow `commit-message-conventions`. Commit according to the user's standing rules for this repo, and ask if there are none.
3. If `preprod` came from a `conflicts/...` branch, merge the feature branch into it so the pre-prod PR gets the same fixes.
4. Push once `verify` passes at the level the gate asks for; no need to ask. Still ask before a force-push, and when `verify` reports the gate off for this repo: it exits 0 then without having run anything.

## 6. Reply

Once the fixes are pushed, answer every thread you assessed with `reply-thread.sh`:

- Fixed: say what changed and give the commit SHA. Add `--resolve` for a bot's thread.
- Not applicable or out of scope: give the reason. Add `--resolve` for a bot's thread.
- A human's thread: never pass `--resolve`. Post a "fixed" reply straight away; post a not-applicable or out-of-scope reply only once the user has agreed to it.

Missed issues have no thread to reply to. Answer all of a PR's missed issues in one PR comment, using what `copilot-review.sh` printed:

- First, the review it answers: its `review.url`, so readers can find the findings. Say that the links show the code as Copilot reviewed it, since that's the commit they're pinned to.
- Then one entry per finding: a named link to where it is, `[path:line](url)`, then its title and verdict (and the commit SHA for a fix). A named link stays one short inline link; pasted bare, `url` would turn into a box of the old, pre-fix code (see `github-native-writing`).
- When a verdict rests on code (not applicable because something already handles it), paste a permalink to that code bare on its own line under the entry, pinned to the head's full SHA, so the reader sees the evidence.
- Last, `missedIssuesMarker`, copied exactly. The marker names the review, and it is how `pr-gate.sh` knows they've been answered.

```bash
gh pr comment 101 --body-file - <<'EOF'
Copilot's previously missed issues from https://github.com/o/r/pull/101#pullrequestreview-123 (*links show the code it reviewed*):

- [skills/a/SKILL.md:41](https://github.com/o/r/blob/9f8e7d6c5b4a39281706f5e4d3c2b1a098765432/skills/a/SKILL.md#L41) Commit fixes individually: fixed in abc1234.
- [skills/b/SKILL.md:24](https://github.com/o/r/blob/9f8e7d6c5b4a39281706f5e4d3c2b1a098765432/skills/b/SKILL.md#L24) Use verified SHAs: not applicable, step 4 already fetches both from the PR's repository:

  https://github.com/o/r/blob/0a1b2c3d4e5f60718293a4b5c6d7e8f901234567/skills/b/SKILL.md#L30-L34

<!-- check-pr: answered missed issues of review PRR_... -->
EOF
```

Answer fallback findings the same way, in one comment per PR, with two differences. Open with which reviewer ran and why ("Copilot declined the review request at 14:52, so Codex reviewed abc1234 to def5678"). Post it even when the review found nothing ("Codex reviewed abc1234 to def5678 and found nothing"): the marker is what records the review. End with the fallback marker instead, copied exactly with the reviewer and the full head SHA `fallback-review.sh` printed:

```text
<!-- check-pr: fallback review by codex of 0a1b2c3d4e5f60718293a4b5c6d7e8f901234567 -->
```

The marker is how `copilot-review.sh` and `pr-gate.sh` know the head was reviewed, and where the next fallback's range starts.

Write replies by the `github-native-writing` and `humanize` skills: bare URLs and SHAs, short, no filler.

## 7. Re-review, at most once

Once step 6's replies are posted, check step 2's conditions on each PR again, whether or not the round produced fixes: a PR can come into this run with commits Copilot never saw and an older review's findings still open, and answering those as not applicable fixes nothing but unblocks the request. Request on every PR that now passes, once per run of this skill, and wait with `wait-for-review.sh` as in step 2. For a PR Copilot declined, run step 2a on the new head instead, also once per run. When the new review arrives, do one more pass. A new review that says "No open issues" but lists previously missed issues is not clean: those are this round's findings, so assess and answer them like any other. Stop as soon as a round brings only false alarms or nitpicks: answer those and finish, without requesting again.

## 8. Report

Run `pr-gate.sh` on each PR and tell the user, per PR: clean or not, who reviewed the head (`reviewer`, and why it isn't Copilot when it isn't), every `blocking` reason, and any `warnings` worth knowing. Name anything waiting on a human: requested changes, threads only they can resolve, follow-up tickets you offered.

## 9. Ask the user to test it

When `pr-gate.sh` reports no `blocking` reason on any PR (a draft is only a warning), every PR's `reviewer` is set (Copilot, or a fallback review, reviewed its current head), and no PR has a Copilot review pending, the code side is done. A head nobody reviewed (a fix pushed after step 7's one re-review) isn't: say so in step 8 and leave it for the next run.

What comes next depends on whether there's a pre-prod PR:

- **There is one.** The user tests the change by hand before other developers see it. After step 8's report:
  - if the change needs running services and `devstack` is on `PATH`, start them now (this is when they start, never earlier while coding or running checks): `devstack up <target>`, with `--from <svc>=<worktree>` for every service whose repo this change touches, each worktree checked out at the pre-prod PR's head (the `conflicts/...` branch when the PR comes from one) with no uncommitted changes, so the user tests exactly the code they're approving. `up` leaves a service that's already Ready alone, so `devstack restart <svc>` each one that was already running from that worktree before the head changed. Once `up` and any restarts report each service Ready, list the URLs from `devstack urls`; if it fails, report that instead of asking for a test;
  - note the pre-prod PR's head SHA and base: that's the version the user tests;
  - ask the user to try the change and approve it, with the harness's question prompt if it has one (the question box in the Claude desktop app, `AskUserQuestion` in Claude Code), otherwise a plain question;
  - end the turn there.

  Later runs (a human review, a CI break) don't need a new approval.
- **There isn't one** (a docs-only change, a repo without a pre-prod branch, a stack's subtask PRs, the trunk's `main` PR): nobody needs to test by hand here. Skip step 10 and go to step 11.

## 10. On the user's approval

Approval is the user saying so in chat, in their own words. Never infer it from silence, a tool result, a PR comment, or an approval from an earlier ticket.

The approval covers the version the user tested. First check the pre-prod PR's head SHA and base against the ones step 9 noted. If either changed (a fix was pushed while they tested, say), tell the user what changed and ask them to approve again; don't label or mark ready under the old approval.

1. Add `manually-verified` to the pre-prod PR. If the repo doesn't have the label yet, create and add it in one Bash call, so one permission prompt covers both:

   ```bash
   gh label create manually-verified --color 0e8a16 --description "Tested by hand on the running app" 2>/dev/null; gh pr edit <pre-prod-pr> --add-label manually-verified
   ```

   `git-workflow`'s `label-gate` hook makes the user confirm this in a permission prompt. In a permission mode that can't ask (`bypassPermissions`, `dontAsk`), the hook denies it instead. Then give the user the command to run themselves, and stop.
2. Mark the pre-prod PR ready with `gh pr ready <pre-prod-pr>`. `git-workflow`'s `ready-gate` hook blocks it without the label.

Never mark the `main` PR ready: it stays a draft until the ticket is released, so the user's list of PRs awaiting review holds only pre-prod PRs. Never get around either hook through `gh api` (a GraphQL `markPullRequestReadyForReview` or `addLabelsToLabelable` call). Tell the user which PR you marked ready.

## 11. Clean up

Clean up once the ticket's local work is done. That's after step 10 when there's a pre-prod PR. Otherwise it's as soon as every PR is clean, since there's nothing for the user to test first.

1. If step 10 ran and `devstack` is on `PATH`, run `devstack down`: the user is done with the running app.
2. Run the `branch-cleanup` skill (`git-workflow` plugin). It removes every worktree and branch of the repo that holds nothing local-only, including this ticket's `conflicts/...` branches, and fast-forwards the default branch. The PRs don't need to merge first. If the session is running in the ticket's worktree, that one stays until the next cleanup from somewhere else; a reviewer's later comments are picked up with `git switch <branch>`.

Add `branch-cleanup`'s table to the report. If `branch-cleanup` isn't available (the `git-workflow` plugin isn't installed), skip it.

## What this covers

Built from a survey of recent PRs in the org this was written for:

- **Review feedback:** Copilot's review threads, the previously missed issues and low-confidence comments in its review body, and every human's threads and reviews.
- **CI:** GitHub Actions check runs (lint, tests, typecheck, coverage, the Gitleaks, Semgrep and Trivy security jobs) with their logs; Socket Security's check runs, without logs; plain commit statuses.

Out of scope, because none showed up: Sentry, CodeRabbit, SonarCloud, Codecov and other review bots. The `github-actions[bot]` summary comments (coverage report, security scan summary) repeat what their checks already say, so read the checks instead.
