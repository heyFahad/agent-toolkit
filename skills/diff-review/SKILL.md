---
name: diff-review
description: Find the bugs in a diff with a fresh-context reviewer subagent, using one prompt, one bar and one finding format whether the change is your own or someone else's. Use before a branch's PRs are opened (branching-pr-workflow's self-review), when reviewing someone else's PR (give-pr-review then anchors and posts the findings), and whenever a change needs an independent bug hunt. It finds and checks findings only; it never fixes, posts or replies.
metadata:
  category: pr-conventions
---

# Review a diff

Finding a bug is the same job whoever wrote the code, so there is one reviewer for both audiences. This skill finds the issues and checks them. What happens next belongs to the caller:

- **Your own branch:** `branching-pr-workflow` folds each fix into the commit that caused it.
- **Someone else's PR:** `give-pr-review` anchors each finding to a diff line, writes it for a human and previews it before posting.

## 1. Gather the inputs

The reviewer starts with no context, so it gets everything it needs up front:

- **The range.** A base and a head SHA, always from a fresh fetch.
  - Your own branch: `git fetch origin`, then `BASE=$(git merge-base origin/<default-branch> HEAD)` and `HEAD=$(git rev-parse HEAD)`. Commit first: the reviewer reads commits, not the working tree.
  - A subtask in a `stacked-epics` stack: the base is the merge base with the local branch below it.
  - Someone else's PR: the head is the PR's `headRefOid`. Fetch it with `git fetch origin pull/<N>/head` so the reviewer can read it locally. The base is its merge base with the freshly fetched base branch (`give-pr-review` step 4).
- **The intent.** What the change is meant to do: the whole ticket, comments included (`jira-ticket-lifecycle`), the user's request, and any design doc the change ships or links. A PR description is the author's account of the change; pass it as a claim to check, not as fact.
- **The rules.** Paths to every instruction file that applies to the changed files: the root and nested `AGENTS.md`, `CLAUDE.md` and their overrides, plus any checklist those files point to. The reviewer prompt stays language- and framework-neutral, so a repo's own pitfalls (its ORM's query traps, its framework's rules) belong in those files, where every review picks them up.

## 2. Dispatch the reviewer

Fill in [reviewer-prompt.md](reviewer-prompt.md) and give it to a fresh subagent on the most capable model available. Never run it in the context that wrote the code: that context reads what it meant to write, not what it wrote.

- **Claude Code:** the `Agent` tool with a `general-purpose` subagent.
- **Codex or another harness:** its own subagent or a new session, given the same filled-in prompt.
- **No way to start a fresh context:** tell the user, and don't review in place instead.

One reviewer handles a normal change. Split only when the diff is too big for one careful pass, roughly beyond 1,500 changed lines once lockfiles and generated files are left out. Then split by area into at most three reviewers. Each gets the full file list so it can follow references across areas, and a `{FOCUS}` naming its own area.

For a risky change (auth, payments, data migrations), Claude Code's built-in `/code-review high` can add a second opinion on top of this. It doesn't replace it.

## 3. Check every finding

A finding is a lead, not a verdict. Before acting on one, read the code at the cited line and confirm the failure scenario holds. Run a test or a command when that's cheaper than reasoning about it. Each finding gets one verdict:

- **Confirmed.** The scenario is real and this change introduced it.
- **Not applicable.** It's wrong, already handled, or intended. Cite the line or the command output that shows it. "Looks fine" isn't evidence, and this matters most on your own code, where the pull is to wave findings away.
- **Out of scope.** It's real but pre-existing, or another ticket's job.
- **Unverified.** You can't confirm or rule it out from here: it needs a running service, production data or knowledge you don't have. Say what would settle it. An unverified finding is never `High`.

Then read the reviewer's "declined to judge" list. Anything on it that is in fact a bug becomes a finding, with a verdict.

Hand the caller the confirmed findings and, marked as such, the unverified ones, in the format below and ordered by severity. Mention the out-of-scope ones separately, so the user can decide whether they need a follow-up ticket.

## Finding format

| Field | Content |
| --- | --- |
| `file`, `line` | Repo path and line number in the head commit. For a removed line, the line in the base, with `side: LEFT`. |
| `lineText` | The text of that line, so the caller can confirm the anchor. |
| `severity` | `High`: must not reach the pre-prod branch or production (security flaw, data loss or corruption, breaking change, crash on a normal path). `Medium`: fix it, but not a blocker (an edge-case bug, missing error handling, a missing test for risky logic). `Low`: cosmetic or minor. |
| `title` | Imperative, at most 80 characters. |
| `scenario` | The inputs, state or environment that trigger it, and what happens. |
| `fix` | The smallest change that fixes it. |
| `rule` | Only when a repo rule backs the finding: the instruction file and line range. |

The same scale feeds `give-pr-review`'s severity labels, so High, Medium and Low mean the same thing on your PRs and on everyone else's.
