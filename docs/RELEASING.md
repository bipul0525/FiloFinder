# Releasing Filofinder

## The keys (back these up!)

Everything lives in `~/.filofinder-signing/` on the release Mac. It is **never** committed.

| File | What it is | If lost |
|---|---|---|
| `FilofinderDev.p12` + `p12-password.txt` | The "Filofinder Dev" code-signing certificate (SHA-1 `08266A7F…42EB`, valid until 2046) | Users must re-grant Full Disk Access once, and `install.sh` / `release.sh` need the new hash |
| `sparkle-private-key.txt` | EdDSA key that signs updates (public key is in `app/Info.plist` → `SUPublicEDKey`) | **Installed copies can never auto-update again** (users must reinstall) |
| `keychain-password.txt` | Password of `~/Library/Keychains/filofinder-signing.keychain-db`, used by `scripts/build.sh` | Re-create the keychain from the `.p12` |

**Keep two offline copies** of the whole folder, for example an encrypted USB drive plus a password manager. Never rotate the certificate and the EdDSA key in the same release.

### Restoring on a new Mac
```sh
mkdir -p ~/.filofinder-signing && cp <backup>/* ~/.filofinder-signing/ && chmod 600 ~/.filofinder-signing/*
KC=~/Library/Keychains/filofinder-signing.keychain-db
security create-keychain -p "$(cat ~/.filofinder-signing/keychain-password.txt)" $KC
security set-keychain-settings $KC
security unlock-keychain -p "$(cat ~/.filofinder-signing/keychain-password.txt)" $KC
security import ~/.filofinder-signing/FilofinderDev.p12 -k $KC -P "$(cat ~/.filofinder-signing/p12-password.txt)" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$(cat ~/.filofinder-signing/keychain-password.txt)" $KC
security list-keychains -d user -s $(security list-keychains -d user | tr -d '"') $KC
```

## Cutting a release

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` (Sparkle compares this integer) in `app/Info.plist`.
2. `cd core && cargo test`, then run the app and go through the manual checklist below.
3. `scripts/release.sh` creates `build/release/vX.Y.Z/` containing the zip, the DMG, `SHA256SUMS` and `appcast.xml`.
4. Commit, tag `vX.Y.Z`, and push.
5. Create a GitHub Release for the tag and upload all four files. **`appcast.xml` must be attached to every release**, because installed apps read `releases/latest/download/appcast.xml`.
6. Test: `curl -fsSL https://raw.githubusercontent.com/bipul0525/filofinder/main/install.sh | bash` on a second Mac or user account.

## Manual checklist (until UI tests exist)
- [ ] Light and dark mode.
- [ ] Copy, cut/paste and drag between two folders, and between split panes; undo each.
- [ ] Name conflict: Keep Both, Replace and Skip.
- [ ] Move to Trash (asks), Put Back, Delete Immediately, Empty Trash.
- [ ] Double-click a .zip, including one with `__MACOSX` junk.
- [ ] External drive: copy to it, eject during idle.
- [ ] Update from the previous version keeps Full Disk Access.
- [ ] Intel: `arch -x86_64 /Applications/Filofinder.app/Contents/MacOS/Filofinder`.
