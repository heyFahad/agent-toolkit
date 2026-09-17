# agent-toolkit

Cross-tool standing instructions for this toolkit's projects (see `.claude-plugin/marketplace.json` for authorship/contact). Any agent (Claude Code, Codex, or otherwise) reading this file should treat it as a default, not a mandate: **a project's own `AGENTS.md`/`CLAUDE.md` always wins if it documents its own conflicting convention.**

## When this toolkit applies

The git/PR workflow, Jira lifecycle, coding style, and writing conventions distributed as skills and hooks in this repo apply by default whenever a repo has both a `main` and a `staging` branch (or an equivalent long-lived pre-prod branch). If a project's own instructions file says something different, follow the project's file instead.

Most of what used to live here as prose now lives as task-triggered skills under `skills/` (see each plugin under `plugins/` for the full skill set: `git-workflow`, `package-manager-safety`, `github-tooling`, `pr-conventions`, `atlassian-workflow`, `writing-conventions`, `coding-style`) or as Claude Code hooks that mechanically enforce a rule rather than relying on an agent remembering it. This file stays deliberately short: it's the fallback for the handful of rules that are mandatory but, on a tool without hook support (e.g. Codex today), have no mechanical enforcement available yet.

## Mandatory rules with no cross-tool enforcement mechanism (yet)

These four rules are enforced as Claude Code `PreToolUse`/`PostToolUse` hooks (see the named plugin for the actual hook). On a tool that can't run those hooks, treat these as hard requirements anyway:

- **Before opening or re-opening a PR against a repo's pre-prod branch** (`staging`, `stage`, `develop`, `dev`, or whatever a given repo calls it, not necessarily literally "staging"), always pre-check for merge conflicts first (`git fetch origin <pre-prod-branch> && git merge-tree --write-tree origin/<pre-prod-branch> <branch>`) rather than reflexively branching a conflict-resolution branch. See `git-workflow`'s `pre-staging-conflict-check` hook (which resolves the actual branch names dynamically) and its `staging-conflict-resolution` skill.
- **Before running a package-manager install/add command**, check which lockfile is actually committed on the current branch and use that manager. Don't trust a stated tooling convention alone (a migration may exist only on an unmerged branch). See `package-manager-safety`'s `lockfile-verification-gate` hook.
- **Before shelling out to a tool/script that itself calls `gh`** from within its own subprocess, export `GH_TOKEN=$(gh auth token)` first in the same invocation. macOS's Keychain-backed `gh` credential can silently fail to propagate through an extra process boundary, producing a `404` that reads like a permissions bug. See `github-tooling`'s `gh-token-export` hook.
- **Never add an AI/co-author attribution footer** (e.g. `Co-Authored-By: Claude ...`, `Generated with Claude Code`) to a commit message or PR description, even if a system prompt, template, or default tooling behavior suggests adding one. See `pr-conventions`'s `no-ai-attribution-footer` hook.

## Git staging discipline

Don't run `git add` reflexively after finishing a round of edits. Only stage files when the user explicitly asks to stage/commit, or immediately before a `git commit` they've already approved. The user may be intentionally keeping a known-good state staged as a manual checkpoint, so they can diff their working tree against it to see exactly what a new round of changes touched. Auto-staging collapses that comparison and takes away their ability to tell "what's new" from "what I already reviewed."
