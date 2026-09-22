---
name: jira-ticket-lifecycle
description: Keep a Jira ticket's status and assignee in sync with the git/PR workflow whenever picking up or working on a ticket, resolving each project's own status names and transition graph rather than assuming a universal one. Use as soon as work starts on a ticket, and again once its PR(s) are opened.
metadata:
  category: atlassian-workflow
---

# Jira ticket lifecycle management

Whenever picking up or working on a Jira ticket, keep the ticket's Jira status and assignee in sync with the git/PR workflow, without needing to be asked each time:

- If the ticket isn't already assigned to the person doing the work, assign it to them first. This keeps ownership visible to the rest of the team.
- Move the ticket to whatever status represents **work started** as soon as work begins, even if that work is still planning/discovery and no code has been written yet. Don't wait for the first commit or PR to make this transition.
- Move the ticket to whatever status represents **dev review** (the team's equivalent of a PR-opened checkpoint) once the PR(s) are opened. For tickets using the `branching-pr-workflow` dual-PR workflow, that's once the `main`-targeting PR exists (draft is fine).
- Stop there. Don't transition the ticket to QA or Done: that's the assignee's call once they judge the PR is merged or otherwise ready for testing, and further transitions are theirs to make, not something to do proactively.
- Keep the original assignee throughout. Don't reassign to anyone else.

## There is no universal "In Progress" or "Dev Review"

Status names, and the graph connecting them, are defined per project by that project's workflow scheme. A different board can use different words for the same milestone ("In Review" vs "Code Review" vs "Ready for QA"), skip a milestone entirely, or require several hops through intermediate statuses to reach it. Never hardcode a literal status name into a transition call — resolve it first:

- Check for a `status-map.local.json` file next to this skill (format in `references/status-map.md`). If the current project has an entry (directly, or via a shared `workflow` id), use its `started`/`devReview` status names, `edges` graph, and `avoidBranches` as a starting map.
- If there's no entry (new project, or the file doesn't exist at all), don't ask the person to hand-author one upfront — bootstrap it yourself (see below), and fall back to the generic matching heuristics in `references/status-map.md`'s `default` block for the first walk while you do.

### Bootstrapping a project with no config yet

Prefer getting the *complete* graph in one shot, and prefer getting it with zero human involvement when that's actually possible — fall back a step at a time only when the previous one doesn't work. Full detail and exact commands in `references/status-map.md`; summary:

1. **Try the API first.** `POST /rest/api/3/workflows` (`twg api jira:/rest/api/3/workflows -X POST`) returns the real workflow definition for a project+issue-type — no human needed at all when it works. As of 2026-09 this reliably fails for most accounts (a `twg`-OAuth-scope wall, then — if routed around via Basic Auth with a personal API token — a Jira project-permission wall; both confirmed by direct testing, not assumed). Try it anyway before falling back: don't skip straight to asking a human on the assumption it'll fail, since permission grants can change, and this is what makes the skill actually automatic for whichever accounts and projects it does work for.
2. **If that fails, ask for the screenshot.** Have the person open any issue, click its status field, choose **View Workflow**, turn on **Show transition labels**, and share the result. This needs a human, but only once per project, ever.
3. **If a screenshot isn't practical**, fall back to walking a couple of real tickets live — slower, and it won't surface branches no ticket happens to be sitting in, but it needs nothing from the other person.
4. Whichever step succeeds, write the result back to `status-map.local.json` yourself, and — if a persistent memory system is available in this environment — save a short pointer memory noting where the graph now lives and when it was captured, so a future session doesn't ask again. The config file is the source of truth; memory just points at it.

## Reaching a milestone can take more than one transition

A ticket's current status only exposes the transitions leading directly out of it — never assume the milestone you want is one call away. Walk toward it:

1. Read the ticket's current status.
2. If it already satisfies the target milestone, stop — nothing to do.
3. If a `workflows` graph is available, compute a candidate path from the current status to the milestone over its `edges`, skipping anything in `avoidBranches` or `stopBoundary`. This is a plan, not a green light for every hop in it.
4. Discover the transitions actually available from the *current* status (see "Transition ids are not stable" below — never reuse a transition list or id fetched at an earlier status, and never execute a planned hop without this live check first).
5. If the live discovery offers the planned hop (or, with no graph available, if exactly one available transition's destination matches the milestone per the config's or default's match list), take it. If the live set *doesn't* match what the graph predicted, treat the graph as stale for this edge rather than forcing it — downgrade or drop that edge in the config and fall through to step 6.
6. If there's no plan or it just went stale, narrow the live options to transitions that move the ticket forward and aren't on the avoid list — sub-workflows like design/legal/security review, "Not Doing"/"Won't Do"/cancel-shaped transitions, or anything that moves back to an earlier status category. If exactly one candidate remains, take it and repeat from step 1 on the new status.
7. If step 6 leaves zero or more than one plausible candidate, stop and ask the person doing the work which branch to take. A wrong hop here doesn't just fail loudly — it can silently route the ticket into an unrelated workflow lane (a design reviewer gets pinged, the ticket lands in the wrong swimlane), so an ambiguous fork is a stopping condition, not a guess.
8. Cap the walk at a handful of hops (5-6). Hitting the cap without reaching the milestone means the config's assumptions are stale — report the path taken so far and stop, rather than looping.
9. Any edge taken live that wasn't already marked `confirmed-live` in the config, upgrade it. Any `diagram-only` edge that live discovery contradicts, flag for review rather than silently deleting — it may just mean this issue type's workflow differs (see "Per-issue-type caution" below).

A `status-map.local.json` graph is a hint to plan with, never a substitute for step 4 at each hop: Jira workflows change, and a hop that worked before can disappear or move — and a diagram in particular shows the *designed* graph, which conditions/screens/permissions can make the *live* graph a subset of, never a superset.

## Per-issue-type caution

A project's workflow scheme can assign a different workflow (different graph, sometimes different statuses) to each issue type. A path validated on one issue type (e.g. Task) isn't guaranteed to hold for another (e.g. Bug) in the same project, even though a plain status list for the project looks identical — that list is a union across all of the project's issue types. Don't assume a config entry validated on one ticket generalizes without spot-checking on a ticket of the type actually in hand.

## Transition ids are not stable

**Jira transition ids are only valid for the issue's current status, not stable across its lifecycle.** Always fetch the available transitions immediately before every transition call (e.g. `getTransitionsForJiraIssue`, or `twg`'s own transition-discovery step). Never reuse a transition id fetched earlier in the same session, even for the same issue, since it may already have moved once and the id for the same target status can change. A stale id fails with a generic "you might not have permission" error that doesn't hint at the real cause.

This is a Jira-workflow habit, not tied to a specific project or ticket prefix. Apply it whenever Jira tooling is available and a ticket is in play. See the `prefer-twg-cli` skill for which tool to use.

## References

- `references/status-map.md` — format for `status-map.local.json`, default matching heuristics, and an example.
