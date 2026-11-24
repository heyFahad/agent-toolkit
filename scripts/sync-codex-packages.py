"""Build the runtime copies used by the Codex marketplace."""

import argparse
import json
from pathlib import Path
import shutil
import subprocess


ROOT = Path(__file__).resolve().parents[1]
CODEX_MARKETPLACE = ROOT / ".agents/plugins/marketplace.json"


def files_in_checkout(*options):
    files = subprocess.check_output(
        ["git", "ls-files", "-z", *options, "--",
         "skills/", "plugins/", "codex-plugins/"],
        cwd=ROOT,
    )
    return {ROOT / path for path in files.decode().split("\0") if path}


def skill_files(plugin, files):
    for link in sorted((plugin / "skills").glob("*")):
        source = ROOT / "skills" / link.name
        skill = source / "SKILL.md"
        if not link.is_symlink() or link.resolve() != source or skill not in files or not skill.is_file():
            raise SystemExit(f"{link.relative_to(ROOT)} must link to {source.relative_to(ROOT)}")
        for path in files:
            if source not in path.parents or not path.is_file():
                continue
            relative = path.relative_to(source)
            if "tests" not in relative.parts[:-1]:
                yield Path("skills") / link.name / relative, path


def needs_copy(source, destination):
    return (
        destination.is_symlink()
        or not destination.is_file()
        or source.read_bytes() != destination.read_bytes()
        or (source.stat().st_mode & 0o111) != (destination.stat().st_mode & 0o111)
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="report drift without copying files")
    args = parser.parse_args()

    tracked = files_in_checkout("--cached")
    files = tracked | files_in_checkout("--others", "--exclude-standard")
    plugins = json.loads(CODEX_MARKETPLACE.read_text())["plugins"]
    remove = []
    copy = []
    for plugin in plugins:
        package = ROOT / plugin["source"]["path"]
        source = ROOT / "plugins" / plugin["name"]
        expected = dict(skill_files(source, files))
        existing = {
            path.relative_to(package) for path in files
            if package / "skills" in path.parents and (path.is_file() or path.is_symlink())
        }
        remove.extend(package / relative for relative in sorted(existing - expected.keys()))
        for relative, source in sorted(expected.items()):
            destination = package / relative
            if needs_copy(source, destination):
                copy.append((source, destination))

    changed = [*remove, *(destination for _, destination in copy)]
    untracked = [
        destination for destination in changed
        if destination not in tracked and (destination.exists() or destination.is_symlink())
    ]
    if untracked:
        paths = "\n".join(f"  {path.relative_to(ROOT)}" for path in untracked)
        raise SystemExit(f"Move the conflicting untracked files before syncing:\n{paths}")

    if args.check:
        if changed:
            paths = "\n".join(f"  {path.relative_to(ROOT)}" for path in changed)
            raise SystemExit(f"Run python3 scripts/sync-codex-packages.py to refresh:\n{paths}")
        return

    for destination in remove:
        destination.unlink()
    for source, destination in copy:
        destination.parent.mkdir(parents=True, exist_ok=True)
        if destination.is_symlink():
            destination.unlink()
        shutil.copy2(source, destination)
    print(f"Updated {len(changed)} Codex package files.")


if __name__ == "__main__":
    main()
