---
name: dev-stack
description: Start, check and stop the local services a change needs, each on its own Node version, Doppler config and port, through one background process-compose server. Use before verifying a change against running services, when a change has to be tried end to end across repos, when the user needs a running app (web URL or Simulator) to test, when a dev server won't start or a port is taken, and when the user asks what's running locally.
metadata:
  category: development
---

# Dev stack

`devstack` starts only what a change needs, plus everything it depends on, in order, and waits for each to answer its health check. It reads a registry, `stack.yaml`, from `$DEVSTACK_REGISTRY` or the nearest one above the current directory. Run it as `devstack` if it's on `PATH`, otherwise as `scripts/devstack` in this skill's directory. Agents don't need it on `PATH`. For people using it from a terminal, a link is enough: `ln -s <this skill's directory>/scripts/devstack ~/.local/bin/devstack`.

Prerequisites: `jq`, `yq` and `process-compose` (`brew install f1bonacc1/tap/process-compose`). If one is missing, every command says which and exits 3. Don't install it yourself: tell the user the line.

## Commands

| Command | Use it to |
|---|---|
| `devstack up <target or service…>` | Start what a change needs. Prints one line per service. |
| `… --from <svc>=<worktree>` | Run that service from the ticket's worktree instead of the main checkout. Repeat per service. |
| `… --with <svc>` | Also start an optional dependency. |
| `devstack status [--json]` | See what's running, on which port, from which directory. |
| `devstack logs <svc> [--errors] [--tail N]` | Read one service's log (30 lines by default). |
| `devstack restart <svc> [--from <path>]` | Restart one service, optionally from another checkout. |
| `devstack urls` | Get what to hand the user: web URLs, APIs, Metro ports. |
| `devstack down [svc…]` | Stop services. Docker containers are never touched. |
| `devstack attach` | The live dashboard. This is for the user, in their own terminal. |
| `devstack ports [--markdown]` | Print the port table. |

Exit codes: 0 fine, 1 a service failed or wasn't healthy in time, 2 a usage, registry or ownership problem, 3 a missing tool or Node version.

## How to use it while verifying a change

1. Start the ticket's target, with `--from` for every service whose repo the ticket changed in a worktree: `devstack up connect --from connect-api=$PWD`.
2. Read what `up` printed. On failure it already shows up to 20 error lines from the failing service, so don't open whole logs. If you need more, use `devstack logs <svc> --errors`.
3. Check behaviour against the running services. In the Claude desktop app, open web URLs in the browser pane with `preview_start` and a `url`. Don't write `launch.json` files for this.
4. When handing over to the user, give them the `devstack urls` output, and mention `devstack attach` if they want to watch the stack from iTerm2.

## Rules

- If `up` says a service "is running from" another directory, another session may be testing with it. Don't add `--takeover` unless the user says that session is done.
- Don't `devstack down` while the user is still testing. Stopping the stack waits for their approval of the change.
- Never stop, recreate or remove Docker containers to fix a failure. `up` only starts a stopped container that's listed in the registry's `infra`. If Docker itself is down, tell the user.
- A port held by something else (`port 3010 for bsa is held by node (pid …)`) is the user's process. Tell them what's holding it rather than killing it.
- If `up` says one service "can't run while" another runs from the same folder (two brands of one Next.js app, say), stop the other one or run this one from a worktree with `--from`. That limit comes from the app, not devstack.
- Ports come from the registry. Don't pass a different port on the command line to get around a conflict.
