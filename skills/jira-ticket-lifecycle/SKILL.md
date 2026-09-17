---
name: jira-ticket-lifecycle
description: Keep a Jira ticket's status and assignee in sync with the git/PR workflow whenever picking up or working on a ticket. Use as soon as work starts on a ticket, and again once its PR(s) are opened.
metadata:
  category: atlassian-workflow
---

# Jira ticket lifecycle management

Whenever picking up or working on a Jira ticket, keep the ticket's Jira status and assignee in sync with the git/PR workflow, without needing to be asked each time:

- If the ticket isn't already assigned to the person doing the work, assign it to them first. This keeps ownership visible to the rest of the team.
- Move the ticket to **In Progress** as soon as work starts, even if that work is still planning/discovery and no code has been written yet. Don't wait for the first commit or PR to make this transition.
- Move the ticket to **Dev Review** (or the team's equivalent status) once the PR(s) are opened. For tickets using the `branching-pr-workflow` dual-PR workflow, that's once the `main`-targeting PR exists (draft is fine).
- Stop there. Don't transition the ticket to QA or Done: that's the assignee's call once they judge the PR is merged or otherwise ready for testing, and further transitions are theirs to make, not something to do proactively.
- Keep the original assignee throughout. Don't reassign to anyone else.

## Transition ids are not stable

**Jira transition ids are only valid for the issue's current status, not stable across its lifecycle.** Always fetch the available transitions immediately before every transition call (e.g. `getTransitionsForJiraIssue`, or `twg`'s own transition-discovery step). Never reuse a transition id fetched earlier in the same session, even for the same issue, since it may already have moved once and the id for the same target status can change. A stale id fails with a generic "you might not have permission" error that doesn't hint at the real cause.

This is a Jira-workflow habit, not tied to a specific project or ticket prefix. Apply it whenever Jira tooling is available and a ticket is in play. See the `prefer-twg-cli` skill for which tool to use.
