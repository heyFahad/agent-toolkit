"""Regression test for preserving untracked files in generated packages."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[2]


def write(root, path, text):
    target = root / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text)
    return target


def run(root, *args, check=True):
    env = os.environ.copy()
    for key in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY", "GIT_PREFIX"):
        env.pop(key, None)
    return subprocess.run(args, cwd=root, env=env, capture_output=True, text=True, check=check)


def main():
    with tempfile.TemporaryDirectory() as temp:
        root = Path(temp).resolve()
        run(root, "git", "init", "-q")
        sync = "scripts/sync-codex-packages.py"
        write(root, sync, "")
        shutil.copy2(ROOT / sync, root / sync)
        write(root, ".agents/plugins/marketplace.json", json.dumps({
            "plugins": [{"name": "example", "source": {"path": "./codex-plugins/example"}}],
        }))
        write(root, "skills/example/SKILL.md", "canonical\n")
        plugin_skills = root / "plugins/example/skills"
        plugin_skills.mkdir(parents=True)
        (plugin_skills / "example").symlink_to("../../../skills/example")
        package = "codex-plugins/example/skills/example"
        stale = write(root, f"{package}/stale.md", "obsolete package file\n")
        run(root, "git", "add", "--", "skills", "plugins", "codex-plugins")

        local_note = write(root, f"{package}/local.md", "untracked notes\n")
        local_skill = write(root, f"{package}/SKILL.md", "untracked draft\n")
        result = run(root, sys.executable, sync, check=False)
        assert result.returncode != 0, result.stdout
        assert "local.md" in result.stderr and "SKILL.md" in result.stderr, result.stderr
        assert local_note.read_text() == "untracked notes\n"
        assert local_skill.read_text() == "untracked draft\n"
        assert stale.is_file(), "sync modified the package before reporting the conflict"

        local_note.unlink()
        local_skill.unlink()
        run(root, sys.executable, sync)
        assert not stale.exists(), "tracked stale output should be pruned"
        assert local_skill.read_text() == "canonical\n"
        run(root, sys.executable, sync, "--check")


if __name__ == "__main__":
    main()
