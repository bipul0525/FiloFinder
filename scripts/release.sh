#!/bin/zsh
# Prepares a release locally (publishes nothing):
#   build/release/vX.Y.Z/
#     Filofinder-X.Y.Z.zip   app archive (installer + Sparkle updates)
#     Filofinder-X.Y.Z.dmg   drag-to-Applications disk image
#     SHA256SUMS             checksums verified by install.sh
#     appcast.xml            Sparkle feed, EdDSA-signed
#
# Upload those four files to a GitHub Release tagged vX.Y.Z (see docs/RELEASING.md).
set -euo pipefail

ROOT="${0:A:h:h}"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$ROOT/app/Info.plist")
TAG="v$VERSION"
OUT="$ROOT/build/release/$TAG"
REPO="bipul0525/FiloFinder"
GENERATE_APPCAST="$(find "$ROOT/app/.build" -path '*Sparkle/bin/generate_appcast' -type f 2>/dev/null | head -1)"

step() { print -P "%F{cyan}▸ $1%f" }

step "Build $TAG (universal, signed)"
"$ROOT/scripts/build.sh"
APP="$ROOT/build/Filofinder.app"
if ! codesign -dr - "$APP" 2>&1 | grep -q 'certificate root = H"08266a7fc7a922901867bebe310216a1eb4e42eb"'; then
  echo "✗ The app is not signed with the Filofinder Dev certificate — refusing to package it." >&2
  exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT"

step "Zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/Filofinder-$VERSION.zip"

step "Disk image"
STAGE="$(mktemp -d)"
ditto "$APP" "$STAGE/Filofinder.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Filofinder $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$OUT/Filofinder-$VERSION.dmg"
rm -rf "$STAGE"

step "Checksums"
(cd "$OUT" && shasum -a 256 Filofinder-$VERSION.zip Filofinder-$VERSION.dmg > SHA256SUMS)

step "Sparkle appcast"
if [[ -n "$GENERATE_APPCAST" ]]; then
  # Signs the zip with the EdDSA update key (backup file, so no keychain dialog).
  APPCAST_DIR="$(mktemp -d)"
  cp "$OUT/Filofinder-$VERSION.zip" "$APPCAST_DIR/"
  "$GENERATE_APPCAST" --ed-key-file "$HOME/.filofinder-signing/sparkle-private-key.txt" \
    --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
    -o "$OUT/appcast.xml" "$APPCAST_DIR"
  rm -rf "$APPCAST_DIR"
else
  echo "  (Sparkle tools not found — run scripts/build.sh once to resolve the package)" >&2
fi

print -P "%F{green}✓ Release $TAG ready in $OUT%f"
ls -la "$OUT"
cat "$OUT/SHA256SUMS"
