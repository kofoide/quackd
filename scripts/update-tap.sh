#!/bin/bash
# Point the Homebrew tap at a quackd release. In a checkout of kofoide/homebrew-tap,
# it updates the formula's url and sha256 (the tag's source tarball) and the cask's
# version and sha256 (the release's app zip). It doesn't commit.
#
#   scripts/update-tap.sh <tap-dir> <version> [<path/to/Quackd-X.Y.Z.zip>]
#
# The release workflow runs this after publishing a release, then commits and pushes
# the tap. To do it by hand once the release exists:
#   scripts/update-tap.sh ~/projects/homebrew-tap 1.7.0
# Without a zip path, the zip's checksum comes from the release's SHA256SUMS.
set -euo pipefail

usage() { echo "usage: scripts/update-tap.sh <tap-dir> <version> [<Quackd-X.Y.Z.zip>]" >&2; exit 1; }
die() { echo "update-tap: $*" >&2; exit 1; }

[[ $# -ge 2 ]] || usage
TAP="$1" VERSION="${2#v}" ZIP="${3:-}"
REPO="kofoide/quackd"
FORMULA="$TAP/Formula/quackd.rb"
CASK="$TAP/Casks/quackd-menu.rb"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must look like 1.2.3 (got: $VERSION)"
[[ -f "$FORMULA" ]] || die "formula not found: $FORMULA"

is_sha() { [[ "$1" =~ ^[0-9a-f]{64}$ ]]; }

# The formula installs from GitHub's source tarball for the tag. Hash what GitHub
# actually serves, since that's what `brew install` will download and check.
TARBALL_URL="https://github.com/$REPO/archive/refs/tags/v$VERSION.tar.gz"
TARBALL_SHA="$(curl -fsSL --retry 5 "$TARBALL_URL" 2>/dev/null | shasum -a 256 | cut -d' ' -f1)" \
  || die "could not download $TARBALL_URL (has tag v$VERSION been pushed?)"
is_sha "$TARBALL_SHA" || die "could not download $TARBALL_URL"

# The cask installs the app zip attached to the release.
if [[ -n "$ZIP" ]]; then
  [[ -f "$ZIP" ]] || die "zip not found: $ZIP"
  ZIP_SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
else
  ZIP_SHA="$(curl -fsSL --retry 5 "https://github.com/$REPO/releases/download/v$VERSION/SHA256SUMS" 2>/dev/null \
    | awk -v f="Quackd-$VERSION.zip" '$2 == f { print $1 }')" || ZIP_SHA=""
fi
is_sha "$ZIP_SHA" || die "no checksum for Quackd-$VERSION.zip (is the v$VERSION release published?)"

# Replace whole lines, matched by their two-space indent, so nothing else in the
# files can match. Then check each new line really is there.
sed -i '' -E \
  -e "s|^  url \".*\"$|  url \"$TARBALL_URL\"|" \
  -e "s|^  sha256 \"[0-9a-f]*\"$|  sha256 \"$TARBALL_SHA\"|" \
  "$FORMULA"
grep -qxF "  url \"$TARBALL_URL\"" "$FORMULA" || die "couldn't update url in $FORMULA"
grep -qxF "  sha256 \"$TARBALL_SHA\"" "$FORMULA" || die "couldn't update sha256 in $FORMULA"
ruby -c "$FORMULA" >/dev/null
echo "Formula: v$VERSION  sha256 $TARBALL_SHA"

if [[ -f "$CASK" ]]; then
  sed -i '' -E \
    -e "s|^  version \".*\"$|  version \"$VERSION\"|" \
    -e "s|^  sha256 \"[0-9a-f]*\"$|  sha256 \"$ZIP_SHA\"|" \
    "$CASK"
  grep -qxF "  version \"$VERSION\"" "$CASK" || die "couldn't update version in $CASK"
  grep -qxF "  sha256 \"$ZIP_SHA\"" "$CASK" || die "couldn't update sha256 in $CASK"
  ruby -c "$CASK" >/dev/null
  echo "Cask:    $VERSION  sha256 $ZIP_SHA"
else
  echo "Cask:    skipped ($CASK not found)"
fi
