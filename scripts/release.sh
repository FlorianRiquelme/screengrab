#!/bin/bash
# Builds build/Screengrab-<version>.zip for a GitHub Release and prints the sha256 for the Homebrew cask.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=${1:?usage: scripts/release.sh <version>}

VERSION=$VERSION scripts/build.sh --no-install
ZIP="build/Screengrab-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent build/Screengrab.app "$ZIP"
echo "$ZIP"
shasum -a 256 "$ZIP"
