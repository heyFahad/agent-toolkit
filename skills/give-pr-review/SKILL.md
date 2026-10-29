---
name: give-pr-review
description: Use at any point in a conversation when a pull request authored by someone else is to be reviewed, approved, commented on, or have changes requested, including a bare PR number or URL to review, before dispatching subagents to review PRs, and when existing findings are to be posted on PRs. Applies alongside generic code-review skills, which find issues; this one governs how they are anchored and posted. Not for reviewing your own diff or triaging bot comments on your own PR.
metadata:
  category: pr-conventions
---

# Giving a review on someone else's PR

Findings are inline comments on the exact line, in a pending review the user sees before anything is submitted. "Post the findings" authorises inline comments. It does not authorise a findings list in the review body, a skipped preview, or `gh pr review`.

## Before you review: get the context

A diff does not say what the change is for, what was already decided, or what the author left out. Collect that before reading the code.

1. **Read the ticket, all of it.** Find the key in the PR title, branch name or description, then read the whole ticket including its comments, not just the description. With `twg` installed: `twg jira workitem get KEY --full` (see `prefer-twg-cli`). Look for decisions, sign-offs, scope changes and links to design docs.
2. **Treat the PR description as the author's account, not as fact.** It goes stale: sign-offs and decisions land on the ticket after the description was written. When the two disagree, the newer one wins. If you cannot tell which is current, say so instead of picking one.
3. **Read the docs the PR ships or links.** A design doc or ADR tells you what the code is supposed to do, which is what you are checking it against.
4. **Diff against the right base.** `git fetch origin <base>` and use `git merge-base origin/<base> <head>`, or `gh pr diff`. A stale local base branch makes the PR look like it adds things it does not.
5. **Check claims that matter.** If the PR says "same behaviour as before" or "all tests pass", and your verdict leans on it, verify it.

## Review all of it

Review the whole change, not a sample. A change that is meant to preserve behaviour (auth, routing, a refactor) is checked by running before and after, not by reading both versions and hoping. If you cannot finish, say what is left and why. A partial review must not quietly soften the verdict: `COMMENT` is for a question that really is open, not for effort you skipped.

## Rules

1. **Inline only.** Every finding is a comment on a file and line in the PR head commit. The review body never lists findings.
2. **Anchor before writing.** Per PR: `gh pr view N --repo O/R --json headRefOid,author,state`, then `gh api repos/O/R/pulls/N/files --paginate` for the patch hunks. For each finding read the actual line at that SHA and confirm it is inside a hunk. Added or unchanged lines in a hunk: `side: RIGHT`. Removed lines: `side: LEFT`. Line numbers are repo line numbers in the head commit, never positions in a saved diff file.
   - A line outside the diff gets a 422. Do not nudge it to a nearby line silently. Anchor to the closest changed line and say what it refers to, or tell the user.
   - A finding without a verified repo line is not postable. Say so in the preview.
3. **Severity label** at the start of the comment: an emoji, the bold level, then a colon.
   - `🔴 **High:**` must not reach staging or production. Security flaw, breaking change, data loss or corruption, any blocker.
   - `🟠 **Medium:**` fix it, but not a blocker. Edge-case bug, missing error handling, missing test for risky logic, maintainability that will cost later.
   - `🟡 **Low:**` cosmetic. Naming, unused imports, comments, style.
   - A plain question has no label. A concern you could not verify says so in the comment and is not `High`.
