---
name: github-native-writing
description: Reference-formatting rules specific to GitHub-native surfaces (PR/issue comments, review replies, PR/issue descriptions, Discussions) - paste bare URLs for PRs, issues and commits, never backtick them, pick bare or named links to lines of code by how GitHub will render them, and @-mention people and bots correctly. Use whenever writing a PR comment, review reply, PR/issue description, or Discussion post.
metadata:
  category: writing-conventions
---

# Writing on GitHub-native surfaces: paste bare URLs

This is the one exception to the general "always write an explicit hyperlink" rule (see the `external-reference-links` skill), and it goes the other way.

**On GitHub-native surfaces only (PR/issue comments and review replies, PR/issue descriptions, Discussions), paste the bare, full `github.com` URL. Don't hand-build a Markdown link (links to lines of code are the one exception, below), and never wrap it in backticks.**

GitHub auto-shortens a bare URL to one of its own resources into a real clickable link with a hovercard preview:

- a commit URL renders as just the short SHA in monospace
- a PR/issue URL renders as `#123`, or `owner/repo#123` when it is in another repository
- a comment permalink renders as `#123 (comment)`

This is strictly better than manually writing `` [`85e5005`](url) ``.

**Backticking the reference instead of pasting it bare defeats this.** GitHub's autolinker skips code spans. This is a real mistake to watch for, not a style nit: it was confirmed to actually break the intended rendering on a live PR review comment (`PATCH`ing the comment body and reading back its `body_html` showed the backticked reference rendered as inert literal text instead of an autolink).

This is GitHub-specific: no other URL (Jira, Confluence, Slack, or otherwise) gets this treatment. It's also scoped to GitHub-native surfaces specifically. A Markdown file *in* a GitHub repo (`docs/*.md`, `README.md`) or a wiki page still needs an explicit Markdown link, per [GitHub's own docs on autolinked references](https://docs.github.com/en/get-started/writing-on-github/working-with-advanced-formatting/autolinked-references-and-urls), which explicitly scope autolinking out of those contexts.

## Links that are not a bare GitHub resource

- **A non-GitHub link inside a GitHub comment** (Jira, Confluence, a dashboard) gets a named Markdown link, `[TN-594](https://...)`. GitHub does not title these for you, and a bare long URL reads as noise. Name it for what the reader will find.
- **Pointing at lines of code**: see the next section.

## Links to lines of code

A link to lines of a file (`https://github.com/O/R/blob/<sha>/path#L20-L24`) renders in one of two ways, and which one depends on the link, not on you:

- **A snippet box** showing those lines, under a header naming the file and commit. GitHub does this only when the link is bare, points into the same repository as the comment, and is pinned to a full 40-character commit SHA. It does it wherever the link sits, even mid-sentence, where the box splits the sentence in two.
- **The raw URL**, a long unreadable string, in every other case: a link into another repository, or one pinned to a short SHA or a branch name.

So decide first what the link is for:

- **The code is the argument** (the lines that prove a finding is not applicable, the lines a discussion is about) and they are in this repository: paste the link bare, on its own line, pinned to the full SHA. The reader sees the evidence without clicking.

  ```text
  Not applicable: the retry loop already stops after three attempts:

  https://github.com/O/R/blob/1b6c95d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7/src/retry.ts#L40-L52
  ```

- **The link only says where something is**, or it points into another repository: write a named Markdown link. It reads as one short inline link and never turns into a box. Its text says where the lines are, the way GitHub's own snippet header does:
  - In this repository, the path from the repository root: `src/client/session.ts:88-97`. A bare file name can match several files.
  - In another repository, that path with the repository's name in front: `other-repo/src/client/session.ts:88-97`, or `other-org/other-repo/...` when the owner differs from this repository's. Without the prefix, the reader assumes the file is in this one.

  ```text
  The client only sends the header on its first request ([other-repo/src/client/session.ts:88-97](https://github.com/O/other-repo/blob/6b05599d1a69c5a3b8c5b6f4df20d3bca6b41ff9/src/client/session.ts#L88-L97)).
  ```

This is the one place to hand-build a Markdown link to a GitHub resource. Unlike a PR, issue or commit URL, which GitHub shortens even across repositories (`O/other-repo#123`), a line link has no short form: bare, it is either a box or a raw URL.

Either way, pin the link to the commit the reader is discussing, not a branch, so it keeps pointing at the same lines. When that isn't the PR's current head, say which version it shows. A box of the code a reviewer flagged, posted under "fixed in abc1234", looks like the current code unless the text says otherwise. For a Markdown file, a plain click on the link scrolls but does not highlight; `?plain=1` before the `#` opens the source view with the lines marked.

## Mentioning people and bots

When to tag someone is in `humanize`'s "Mentioning people". On GitHub:

- Write `@login` bare in the text. Inside backticks it is literal and notifies no one, which is how to write a placeholder or an example (`@reviewer`).
- Take the login from where the person already appears: the PR or issue author and commenters (`gh pr view N --json author,comments,reviews`). Confirm one you were given with `gh api users/<login>`. If you only have a name and the match isn't certain, ask the user rather than tagging a stranger.
- `@org/team` notifies every member of the team. Use it only when the whole team should act.
- A bot mention can start work: `@copilot` in a PR comment can hand the PR to Copilot's coding agent. Request Copilot's review with `gh pr edit N --add-reviewer @copilot` instead, and write `@copilot` in a comment only to give it work.

If this rule is violated in a way a script can check (a backtick-wrapped `github.com` URL, SHA, or `#123`-style reference inside a `gh` comment/review/PR-body command), this plugin's `github-comment-formatting-gate` hook denies the command before it runs.
