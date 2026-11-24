---
name: pr-title-conventions
description: Gitmoji-style PR title format. Use whenever opening or renaming a pull request.
metadata:
  category: pr-conventions
---

# PR title conventions

PR titles use [gitmoji](https://gitmoji.dev/specification) style, **not** Conventional Commits (that format is for commit messages only; see the `commit-message-conventions` skill).

- Format: `<emoji> <TICKET>: <Capitalized message>`, one intention emoji, then the ticket number with **no parentheses**, a colon, then a capitalized message.
- A PR can bundle multiple commits across different Conventional Commit types, so don't just copy the first/last commit's type. Infer the single best emoji collectively from the branch name prefix (`feature/`, `fix/`, `bug/`, `chore/`...), the overall set of commits in the PR, and the linked ticket's type/summary.
- Don't stack a second emoji (e.g. `🚀`) to flag the `main`-targeting PR as "the one that ships to prod": the `production` label and the base branch already convey that.
- Use the same title on both the `main` and `staging` PRs for a ticket.
- Example: `✨ PROJ-1174: Retry failed webhook deliveries on a backoff schedule`
