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
- Fall back to Jira/Atlassian MCP tools only if `twg` isn't installed/authenticated in that environment (`twg whoami`/`twg doctor` failing), or a specific capability genuinely isn't covered by `twg`.
- The standing Jira ticket lifecycle rules (assign, transition through In Progress/Dev Review, re-fetch transition ids before every transition; see `jira-ticket-lifecycle`) still apply regardless of which tool executes them. `twg`'s own transition-discovery step satisfies the same requirement.
