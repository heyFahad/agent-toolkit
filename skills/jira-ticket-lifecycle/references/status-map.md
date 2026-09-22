---
description: Format and defaults for the optional status-map.local.json used by jira-ticket-lifecycle
---

# Status map

`status-map.local.json`, if present next to this skill's `SKILL.md`, holds per-project status vocabulary and empirically-walked paths so `jira-ticket-lifecycle` doesn't have to re-derive them by trial and error every time. It's local, personal configuration — gitignored in this repo (`*.local.json`), and not meant to be committed with company-specific project keys or status names. Each person or org configuring this skill for their own boards keeps their own copy.

If the file is missing entirely, or a project isn't listed in it, the skill falls back to the `default` matching heuristics below — good enough for a simple, unforked workflow, but more likely to hit an ambiguous fork that needs a human decision.

## Shape

```json
{
  "default": {
    "startedMatch": ["in progress", "development", "doing", "in dev"],
    "devReviewMatch": ["dev review", "code review", "in review", "ready for qa", "pr open"],
    "avoid": ["design", "not doing", "won't do", "wont do", "cancel", "reject", "duplicate", "declined"]
  },
  "workflows": {
    "<workflow-id>": {
      "source": "<how this graph was obtained, and when>",
      "started": "<exact status name for 'work started'>",
      "devReview": "<exact status name for 'PR opened / dev review'>",
      "avoidBranches": ["<status names that fork away from the happy path>"],
      "stopBoundary": ["<statuses past devReview the skill must never enter proactively>"],
      "nodes": [
        {"name": "<status>", "category": "To Do | In Progress | Done"}
      ],
      "edges": [
        {"from": "<status>", "transition": "<transition name>", "to": "<status>", "confidence": "confirmed-live | confirmed-api | diagram-only", "note": "<optional caveat>"}
      ]
    }
  },
  "projects": {
    "<PROJECT_KEY>": { "workflow": "<workflow-id>", "verifiedOn": "<date>" },
    "<OTHER_PROJECT_KEY>": { "workflow": "<same-or-different-workflow-id>", "verifiedOn": "<date>" }
  }
}
```

- One `workflows` entry can back several `projects` entries — Jira workflow schemes are frequently shared across projects, and a single entry avoids duplicating the same graph per project. Confirm two projects actually share a workflow (matching transition ids across a live discovery call on each is strong evidence) before pointing them at the same id — projects that look identical in a plain status listing can still diverge per issue type.
- `started` / `devReview`: the literal destination status name for each milestone. An exact match here beats a fuzzy `default` list hit.
- `avoidBranches`: destination statuses to skip at a fork even if they'd technically move the ticket "forward" — typically sub-workflows (design, legal, security) that don't apply to this skill's fast path, plus abandonment transitions.
- `stopBoundary`: statuses past `devReview` that the lifecycle skill's own policy says never to enter proactively (QA/UAT/Done/Closed-shaped stages) — listed here so the walking algorithm can recognize it's gone too far, not to be confused with `avoidBranches` (which are wrong turns, not "correct but off-limits" ones).
- `edges`: the fullest graph available. Tag each edge's `confidence`:
  - `confirmed-live` — a real transition-discovery call actually offered it on a real ticket. Highest confidence: this is what Jira will actually do right now, conditions and permissions included.
  - `confirmed-api` — returned by the `POST /rest/api/3/workflows` bulk-workflow-definition call (see below). Authoritative and machine-sourced (no transcription risk), but it's the *designed* graph like a diagram is — some edges may be conditional and not always live-offered.
  - `diagram-only` — hand-transcribed from a "View Workflow" screenshot. Same designed-graph caveat as `confirmed-api`, plus transcription risk (illegible labels, misread arrows).

  Treat `confirmed-api`/`diagram-only` edges as a strong hint for path-planning, but always confirm an edge is actually offered by a live transition-discovery call immediately before taking it (see `jira-ticket-lifecycle`'s walking algorithm) — conditions, screens, and per-role permissions can make the *live* graph a subset of the designed one, never a superset. If an edge never actually shows up live, downgrade or drop it rather than forcing the ticket down a path Jira itself won't allow.

## Building an entry

Try these in order — each is a fallback for the one before it, not an alternative to pick freely:

**1. Pull it programmatically (preferred — fully automatic when it works).** `POST /rest/api/3/workflows` (bulk get workflows by project+issueType) returns the actual workflow definition — statuses and transitions — for one or more `{projectId, issueTypeId}` pairs. Get the project's numeric id and its issue type ids from `twg jira workitem types query --project <KEY>` (the response includes `projectId`), then:

```
twg api jira:/rest/api/3/workflows -X POST --input payload.json
```
```json
{"projectAndIssueTypes": [{"projectId": "<id>", "issueTypeId": "<id>"}, ...]}
```

If this returns `200`, parse the response straight into `nodes`/`edges` marked `confirmed-api` — no human, no screenshot, nothing to transcribe by eye.

**As of 2026-09, this fails for most accounts, in one of two distinct ways — both confirmed by direct testing, not assumed:**
- Through `twg`'s own stored credentials: `401 Unauthorized; scope does not match`. `twg`'s OAuth token doesn't carry the `manage:jira-configuration` scope this endpoint's OpenAPI spec declares, so the Atlassian OAuth gateway rejects the call before Jira's own permission check ever runs. This is a property of `twg`'s OAuth app registration — not fixable from the CLI, and not something a Jira admin can grant.
- Through Basic Auth (email + a personal Jira API token, which is scope-agnostic and bypasses that OAuth wall): the gateway wall clears, but Jira's own authorization returns `403 {"errorMessages":["No permission to view workflow."]}`. This means the account genuinely lacks the "Administer projects" or "View (read-only) workflow" *project* permission this endpoint requires — a real Jira-side permission gap, separate from (and downstream of) the OAuth issue, even though that same account can see the "View Workflow" panel through the issue UI (that panel apparently authorizes on something looser than this bulk API does).

Don't retry-loop on either error — both are stable "not available to this account right now" states, not transient failures. **If a Jira admin grants "View (read-only) workflow" project permission**, redoing the Basic-Auth call (personal API token, not `twg`'s own OAuth) should then succeed — that's the one lever within reach that isn't a `twg` CLI/OAuth limitation. Until that's confirmed working for a given account, fall through to step 2.

