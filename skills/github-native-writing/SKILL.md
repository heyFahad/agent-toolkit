---
name: github-native-writing
description: Reference-formatting rule specific to GitHub-native surfaces (PR/issue comments, review replies, PR/issue descriptions, Discussions) - paste bare URLs, never Markdown-link or backtick them. Use whenever writing a PR comment, review reply, PR/issue description, or Discussion post.
metadata:
  category: writing-conventions
---

# Writing on GitHub-native surfaces: paste bare URLs

This is the one exception to the general "always write an explicit hyperlink" rule (see the `external-reference-links` skill), and it goes the other way.

**On GitHub-native surfaces only (PR/issue comments and review replies, PR/issue descriptions, Discussions), paste the bare, full `github.com` URL. Don't hand-build a Markdown link, and never wrap it in backticks.**

GitHub auto-shortens a bare URL to one of its own resources into a real clickable link with a hovercard preview:

- a commit URL renders as just the short SHA in monospace
- a PR/issue URL renders as `#123`
- a comment permalink renders as `#123 (comment)`

This is strictly better than manually writing `` [`85e5005`](url) ``.

**Backticking the reference instead of pasting it bare defeats this.** GitHub's autolinker skips code spans. This is a real mistake to watch for, not a style nit: it was confirmed to actually break the intended rendering on a live PR review comment (`PATCH`ing the comment body and reading back its `body_html` showed the backticked reference rendered as inert literal text instead of an autolink).

This is GitHub-specific: no other URL (Jira, Confluence, Slack, or otherwise) gets this treatment. It's also scoped to GitHub-native surfaces specifically. A Markdown file *in* a GitHub repo (`docs/*.md`, `README.md`) or a wiki page still needs an explicit Markdown link, per [GitHub's own docs on autolinked references](https://docs.github.com/en/get-started/writing-on-github/working-with-advanced-formatting/autolinked-references-and-urls), which explicitly scope autolinking out of those contexts.

If this rule is violated in a way a script can check (a backtick-wrapped `github.com` URL, SHA, or `#123`-style reference inside a `gh` comment/review/PR-body command), this plugin's `github-comment-formatting-gate` hook denies the command before it runs.
