---
name: coding-style-defaults
description: Intent behind this toolkit's default JS/TS coding style, and the judgment calls the eslint.config.js in this plugin can't make on its own. Use when generating or editing JS/TS code, or when the eslint-autofix-gate hook's output disagrees with a repo's own lint config.
metadata:
  category: coding-style
---

# Coding style preferences (JavaScript/TypeScript)

This plugin's `eslint.config.js` mechanically enforces most of this: the `eslint-autofix-gate` hook runs it on every edited JS/TS file, so these rules don't depend on being remembered. This skill covers what the config can't decide on its own.

## What's mechanically enforced (see `eslint.config.js`)

- Always brace conditionals/loops, blank line after.
- Arrow functions: explicit block body + explicit `return` (exception: `jest.mock(...)` factory callbacks, approximated via a test-file glob since ESLint can't target a specific call site).
- Import ordering and grouping (only if `eslint-plugin-import` is installed in the target repo).
- No leading/trailing-underscore identifiers except `_id`.
- Prefer object destructuring for a single property.
- `parseInt` radix only when non-default.
- TSX: `@typescript-eslint/no-misused-promises` with `checksVoidReturn.attributes: false` (only if `@typescript-eslint` is installed in the target repo).

## What's a judgment call, not a lint rule

**`console.*` usage.** The rule is "prefer avoiding `console.*` in application code where the project already has structured logging, but match an existing repo's own established pattern when one exists" (e.g. a repo whose error middleware already uses `console.error` deliberately shouldn't get a divergent logging call bolted on next to it). Whether a repo "already has structured logging" isn't something a lint rule can determine. Check the surrounding code before adding or flagging a `console.*` call. The config sets `no-console` to `warn` rather than `error` for this reason.

## When the config disagrees with a repo's real lint setup

**A project's own actual, currently-enforced lint config wins when it visibly conflicts with a rule here.** Never fight a repo's real CI. But flag the conflict when it comes up rather than silently picking a side, so the conflict can be resolved deliberately (e.g. updating the repo's config, or deciding this default doesn't apply here). This is about default output for new code, not something to bulk-retrofit onto a repo's existing code or its own ESLint config.

This skill is about writing/editing code inside an already-scaffolded project. For default Node.js version and package-manager choices when starting a brand-new project, see the `nodejs-toolchain-defaults` skill instead. That's a different trigger (scaffolding, not editing) and it ages differently: those defaults shift every few months as Node ships new majors, so they're written to stay current rather than naming a specific version.

## Why this lives here and not hand-applied per edit

The original ask was for generated code to already look like it was hand-written to this standard, independent of whatever a given repo's own config does or doesn't enforce, not to change any repo's actual lint rules or retroactively reformat its existing code. Prose alone didn't hold this reliably. The `eslint-autofix-gate` hook is what actually closes the loop by running immediately after every edit.
