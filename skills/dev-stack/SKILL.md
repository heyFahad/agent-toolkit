---
name: dev-stack
description: Start, check and stop the local services a change needs, each on its own Node version, Doppler config and port, through one background process-compose server. Use before verifying a change against running services, when a change has to be tried end to end across repos, when the user needs a running app (web URL or Simulator) to test, when a dev server won't start or a port is taken, and when the user asks what's running locally.
metadata:
  category: development
---

# Dev stack

`devstack` starts only what a change needs, plus everything it depends on, in order, and waits for each to answer its health check. It reads a registry, `stack.yaml`, from `$DEVSTACK_REGISTRY` or the nearest one above the current directory. Run it as `devstack` if it's on `PATH`, otherwise as `scripts/devstack` in this skill's directory. Agents don't need it on `PATH`. For people using it from a terminal, a link is enough: `ln -s <this skill's directory>/scripts/devstack ~/.local/bin/devstack`.

Prerequisites: `jq`, `yq` and `process-compose` (`brew install f1bonacc1/tap/process-compose`). If one is missing, every command says which and exits 3. Don't install it yourself: tell the user the line.

In a sandbox, devstack needs to reach its unix socket and write to its state folder (`~/.local/state/devstack`). In Codex that means `sandbox_workspace_write.network_access = true` and the state folder in `sandbox_workspace_write.writable_roots`. Without them it says so instead of guessing.

## Commands

| Command | Use it to |
|---|---|
| `devstack up <target or service…>` | Start what a change needs. Prints one line per service. |
| `… --from <svc>=<worktree>` | Run that service from the ticket's worktree instead of the main checkout. Repeat per service. |
| `… --with <svc>` | Also start an optional dependency. |
| `devstack status [--json]` | See what's running, on which port, from which directory, and when each service's idle stop is due. |
| `devstack logs <svc> [--errors] [--tail N]` | Read one service's log (30 lines by default). |
| `devstack restart <svc> [--from <path>]` | Restart one service, optionally from another checkout. |
| `devstack urls` | Get what to hand the user: web URLs, APIs, Metro ports. |
| `devstack down [svc…]` | Stop services. Docker containers are left running. |
| `devstack attach` | The live dashboard. This is for the user, in their own terminal. |
| `devstack ports [--markdown]` | Print the port table. |

Exit codes: 0 fine, 1 a service failed or wasn't healthy in time, 2 a usage, registry or ownership problem, 3 a missing tool or Node version.

## When to start it

Running services cost memory and CPU the whole time they're up, so start them late. Write the code, run the tests, lint and `verify` with nothing running: none of those need a live stack. Run `devstack up` only right before you check behaviour against running services or ask the user to try the change, and stop it (`devstack down`) once they've approved it.

## How to use it while verifying a change

1. Start the ticket's target, with `--from` for every service whose repo the ticket changed in a worktree: `devstack up connect --from connect-api=$PWD`.
2. Read what `up` printed. On failure it already shows up to 20 error lines from the failing service, so don't open whole logs. If you need more, use `devstack logs <svc> --errors`.
3. Check behaviour against the running services. In the Claude desktop app, open web URLs in the browser pane with `preview_start` and a `url`. Don't write `launch.json` files for this.
4. When handing over to the user, give them the `devstack urls` output, and mention `devstack attach` if they want to watch the stack from iTerm2.

## Idle shutdown

`up` starts a watchdog that stops each service nobody has used for 15 minutes: no connection on its port and no new line in its log. Working on one target, the others you started earlier stop on their own. A quiet service stays up while a running service depends on it (a shared API stays while either app that uses it runs), and dependants stop before what they depend on. When the last service stops, the whole stack goes down.

The watchdog checks once a minute, runs once per state folder (one for the whole stack), and exits when the stack goes down any other way. Lines that name a service's health-check path don't count: those are process-compose's own probes. An app that keeps a connection open (the Simulator's link to Metro, a browser tab holding a websocket) keeps its service up; that's someone using it. So does a service that logs on a timer.

- `devstack status` ends with each running service's countdown (`idle stop in: …`) and lists what the watchdog stopped (`stopped while idle: …`). A stopped service shows as `Stopped`.
- Change the limit with `idle: {minutes: 30}` in `stack.yaml`, or `DEVSTACK_IDLE_MINUTES` for one `up`; `0` turns it off. The setting from the latest `up` applies.
- If the user comes back to a stopped service, run `devstack up` for it again. It starts cold, so a URL handed over earlier answers again only once it's Ready.

Docker containers stay running unless the registry sets `idle: {stop_infra: true}`. Then, once no running service lists a container in its `infra`, the watchdog stops it, but only if devstack itself started it (never one that was already running). Suggest it to a user whose Docker VM is short of memory.

MongoDB sizes its WiredTiger cache to about half the Docker VM's memory unless told otherwise: 3.6 GB of a 7.8 GB VM has been seen. devstack doesn't create containers, so it can't set that, but `up` says once when a MongoDB container it relies on has no cap. Tell the user that whoever creates the container should add `--wiredTigerCacheSizeGB 1` to the `mongod` command (`docker run … mongo:7 --wiredTigerCacheSizeGB 1`, or `command:` in a compose file); the container has to be recreated for it to apply.

## Rules

- If `up` says a service "is running from" another directory, another session may be testing with it. Don't add `--takeover` unless the user says that session is done.
- Don't `devstack down` while the user is still testing. Stopping the stack waits for their approval of the change.
- Don't start services while you're still coding or running checks. Start them right before the user tests (see "When to start it").
- Never stop, recreate or remove Docker containers to fix a failure. `up` only starts a stopped container that's listed in the registry's `infra`. If Docker itself is down, tell the user.
- A port held by something else (`port 3010 for bsa is held by node (pid …)`) is the user's process. Tell them what's holding it rather than killing it.
- If `up` says one service "can't run while" another runs from the same folder (two brands of one Next.js app, say), stop the other one or run this one from a worktree with `--from`. That limit comes from the app, not devstack.
- There is one running stack per state folder (`~/.local/state/devstack`). If `up` says the running stack "was started from" another `stack.yaml`, stop it there, or give the second workspace its own `DEVSTACK_STATE_DIR`.
- Ports come from the registry. Don't pass a different port on the command line to get around a conflict.
