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
                elif request_id == 2:
                    if "error" in response:
                        raise SystemExit(response["error"])
                    return response["result"]["data"][0]
            raise SystemExit("Codex app server exited before returning the skill inventory.")
        finally:
            server.terminate()


def expected_skills(plugins):
    return {
        (f"{plugin}@{MARKETPLACE}", f"{plugin}:{link.name}")
        for plugin in plugins
        for link in (ROOT / "plugins" / plugin / "skills").glob("*")
    }


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

        skills = discover(workspace, env)
        for issue in skills["errors"]:
            if str(codex_home) in json.dumps(issue):
                raise SystemExit(issue)
        declared = expected_skills(expected)
        check_set("runtime skills", declared, {
            (skill["pluginId"], skill["name"])
            for skill in skills["skills"]
            if (skill.get("pluginId") or "").endswith(f"@{MARKETPLACE}") and skill["enabled"]
        })
        print(f"Codex discovered {len(declared)} skills from {len(expected)} plugins.")


if __name__ == "__main__":
    main()
