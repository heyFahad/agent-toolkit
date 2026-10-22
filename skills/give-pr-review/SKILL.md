---
name: give-pr-review
description: Use at any point in a conversation when a pull request authored by someone else is to be reviewed, approved, commented on, or have changes requested, including a bare PR number or URL to review, before dispatching subagents to review PRs, and when existing findings are to be posted on PRs. Applies alongside generic code-review skills, which find issues; this one governs how they are anchored and posted. Not for reviewing your own diff or triaging bot comments on your own PR.
metadata:
  category: pr-conventions
---

# Giving a review on someone else's PR

Findings are inline comments on the exact line, in a pending review the user sees before anything is submitted. "Post the findings" authorises inline comments. It does not authorise a findings list in the review body, a skipped preview, or `gh pr review`.

## Rules

1. **Inline only.** Every finding is a comment on a file and line in the PR head commit. The review body never lists findings.
2. **Anchor before writing.** Per PR: `gh pr view N --repo O/R --json headRefOid,author,state`, then `gh api repos/O/R/pulls/N/files --paginate` for the patch hunks. For each finding read the actual line at that SHA and confirm it is inside a hunk. Added or unchanged lines in a hunk: `side: RIGHT`. Removed lines: `side: LEFT`. Line numbers are repo line numbers in the head commit, never positions in a saved diff file.
   - A line outside the diff gets a 422. Do not nudge it to a nearby line silently. Anchor to the closest changed line and say what it refers to, or tell the user.
   - A finding without a verified repo line is not postable. Say so in the preview.
3. **Severity prefix**, bold, at the start of the comment:
   - `**High**`: must not reach staging or production. Security flaw, breaking change, data loss or corruption, any blocker.
   - `**Medium**`: fix it, but not a blocker. Edge-case bug, missing error handling, missing test for risky logic, maintainability that will cost later.
   - `**Low**`: cosmetic. Naming, unused imports, comments, style.
   - A plain question has no label. A concern you could not verify says so in the comment and is not `High`.
4. **One issue per comment**: what is wrong, the concrete failing scenario, what to do. Use a ```` ```suggestion ```` block when the fix is mechanical and local.
5. **Body is a summary**: the verdict plus two or three lines. No list, no repeat of the inline comments.
6. **Verdict**
   - `REQUEST_CHANGES` if any comment is `High`.
   - `APPROVE` if nothing is `High`. Inline `Medium` and `Low` comments alongside an approval are fine and encouraged.
   - `COMMENT` only when you cannot conclude: partial review, an open question that must be answered first, or an unverified concern that might be `High`.
   - Your own PR (author equals `gh api user -q .login`): `COMMENT` at most.
7. **Several PRs**: one review, one verdict, one preview per PR. Never batch-submit. A cross-PR concern is an inline comment on the PR where the fix belongs, naming the other PR by bare URL.
8. **Writing**: bare URLs for GitHub references, no backticks around them (`github-native-writing`). No AI or co-author footer.

`gh pr review` cannot attach inline comments. Never use it for a review that has findings. It is only for a short verdict on a PR with none.

## Flow

1. Anchor (rule 2) and write the comments. When delegating to subagents, the prompt must require, per finding: file, repo line number at the head SHA, side, severity, and the line's text. Give them the head SHA and the commands above. Re-anchor anything that comes back without them.
2. Create the review **pending**: no `event` field. Run it with `GH_TOKEN=$(gh auth token)` if it goes through a script.

   ```bash
   gh api repos/O/R/pulls/N/reviews --input - <<'EOF'
   {"commit_id": "<headRefOid>", "comments": [
     {"path": "src/a.js", "line": 42, "side": "RIGHT", "body": "..."}
   ]}
   EOF
   ```

   The response `id` is the review id. Pending reviews are visible only to you.
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
   "body": "**High** `verify()` returns early when `token` is empty, so a request with no Authorization header is treated as authenticated.\n\n```suggestion\n  if (!token) throw new UnauthorizedError();\n```"},
  {"path": "src/util.js", "line": 7, "side": "RIGHT",
   "body": "**Low** `path` is imported but no longer used after the rename.\n\n```suggestion\n```"}
]}
```

Preview in chat:

> **PR 12: REQUEST_CHANGES.** Summary: auth bypass on empty token (blocker); one rename nit.
> - src/auth.js:58 RIGHT, High: empty token passes verify()
> - src/util.js:7 RIGHT, Low: unused import after the rename
>
> Submit?

Submit body: `One blocker (empty token bypass), see inline. Rest is minor.`
