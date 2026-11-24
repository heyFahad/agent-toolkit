---
name: nodejs-toolchain-defaults
description: Default Node.js version and package-manager choice for a brand-new JS/TS project, and how to pin them without the pin going stale. Use when scaffolding a new project's toolchain, not when editing an existing repo's already-established one (see the coding-style-defaults skill for that).
metadata:
  category: coding-style
---

# Node.js and package-manager defaults for a new project

Two defaults, for a brand-new project only. An existing repo's own already-established toolchain always wins; this is about what to pick when there isn't one yet.

## Node version: latest Current, not latest LTS

Default to whichever even-numbered Node major is currently in its **Current** phase, not the latest **Active LTS** one. Node ships a new even major roughly every six months (April), which runs as Current for about six months before converting to Active LTS the following October. Picking Current-not-LTS means the "right" answer changes on that same roughly-six-month cadence.

**Don't hardcode a specific version number as the answer, here or anywhere else this skill's content ends up.** A number written down today will be stale in a few months and, worse, will look authoritative to whoever reads it next. Determine it fresh each time: check Node's real release schedule (`https://github.com/nodejs/Release/blob/main/schedule.json`, or `nodejs.org`) for the even major whose `start` date has passed but whose `lts` date has not. That one is the current Current release.

This is a deliberate trade: newer runtime features and performance for less time for the ecosystem to have caught up. A project leaning heavily on native addons or a slow-moving dependency might reasonably choose the latest LTS instead.

## Package manager: pnpm, pinned with `devEngines`

Prefer pnpm over npm/yarn for a new project. Pin both the Node version and the package manager with the `devEngines` field in `package.json`, not the legacy top-level `packageManager` field: pnpm's own documentation now calls `packageManager` legacy, Corepack (its usual enforcer) stopped being bundled with Node starting at major 25, and `devEngines` is the cross-tool standard that npm, pnpm, and Corepack all read directly. Never set both `packageManager` and `devEngines.packageManager` in the same `package.json`: pnpm will ignore `packageManager` when both are present, which is a real, documented source of drift between what a `package.json` claims and what actually runs.

Shape (illustrative field names and structure only, resolve the actual version numbers at the time the same way as the Node version above: `pnpm --version` for whatever's newest, or the latest tag on npm):

```json
{
  "engines": { "node": ">=<current Current major>" },
  "devEngines": {
    "runtime": { "name": "node", "version": ">=<current Current major>", "onFail": "error" },
    "packageManager": { "name": "pnpm", "version": "^<current pnpm version>", "onFail": "error" }
  }
}
```

Also add an `.nvmrc` with the same major version. Classic `nvm` only reads `.nvmrc`; it does not understand `engines` or `devEngines` in `package.json` at all, so this isn't redundant with the block above, it covers a tool the block above doesn't reach.

Any pnpm-specific settings (`engineStrict: true`, etc.) belong in `pnpm-workspace.yaml`, not `.npmrc`. pnpm now reads `.npmrc` for auth and registry settings only; everything else has moved to `pnpm-workspace.yaml` (or the global `~/.config/pnpm/config.yaml`), and a setting like `engine-strict` left in `.npmrc` is silently ignored by pnpm rather than erroring, which makes the mistake easy to miss.

## When this doesn't apply

This is for a project that actually builds or runs JS/TS. A repo with no real dependencies and no build step (this toolkit's own repo included) doesn't need `package.json`, `.nvmrc`, or a package-manager pin at all: adding them anyway just recreates the toolchain-pinning problem for a project with nothing to pin. Pin only when there's a real reason to, such as a CI step that needs a package manager to install something, or actual dependencies to lock.
