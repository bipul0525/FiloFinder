#!/bin/zsh
# Builds Filofinder.app without Xcode (PLAN D13):
#   Rust core → UniFFI Swift bindings → SwiftPM → .app bundle → codesign.
#
#   scripts/build.sh            release build into build/Filofinder.app
#   scripts/build.sh --debug    debug build (faster compile)
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

export MACOSX_DEPLOYMENT_TARGET=13.0
CORE="$ROOT/core"
APP_PKG="$ROOT/app"
FFI_INC="$APP_PKG/Sources/FilofinderFFI/include"
GEN_SWIFT="$APP_PKG/Sources/Filofinder/Generated"
LIB_DIR="$ROOT/build/lib"
BUNDLE="$ROOT/build/Filofinder.app"
# Ad-hoc ("-") until the self-signed identity exists (Phase 0 / S2).
SIGN_ID="${FILOFINDER_SIGN_ID:--}"

step() { print -P "%F{cyan}▸ $1%f" }

step "Rust core ($CONFIG)"
cargo_flags=(--manifest-path "$CORE/Cargo.toml" -p filofinder-ffi)
[[ $CONFIG == release ]] && cargo_flags+=(--release)
cargo build "${cargo_flags[@]}"
RUST_OUT="$CORE/target/$CONFIG"

step "Swift bindings (UniFFI)"
cargo build --manifest-path "$CORE/Cargo.toml" -p uniffi-bindgen --release -q
TMP_GEN="$(mktemp -d)"
# Library mode reads crate metadata via `cargo metadata`, so run inside the workspace.
(cd "$CORE" && "$CORE/target/release/uniffi-bindgen" generate --library "$RUST_OUT/libfilofinder_ffi.dylib" \
  --language swift --out-dir "$TMP_GEN" >/dev/null)
mkdir -p "$FFI_INC" "$GEN_SWIFT"
cp "$TMP_GEN"/*.h "$FFI_INC/"
cp "$TMP_GEN"/*.swift "$GEN_SWIFT/"
# SwiftPM picks up module.modulemap from the C target's include dir.
cp "$TMP_GEN"/*.modulemap "$FFI_INC/module.modulemap"
rm -rf "$TMP_GEN"

# Only the static library goes in the link dir, so the app never depends
# on a dylib at runtime.
mkdir -p "$LIB_DIR"
cp "$RUST_OUT/libfilofinder_ffi.a" "$LIB_DIR/"

step "Swift app ($CONFIG)"
swift build --package-path "$APP_PKG" -c "$CONFIG" \
  -Xlinker -L"$LIB_DIR"
BIN="$(swift build --package-path "$APP_PKG" -c "$CONFIG" --show-bin-path)/Filofinder"

step "Bundle"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN" "$BUNDLE/Contents/MacOS/Filofinder"
cp "$APP_PKG/Info.plist" "$BUNDLE/Contents/Info.plist"

step "Codesign (${SIGN_ID})"
codesign --force --sign "$SIGN_ID" --timestamp=none "$BUNDLE"
codesign --verify --strict "$BUNDLE"

print -P "%F{green}✓ $BUNDLE%f"
[[ $RUN == 1 ]] && open "$BUNDLE"
exit 0