4. **One issue per comment**: what is wrong, the concrete failing scenario, what to do. Use a ```` ```suggestion ```` block when the fix is mechanical and local.
5. **Body is a summary**: the verdict and the reason in plain words, two or three lines. No list, no repeat of the inline comments. If the PR is a draft or its description lists unfinished items, say whether your approval covers only the code. No test reports (see "Writing the comments").
6. **Verdict**
   - `REQUEST_CHANGES` if any comment is `High`.
   - `APPROVE` if nothing is `High`. Inline `Medium` and `Low` comments alongside an approval are fine and encouraged.
   - `COMMENT` only when you cannot conclude: a review you could not finish (and have said why), an open question that must be answered first, or an unverified concern that might be `High`.
   - Your own PR (author equals `gh api user -q .login`): `COMMENT` at most.
7. **Several PRs**: one review, one verdict, one preview per PR. Never batch-submit. A cross-PR concern is an inline comment on the PR where the fix belongs, naming the other PR by bare URL.
8. **No AI or co-author footer.** Writing rules are in the next section.

`gh pr review` cannot attach inline comments. Never use it for a review that has findings. It is only for a short verdict on a PR with none.

## Writing the comments

One test decides everything here: **could someone who reads only this comment understand the problem and the fix?** You have the ticket, the ADRs and the design doc in your head. The author may too, but a second reviewer, or the author in three weeks, may not.

- **Plain words.** Write like a teammate in a thread: short sentences, "could we...?" for a suggestion, no stacked clauses. Say what happens first, then what to do, and give the concrete failing case.
- **No unexplained shorthand.** The first time you use a term, say what it means in a few words ("shadow mode, the log-only trial run before enforcement") or link it. An ADR number, a phase name or a ticket key alone tells the reader nothing.
- **Link the lines that explain it.** When a doc, ADR or ticket backs the point, link the exact lines: a permalink with a line range, bare, on its own line (`https://github.com/O/R/blob/<sha>/docs/x.md#L20-L24`). GitHub expands it into an inline snippet, so the reader does not leave the thread. A heading anchor alone drops them into a long document with nothing marked. A non-GitHub link (Jira, Confluence) is a named Markdown link such as `[TN-594](url)`. Details in `github-native-writing`.
- **Formatting does a job.** The severity label opens the comment. Backticks for identifiers, paths, config keys and values. Bold on the one phrase the reader must not miss, at most one per comment. Italics for a quiet aside or background. No headings, no emoji beyond the severity marker, no bullet list unless there are three or more parallel items. Short paragraphs with a blank line between.
- **Run `humanize` on every comment and the summary** before creating the review.
- **Do not claim work in the user's name.** The review posts as the user. Do not write "I tested", "I ran" or "I compared" for checks the user did not do, and keep what you ran in the chat. The review carries the finding and the reviewer's conclusion.

## Flow

1. Get the context, anchor (rule 2) and write the comments. When delegating to subagents, the prompt must require, per finding: file, repo line number at the head SHA, side, severity, and the line's text. Give them the head SHA and the commands above. Re-anchor anything that comes back without them.
2. Create the review **pending**: no `event` field. Run it with `GH_TOKEN=$(gh auth token)` if it goes through a script.

   ```bash
   gh api repos/O/R/pulls/N/reviews --input - <<'EOF'
   {"commit_id": "<headRefOid>", "comments": [
     {"path": "src/a.js", "line": 42, "side": "RIGHT", "body": "..."}
   ]}
   EOF
   ```

   Put the JSON inline in the command like this. If it comes from a file or from a script that generates it, the guard cannot see it and measures the whole command text instead, which can deny a long comment.

   The response `id` is the review id. Pending reviews are visible only to you. To change a comment, delete the pending review (`gh api -X DELETE repos/O/R/pulls/N/reviews/<id>`) and create it again.
3. `bash scripts/mark-preview.sh O/R N <review id>` (this skill's `scripts/` directory). It prints the comments as GitHub stored them and records the preview marker.
4. **Show the preview in chat, then stop and wait**: per PR, the verdict, the summary body, and every comment with file, line and severity. Say plainly if any finding is not fully anchored or verified. Do not run step 5 in the same turn.
5. After the user says go, submit:

   ```bash
   gh api repos/O/R/pulls/N/reviews/<id>/events -f event=REQUEST_CHANGES -f body="<summary>"
   ```

   If the user asks for changes first, edit the pending review, re-run step 3, and preview again.

The `review-guard` hook (same plugin) denies the shortcuts it can detect: a long or itemised body, an `event` on creation, comments with no `line`/`side` or no `commit_id`, and a submit with no matching preview marker. It cannot read the chat, so the marker proves the preview step ran on this exact content, not that the user read it. Step 4 is still on you.

## Example

PR 12 adds a token check and renames a helper. Two findings.

Pending review payload:

```json
{"commit_id": "9f3c2ab", "comments": [
  {"path": "src/auth.js", "line": 58, "side": "RIGHT",
   "body": "🔴 **High:** `verify()` returns early when `token` is empty, so a request with no Authorization header counts as signed in. Could we throw `UnauthorizedError` there instead?\n\n```suggestion\n  if (!token) throw new UnauthorizedError();\n```"},
  {"path": "src/util.js", "line": 7, "side": "RIGHT",
   "body": "🟡 **Low:** `path` is imported but no longer used after the rename.\n\n```suggestion\n```"}
]}
```

Preview in chat:

> **PR 12: REQUEST_CHANGES.** Summary: auth bypass on empty token (blocker); one rename nit.
> - src/auth.js:58 RIGHT, High: empty token passes verify()
> - src/util.js:7 RIGHT, Low: unused import after the rename
>
> Submit?

Submit body: `One blocker (empty token bypass), see inline. Rest is minor.`
