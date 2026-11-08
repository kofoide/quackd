#!/bin/bash
# Build Quackd.app (menu bar controller for the quackd service).
# Usually run via `make app` / `make install-app`.
#
#   app/build.sh [output-dir]    build <output-dir>/Quackd.app (default: build/)
#
# Needs only the Xcode Command Line Tools (swiftc); no Xcode project.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SCRIPT="$ROOT/bin/quackd"
OUT="${1:-$ROOT/build}"
APP="$OUT/Quackd.app"
EXE_NAME="QuackdMenu"
MIN_MACOS="13.0"   # MenuBarExtra and SMAppService need macOS 13+

[[ -f "$SCRIPT" ]] || { echo "build.sh: quackd script not found at $SCRIPT" >&2; exit 1; }
command -v swiftc >/dev/null || { echo "build.sh: swiftc not found (run: xcode-select --install)" >&2; exit 1; }

# One version for the script and the app: read it from the script.
VERSION="$(sed -n 's/^QUACKD_VERSION="\(.*\)"$/\1/p' "$SCRIPT")"
[[ -n "$VERSION" ]] || { echo "build.sh: QUACKD_VERSION not found in $SCRIPT" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Universal binary (Apple Silicon + Intel) so a downloaded release runs on any Mac.
# The x86_64 link may warn "ignoring file ... libswiftCompatibilityPacks.a ... missing
# arch 'x86_64'": harmless, the app doesn't use Swift parameter packs.
echo "Compiling Quackd ${VERSION}…"
OBJ="$(mktemp -d)"
trap 'rm -rf "$OBJ"' EXIT
for arch in arm64 x86_64; do
  swiftc -O -parse-as-library -swift-version 5 \
    -target "$arch-apple-macos$MIN_MACOS" \
    -o "$OBJ/$EXE_NAME-$arch" \
    "$HERE/QuackdMenu.swift"
done
lipo -create -output "$APP/Contents/MacOS/$EXE_NAME" "$OBJ/$EXE_NAME-arm64" "$OBJ/$EXE_NAME-x86_64"

sed -e "s|@EXE_NAME@|$EXE_NAME|g" \
    -e "s|@MIN_MACOS@|$MIN_MACOS|g" \
    -e "s|@VERSION@|$VERSION|g" \
    "$HERE/Info.plist" >"$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# The app carries its own copy of the script; at launch it installs it to
# ~/Library/Application Support/quackd/quackd.
install -m 755 "$SCRIPT" "$APP/Contents/Resources/quackd"

# Ad-hoc signature: enough to run on the Mac that built it (no developer account).
codesign --force --sign - "$APP" 2>/dev/null
echo "Built $APP"
