---
name: bot-review-triage-calibration
description: How to calibrate use of automated bot-review triage tooling on a PR, and the human-review check it will never do for you. Use before or while triaging PR review findings, secret scans, or SAST results.
metadata:
  category: github-tooling
---

# Bot PR review triage: calibrate before defaulting to it

If your environment has automated bot-review triage tooling (a skill or CLI that fetches bot-authored PR review findings such as Copilot, Sentry, gitleaks, semgrep, or trivy, replies to and resolves the corresponding GitHub review threads, and computes a single "is this PR clean" gate), it's useful, but narrower than it first appears. Calibrate before defaulting to it on every PR.

## What it will never do

It is strictly bot-only. A Copilot-review fetch is typically hard-filtered to the bot's own account (e.g. `copilot-pull-request-reviewer[bot]`), and there is usually no source module for human reviewers at all. **Always pair it with a manual check for human reviewers.** It will never surface those on its own:

```bash
gh pr view --json reviews
gh api repos/OWNER/REPO/pulls/N/comments
```

It also contributes nothing to the actual judgment work: classifying a finding as a true or false positive, or cross-verifying a claim against real code, is left entirely to the invoking prompt: the tooling only automates fetch/reply/resolve/gate.

## When to actually reach for it

- Before invoking it, check bot-review volume first: `gh pr view --json reviews` shows whether Copilot/Sentry left anything. For 0-2 simple findings, just handle them directly via `gh api` rather than loading the full multi-source tooling.
- Its real value (multi-source triage, an autonomous loop with re-review pacing) is built for repos with several scanners wired into CI and PRs that churn through multiple bot re-review rounds after each push. On a repo with light CI (e.g. just a dependency-scan check, no real test/lint gate), most of what it's for goes unused and it mainly adds context load.
- Start with a single-pass mode; only reach for a looping/autonomous mode on a PR with visible multi-round bot re-review churn or several scanners actually posting findings.

## Auth gotcha

If this tooling shells out to `gh` from its own subprocess, see this plugin's `gh-token-export` hook and the matching rule in `AGENTS.md`. An unauthenticated-looking `404` from a private-repo call is usually this, not a real permissions problem.
