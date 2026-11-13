#!/bin/bash
# Builds the app at a given version and publishes it as a GitHub release.
# The app's updater picks up the newest release automatically.
#
#   ./release.sh 1.2.1 "Fixed start timecode for 25 fps bins"
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?Usage: ./release.sh VERSION \"release notes\"}"
NOTES="${2:-}"
TAG="v$VERSION"

if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
  echo "Version must look like 1.2.1" >&2; exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
  echo "Commit your changes first (git status isn't clean)." >&2; exit 1
fi
if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "Tag $TAG already exists - pick a higher version." >&2; exit 1
fi

VERSION="$VERSION" ./build_app.sh
git push origin HEAD
gh release create "$TAG" dist/Bin-Diff.zip \
  --target "$(git rev-parse HEAD)" \
  --title "Bin Diff $VERSION" \
  --notes "${NOTES:-Bin Diff $VERSION}"
echo "Released $TAG"
