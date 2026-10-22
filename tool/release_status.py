#!/usr/bin/env python3
# Reports which workspace packages still need publishing to pub.dev and/or
# git tag creation/pushing, and lints the docs, the skills and the version
# constraints for consistency with the package pubspecs. Detection is
# read-only by default; --push-tags and --publish perform the actions with a
# per-item confirmation prompt.
#
# Usage:
#   tool/release_status.py            # release status + lint; exit 1 if action is needed
#   tool/release_status.py --lint     # lint only (no network); exit 1 if anything is stale
#   tool/release_status.py --push-tags
#   tool/release_status.py --publish
import argparse
import concurrent.futures
import json
import re
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PUBDEV_API = "https://pub.dev/api/packages/{}"
TIMEOUT = 15
# Publish dependencies before their dependents.
PUBLISH_ORDER = ["sqlite_schema_forge", "sqlite_query_forge", "sqlite3_driver_forge", "fetch_forge"]
DOCS_PAGES = ROOT / "docs" / "src" / "pages"
INDEX_PAGE = DOCS_PAGES / "index.astro"
GUIDES_DIR = DOCS_PAGES / "guides"
ROOT_SKILLS = ROOT / "skills"


def sh(*args, cwd=ROOT):
    return subprocess.run(args, cwd=cwd, capture_output=True, text=True)


def read_pubspec(path):
    text = path.read_text()
    name = re.search(r"^name:\s*(\S+)\s*$", text, re.M).group(1)
    version = re.search(r"^version:\s*(\S+)\s*$", text, re.M).group(1)
    return name, version


def read_dependencies(pubspec_path):
    """Runtime dependencies of a pubspec as {name: constraint}."""
    deps = {}
    in_deps = False
    indent = None
    for line in pubspec_path.read_text().splitlines():
        if re.match(r"^[A-Za-z_]+:\s*$", line):
            in_deps = line.startswith("dependencies:")
            indent = None
            continue
        if not in_deps or not line.strip():
            continue
        current = len(line) - len(line.lstrip())
        if indent is None:
            indent = current
        if current != indent:
            # A nested mapping, such as the `sdk: flutter` under `flutter:`.
            continue
        m = re.match(r"^\s+([A-Za-z_][A-Za-z0-9_]*):\s*(.*)$", line)
        if m:
            deps[m.group(1)] = m.group(2).strip() or "sdk"
    return deps


def key(version):
    return tuple(int(p) for p in version.split("."))


def constraint_min(constraint):
    """The lowest version a constraint allows, or None when unknown."""
    m = re.match(r"^\^?(\d+)\.(\d+)\.(\d+)", constraint.strip())
    if not m:
        return None
    return (int(m.group(1)), int(m.group(2)), int(m.group(3)))


def constraint_allows(constraint, version):
    """Whether `version` satisfies `constraint`; None when unknown."""
    low = constraint_min(constraint)
    if low is None:
        return None
    v = key(version)
    if constraint.strip().startswith(">="):
        return v >= low
    if constraint.strip().startswith("^"):
        if low[0] == 0:
            # On 0.x a caret stops at the next minor: ^0.2.0 is >=0.2.0 <0.3.0.
            return v >= low and v[0] == 0 and v[1] == low[1]
        return v >= low and v[0] == low[0]
    return v == low


def find_constraint(text, name):
    """The version constraint a document states for `name`, or None.

    Only version-like tokens count, so a path-based dependency
    (`fetch_forge:` followed by `path: ../fetch_forge`) is not mistaken for
    a constraint.
    """
    m = re.search(r"^\s*" + re.escape(name) + r":\s*(\^?[0-9][0-9A-Za-z.+-]*)", text, re.M)
    return m.group(1) if m else None


def has_install_block(text):
    """Whether a document shows a dependencies block at all."""
    for block in re.findall(r"```yaml\n(.*?)```", text, re.S):
        if "dependencies:" in block:
            return True
    return "dependencies:" in text


def guide_file(name):
    return GUIDES_DIR / (name.replace("_", "-") + ".astro")


def fetch_pubdev(name):
    """(status, version): status is ok/missing/offline."""
    try:
        with urllib.request.urlopen(PUBDEV_API.format(name), timeout=TIMEOUT) as r:
            latest = json.load(r)["latest"]["version"]
            return ("ok", latest)
    except urllib.error.HTTPError as e:
        return ("missing", None) if e.code == 404 else ("offline", None)
    except Exception:
        return ("offline", None)


def confirm(prompt):
    return input(f"{prompt} [y/N] ").strip().lower() in ("y", "yes")


