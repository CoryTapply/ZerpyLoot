#!/bin/sh
# Prints the "## <version>" section of CHANGELOG.md (up to the next "## "
# heading), without the heading itself. Exits 1 if there's no such section,
# so a release can't go out without changelog notes.
set -eu
cd "$(dirname "$0")/.."

version=${1:?usage: tools/changelog-section.sh <version>}

awk -v want="$version" '
    /^## / {
        heading = substr($0, 4);
        sub(/ \(pre-release\)$/, "", heading);
        if (found) exit;
        if (heading == want) { found = 1; next; }
    }
    found { print }
    END { exit found ? 0 : 1 }
' CHANGELOG.md || { echo "No \"## $version\" section in CHANGELOG.md." >&2; exit 1; }
