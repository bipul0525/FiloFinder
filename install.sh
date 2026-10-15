#!/bin/bash
# Filofinder installer — https://github.com/bipul0525/filofinder
#
#   curl -fsSL https://raw.githubusercontent.com/bipul0525/filofinder/main/install.sh | bash
#
# What it does (read it before running — that's good practice):
#   1. downloads the latest release from GitHub
#   2. verifies its SHA-256 checksum
#   3. checks the app is signed with the Filofinder certificate (rejects anything else)
#   4. installs it to /Applications (or ~/Applications without admin rights)
#   5. removes the download quarantine flag, so macOS doesn't call it "damaged"
#   6. opens Filofinder
set -euo pipefail

REPO="bipul0525/filofinder"
# The Filofinder Dev signing certificate (SHA-1). Builds signed by anything
# else are refused.
CERT_HASH="08266a7fc7a922901867bebe310216a1eb4e42eb"

info() { printf '\033[36m▸\033[0m %s\n' "$*"; }
fail() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "Filofinder is a macOS app."
major=$(sw_vers -productVersion | cut -d. -f1)
(( major >= 13 )) || fail "Filofinder needs macOS 13 Ventura or newer (this Mac has $(sw_vers -productVersion))."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

if [[ -n "${FILOFINDER_RELEASE_DIR:-}" ]]; then
  # Local testing: use files from a release folder instead of GitHub.
  zip=$(cd "$FILOFINDER_RELEASE_DIR" && ls Filofinder-*.zip | head -1)
  info "Using local release $zip"
  cp "$FILOFINDER_RELEASE_DIR/$zip" "$FILOFINDER_RELEASE_DIR/SHA256SUMS" "$tmp/"
else
  info "Finding the latest release…"
  tag=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | grep -m1 '"tag_name"' | cut -d'"' -f4)
  [[ -n "$tag" ]] || fail "Couldn't find a release. Check your connection, or download from https://github.com/$REPO/releases"
  zip="Filofinder-${tag#v}.zip"
  base="https://github.com/$REPO/releases/download/$tag"
  info "Downloading Filofinder ${tag#v}…"
  curl -fL --progress-bar "$base/$zip" -o "$tmp/$zip"
  curl -fsSL "$base/SHA256SUMS" -o "$tmp/SHA256SUMS"
fi

info "Verifying checksum…"
(cd "$tmp" && grep " $zip\$" SHA256SUMS | shasum -a 256 -c - >/dev/null) || fail "Checksum mismatch — the download is corrupted or was tampered with. Nothing was installed."

ditto -x -k "$tmp/$zip" "$tmp/x"
app="$tmp/x/Filofinder.app"
[[ -d "$app" ]] || fail "The archive doesn't contain Filofinder.app."

info "Checking the signature…"
codesign --verify --deep --strict "$app" 2>/dev/null || fail "The app's signature is invalid. Nothing was installed."
codesign -dr - "$app" 2>&1 | grep -q "certificate root = H\"$CERT_HASH\"" \
  || fail "This app isn't signed with the Filofinder certificate. Nothing was installed."

dest="${FILOFINDER_INSTALL_DIR:-/Applications}"
if [[ ! -w "$dest" ]]; then
  dest="$HOME/Applications"
  info "No write access to /Applications — installing to $dest"
fi
mkdir -p "$dest"

if pgrep -xq Filofinder; then
  info "Quitting the running Filofinder…"
  osascript -e 'quit app "Filofinder"' 2>/dev/null || true
  sleep 1
fi

info "Installing to $dest…"
rm -rf "$dest/Filofinder.app"
ditto "$app" "$dest/Filofinder.app"
# Downloads from the internet carry a quarantine flag; without Apple's paid
# notarization macOS would then refuse to open the app ("damaged").
xattr -dr com.apple.quarantine "$dest/Filofinder.app" 2>/dev/null || true

printf '\033[32m✓ Filofinder installed in %s\033[0m\n' "$dest"
echo "  On first launch, Filofinder asks for Full Disk Access so it can show every folder."
echo "  Updates install automatically from now on."
[[ -n "${FILOFINDER_NO_OPEN:-}" ]] || open "$dest/Filofinder.app"
