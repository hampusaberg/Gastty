#!/usr/bin/env bash
# Builds libghostty as an xcframework that our Swift app can link against.
#
# Output: Frameworks/GhosttyKit.xcframework/
#
# This uses Ghostty's own build system (build.zig) which produces a fat
# xcframework (arm64 + arm64-simulator + x86_64 as configured) targeting macOS.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GHOSTTY="$ROOT/vendor/ghostty"
OUT="$ROOT/Frameworks"

# Ghostty pins to a specific Zig minor (currently 0.15.2). Homebrew's `zig`
# formula tracks latest stable, which is too new. Prefer the keg-only zig@0.15.
if [ -x /opt/homebrew/opt/zig@0.15/bin/zig ]; then
  export PATH="/opt/homebrew/opt/zig@0.15/bin:$PATH"
fi

ZIG_VERSION="$(zig version)"
case "$ZIG_VERSION" in
  0.15.*) ;;
  *)
    echo "error: need Zig 0.15.x to build Ghostty 1.3, got $ZIG_VERSION" >&2
    echo "  brew install zig@0.15" >&2
    exit 1
    ;;
esac

if [ ! -d "$GHOSTTY" ]; then
  echo "error: $GHOSTTY missing — run: git submodule update --init --recursive" >&2
  exit 1
fi

mkdir -p "$OUT"

cd "$GHOSTTY"

# `native` produces just the local machine's macOS arch slice. Avoids
# building iOS slices, which the runner's Xcode/iOS SDK may not support.
# Set XCFRAMEWORK_TARGET=universal to opt back in (release workflow does this).
XCFRAMEWORK_TARGET="${XCFRAMEWORK_TARGET:-native}"

echo "==> Building libghostty xcframework (target=$XCFRAMEWORK_TARGET, takes a few minutes)…"
zig build \
  -Doptimize=ReleaseFast \
  -Demit-xcframework=true \
  -Demit-macos-app=false \
  "-Dxcframework-target=$XCFRAMEWORK_TARGET"

# Ghostty installs the xcframework under macos/GhosttyKit.xcframework by default.
SRC_XCF="$GHOSTTY/macos/GhosttyKit.xcframework"
if [ ! -d "$SRC_XCF" ]; then
  # Fallback path in newer builds
  SRC_XCF="$GHOSTTY/zig-out/GhosttyKit.xcframework"
fi
if [ ! -d "$SRC_XCF" ]; then
  echo "error: xcframework not found after build. Searched:" >&2
  echo "  $GHOSTTY/macos/GhosttyKit.xcframework" >&2
  echo "  $GHOSTTY/zig-out/GhosttyKit.xcframework" >&2
  exit 2
fi

# Sync the framework into our Frameworks/ dir
rm -rf "$OUT/GhosttyKit.xcframework"
cp -R "$SRC_XCF" "$OUT/GhosttyKit.xcframework"

echo "==> xcframework ready at $OUT/GhosttyKit.xcframework"

# --- Copy resources (terminfo + shell-integration) -----------------
# Ghostty auto-discovers these by walking from the executable upward looking
# for a `terminfo/78/xterm-ghostty` sentinel. We put them into Resources/ so
# XcodeGen picks them up into the bundle.
RES_OUT="$ROOT/Resources"
SRC_RES="$GHOSTTY/zig-out/share"

rm -rf "$RES_OUT/terminfo" "$RES_OUT/ghostty"
mkdir -p "$RES_OUT/terminfo/78" "$RES_OUT/ghostty"

if [ -d "$SRC_RES/terminfo/78" ]; then
  cp -R "$SRC_RES/terminfo/78/xterm-ghostty" "$RES_OUT/terminfo/78/"
fi
if [ -d "$SRC_RES/ghostty/shell-integration" ]; then
  cp -R "$SRC_RES/ghostty/shell-integration" "$RES_OUT/ghostty/"
fi
if [ -d "$SRC_RES/ghostty/themes" ]; then
  cp -R "$SRC_RES/ghostty/themes" "$RES_OUT/ghostty/"
fi

echo "==> Resources copied to $RES_OUT"
