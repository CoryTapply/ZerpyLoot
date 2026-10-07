#!/bin/sh
# Builds dist/ForeverLoot-<version>.zip from the committed HEAD, for manual
# upload to CurseForge. Files marked export-ignore in .gitattributes (docs,
# tools, editor config) are left out. The zip's one top-level folder is
# ForeverLoot/, matching the TOC name and Interface\AddOns\ForeverLoot paths.
set -eu
cd "$(dirname "$0")/.."

if [ -n "$(git status --porcelain)" ]; then
    echo "Working tree has uncommitted changes. Commit or stash them first." >&2
    exit 1
fi

version=$(sed -n 's/^## Version: *//p' ForeverLoot.toc | tr -d '\r')
if [ -z "$version" ]; then
    echo "No ## Version line found in ForeverLoot.toc." >&2
    exit 1
fi

mkdir -p dist
out="dist/ForeverLoot-$version.zip"
git archive --format=zip --prefix=ForeverLoot/ -o "$out" HEAD
echo "Built $out (version $version, commit $(git rev-parse --short HEAD))"

if ! git rev-parse -q --verify "refs/tags/v$version" >/dev/null; then
    echo "Note: no tag v$version yet. Tag this release with: git tag v$version"
fi
