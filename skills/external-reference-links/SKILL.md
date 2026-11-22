---
name: external-reference-links
description: Explicit-hyperlink and code-reference-backtick conventions for prose outside GitHub-native surfaces - Jira ticket descriptions/comments, Confluence, Slack, and any other doc or write-up. Also covers how to tag people in Jira, Confluence and Slack. Use whenever writing prose that references a PR, ticket, commit, doc, code identifier or person outside of a GitHub comment/description/Discussion.
metadata:
  category: writing-conventions
---

# Explicit hyperlinks and code-reference formatting

Applies to Jira ticket descriptions and comments, Confluence pages, Slack messages, and any other prose written outside GitHub-native surfaces (see the `github-native-writing` skill for the GitHub-specific exception, which goes the other way).

## Always write an explicit hyperlink

Never rely on platform auto-linking. If the text references another PR, Jira ticket, commit, doc, or any other resource, include the actual link, not a bare mention like "PR #112" or "PROJ-937". Auto-linking is inconsistent across contexts (cross-repo mentions, plain-text comment fields, viewers without that integration active), and a bare reference gives a reader nothing if it doesn't fire.

Use standard Markdown link syntax for this: `[PR #112](https://github.com/.../pull/112)`. (JSDoc has its own mechanism: see the `jsdoc-cross-references` skill.)

## Mentioning people

When to tag someone is in `humanize`'s "Mentioning people". A tag only notifies when it carries the person's account ID; a typed `@Name` is plain text on these platforms. Never invent an ID: look it up, and use the plain name if you can't.

- **Jira and Confluence**: get the account ID with `twg user get "<exact name or email>"`, then write `<span data-type="mention" data-user-id="ACCOUNT_ID">@Display Name</span>` in an HTML body, or `[~accountId:ACCOUNT_ID]` where the write path takes Markdown. `twg-jira`'s `references/rich-content.md` has the details. Read the result back when it matters that the mention rendered.
- **Slack**: find the user ID (`U0123ABCD`) with a user search, then write `<@U0123ABCD>`. A group is `<!subteam^S0123ABCD>`. Never use `@here`, `@channel` or `@everyone` unless the user asks for it.

## Backtick every code-related reference

Wrap every code-related reference in backticks: function/variable names, file paths, config keys, HTTP headers, anything that's literally an identifier in the code. This improves skimmability and is the standard Markdown-as-code convention.

One minor, acceptable tradeoff: raw `git log` in a terminal shows literal backticks rather than rendering them. GitHub/GitLab's web views and most modern git tooling render them fine, and readability there outweighs the terminal cosmetic cost.