def lint_package(pkg):
    """Consistency checks for one package: (label, status, detail) tuples.

    status is "ok", "FAIL" or "skip".
    """
    name, version, directory = pkg["name"], pkg["version"], pkg["dir"]
    checks = []

    def check(label, ok, detail="", skipped=False):
        checks.append((label, "skip" if skipped else ("ok" if ok else "FAIL"), detail))

    index_text = INDEX_PAGE.read_text() if INDEX_PAGE.exists() else ""

    # The package card in the docs index.
    entry = re.search(r'pkg:\s*"' + re.escape(name) + r'"(?P<body>.*?)\n\s*\},', index_text, re.S)
    if not entry:
        check("docs index card", False, "no entry for this package")
    else:
        found = re.search(r'version:\s*"([^"]+)"', entry.group("body"))
        got = found.group(1) if found else "?"
        check("docs index card", got == version, got if got == version else f"{got} != {version}")

    # The static fallback heading the page shows before the script runs.
    heading = re.search(r'id="spec-pkg">\s*(\S+)\s*<span class="v">([^<]+)</span>', index_text)
    if not heading or heading.group(1) != name:
        check("docs card heading", True, "not the default card", skipped=True)
    else:
        got = heading.group(2)
        check("docs card heading", got == version, got if got == version else f"{got} != {version}")

    # The guide page: version badge, own constraint, dependency constraints.
    guide = guide_file(name)
    if not guide.exists():
        check("guide page", False, "missing")
        check("guide badge", False, "missing")
    else:
        guide_text = guide.read_text()
        found = re.search(r'<span class="ver">([^<]+)</span>', guide_text)
        got = found.group(1) if found else "?"
        check("guide badge", got == version, got if got == version else f"{got} != {version}")

        constraint = find_constraint(guide_text, name)
        if constraint is None:
            check("guide constraint", True, "none (dart pub add)", skipped=True)
        else:
            allows = constraint_allows(constraint, version)
            check("guide constraint", allows is not False, constraint if allows is not False else f"{constraint} excludes {version}")

        for dep, declared in read_dependencies(directory / "pubspec.yaml").items():
            if declared == "sdk" or "sdk:" in declared:
                continue
            stated = find_constraint(guide_text, dep)
            if stated is None:
                continue
            same = constraint_min(stated) == constraint_min(declared)
            check(f"guide dep {dep}", same, stated if same else f"{stated} != {declared}")

    # The README: own constraint and dependency constraints.
    readme = directory / "README.md"
    if not readme.exists():
        check("README", True, "none", skipped=True)
    else:
        readme_text = readme.read_text()
        constraint = find_constraint(readme_text, name)
        if constraint is None:
            check("README constraint", True, "none (dart pub add)", skipped=True)
        else:
            allows = constraint_allows(constraint, version)
            check("README constraint", allows is not False, constraint if allows is not False else f"{constraint} excludes {version}")

        if not has_install_block(readme_text):
            check("README deps", True, "no dependencies block", skipped=True)
        else:
            for dep, declared in read_dependencies(directory / "pubspec.yaml").items():
                if declared == "sdk" or "sdk:" in declared:
                    continue
                stated = find_constraint(readme_text, dep)
                if stated is None:
                    check(f"README dep {dep}", False, "not mentioned")
                else:
                    same = constraint_min(stated) == constraint_min(declared)
                    check(f"README dep {dep}", same, stated if same else f"{stated} != {declared}")

    # The skills: the package copy and the root copy must be identical.
    package_skills = directory / "skills"
    if not package_skills.is_dir():
        check("skills", True, "none", skipped=True)
    else:
        for skill in sorted(package_skills.iterdir()):
            if not skill.is_dir():
                continue
            source = skill / "SKILL.md"
            mirror = ROOT_SKILLS / skill.name / "SKILL.md"
            if not source.exists():
                check(f"skill {skill.name}", False, "missing SKILL.md")
            elif not mirror.exists():
                check(f"skill {skill.name}", False, "no root copy")
            elif source.read_bytes() != mirror.read_bytes():
                check(f"skill {skill.name}", False, "root copy differs")
            else:
                check(f"skill {skill.name}", True, "in sync")

    # The changelog must carry the version that is about to ship.
    changelog = directory / "CHANGELOG.md"
    if not changelog.exists():
        check("changelog", True, "none", skipped=True)
    else:
        has_entry = re.search(r"^##\s*" + re.escape(version) + r"\s*$", changelog.read_text(), re.M)
        check("changelog", bool(has_entry), version if has_entry else f"no ## {version} entry")

    return checks


def print_lint(pkgs):
    """Print the consistency report; returns the number of failures."""
    failures = 0
    print("CONSISTENCY LINT")
    print()
    for pkg in pkgs:
        checks = lint_package(pkg)
        bad = [c for c in checks if c[1] == "FAIL"]
        failures += len(bad)
        state = "FAIL" if bad else "ok"
        print(f"{pkg['name']} {pkg['version']}  [{state}]")
        for label, status, detail in checks:
            marker = {"ok": "ok  ", "FAIL": "FAIL", "skip": "skip"}[status]
            print(f"  {marker} {label:<22} {detail}")
        print()
    return failures


