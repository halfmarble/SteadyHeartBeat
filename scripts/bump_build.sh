#!/bin/bash
# Syncs kBuildNumber in lib/build_info.dart FROM the build number in
# pubspec.yaml (the "version: x.y.z+BUILD" line).
#
# pubspec is the SINGLE SOURCE OF TRUTH for the build number:
#   - CFBundleVersion comes from it via $(FLUTTER_BUILD_NUMBER) in Info.plist.
#   - This script keeps the in-app display number (kBuildNumber, shown as "bN"
#     in the AppBar) equal to it.
# Result: the number on screen always equals CFBundleVersion.
#
# Idempotent — safe to run repeatedly (no drift). This replaces the old
# auto-increment, which drifted the display number one ahead of CFBundleVersion
# on every build and meant reinstalls with an unchanged CFBundleVersion were
# silent no-ops on device.
#
# ORDERING: in `flutter build ios`, Dart is AOT-compiled BEFORE this Xcode build
# phase runs, so to make the CURRENT build's display number correct, build_info
# must already be in sync with pubspec BEFORE `flutter build`. As a wired-in
# Xcode phase this script then serves as a backstop that keeps them from
# drifting. Running it standalone right after editing pubspec guarantees the
# next build is correct.
#
# To cut a new build: bump the "+N" in pubspec.yaml, run this script, then build.
set -e

# ${SRCROOT} is the ios/ folder when invoked from Xcode. When run standalone,
# fall back to the script's parent's parent (the repo root).
ROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
[ -d "$ROOT/../lib" ] && ROOT="$ROOT/.."
PUBSPEC="$ROOT/pubspec.yaml"
FILE="$ROOT/lib/build_info.dart"

for f in "$PUBSPEC" "$FILE"; do
    [ -f "$f" ] || { echo "error: $f not found" >&2; exit 1; }
done

BUILD=$(grep -oE "^version:[[:space:]]*[0-9.]+\+[0-9]+" "$PUBSPEC" | grep -oE "[0-9]+$")
if [ -z "$BUILD" ]; then
    echo "error: could not parse build number (version: x.y.z+N) in $PUBSPEC" >&2
    exit 1
fi

CURRENT=$(grep -oE "kBuildNumber = '[0-9]+'" "$FILE" | grep -oE "[0-9]+")
if [ -z "$CURRENT" ]; then
    echo "error: could not parse current build number in $FILE" >&2
    exit 1
fi

if [ "$CURRENT" = "$BUILD" ]; then
    echo "Build number already in sync: b$BUILD"
else
    sed -i '' "s/kBuildNumber = '$CURRENT'/kBuildNumber = '$BUILD'/" "$FILE"
    echo "Synced build number: b$CURRENT -> b$BUILD (from pubspec)"
fi
