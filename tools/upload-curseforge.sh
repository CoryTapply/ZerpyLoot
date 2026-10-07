#!/bin/sh
# Uploads a release zip to CurseForge. Run by .github/workflows/release.yml
# on a version tag push, and runnable locally the same way.
#
#   CF_API_KEY=... CF_GAME_VERSIONS=1234 tools/upload-curseforge.sh <zip> <version>
#
# The project id comes from the TOC's "## X-Curse-Project-ID". CF_GAME_VERSIONS
# is a comma-separated list of CurseForge game version ids (numbers). The
# release type follows the version: "alpha" or "beta" in it uploads as that
# type, anything else as a full release.
set -eu
cd "$(dirname "$0")/.."

zip=${1:?usage: tools/upload-curseforge.sh <zip> <version>}
version=${2:?usage: tools/upload-curseforge.sh <zip> <version>}
: "${CF_API_KEY:?CF_API_KEY is not set}"
: "${CF_GAME_VERSIONS:?CF_GAME_VERSIONS is not set (comma-separated CurseForge game version ids)}"

project_id=$(sed -n 's/^## X-Curse-Project-ID: *//p' ForeverLoot.toc | tr -d '\r')
if [ -z "$project_id" ]; then
    echo "No ## X-Curse-Project-ID line in ForeverLoot.toc." >&2
    exit 1
fi

case "$version" in
    *alpha*) release_type=alpha ;;
    *beta*) release_type=beta ;;
    *) release_type=release ;;
esac

changelog=$(tools/changelog-section.sh "$version")

metadata=$(jq -n \
    --arg changelog "$changelog" \
    --arg displayName "ForeverLoot $version" \
    --arg releaseType "$release_type" \
    --arg gameVersions "$CF_GAME_VERSIONS" \
    '{
        changelog: $changelog,
        changelogType: "markdown",
        displayName: $displayName,
        releaseType: $releaseType,
        gameVersions: ($gameVersions | split(",") | map(gsub("\\s"; "") | tonumber))
    }')

response=$(mktemp)
status=$(curl -sS -o "$response" -w '%{http_code}' \
    -H "X-Api-Token: $CF_API_KEY" \
    -F "metadata=$metadata" \
    -F "file=@$zip" \
    "https://wow.curseforge.com/api/projects/$project_id/upload-file")

if [ "$status" != "200" ]; then
    echo "CurseForge upload failed (HTTP $status):" >&2
    cat "$response" >&2
    echo >&2
    exit 1
fi

echo "Uploaded $zip to CurseForge project $project_id as $release_type: $(cat "$response")"
