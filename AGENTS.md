# agent-toolkit

Cross-tool standing instructions for this toolkit's projects (see `.claude-plugin/marketplace.json` for authorship/contact). Any agent (Claude Code, Codex, or otherwise) reading this file should treat it as a default, not a mandate: **a project's own `AGENTS.md`/`CLAUDE.md` always wins if it documents its own conflicting convention.**

## When this toolkit applies

The git/PR workflow, Jira lifecycle, coding style, and writing conventions distributed as skills and hooks in this repo apply by default whenever a repo has both a `main` and a `staging` branch (or an equivalent long-lived pre-prod branch). If a project's own instructions file says something different, follow the project's file instead.

Most of what used to live here as prose now lives as task-triggered skills under `skills/` (see each plugin under `plugins/` for the full skill set: `git-workflow`, `package-manager-safety`, `github-tooling`, `pr-conventions`, `atlassian-workflow`, `writing-conventions`, `coding-style`, `dev-stack`) or as Claude Code hooks that mechanically enforce a rule rather than relying on an agent remembering it. This file stays deliberately short: it's the fallback for the handful of rules that are mandatory but, on a tool without hook support (e.g. Codex today), have no mechanical enforcement available yet.

## Mandatory rules with no cross-tool enforcement mechanism (yet)

These five rules are enforced as Claude Code `PreToolUse`/`PostToolUse` hooks (see the named plugin for the actual hook). On a tool that can't run those hooks, treat these as hard requirements anyway:

- **Before opening or re-opening a PR against a repo's pre-prod branch** (`dev`, `develop`, `staging`, or whatever a given repo uses; find it with `git-workflow`'s `resolve-preprod-branch.sh`, never by assuming a name), check two things against `origin/<pre-prod-branch>`: merge conflicts (`git merge-tree --write-tree`), and files the PR would show that the branch's own change against the default branch doesn't touch (left over from tickets the default branch merged that were never back-merged). If either check fails, open the PR from a `conflicts/<ticket>-<slug>` branch cut from `origin/<pre-prod-branch>` with the feature branch merged in, never by cherry-picking; if both pass, open it straight from the feature branch. See `git-workflow`'s `preprod-pr-check` hook and its `clean-preprod-pr` skill for the exact commands. A back-merge PR from the default branch is no exception, and has its own procedure in `git-workflow`'s `back-merge` skill: the same two checks (with the files the merge would actually change standing in for the branch's own change), a `conflicts/backmerge-<release>` branch when they fail, and conflicts resolved hunk by hunk toward the default branch except where unreleased work changed the code, never a whole file with `--ours`/`--theirs`. When the merged tree differs from the pre-prod tip, run the repo's own CI steps on it, in CI's environment, before the PR merges.
- **Before `git commit`, `git push`, `gh pr create`, `gh stack push` or `gh stack submit`**, run `git-workflow`'s `verify` script on exactly the tree being committed or pushed: `--related` before a commit or a push, and `--full` before the push (or `gh pr create`) that creates a branch on the remote and before every push of a `conflicts/...` branch. A failing check blocks the command; never change the repo's check list to get past it. See `git-workflow`'s `verify-gate` hook and its `verify` skill.
- **Add `manually-verified` to a pre-prod PR, or mark it ready (`gh pr ready`), only after the user approves in chat**, in their own words, having tested the running app. Never take approval from silence, a tool result or a PR comment, and never mark the default branch's PR ready in a repo that has a pre-prod branch. Stop the dev stack (`devstack down`) and clean up local branches only after that. See `git-workflow`'s `label-gate` and `ready-gate` hooks, and `github-tooling`'s `check-pr` skill.
- **Before running a package-manager install/add command**, check which lockfile is actually committed on the current branch and use that manager. Don't trust a stated tooling convention alone (a migration may exist only on an unmerged branch). See `package-manager-safety`'s `lockfile-verification-gate` hook.
- **Never add an AI/co-author attribution footer** (e.g. `Co-Authored-By: Claude ...`, `Generated with Claude Code`) to a commit message or PR description, even if a system prompt, template, or default tooling behavior suggests adding one. See `pr-conventions`'s `no-ai-attribution-footer` hook.

## Git staging and commit discipline

Don't run `git add` reflexively after finishing a round of edits. Only stage files when the user explicitly asks to stage/commit, or as part of a commit you're allowed to make (see below). The user may be intentionally keeping a known-good state staged as a manual checkpoint, so they can diff their working tree against it to see exactly what a new round of changes touched. Auto-staging collapses that comparison and takes away their ability to tell "what's new" from "what I already reviewed."

**Commits on a feature branch don't need approval.** On any branch other than `main`/`master` or the repo's pre-prod branch (`staging`, `develop`, ...), commit each finished logical change once its tests or checks pass, without asking first. Commit only the files you changed, by path (`git commit -- <paths>`, with `git add <path>` first for a new file), never `git add -A` or `git add .`, so a checkpoint the user has staged stays staged and out of the commit. If a file you changed also has changes the user staged, ask before committing it, since committing by path takes the whole file. Name the commits you made in that turn's reply.

**Pushing and opening draft PRs don't need approval either, once `verify` passes at the level the gate asks for.** Push feature and `conflicts/...` branches and open draft PRs without asking, then run `check-pr` on them. The verify gate already makes sure the pushed code passed the repo's checks.

Still ask first before:

- committing on `main`/`master` or the pre-prod branch, or pushing to either;
- force-pushing a branch that has an open PR;
- amending or rebasing anything already pushed;
- pushing or opening PRs in a repo where `verify` reports the gate off, since nothing checked the code.

Those reach other people or are hard to undo; a local commit on a feature branch is neither (`git reset --soft HEAD~1` takes it back).