def main():
    ap = argparse.ArgumentParser(description="Detect (and optionally perform) pending package releases, and lint the docs for consistency.")
    ap.add_argument("--lint", action="store_true", help="run only the docs/skills/constraint consistency checks, without touching the network")
    ap.add_argument("--push-tags", action="store_true", help="create missing tags and push unpushed ones, with confirmation")
    ap.add_argument("--publish", action="store_true", help="run dart pub publish for unpublished packages, with confirmation")
    args = ap.parse_args()

    pkgs = []
    for pubspec in sorted(ROOT.glob("packages/*/pubspec.yaml")):
        name, version = read_pubspec(pubspec)
        pkgs.append({"name": name, "version": version, "dir": pubspec.parent, "tag": f"{name}-v{version}"})

    if args.lint:
        failures = print_lint(pkgs)
        print()
        if failures:
            print(f"{failures} check(s) failed. Fix the docs, the skills or the constraints before publishing.")
        else:
            print("Docs, skills and version constraints are consistent with the pubspecs.")
        return 1 if failures else 0

    with concurrent.futures.ThreadPoolExecutor(max_workers=len(pkgs)) as ex:
        pub = dict(zip([p["name"] for p in pkgs], ex.map(fetch_pubdev, [p["name"] for p in pkgs])))

    local_tags = set(sh("git", "tag", "--list").stdout.split())
    ls = sh("git", "ls-remote", "--tags", "origin")
    remote_tags = (
        {line.split()[1].removeprefix("refs/tags/").removesuffix("^{}") for line in ls.stdout.splitlines() if line}
        if ls.returncode == 0
        else None
    )

    lint = {p["name"]: lint_package(p) for p in pkgs}

    rows = []
    for p in pkgs:
        status, published = pub[p["name"]]
        if status == "offline":
            publish = ("unknown", False)
        elif status == "missing":
            publish = ("NEEDS PUBLISH", True)
        elif published == p["version"]:
            publish = ("up to date", False)
        elif key(p["version"]) > key(published):
            publish = ("NEEDS PUBLISH", True)
        else:
            publish = ("local behind!", False)

        if p["tag"] not in local_tags:
            tag = ("NEEDS CREATE", True)
        elif remote_tags is None:
            tag = ("remote?", False)
        elif p["tag"] in remote_tags:
            tag = ("pushed", False)
        else:
            tag = ("NEEDS PUSH", True)

        dirty = bool(sh("git", "status", "--porcelain", "--", str(p["dir"])).stdout.strip())
        failed = [c for c in lint[p["name"]] if c[1] == "FAIL"]
        docs = ("STALE" if failed else "ok")
        rows.append({**p, "published": published or "-", "publish": publish, "tag": tag, "dirty": dirty, "docs": docs, "failed": failed})

    print(f"{'PACKAGE':<22} {'LOCAL':<9} {'PUB.DEV':<9} {'PUBLISH':<14} {'TAG':<16} {'DOCS':<6} DIRTY")
    for r in rows:
        print(f"{r['name']:<22} {r['version']:<9} {r['published']:<9} {r['publish'][0]:<14} {r['tag'][0]:<16} {r['docs']:<6} {'dirty' if r['dirty'] else 'clean'}")

    pending = [r for r in rows if r["publish"][1] or r["tag"][1]]
    stale = [r for r in rows if r["failed"]]
    for r in stale:
        print()
        print(f"{r['name']}: docs, skills or constraints are out of date:")
        for label, _status, detail in r["failed"]:
            print(f"  - {label}: {detail}")
    if args.push_tags:
        for r in rows:
            tag_name = f"{r['name']}-v{r['version']}"
            if r["tag"][1] and confirm(f"Push tag {tag_name} ({'create + push' if r['tag'][0] == 'NEEDS CREATE' else 'push'})?"):
                if r["tag"][0] == "NEEDS CREATE":
                    sh("git", "tag", "-a", tag_name, "-m", f"{r['name']} {r['version']}")
                rc = sh("git", "push", "origin", tag_name).returncode
                print("pushed" if rc == 0 else "push FAILED")
    if args.publish:
        ordered = sorted([r for r in rows if r["publish"][1]], key=lambda r: (PUBLISH_ORDER.index(r["name"]) if r["name"] in PUBLISH_ORDER else 99))
        for r in ordered:
            if r["dirty"]:
                print(f"Skipping {r['name']}: working tree dirty, commit first.")
                continue
            if confirm(f"Publish {r['name']} {r['version']} to pub.dev?"):
                rc = subprocess.run(["dart", "pub", "publish"], cwd=r["dir"]).returncode
                print("published" if rc == 0 else "publish FAILED")

    print()
    if not pending and not stale and not args.push_tags and not args.publish:
        print("Everything is released: all tags pushed, all versions on pub.dev, docs in sync.")
    return 1 if pending or stale else 0


if __name__ == "__main__":
    sys.exit(main())
