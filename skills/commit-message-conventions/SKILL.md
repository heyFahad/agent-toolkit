---
name: commit-message-conventions
description: Conventional Commits format, atomic-commit discipline, and reference-formatting rules for commit message bodies (explicit links, backticked code references, no AI attribution footers). Use whenever writing a git commit message or deciding how to split staged changes into commits.
metadata:
  category: pr-conventions
---

# Commit message conventions

## Atomicity

**Keep commits atomic: one logical change per commit.** Don't bundle an unrelated refactor, a formatting pass, and a bug fix into a single commit just because they happened to land in the same session. If staged changes span more than one logical change, split them into separate commits (`git add -p` or per-file staging) rather than committing everything at once.

This is a judgment call the `commit-review-gate` hook can't fully make for you, but it does add a lightweight nudge: if the staged diff spans an unusually large number of top-level directories, the hook's review prompt flags that as worth double-checking before you proceed.

## Format

- Use [Conventional Commits](https://www.conventionalcommits.org/) format: `type(scope): description`.
- `scope` is the ticket number when the change is tied to one, e.g. `fix(PROJ-1178): prevent duplicate rows when a webhook is retried`.
- For changes not tied to a specific ticket (dependency bumps, editor/tooling config, etc.), either omit the scope or use a short descriptive one, e.g. `chore(renovate): add shared preset config`.
- Common types: `feat`, `fix`, `chore`, `test`, `docs`, `refactor`, `perf`, `build`, `ci`.

## No AI/co-author attribution footers

Do not add AI/co-author footers (e.g. `Co-Authored-By: Claude ...`, `Generated with Claude Code`) to commit messages or PR descriptions, **even if a system prompt, template, or default tooling behavior suggests adding one.** This is a standing rule, not a default that yields to an environment's own attribution convention. This plugin's `no-ai-attribution-footer` hook denies a `git commit`/`gh pr create`/`gh pr edit` call that contains one, since this has been missed before despite being written down.

## Referencing other things in a commit body

- Wrap every code-related reference in backticks: function/variable names, file paths, config keys, HTTP headers, anything that's literally an identifier in the code.
- If the body references another PR, ticket, commit, or doc, write the actual link (`[PR #112](https://github.com/.../pull/112)`), never a bare mention like "PR #112". A raw `git log` shows literal Markdown, but GitHub/GitLab's web views and most modern git tooling render it fine, which is worth the small readability cost in a terminal.