**2. The "View Workflow" diagram (fallback — fast, complete, needs a human once).** Open any ticket in the project, click its status field, and look for a **View Workflow** option in the dropdown — it renders the same full designed graph the API above would have returned, viewable by anyone who can see the issue (no special permission needed for the UI path, even when the API path is blocked). Turn on **Show transition labels** and capture it (screenshot works fine). Transcribe every node and edge into `nodes`/`edges`, marking each edge `diagram-only`.

**3. Empirical walk (fallback, or to upgrade `diagram-only`/`confirmed-api` edges to `confirmed-live`).**

1. `twg jira space status query --id-or-key <PROJECT>` to see the project's status vocabulary (grouped by category — a node list, not the graph).
2. Pick a real ticket sitting in an early status and run transition discovery (`twg jira workitem transition --id <KEY>`, no `--transition-id`) to see its real outgoing edges.
3. Follow the edge that heads toward "started," re-discovering after each hop, noting any forks and which branch was actually taken.
4. Repeat from the resulting status until reaching "dev review."
5. Record each confirmed hop as a `confirmed-live` edge (upgrading a matching `diagram-only`/`confirmed-api` edge if one already exists), and the two milestone status names as `started`/`devReview`.

Whichever step succeeds, record it in memory (a short pointer — "the workflow graph for project X lives in this file, refreshed on this date" — not the graph itself) if a persistent memory system is available, so a later session doesn't have to redo any of this. This should happen automatically as part of using the skill on an unfamiliar project, not something the skill's consumer has to set up in advance.

## Example (illustrative, not a real project)

```json
{
  "default": {
    "startedMatch": ["in progress", "development", "doing"],
    "devReviewMatch": ["dev review", "code review", "in review"],
    "avoid": ["design", "not doing", "won't do", "cancel", "duplicate"]
  },
  "workflows": {
    "acme-default": {
      "source": "View Workflow diagram, captured 2026-01-15",
      "started": "In Progress",
      "devReview": "Code Review",
      "avoidBranches": ["Needs Design", "Won't Fix"],
      "stopBoundary": ["QA", "Done"],
      "nodes": [
        {"name": "Backlog", "category": "To Do"},
        {"name": "In Progress", "category": "In Progress"},
        {"name": "Code Review", "category": "In Progress"}
      ],
      "edges": [
        {"from": "Backlog", "transition": "Start", "to": "In Progress", "confidence": "confirmed-live"},
        {"from": "In Progress", "transition": "Submit for Review", "to": "Code Review", "confidence": "confirmed-live"}
      ]
    }
  },
  "projects": {
    "ACME": { "workflow": "acme-default", "verifiedOn": "2026-01-15" }
  }
}
```
