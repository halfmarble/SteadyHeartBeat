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

# ---------------------------------------------------------------------------
# ARM THE NEXT BUILD (2026-08-23, founder: "do the SteadyHeartBeat pubspec bump
# phase too" — the same mechanism ViroFlick, StringFusor and DashTales use).
#
# AUTO-INCREMENT WAS HERE BEFORE AND WAS REMOVED FOR A REAL REASON, recorded in
# the header above: it "drifted the display number one ahead of CFBundleVersion
# on every build". That is a Flutter-specific hazard and it is worth naming
# precisely, because getting it wrong again is easy — Dart is AOT-compiled
# BEFORE this phase runs, so anything this script changes cannot reach the build
# it runs in. A phase that bumped only the DISPLAY number therefore showed N+1
# while CFBundleVersion stayed N, and a reinstall with an unchanged
# CFBundleVersion is a silent no-op on device.
#
# The fix is to move BOTH numbers together, and to accept that they move for the
# NEXT build rather than this one — which is exactly what the siblings' xcconfig
# does, for the same underlying reason (an xcconfig is read at build start).
#
#   during this build   pubspec N   CFBundleVersion N   display N   consistent
#   after this phase    pubspec N+1                     display N+1
#   next build          pubspec N+1 CFBundleVersion N+1 display N+1 consistent
#
# ONLY FROM XCODE. Run standalone — which the header documents as the way to
# make a hand-edited pubspec take effect — this must stay a pure sync, or
# checking your work would silently cut a new build number every time.
if [ -n "${SRCROOT:-}" ]; then
    # A CI or release build that passes --build-number owns the number itself;
    # bumping pubspec underneath it would fight the caller.
    if [ -n "${FLUTTER_BUILD_NUMBER:-}" ] && [ "${FLUTTER_BUILD_NUMBER}" != "$BUILD" ]; then
        echo "Build number supplied externally (b$FLUTTER_BUILD_NUMBER); leaving pubspec at b$BUILD"
    else
        NEXT=$((BUILD + 1))
        sed -i '' "s/^version:\([[:space:]]*[0-9.]*\)+$BUILD$/version:\1+$NEXT/" "$PUBSPEC"
        if grep -qE "^version:[[:space:]]*[0-9.]+\+$NEXT$" "$PUBSPEC"; then
            # Move the display number WITH it, or the two drift by one — the
            # exact failure that got the old auto-increment removed.
            sed -i '' "s/kBuildNumber = '$BUILD'/kBuildNumber = '$NEXT'/" "$FILE"
            echo "Armed the next build: b$NEXT (pubspec and build_info together)"
        else
            echo "warning: could not advance $PUBSPEC; the next build would repeat b$BUILD" >&2
        fi
    fi
fi
