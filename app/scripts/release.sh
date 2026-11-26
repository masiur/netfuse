#!/bin/sh
# Builds Nethance.app, zips it and publishes it as a GitHub release, which install.sh downloads.
# Usage: scripts/release.sh 0.2.0   (tags v0.2.0 on the current commit and pushes the tag)
set -eu
cd "$(dirname "$0")/.."
[ $# -eq 1 ] || { echo "usage: $0 VERSION" >&2; exit 2; }
[ -z "$(git status --porcelain)" ] || { echo "commit your changes first" >&2; exit 1; }
VERSION=$1 scripts/bundle.sh
# The asset keeps one name so releases/latest/download/Nethance.zip always points at the newest.
rm -f build/Nethance.zip
ditto -c -k --keepParent build/Nethance.app build/Nethance.zip
git tag "v$1"
git push origin "v$1"
gh release create "v$1" build/Nethance.zip --title "Nethance $1" --generate-notes
