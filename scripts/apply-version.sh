#!/bin/bash
# Patch a built `.app`'s Info.plist with version numbers derived from git.
#
# Usage:
#   scripts/apply-version.sh <path-to-app-bundle>
#
# Resolution rules (in priority order):
#   • CFBundleShortVersionString  ← $MARKETING_VERSION (if set, used verbatim)
#                                ← latest `v*` git tag with leading "v" stripped
#                                ← "0.0.0" if no tags exist
#   • CFBundleVersion             ← $BUILD_VERSION (if set, used verbatim)
#                                ← `git rev-list --count HEAD`  (monotonic)
#                                ← "1" if not a git repo
#
# This script never modifies the source `Info.plist`; only the copy that's
# already inside the built bundle. Run it after copying Info.plist into
# "<bundle>/Contents/" and before code-signing.

set -euo pipefail

BUNDLE="${1:?Usage: $0 <path-to-app-bundle>}"
PLIST="$BUNDLE/Contents/Info.plist"

if [ ! -f "$PLIST" ]; then
    echo "error: $PLIST not found" >&2
    exit 1
fi

if [ -n "${MARKETING_VERSION:-}" ]; then
    SHORT_VERSION="$MARKETING_VERSION"
elif TAG=$(git describe --tags --abbrev=0 2>/dev/null); then
    SHORT_VERSION="${TAG#v}"
else
    SHORT_VERSION="0.0.0"
fi

if [ -n "${BUILD_VERSION:-}" ]; then
    BUILD_NUMBER="$BUILD_VERSION"
elif BUILD_NUMBER=$(git rev-list --count HEAD 2>/dev/null); then
    :
else
    BUILD_NUMBER="1"
fi

# `plutil -replace` adds the key if missing, otherwise overwrites.
plutil -replace CFBundleShortVersionString -string "$SHORT_VERSION" "$PLIST"
plutil -replace CFBundleVersion           -string "$BUILD_NUMBER"  "$PLIST"

echo "Versioned $BUNDLE: short=$SHORT_VERSION, build=$BUILD_NUMBER"
