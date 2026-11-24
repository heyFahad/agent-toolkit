"""Install the marketplace in an isolated Codex home and check runtime discovery."""

import json
import os
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
MARKETPLACE = "agent-toolkit"


def codex(args, cwd, env):
    return json.loads(subprocess.check_output(["codex", *args, "--json"], cwd=cwd, env=env, timeout=30))


def discover(cwd, env):
    requests = [
        {
            "id": 1,
            "method": "initialize",
            "params": {
                "clientInfo": {"name": "agent-toolkit-ci", "version": "1"},
                "capabilities": {"experimentalApi": True},
            },
        },
        {"method": "initialized"},
        {"id": 2, "method": "skills/list", "params": {"cwds": [str(cwd)], "forceReload": True}},
        {"id": 3, "method": "hooks/list", "params": {"cwds": [str(cwd)]}},
    ]
    with subprocess.Popen(
        ["codex", "app-server", "--listen", "stdio://"],
        cwd=cwd,
        env=env,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
    ) as server:
        def send(request):
            print(json.dumps({"jsonrpc": "2.0", **request}), file=server.stdin, flush=True)

        replies = {}
        try:
            send(requests[0])
            for line in server.stdout:
                response = json.loads(line)
                request_id = response.get("id")
                if request_id == 1:
                    if "error" in response:
                        raise SystemExit(response["error"])
                    for request in requests[1:]:
                        send(request)
                elif request_id in (2, 3):
                    if "error" in response:
                        raise SystemExit(response["error"])
                    replies[request_id] = response["result"]["data"][0]
                    if len(replies) == 2:
                        return replies[2], replies[3]
            raise SystemExit("Codex app server exited before returning the skill and hook inventories.")
        finally:
            server.terminate()


def expected_skills(plugins):
    return {
        (f"{plugin}@{MARKETPLACE}", f"{plugin}:{link.name}")
        for plugin in plugins
        for link in (ROOT / "plugins" / plugin / "skills").glob("*")
    }


def expected_hooks(plugins):
    hooks = set()
    for plugin in plugins:
        config = ROOT / "plugins" / plugin / "hooks/hooks.json"
        if not config.is_file():
            continue
        for event, entries in json.loads(config.read_text())["hooks"].items():
            runtime_event = event[0].lower() + event[1:]
            hooks.update(
                (f"{plugin}@{MARKETPLACE}", Path(hook["command"]).stem, runtime_event)
                for entry in entries
                for hook in entry["hooks"]
                if hook["type"] == "command"
            )
    return hooks


def check_set(component, expected, actual):
    if expected != actual:
        raise SystemExit(
            f"{component} mismatch. Missing: {sorted(expected - actual)}. Unexpected: {sorted(actual - expected)}."
        )


def main():
    expected = {plugin["name"] for plugin in json.loads(
        (ROOT / ".claude-plugin/marketplace.json").read_text()
    )["plugins"]}
    with tempfile.TemporaryDirectory(prefix="agent-toolkit-") as temp:
        workspace = Path(temp)
        codex_home = workspace / "codex"
        codex_home.mkdir()
        env = {**os.environ, "CODEX_HOME": str(codex_home)}

        codex(["plugin", "marketplace", "add", str(ROOT)], workspace, env)
        available = codex(
            ["plugin", "list", "--marketplace", MARKETPLACE, "--available"], workspace, env,
        )
        check_set("marketplace plugins", expected, {plugin["name"] for plugin in available["available"]})
        for plugin in sorted(expected):
            codex(["plugin", "add", f"{plugin}@{MARKETPLACE}"], workspace, env)
        installed = codex(["plugin", "list", "--marketplace", MARKETPLACE], workspace, env)
        check_set("enabled plugins", expected, {plugin["name"] for plugin in installed["installed"] if plugin["enabled"]})

        skills, hooks = discover(workspace, env)
        for diagnostics in (skills["errors"], hooks["errors"], hooks.get("warnings", [])):
            for issue in diagnostics:
                if MARKETPLACE in json.dumps(issue):
                    raise SystemExit(issue)
        declared_skills = expected_skills(expected)
        declared_hooks = expected_hooks(expected)
        check_set("runtime skills", declared_skills, {
            (skill["pluginId"], skill["name"])
            for skill in skills["skills"]
            if (skill.get("pluginId") or "").endswith(f"@{MARKETPLACE}") and skill["enabled"]
        })
        check_set("runtime hooks", declared_hooks, {
            (hook["pluginId"], hook["statusMessage"], hook["eventName"])
            for hook in hooks["hooks"]
            if (hook.get("pluginId") or "").endswith(f"@{MARKETPLACE}") and hook["enabled"]
        })
        print(f"Codex discovered {len(declared_skills)} skills and {len(declared_hooks)} hooks from {len(expected)} plugins.")


if __name__ == "__main__":
    main()
