'use strict';

// Shareable flat ESLint config implementing this toolkit's default JS/TS style.
// Designed to degrade gracefully: the rules below need no plugin at all.
// import/order and the TSX-specific rule only activate if the target
// repo already has eslint-plugin-import / @typescript-eslint installed -
// this config never fails to load just because those aren't present.

function tryRequire(name) {
  try {
    return require(name);
  } catch {
    return null;
  }
}

const importPlugin = tryRequire('eslint-plugin-import');
const tsPlugin = tryRequire('@typescript-eslint/eslint-plugin');
const tsParser = tryRequire('@typescript-eslint/parser');

const JS_TS_FILES = ['**/*.js', '**/*.jsx', '**/*.ts', '**/*.tsx'];

const config = [
  {
    files: JS_TS_FILES,
    rules: {
      // Always brace conditionals and loops, even single-statement bodies,
      // followed by a blank line before the next statement.
      curly: ['error', 'all'],
      'padding-line-between-statements': [
        'error',
        { blankLine: 'always', prev: 'block-like', next: '*' },
      ],

      // Arrow functions use an explicit block body with an explicit return.
      'arrow-body-style': ['error', 'always'],

      // No leading/trailing-underscore identifiers, except Mongo's _id.
      'no-underscore-dangle': ['error', { allow: ['_id'] }],

      // Prefer object destructuring when pulling a single property off an
      // object (not enforced for arrays).
      'prefer-destructuring': [
        'error',
        { VariableDeclarator: { object: true, array: false } },
        { enforceForRenamedProperties: false },
      ],

      // parseInt only takes an explicit radix when it isn't the default (10).
      radix: ['error', 'as-needed'],

      // Prefer avoiding console.* in application code where the project
      // already has structured logging - this is a judgment call the
      // static rule can't make on its own (see the coding-style-defaults
      // skill), so it's a warning, not a hard error.
      'no-console': 'warn',
    },
  },
  {
    // jest.mock('x', () => ({...})) factory callbacks are the near-universal
    // Jest idiom for an implicit-return arrow - don't force a block body
    // there. ESLint has no callee-based exception, so this is a file-glob
    // approximation scoped to test files rather than the exact call site.
    files: ['**/*.test.*', '**/*.spec.*', '**/__mocks__/**'],
    rules: {
      'arrow-body-style': 'off',
    },
  },
];

if (importPlugin) {
  config.push({
    files: JS_TS_FILES,
    plugins: { import: importPlugin },
    rules: {
      // Import ordering: builtin -> external -> internal -> parent ->
      // sibling -> index, blank line between groups, alphabetized
      // case-insensitively within a group, react pinned first in external.
      'import/order': [
        'error',
        {
          groups: ['builtin', 'external', 'internal', 'parent', 'sibling', 'index'],
          'newlines-between': 'always',
          alphabetize: { order: 'asc', caseInsensitive: true },
          pathGroups: [{ pattern: 'react', group: 'external', position: 'before' }],
          pathGroupsExcludedImportTypes: ['react'],
        },
      ],
    },
  });
}

if (tsPlugin && tsParser) {
  config.push({
    // TSX/React projects: allow an async function as a JSX/DOM event-handler
    // attribute (e.g. onClick={async () => {...}}) without a false-positive
    // "misused promise" flag.
    files: ['**/*.tsx'],
    languageOptions: { parser: tsParser },
    plugins: { '@typescript-eslint': tsPlugin },
    rules: {
      '@typescript-eslint/no-misused-promises': [
        'error',
        { checksVoidReturn: { attributes: false } },
      ],
    },
  });
}

module.exports = config;
