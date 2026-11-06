---
name: prefer-twg-cli
description: Prefer the twg CLI over Jira/Confluence/Bitbucket MCP tools when it's installed and authenticated. Use at the start of any session where Jira, Confluence, Bitbucket, or other Atlassian/work-graph queries come up.
metadata:
  category: atlassian-workflow
---

# Prefer the TWG CLI over Jira/Confluence MCP tools

For Jira, Confluence, Bitbucket, and related Atlassian/work-graph queries and mutations, prefer the `twg` CLI (Atlassian's TWG CLI, typically installed at `~/.local/bin/twg`, with its own companion skills: a root `twg` skill plus companions like `twg-jira`, `twg-confluence`, `twg-engineering-work`) over the Jira MCP server's tools, whenever `twg` is installed and authenticated in the environment. Treat it the way `gh` is already treated for GitHub: the default entry point, not a fallback.

## Why

A `twg jira workitem get` call returns a curated, much smaller inline summary compared to the full raw payload an equivalent MCP `getJiraIssue` call returns every time. `twg` also spans Confluence, Bitbucket, PR/org-graph, and responsibility-routing queries under one consistent interface instead of needing a separate MCP server per product, and its skills structurally enforce safe-mutation habits (e.g. discovering available transitions as a separate read-only step before a workflow transition is even possible) that would otherwise have to be remembered by convention alone (see the `jira-ticket-lifecycle` skill's transition-id staleness note).

## How to apply

- At the start of a session where Jira/Confluence/Bitbucket work comes up, load the `twg` root skill first, then the narrowest companion skill (`twg-jira`, `twg-confluence`, `twg-engineering-work`, etc.) rather than reaching for Jira/Atlassian MCP tools by default.
- Fall back to Jira/Atlassian MCP tools only if `twg` isn't installed in that environment. If it's installed but `twg whoami`/`twg doctor` fails, its login has lapsed: tell the person and ask them to run `twg login`, rather than quietly switching to the MCP.
- In Claude Code this is enforced, not just advised: the plugin's `prefer-twg-gate` hook denies Atlassian MCP tool calls whenever `twg` is installed, and its denial message names the `twg` command to use instead. Setting `AGENT_TOOLKIT_ALLOW_ATLASSIAN_MCP=1` in Claude Code's settings `env` turns the gate off, for a capability `twg` really lacks.
- A big `twg` response is summarized inline, with the full payload written to the file named under `output_files.stdout`. When the content matters (a ticket's description and comments, a page's body), read that file; the inline summary is only a pointer to it.
- The standing Jira ticket lifecycle rules (assign, transition through In Progress/Dev Review, re-fetch transition ids before every transition; see `jira-ticket-lifecycle`) still apply regardless of which tool executes them. `twg`'s own transition-discovery step satisfies the same requirement.
