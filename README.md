<p align="center"><img src="docs/icon.png" width="128" alt="Filofinder icon"></p>

<h1 align="center">FiloFinder</h1>

<p align="center">A fast, free, open-source file manager for macOS — with real Cut &amp; Paste.</p>

---

Filofinder is a Finder alternative built for speed:
- **Native Mac app:** an AppKit interface over a Rust core, smooth at 120 Hz.
- **Large folders:** lists 100,000-item folders in about a tenth of a second.
- **Small:** around 7 MB.

## Features

- **Real Cut & Paste** (⌘X → ⌘V moves files), plus copy, duplicate, rename and new folder, with **undo** (⌘Z).
- **Never overwrites silently:**
  - Name conflicts ask whether to *Keep Both*, *Replace* or *Skip*.
  - Copies are written under a temporary name first, so a crash never leaves a half-copied file.
  - Moves between drives delete the original only after the copy is verified.
- **Split view** (⌘M) for moving files between two folders, and **tabs**.
- **Drag & drop** between folders, panes, the sidebar and other apps.
- **Quick Look** (Space) and a preview pane for every file type macOS can preview.
- **Colour tags:** tag files from the right-click menu, and browse every tagged file from the sidebar.
- **Trash** inside the app, with *Put Back* and *Empty Trash*.
- **Fast, clean ZIP extraction** (double-click a .zip):
  - Parallel, and skips `.DS_Store` / `__MACOSX` junk.
  - Protected against malicious archives.
- **Live refresh:** folders update when files change elsewhere.
- **Grid and list views, adjustable icon and text size,** and Finder's keyboard shortcuts.

## Install

Requires **macOS 13 Ventura or newer**, on Apple Silicon or Intel.

### Option 1 — One-line install (recommended)

Open **Terminal** (⌘Space → type *Terminal*) and paste:

```sh
curl -fsSL https://raw.githubusercontent.com/bipul0525/FiloFinder/main/install.sh | bash
```

This downloads the latest release, **verifies its checksum and signature**, installs it in `/Applications`, removes the download quarantine and opens it. Nothing else needed. You're welcome to [read the script first](install.sh).

### Option 2 — Install from the DMG

1. Download **`Filofinder-x.y.z.dmg`** from [Releases](https://github.com/bipul0525/FiloFinder/releases/latest).
2. Double-click the DMG and drag **Filofinder** onto **Applications**.
3. Eject the DMG.
4. **Allow it to run (once).** FiloFinder is free and isn't notarised by Apple (that needs a paid $99/year developer account), so macOS blocks the first launch and may say the app *"is damaged"* or *"can't be verified"*. It isn't damaged. Open **Terminal** and paste:

   ```sh
   xattr -dr com.apple.quarantine /Applications/Filofinder.app && open /Applications/Filofinder.app
   ```

   This only removes the "downloaded from the internet" flag from FiloFinder; it doesn't change any system security setting.

   **Without Terminal:** try to open the app once, then go to **System Settings → Privacy & Security**, scroll down and click **Open Anyway** next to the Filofinder message, and confirm.

You only do this once — updates install automatically afterwards.

### First launch

Filofinder asks for **Full Disk Access** so it can show every folder (including the Trash) without macOS asking again and again. Click **Open Settings**, switch Filofinder on, and come back; the window closes by itself. You only do this once, because the permission stays across updates.

### Updates

Filofinder checks for updates every 6 hours and installs them on relaunch. You can also use **Filofinder → Check for Updates…**. Every update is cryptographically signed and verified before it installs.

## Keyboard

| Keys | Action |
|---|---|
| Return / ⌘↓ | Open |
| ⌘[ · ⌘] · ⌘↑ | Back · Forward · Enclosing folder |
| ⌘C · ⌘X · ⌘V | Copy · Cut · Paste |
| ⌘D · F2 | Duplicate · Rename |
| ⌫ / Del | Move to Trash (asks first) |
| ⌘⌫ | Delete immediately (asks first) |
| ⌘Z | Undo |
| Space | Quick Look |
| ⌘M · ⇥ | Split view · Switch pane |
| ⌘T · ⌘W | New tab · Close window |
| ⌘1 · ⌘2 | List · Grid |
| ⌘+ · ⌘− | Zoom icons |
| ⌥⌘+ · ⌥⌘− | Name text size |
| ⇧⌘. | Show hidden files |
| ⇧⌘H · ⇧⌘G | Home · Go to folder |

## Build from source

Requirements:
- macOS 13+
- the Xcode **Command Line Tools** (`xcode-select --install`; the full Xcode app is not needed)
- [Rust via rustup](https://rustup.rs)

```sh
rustup target add aarch64-apple-darwin x86_64-apple-darwin
scripts/build.sh --debug --run    # fast native build, then launch
scripts/build.sh                  # universal release build → build/Filofinder.app
cd core && cargo test             # core test suite
```

The project has two halves:
- `core/` holds the Rust engine: listing, file operations and ZIP.
- `app/` holds the Swift/AppKit interface, connected to the core through [UniFFI](https://github.com/mozilla/uniffi-rs).

See [docs/PLAN.md](docs/PLAN.md) for the design.

## Privacy

Filofinder has no account and no telemetry. Its only network access is the update check against this repository's GitHub Releases.

## License

[MIT](LICENSE)
