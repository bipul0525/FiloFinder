#!/bin/zsh
# Builds Filofinder.app without Xcode (PLAN D13):
#   Rust core → UniFFI Swift bindings → SwiftPM → .app bundle → codesign.
#
#   scripts/build.sh            universal release (Apple Silicon + Intel, macOS 13+)
#   scripts/build.sh --debug    native-arch debug build (fast; includes test hooks)
#   scripts/build.sh --run      build, then launch
set -euo pipefail

ROOT="${0:A:h:h}"
CONFIG=release
RUN=0
for arg in "$@"; do
  case $arg in
    --debug) CONFIG=debug ;;
    --run) RUN=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

# rustup's toolchain (not Homebrew's): its std library targets old macOS
# versions and ships both Apple Silicon and Intel targets.
export PATH="$HOME/.cargo/bin:$PATH"
export MACOSX_DEPLOYMENT_TARGET=13.0

CORE="$ROOT/core"
APP_PKG="$ROOT/app"
FFI_INC="$APP_PKG/Sources/FilofinderFFI/include"
GEN_SWIFT="$APP_PKG/Sources/Filofinder/Generated"
LIB_DIR="$ROOT/build/lib"
BUNDLE="$ROOT/build/Filofinder.app"
# Stable self-signed identity when present (keeps macOS permissions across
# updates); ad-hoc otherwise.
# The identity lives in its own keychain (password in ~/.filofinder-signing),
# so signing never needs an approval dialog.
SIGN_KC="$HOME/Library/Keychains/filofinder-signing.keychain-db"
SIGN_KC_PASS="$HOME/.filofinder-signing/keychain-password.txt"
CODESIGN_KC=()
if [[ -z "${FILOFINDER_SIGN_ID:-}" && -f "$SIGN_KC" && -f "$SIGN_KC_PASS" ]]; then
  security unlock-keychain -p "$(cat "$SIGN_KC_PASS")" "$SIGN_KC"
  SIGN_ID="Filofinder Dev"
  CODESIGN_KC=(--keychain "$SIGN_KC")
else
  SIGN_ID="${FILOFINDER_SIGN_ID:--}"
fi

if [[ $CONFIG == release ]]; then
  ARCHS=(arm64 x86_64)
else
  ARCHS=($(uname -m))
fi
rust_target() { [[ $1 == arm64 ]] && echo aarch64-apple-darwin || echo x86_64-apple-darwin }

step() { print -P "%F{cyan}▸ $1%f" }

step "Rust core ($CONFIG: ${ARCHS[*]})"
LIBS=()
for arch in $ARCHS; do
  t=$(rust_target $arch)
  flags=(--manifest-path "$CORE/Cargo.toml" -p filofinder-ffi --target "$t")
  [[ $CONFIG == release ]] && flags+=(--release)
  cargo build "${flags[@]}"
  LIBS+=("$CORE/target/$t/$CONFIG/libfilofinder_ffi.a")
done
FIRST_OUT="$CORE/target/$(rust_target ${ARCHS[1]})/$CONFIG"

step "Swift bindings (UniFFI)"
cargo build --manifest-path "$CORE/Cargo.toml" -p uniffi-bindgen --release -q
TMP_GEN="$(mktemp -d)"
# Library mode reads crate metadata via `cargo metadata`, so run inside the workspace.
(cd "$CORE" && "$CORE/target/release/uniffi-bindgen" generate --library "$FIRST_OUT/libfilofinder_ffi.dylib" \
  --language swift --out-dir "$TMP_GEN" >/dev/null)
mkdir -p "$FFI_INC" "$GEN_SWIFT"
cp "$TMP_GEN"/*.h "$FFI_INC/"
cp "$TMP_GEN"/*.swift "$GEN_SWIFT/"
# SwiftPM picks up module.modulemap from the C target's include dir.
cp "$TMP_GEN"/*.modulemap "$FFI_INC/module.modulemap"
rm -rf "$TMP_GEN"

# Only the (universal) static library goes in the link dir, so the app never
# depends on a dylib at runtime.
mkdir -p "$LIB_DIR"
lipo -create "${LIBS[@]}" -output "$LIB_DIR/libfilofinder_ffi.a"

step "Swift app ($CONFIG: ${ARCHS[*]})"
BINS=()
for arch in $ARCHS; do
  scratch="$APP_PKG/.build/$arch"
  swift build --package-path "$APP_PKG" -c "$CONFIG" --arch "$arch" --scratch-path "$scratch" \
    -Xlinker -L"$LIB_DIR" -Xswiftc -target -Xswiftc "$arch-apple-macosx13.0"
  BINS+=("$(swift build --package-path "$APP_PKG" -c "$CONFIG" --arch "$arch" --scratch-path "$scratch" --show-bin-path)/Filofinder")
done

step "Bundle"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources" "$BUNDLE/Contents/Frameworks"
lipo -create "${BINS[@]}" -output "$BUNDLE/Contents/MacOS/Filofinder"
cp "$APP_PKG/Info.plist" "$BUNDLE/Contents/Info.plist"
[[ -f "$APP_PKG/Resources/AppIcon.icns" ]] && cp "$APP_PKG/Resources/AppIcon.icns" "$BUNDLE/Contents/Resources/"
# Sparkle (auto-updates), when the package has been resolved.
SPARKLE="$(find "$APP_PKG/.build/${ARCHS[1]}" -path '*macos-arm64_x86_64/Sparkle.framework' -maxdepth 8 -type d 2>/dev/null | head -1)"
[[ -n "$SPARKLE" ]] && ditto "$SPARKLE" "$BUNDLE/Contents/Frameworks/Sparkle.framework"

step "Codesign (${SIGN_ID})"
# Sparkle.framework keeps its own (Sparkle project) signature — it is valid
# as shipped, and an app may embed frameworks signed by someone else.
codesign --force --sign "$SIGN_ID" "${CODESIGN_KC[@]}" --timestamp=none "$BUNDLE"
codesign --verify --strict "$BUNDLE"

print -P "%F{green}✓ $BUNDLE ($(lipo -archs "$BUNDLE/Contents/MacOS/Filofinder"))%f"
[[ $RUN == 1 ]] && open "$BUNDLE"
exit 0
