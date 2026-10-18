#!/usr/bin/env python3
# Reports which workspace packages still need publishing to pub.dev and/or
# git tag creation/pushing. Detection is read-only by default; --push-tags
# and --publish perform the actions with a per-item confirmation prompt.
#
# Usage:
#   tool/release_status.py            # detect only, exit 1 if action needed
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


def sh(*args, cwd=ROOT):
    return subprocess.run(args, cwd=cwd, capture_output=True, text=True)


def read_pubspec(path):
    text = path.read_text()
    name = re.search(r"^name:\s*(\S+)\s*$", text, re.M).group(1)
    version = re.search(r"^version:\s*(\S+)\s*$", text, re.M).group(1)
    return name, version


def key(version):
    return tuple(int(p) for p in version.split("."))


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


def main():
    ap = argparse.ArgumentParser(description="Detect (and optionally perform) pending package releases.")
    ap.add_argument("--push-tags", action="store_true", help="create missing tags and push unpushed ones, with confirmation")
    ap.add_argument("--publish", action="store_true", help="run dart pub publish for unpublished packages, with confirmation")
    args = ap.parse_args()

    pkgs = []
    for pubspec in sorted(ROOT.glob("packages/*/pubspec.yaml")):
        name, version = read_pubspec(pubspec)
        pkgs.append({"name": name, "version": version, "dir": pubspec.parent, "tag": f"{name}-v{version}"})

    with concurrent.futures.ThreadPoolExecutor(max_workers=len(pkgs)) as ex:
        pub = dict(zip([p["name"] for p in pkgs], ex.map(fetch_pubdev, [p["name"] for p in pkgs])))

    local_tags = set(sh("git", "tag", "--list").stdout.split())
    ls = sh("git", "ls-remote", "--tags", "origin")
    remote_tags = (
        {line.split()[1].removeprefix("refs/tags/").removesuffix("^{}") for line in ls.stdout.splitlines() if line}
        if ls.returncode == 0
        else None
    )

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
        rows.append({**p, "published": published or "-", "publish": publish, "tag": tag, "dirty": dirty})

    print(f"{'PACKAGE':<22} {'LOCAL':<9} {'PUB.DEV':<9} {'PUBLISH':<14} {'TAG':<16} DIRTY")
    for r in rows:
        print(f"{r['name']:<22} {r['version']:<9} {r['published']:<9} {r['publish'][0]:<14} {r['tag'][0]:<16} {'dirty' if r['dirty'] else 'clean'}")

    pending = [r for r in rows if r["publish"][1] or r["tag"][1]]
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
    if not pending and not args.push_tags and not args.publish:
        print("Everything is released: all tags pushed, all versions on pub.dev.")
    return 0 if not pending else 1


if __name__ == "__main__":
    sys.exit(main())
