---
name: jsdoc-cross-references
description: Use {@link} for every in-JSDoc cross-reference, not a Markdown link. Use whenever writing a JSDoc comment that references another symbol, a PR, or a ticket.
metadata:
  category: writing-conventions
---

# JSDoc cross-references use `{@link}`, not a Markdown link

This is a correctness point, not a style preference. Verified empirically via the TypeScript language service (`ts.createLanguageService(...).getQuickInfoAtPosition`): `{@link someFunction}` resolves to the actual declaration and IDEs render it as a clickable, navigable link in hover. A Markdown-style `[text](path)` inside a JSDoc block gets no such treatment and renders as inert literal text.

The same tag also works for external URLs (a PR, a ticket):

```js
/**
 * See {@link https://github.com/.../pull/148 PR #148} for the original discussion.
 * @see {@link someOtherFunction}
 */
```

Use `{@link}` for every in-JSDoc reference, whether to another symbol or an external resource. Never a bare Markdown link inside a JSDoc block.
