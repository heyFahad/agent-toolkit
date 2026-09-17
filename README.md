# agent-toolkit

A personal git/PR workflow, Jira lifecycle, coding style, and writing-convention toolkit for coding agents (Claude Code, Codex, or any tool that reads `AGENTS.md` and the open [Agent Skills](https://agentskills.io) format). Distributed as independent plugins, each covering one concern (see the list below for the current set).

- [`git-workflow`](plugins/git-workflow): branching, dual-PR (production + pre-prod), stacked epics, staging-conflict resolution
- [`package-manager-safety`](plugins/package-manager-safety): lockfile verification before install/add commands
- [`github-tooling`](plugins/github-tooling): `gh` CLI auth-propagation safety, bot-review triage calibration
- [`pr-conventions`](plugins/pr-conventions): PR title format, commit message format, no AI attribution footers
- [`atlassian-workflow`](plugins/atlassian-workflow): Atlassian tooling preference, Jira ticket lifecycle
- [`writing-conventions`](plugins/writing-conventions): per-surface hyperlink/formatting rules, an anti-AI-slop humanizing pass
- [`coding-style`](plugins/coding-style): a shareable ESLint config plus an auto-fix hook

Everything mandatory gets a hook, not just a paragraph asking an agent to remember it. See [AGENTS.md](AGENTS.md) for the handful of rules that stay as prose because no hook mechanism covers them everywhere yet.

## Get started

### Let an agent set it up (recommended)

Paste this into Claude Code or Codex:

> Add the `agent-toolkit` plugin marketplace from `heyFahad/agent-toolkit`, then list what's in it. Ask me which plugins I want from that list, with a one-line description of each, and install only the ones I pick. Once installed, run `/reload-plugins` and confirm which skills and hooks are now active by name.

That's deliberately a request for the agent to *ask before installing*, not to install everything unattended, and to work off whatever the marketplace actually lists rather than a number written down here that could go stale. Swap the last sentence for "install everything without asking" if that's what you want instead.

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
```

Or from inside a session: `/plugin marketplace add heyFahad/agent-toolkit`, then `/plugin install <name>@agent-toolkit` for each one you want. There's no requirement to install all of them; they're independent. Run `/reload-plugins` to pick up changes without restarting.

**Codex:**

```bash
codex plugin marketplace add heyFahad/agent-toolkit
```

Then, inside a session: `/plugin install <name>@agent-toolkit` for each plugin, followed by `/reload-plugins`.

**Check what actually loaded:** in Claude Code, `/context` shows active skills and agents, and `/plugin` opens the plugin manager, including an **Errors** tab if a hook or skill failed to load. In Codex, `codex plugin list` shows installed plugins.

### Just want one skill?

Every skill also lives on its own at `skills/<name>/SKILL.md`, in the flat layout that [`npx skills`](https://github.com/vercel-labs/skills) expects, so any tool it supports (Claude Code, Codex, Cursor, Gemini CLI, GitHub Copilot, OpenCode) can pull a single skill without the rest of the plugin:

```bash
npx skills add heyFahad/agent-toolkit --list
npx skills add heyFahad/agent-toolkit --skill humanize --skill commit-message-conventions
```

This only installs the skill text. The mechanical hooks that back some of these skills are Claude Code plugin features and don't come along with a single-skill install.

## Contributing

Testing changes locally before pushing, the reasoning behind the repo's file layout, and what CI checks all live in [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT. See [LICENSE](LICENSE).
