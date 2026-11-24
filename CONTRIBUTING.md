# Contributing to agent-toolkit

Use Python 3 to refresh Codex packages and run the discovery check. The checks use the standalone `claude` and `codex` CLIs.

## Test a change locally, before pushing anywhere

Both Claude Code and Codex can add a marketplace straight from a local directory, so there's no need to push to GitHub first:

```bash
claude plugin marketplace add /path/to/agent-toolkit
claude plugin install git-workflow@agent-toolkit
```

```bash
codex plugin marketplace add /path/to/agent-toolkit
codex plugin add git-workflow@agent-toolkit
```

Run `python3 scripts/check-codex-plugins.py` to install the checkout and verify discovery in an isolated Codex settings directory. Run `claude plugin validate .` or pass a plugin directory or `skills/` to validate Claude Code packages.

## Repo layout

- `AGENTS.md`: the handful of standing rules with no hook mechanism (yet) to enforce them.
- `skills/<name>/SKILL.md`: the real, canonical content for every skill, in the flat layout external tools expect.
- `plugins/<name>/` holds the Claude Code manifests, skill symlinks, and shared hook scripts.
- `codex-plugins/<name>/` holds the Codex manifests and generated runtime files. Codex installs the contents of each package directory, so its runtime files live inside that directory.
- `.claude-plugin/marketplace.json` and `.agents/plugins/marketplace.json` list the same plugin names in each host's format.

Edit canonical skills under `skills/`. The links in `plugins/<name>/skills/` determine which skills each plugin ships. Run `python3 scripts/sync-codex-packages.py` and commit the refreshed Codex copies with the source change. Skill tests stay with the canonical files.

Claude Code follows the existing symlinks during plugin loading. Its validator may report that it skipped symlinks while checking a plugin directory. The canonical skills are validated separately.

Claude Code reads `plugins/<name>/hooks/hooks.json`. For Codex, register command hooks in `codex-plugins/<name>/hooks/codex.json`. The sync script copies their shared scripts and support files from the Claude Code package. CI checks that each shared command hook is discovered by Codex for the same event.

Check the event payload and decision when porting a hook. Codex command hooks accept `PreToolUse` denials and `PostToolUse` context. Success-only Bash reminders must check the tool result because Codex also sends `PostToolUse` on a failed command. Codex continues a tool call after an unsupported `permissionDecision: "ask"` response. For a hook that must enforce human approval, explicitly deny the action and give the user the command to run if there is no supported approval path. The Claude Code agent handlers stay in its config. [Codex hook reference](https://learn.chatgpt.com/docs/hooks)

## CI

Every push and PR to `main` (`.github/workflows/validate.yml`) checks:

- the Claude Code marketplace manifest, with `claude plugin validate --strict`
- Codex package files against their canonical sources
- the Codex marketplace catalog, enabled plugins, and discovered skills and command hooks in an isolated settings directory
- every plugin directory, with plain (non-strict) `claude plugin validate`, since the symlink notice above would otherwise fail a strict check
- the canonical `skills/` directory, with `claude plugin validate --strict` (no symlinks there to trip that check)
- every shell script under `plugins/` and `skills/` (hooks and skill helper scripts), for valid bash syntax and the executable bit
- every `*.test.sh` under `plugins/` and `skills/` (plain bash plus `jq`, no framework; run one directly with `bash`)
- every `hooks.json`'s `if` patterns, for valid wildcard syntax (`claude plugin validate` never reads `hooks.json` at all, so this is the only check that catches it)

Run the same checks locally before opening a PR; the commands are in `.github/workflows/validate.yml`.
