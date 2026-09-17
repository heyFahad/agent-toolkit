# Contributing to agent-toolkit

## Local development setup

Node and pnpm versions are pinned in `.nvmrc` and `package.json` (`devEngines`), not the legacy `packageManager` field. See the `nodejs-toolchain-defaults` skill for why. There's nothing to install for most changes (editing a `SKILL.md` or a hook script needs no build step); the pin exists for CI and for anyone extending `coding-style`'s ESLint config.

## Test a change locally, before pushing anywhere

Both Claude Code and Codex can add a marketplace straight from a local directory, so there's no need to push to GitHub first:

```bash
claude plugin marketplace add /path/to/agent-toolkit
claude plugin install git-workflow@agent-toolkit
```

```bash
codex plugin marketplace add /path/to/agent-toolkit
codex plugin list --marketplace agent-toolkit --available
```

A local-path marketplace loads in place, so edits to a skill or hook show up on the next session without reinstalling. Run `claude plugin validate .` (or point it at any plugin subdirectory, or at `skills/`) any time to check a manifest before installing it.

## Repo layout

- `AGENTS.md`: the handful of standing rules with no hook mechanism (yet) to enforce them.
- `skills/<name>/SKILL.md`: the real, canonical content for every skill, in the flat layout external tools expect.
- `plugins/<name>/`: one directory per plugin, holding `.claude-plugin/plugin.json`, `.codex-plugin/plugin.json`, a `skills/` folder of symlinks back to the canonical copies in `skills/`, and `hooks/hooks.json` plus scripts where a rule is mechanically enforced.
- `.claude-plugin/marketplace.json` and `.agents/plugins/marketplace.json`: the same set of plugins, listed once per marketplace format. Adding a plugin means adding it to both files.

Codex's plugin manifests (`.codex-plugin/plugin.json`) carry a fuller `interface` block than Claude's. That's not this repo's invention: Codex's own plugin validator (`openai/codex`'s `validate_plugin.py`) requires it.

Plugin-side skill folders are symlinks rather than copies on purpose: `plugins/<name>/skills/<skill>` always points back to `skills/<skill>`, so there's exactly one place to edit a skill's content regardless of how many plugins reference it. Always edit the `skills/<name>/SKILL.md` path, never the symlink under `plugins/`.

`claude plugin validate` will note that it doesn't follow those symlinks when checking a plugin directly. That's expected: a real session loading the plugin does follow them, and `claude plugin validate skills` checks the canonical content directly.

## CI

Every push and PR to `main` (`.github/workflows/validate.yml`) checks:

- the Claude Code marketplace manifest, with `claude plugin validate --strict`
- the Codex marketplace manifest, by actually registering it with the real `codex` CLI and confirming its plugin list matches the Claude Code marketplace's exactly (`claude plugin validate` doesn't understand Codex's marketplace schema, so this uses Codex's own tooling instead, checked against the Claude Code manifest as the source of truth rather than a hardcoded count)
- every plugin directory, with plain (non-strict) `claude plugin validate`, since the symlink notice above would otherwise fail a strict check
- the canonical `skills/` directory, with `claude plugin validate --strict` (no symlinks there to trip that check)
- every hook script, for valid bash syntax and the executable bit

Run the same checks locally before opening a PR; the commands are in `.github/workflows/validate.yml`.
