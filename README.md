# agent-toolkit

A personal git/PR workflow, Jira lifecycle, coding style, and writing-convention toolkit for coding agents (Claude Code, Codex, or any tool that reads `AGENTS.md` and the open [Agent Skills](https://agentskills.io) format). Distributed as independent plugins, each covering one concern (see the list below for the current set).

- [`git-workflow`](plugins/git-workflow): branching, dual-PR (production + pre-prod) with pre-prod branch detection, stacked epics, clean pre-prod PRs (conflicts, and noise when the default branch hasn't been back-merged), back-merges with a drift audit, a fresh-context review of your own diff before its PRs are opened, a gate that blocks committing or pushing code that hasn't passed the repo's checks (`verify`), cleaning up finished branches and worktrees
- [`package-manager-safety`](plugins/package-manager-safety): lockfile verification before install/add commands
- [`github-tooling`](plugins/github-tooling): `check-pr` (Copilot, human review and CI triage across a ticket's main and pre-prod PRs, with helper scripts)
- [`pr-conventions`](plugins/pr-conventions): PR title format, commit message format, no AI attribution footers, a fresh-context reviewer for your own diffs and other people's PRs, giving a review on someone else's PR (inline comments in a pending review, with a guard hook)
- [`atlassian-workflow`](plugins/atlassian-workflow): `twg` CLI over the Atlassian MCP (with a gate hook), reading a Jira ticket in full before starting, Jira ticket lifecycle
- [`writing-conventions`](plugins/writing-conventions): per-surface hyperlink/formatting rules, an anti-AI-slop humanizing pass
- [`coding-style`](plugins/coding-style): a shareable ESLint config plus an auto-fix hook
- [`dev-stack`](plugins/dev-stack): a `devstack` command that starts only the local services a change needs, on their own Node version, Doppler config and port, gated on health checks

Everything mandatory gets a hook, not just a paragraph asking an agent to remember it. See [AGENTS.md](AGENTS.md) for the handful of rules that stay as prose because no hook mechanism covers them everywhere yet.

## Get started

### Let an agent set it up (recommended)

Paste this into the coding agent you want to set up:

> Set up the `agent-toolkit` marketplace from `heyFahad/agent-toolkit` for the agent handling this request. Identify the current host and use its own marketplace and plugin tools. List the available plugins with a one-line description of each. If I provided a selection alongside this prompt, install it. Otherwise, ask me once which plugins I want. A selection can name plugins or request the entire catalog. Refresh or start a new session as the host requires. Use its runtime inventory to report the skills and hooks that loaded by name, including any hooks awaiting trust. If the host lacks marketplace support, offer the individual skills it can install and explain which hooks are unavailable.

### Do it yourself

**Claude Code:**

```bash
claude plugin marketplace add heyFahad/agent-toolkit
claude plugin install git-workflow@agent-toolkit
claude plugin install package-manager-safety@agent-toolkit
claude plugin install github-tooling@agent-toolkit
claude plugin install pr-conventions@agent-toolkit
claude plugin install atlassian-workflow@agent-toolkit
claude plugin install writing-conventions@agent-toolkit
claude plugin install coding-style@agent-toolkit
claude plugin install dev-stack@agent-toolkit
```

Or from inside a session: `/plugin marketplace add heyFahad/agent-toolkit`, then `/plugin install <name>@agent-toolkit` for each one you want. There's no requirement to install all of them; they're independent. Run `/reload-plugins` to pick up changes without restarting.

**Codex:**

```bash
codex plugin marketplace add heyFahad/agent-toolkit
codex plugin list --marketplace agent-toolkit --available --json
codex plugin add git-workflow@agent-toolkit
```

Install each plugin you want, then start a fresh Codex session. In the Codex CLI, `/skills` lists discovered skills and `/hooks` shows hook status. Review and trust the toolkit's command hooks in `/hooks` to activate them. Use the `humanize` skill in Codex for the writing checks that Claude Code runs as agent hooks.

In Claude Code, `/context` shows available skills and agents, and `/plugin` shows plugin loading errors.

### Just want one skill?

Every skill also lives on its own at `skills/<name>/SKILL.md`, in the flat layout that [`npx skills`](https://github.com/vercel-labs/skills) expects, so any tool it supports (Claude Code, Codex, Cursor, Gemini CLI, GitHub Copilot, OpenCode) can pull a single skill without the rest of the plugin:

```bash
npx skills add heyFahad/agent-toolkit --list
npx skills add heyFahad/agent-toolkit --skill humanize --skill commit-message-conventions
```

Standalone installs include the skill and its supporting files. Hooks are supplied through the host's plugin package.

## Contributing

Testing changes locally before pushing, the reasoning behind the repo's file layout, and what CI checks all live in [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT. See [LICENSE](LICENSE).
