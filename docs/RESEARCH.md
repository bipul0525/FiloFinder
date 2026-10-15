# Filofinder — Research

Research notes for **Filofinder**: a free, open-source macOS Finder alternative, built from scratch.
It is a successor to the File Manager tool in captools (`~/Documents/Yupcha Office/CODE/captools/src/components/tools/filemanager`).

Compiled 2026-10-09.

> **Superseded in part by [PLAN.md](PLAN.md):** the Tauri + React stack, the 120 fps target for a web view and the Tauri updater sections are out of date. Use PLAN.md for decisions.

> **How reliable is this?** The web research was a light pass, about two searches per topic. Most of the details on competitors, crate APIs and macOS internals come from model knowledge and are cited to canonical docs. Check prices, crate versions and anything marked *(verify)* before you rely on it.

---

## 1. Decision summary

| Decision | Choice | Why |
|---|---|---|
| App shell | **Tauri v2** | Bundle is roughly 3–10 MB and idle RAM roughly 40 MB, against roughly 85–250 MB and 170 MB+ for Electron. Keeps the React UI skills and patterns from captools. |
| Core | **Rust**, kept independent of the UI | Does all filesystem I/O, listing, copying, hashing, thumbnail caching and watching. Could later be reused from Swift if parts of the UI go native. |
| UI | **React + TypeScript**, virtualised (TanStack Virtual) | Captools already has working patterns for the grid/list layout, the dual pane and the rubber-band selection. |
| macOS APIs | **objc2** crates (`objc2-foundation`, `objc2-app-kit`, `objc2-quick-look-thumbnailing`) | Escape hatch: a small Swift static lib or sidecar for anything painful (for example the QLPreviewPanel). |
| Distribution | **Developer ID**, hardened runtime, notarised, DMG, Homebrew cask, `tauri-plugin-updater` on GitHub Releases | The App Sandbox is incompatible with a real file manager. |
| Minimum macOS | **13 Ventura** | The UI renders in WKWebView, whose features depend on the macOS version. |
| License | MIT or Apache-2.0 | Free with no Pro paywall is the differentiator (see §3). |

### Why not the captools approach (the browser File System Access API)?
- The File System Access API is Chromium-only, so it doesn't work in Tauri's WKWebView.
- It has no native move. Every move and rename is copy then delete, and that pattern caused the data-loss bugs listed in §6.
- It can't reach the Trash, Quick Look, tags, FSEvents or real paths, and permissions reset on every reload.

In Filofinder, **the webview never touches the filesystem**. Rust does all of it, and the UI only ever sees paths and file IDs.

### Alternatives considered
- **Electron:** it would run the captools code almost unchanged, but it costs about 10–20× the size and RAM. Users of file managers notice that, and Electron gives nothing else over Tauri here.
- **Native SwiftUI or AppKit:** the best native fidelity (NSTableView handling millions of rows, free Quick Look and drag support), but it means a full rewrite in an unfamiliar stack. SwiftUI `Table` and `List` still struggle at 100k rows, so you would end up wrapping AppKit views anyway. Revisit this only if WKWebView's feel becomes the bottleneck.

---

## 2. Architecture sketch

```
┌──────────────── React UI (WKWebView) ────────────────┐
│ Tabs · Dual pane · Virtual grid/list · Tree sidebar  │
│ Path bar · Command palette · Conflict dialog · Queue │
└──────┬─────────────────────┬─────────────────────┬───┘
   invoke()             Channel<T> streams     thumb://<id>?s=128
       │              (listing batches,        (custom URI protocol,
       │               progress, FS events)     served from cache)
┌──────▼─────────────────────▼─────────────────────▼───┐
│                    Rust core (crate)                 │
│ fs::list   getattrlistbulk, streamed in 2–5k batches │
│ fs::ops    job queue: copy/move/trash/delete/zip;    │
│            cancellable, progress, conflict callbacks │
│ fs::watch  FSEvents (notify crate) → per-dir rescan  │
│ thumbs     QLThumbnailGenerator → disk + LRU cache   │
│ undo       inverse-op journal (persisted)            │
│ macos      trash, tags, QuickLook panel, drag-out,   │
│            TCC/FDA detection, volume info            │
└──────────────────────────────────────────────────────┘
```

The key rules:
- **Listings stream** over `tauri::ipc::Channel` in compact batches, never as one giant JSON payload.
- **Thumbnails are never sent over IPC.** `<img src="thumb://...">` loads them from a custom async URI scheme, so the browser handles caching, lazy loading and parallel requests.
- **Every mutation is a job in one queue**, with an ID, progress, cancel, a conflict prompt and an undo record. This replaces the about six separate copy/move code paths in captools.
- **UI state is keyed by stable IDs** (inode/fileID plus volume ID), never by array index or bare name.

---

## 3. Competitive landscape

| App | Price / license | Stack | Known for | Common complaints |
|---|---|---|---|---|
| ForkLift 4 | ~$20/yr | Swift/AppKit | Most complete option: dual pane, sync, SFTP/S3, batch rename, quick-open | v4 regressions, pricing |
| Path Finder | ~$36/yr subscription | Obj-C | Huge feature set (drop stack, Git, terminal) | Slow, crashes, cluttered, subscription |
| Commander One | Free / Pro ~$30 | Native | Free dual pane | Pro upsell, dated UI |
| QSpace Pro | ~$15–25 | Native | 1–4 panes, many remote types | Thin docs, weaker keyboard support |
| Marta | Free, closed source | Swift + Lua | Fast, scriptable, keyboard-first | Development stalled |
| Fman | ~$29 | Python/Qt | Command palette | Abandoned, sluggish |
| Nimble Commander | GPL-3 | C++/ObjC++ | Very fast, archive VFS | Old-school look |
| Spacedrive | AGPL | Rust + Tauri | Cross-device index | Long-running alpha, heavy |
| Files (Windows) | MIT | C#/WinUI | UX reference: tabs, preview, tags | Slow cold start |
| yazi / superfile | MIT | Rust / Go (TUI) | Async I/O, previews, bulk rename in $EDITOR | Terminal only |

*(Prices are from memory; verify them on the vendor sites.)*

### Finder pain points to target
1. No dual pane, and weak tabs.
2. No discoverable Cut/Paste.
3. No editable path bar and no "go up" button.
4. Network and external drives delete permanently, and Trash restore is opaque.
5. Slow or blank thumbnails, spinning beachballs on network shares.
6. Can't browse inside a ZIP; no 7z/RAR support.
7. Hidden-files toggle is awkward.
8. View settings don't stick; `.DS_Store` litter.
9. Weak batch rename; no folder sizes.
10. Unreliable search with no instant filter.
11. No "open Terminal here".

### Differentiators for Filofinder
- **Free and open source with no paywall.**
- **Safe by design:**
  - every operation can be undone
  - a unified bin that also covers external and network volumes
  - a transfer queue with pause, resume and cancel
  - never overwrites silently
- **Keyboard first:**
  - command palette and fuzzy jump to frequently used folders
  - editable path bar and type-to-filter
  - optional Commander (F5/F6) and vim key maps
- **Archives as folders:** browse and extract zip, 7z, tar and rar.
- **Bulk rename** in $EDITOR, or with regex plus a live preview.
- **Folder sizes, duplicate finder and checksums.**
- **Developer tools:** open Terminal here, Git status badges, text/hex preview pane.
- **Later:** SFTP/S3 (the main reason people pay for ForkLift), plugins and themes.
- **Unique, carried over from captools:**
  - extract → sort → re-zip with a per-panel sort timer
  - the "just moved" highlight
  - spring-loaded tabs and breadcrumbs

---

## 4. macOS engineering checklist (recommended API, then pitfalls)

| Area | Use | Pitfalls |
|---|---|---|
| Copy | `copyfile(3)` with `COPYFILE_ALL \| COPYFILE_CLONE \| COPYFILE_RECURSIVE \| COPYFILE_NOFOLLOW` and a status callback | Clones only work on the same APFS volume. Copies to exFAT/SMB lose creation date and create `._` files. Cancel by returning `COPYFILE_QUIT`. |
| Move / rename | `renamex_np` with `RENAME_EXCL` (never overwrite silently); `RENAME_SWAP` to replace | Moves across volumes are not atomic: copy, verify, fsync, then delete. Compare `volumeIdentifierKey` to detect the volume change. |
| Names | Compare with NFC plus case-folding; check case sensitivity per volume (`volumeSupportsCaseSensitiveNamesKey`) | A case-only rename must call rename directly, because an "exists?" check says the file already exists. Expect NFD names from SMB/HFS. |
| Trash | `FileManager.trashItem(at:resultingItemURL:)` or `NSWorkspace.recycle` | "Put Back" needs Finder-private metadata. The `trash` crate's Finder/AppleScript method supports it but triggers an Automation prompt *(verify)*. Keep our own journal of original paths. Some volumes have no Trash, so warn before deleting permanently. |
| Tags | `URLResourceValues.tagNames` (xattr `com.apple.metadata:_kMDItemUserTags`, a binary plist) | Lost on filesystems without xattr support. |
| Hidden files | `isHiddenKey`; hide `.DS_Store`, `.localized`, `Icon\r` and the `.Spotlight-*` / `.fseventsd` folders | Use `localizedNameKey` for display names. Never write `.DS_Store`. |
| Packages | `isPackageKey`: treat `.app` and `.photoslibrary` as single files | Don't recurse into them for sizes or search unless asked. Offer "Show Package Contents". |
| Links | `isSymbolicLinkKey`, `isAliasFileKey`; resolve aliases with bookmark data | Never follow links during recursive copy or delete, to avoid cycles and escaping the folder tree. |
| iCloud placeholders | `ubiquitousItemDownloadingStatusKey`, the `SF_DATALESS` flag; `setiopolicy_np(...MATERIALIZE_DATALESS_FILES_OFF)` while listing *(verify)* | Thumbnailing or hashing a placeholder downloads the whole file. Show an icon and a cloud badge instead. Use `NSFileCoordinator` for reads and writes. |
| Network volumes | `volumeIsLocalKey` | Every stat is a network round trip. Use pagination and timeouts, and turn off thumbnails and folder sizes by default. FSEvents is unreliable there, so poll or offer manual refresh. |
| Privacy permissions (TCC) | Info.plist usage strings for Desktop, Documents, Downloads and removable volumes | Full Disk Access can't be requested in code. Detect it by probing a protected path, then deep-link to `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`. Permission grants are tied to the code signature, so sign dev builds consistently. |
| Live refresh | FSEvents (`notify` crate), 0.1–0.3 s latency, file-level events | Events get coalesced. `MustScanSubDirs` or `RootChanged` means rescan. Diff the directory rather than trusting individual events. |
| Search | `NSMetadataQuery` on `kMDItemFSName`, `kMDItemUserTags` and similar | Spotlight may be off or still indexing, and results arrive in batches. Fall back to walking the folder tree. |
| Listing | `getattrlistbulk(2)`, requesting only the attributes needed | Check `ATTR_CMN_RETURNED_ATTRS` (some filesystems don't support every attribute) and `ATTR_CMN_ERROR` for per-entry errors. Retry on EINTR. |
| Thumbnails | `QLThumbnailGenerator`, progressive (`.icon` → `.lowQuality` → `.thumbnail`); `NSWorkspace.icon(forFile:)` | Cancel requests for tiles scrolled off screen. Cache by (fileID, mtime, size), not by name. Limit how many run at once. |
| Conflicts / undo | Replace / Keep Both ("name 2") / Skip / Apply to All / Stop; merge folders only as an explicit option | Before undoing, check that the item hasn't changed since. |
| Progress | `Progress` with a cancellation handler; jobs run on background workers | Clean up partial destinations when cancelled. |
| Disk space | `volumeAvailableCapacityForImportantUsageKey`, `totalFileAllocatedSizeKey` | Same-volume APFS clones need almost no space. Still handle `ENOSPC` while copying. |

### Useful crates
`trash`, `notify`, `objc2`, `objc2-foundation`, `objc2-app-kit`, `objc2-quick-look-thumbnailing`, `block2`, `xattr`, `plist`, `zip`/`async_zip` (or `libarchive` bindings for 7z/rar), `tauri-plugin-drag` (drag real files out to other apps), `tauri-plugin-dialog`, `tauri-plugin-updater`. Pin the objc2 crates, which are 0.x and change frequently.

---

## 5. What to carry over from captools

**Ideas and UX worth keeping:**
- Dual pane, with each pane bound to a tab; send a tab to the right pane.
- Tabs that switch when you hover over them while dragging, and spring-loaded folders and breadcrumbs.
- Rubber-band selection drawn directly in the DOM, with no React re-render per mouse move.
- Virtualised grid and list. Column widths in list view come from the longest names. Grid tiles stretch to fill the row (`gridLayout.ts`).
- A conflict dialog with per-item choices, "apply to all", "merge folders" and an "identical" badge from fingerprints.
- The "just moved" highlight and "select the items that just landed".
- The per-panel sort timer: it lives in a small external store (`useSyncExternalStore`), so its once-a-second tick doesn't re-render the whole app. Use this pattern everywhere.
- The command set and shortcuts: Cmd+C/X/V/D/Z and Shift+Cmd+Z, F2, F5, Space to page, Cmd+scroll to zoom, `[` and `]`.
- Restoring scroll position per folder, saving sessions, and the hardening in the streaming ZIP extractor (stall detection, retrying only failed entries).

**Mistakes not to repeat:**
1. **Swallowing errors during folder copy, then deleting the source anyway.** `fs-helpers.ts` uses `Promise.allSettled` and then `batchMove` deletes the source.
2. **Never checking that the destination differs from the source.** That allows cut-paste onto itself and copying a folder into itself (`isSameEntry` was lost after the prototype).
3. **Renaming by copying over the target.** Use `renamex_np(RENAME_EXCL)`.
4. **Comparing names case-sensitively** on a case-insensitive filesystem.
5. **A permanent-delete path that bypasses the bin.** The tree context menu does this.
6. **Writing the bin index only at the end** of an operation, with concurrent read-modify-write. Use an append-only journal (or SQLite) instead.
7. **Duplicating code for the left and right panes.** The "effective*" pattern and many handlers read the left pane's data while the right pane had focus. Build one `Pane` component and one store per pane.
8. **One 150-field context object rebuilt on every render.** Use small stores with selectors (Zustand or `useSyncExternalStore`).
9. **Keying UI state by array index or bare name.** Use stable IDs.
10. **Calling hooks after an early return**, and hiding it with `eslint-disable`. Don't disable that rule.
11. **Thumbnails keyed by name, and late worker replies resurrecting stale entries.** Key by (fileID, mtime, size) and check a generation token before using a reply.
12. **No accessibility.** Use roles for the grid, tree and tabs, `aria-selected`, focusable items and a full keyboard path.

---

## 6. Auto-update from GitHub Releases

Goal: you push a version tag, and every installed copy updates itself with no manual steps.

**Pipeline**
1. Bump the version in `tauri.conf.json` and `Cargo.toml`, then `git tag v0.3.0 && git push --tags`.
2. A GitHub Actions workflow (`tauri-apps/tauri-action`) builds a **universal** (arm64 + x86_64) `.app`, then:
   - signs it with the Developer ID certificate
   - notarises and staples it
   - creates the DMG and the updater bundle (`.app.tar.gz` + `.sig`)
   - publishes a GitHub Release containing a generated **`latest.json`**
3. The app uses `tauri-plugin-updater` with this endpoint:
   `https://github.com/<owner>/filofinder/releases/latest/download/latest.json`
4. Optionally, a second job bumps the Homebrew cask (`brew bump-cask-pr`). Mark the cask `auto_updates true` so `brew upgrade` doesn't fight the in-app updater.

**Keys (two separate kinds; both go in GitHub Actions secrets)**
- **Apple:**
  - the `APPLE_CERTIFICATE` and `APPLE_CERTIFICATE_PASSWORD` pair, which is the Developer ID Application `.p12`
  - one notarisation credential: `APPLE_ID`, `APPLE_PASSWORD` and `APPLE_TEAM_ID`, or App Store Connect API keys
- **Updater:** a signing key generated with `tauri signer generate`, stored as `TAURI_SIGNING_PRIVATE_KEY` plus its password. The public key goes in `tauri.conf.json`. **If you lose this key, already-installed copies can never auto-update again.** Back it up offline.

**In-app behaviour**
- Check about 10 s after launch, then every 6 h. Download silently in the background, then show a "Restart to update" pill. Never interrupt a running copy or move job; wait until the job queue is empty.
- Channels: `stable` uses `releases/latest`. `beta` points at a `latest.json` on a pre-release, or at a small static JSON on GitHub Pages.
- Updates are a full download. Tauri has no delta updates, but at about 5–10 MB that's fine.
- Offer a setting to turn checks off, which matters for privacy in an open-source app.
- Ad-hoc or unsigned builds can't update cleanly because Gatekeeper and TCC permission resets get in the way. Ship signed builds from day one.

## 7. Speed budget ("it must feel instant")

These targets are hard limits checked in CI where possible, measured on an M1 with a warm disk:

| Metric | Target |
|---|---|
| Cold launch → first folder painted | < 400 ms |
| Open a 1k-item folder | < 50 ms |
| First rows of a 100k-item folder | < 150 ms (streamed; full list in < 1 s) |
| Scrolling the grid with thumbnails | 60 fps, 120 fps on ProMotion |
| Keypress → selection or navigation | < 16 ms |
| Visible thumbnails (cache hit / miss) | < 100 ms / < 500 ms |
| Idle RAM | < 80 MB |
| Bundle | < 15 MB |

**How we hit them**
- **Rust and listing**
  - Use `getattrlistbulk` on a worker pool, and send the first batch immediately.
  - Send rows in a compact binary or columnar form, not JSON objects.
  - Cache folder listings in memory (LRU) and keep them current with FSEvents, so Back/Forward is instant.
- **UI rendering**
  - Use a virtualised grid with fixed row heights.
  - Each tile subscribes only to its own row. Use no global context; use small stores with selectors.
  - Sorting and filtering run in Rust (or in a worker for small lists), never in the render path.
- **Thumbnails**
  - Serve them over the `thumb://` protocol from an on-disk cache (`~/Library/Caches/filofinder`), keyed by fileID + mtime.
  - Generate them progressively with QLThumbnailGenerator and cancel requests for tiles that scroll off screen.
  - Limit concurrency to the number of cores.
- **Startup**
  - Restore the last session's folder from the listing cache, then refresh it in the background.
  - Load heavy panels (bin, archive browser, settings) only when first opened.
- **Release build**
  - `opt-level=3`, `lto="fat"`, `codegen-units=1`, `panic="abort"`, `strip=true`.
  - Use Vite code-splitting and avoid heavy UI libraries (no framer-motion in the hot path).
- **Guardrails**
  - A benchmark crate (`criterion`) for listing and copying.
  - A Playwright/WebDriver scroll-fps test.
  - A CI check that fails the PR if the bundle grows by more than 10%.

## 8. Suggested roadmap

**Week 1: technical spikes** (each one proves a risk can be solved)
1. Stream a 100k-entry listing over a Channel into the virtual grid, keeping 60 fps while scrolling.
2. Serve QLThumbnailGenerator output through `thumb://` with a disk cache.
3. Drag real files out to Mail or Slack with `tauri-plugin-drag`.
4. Open the QLPreviewPanel when Space is pressed.
5. Trash an item and undo it, including the Put Back behaviour.
6. Set up the release pipeline: tag, then GitHub Actions builds, signs, notarises and publishes `latest.json`, and an installed v0.0.1 updates itself to v0.0.2.

**MVP (v0.1)**
- browse, tabs, dual pane and tree sidebar
- copy, move, rename, trash and undo through the job queue with conflict handling
- live refresh, thumbnails, Quick Look and drag in/out
- hidden-files toggle, editable path bar and instant filter
- signed, notarised DMG

**v0.2:**
- browse and extract archives
- bulk rename
- folder sizes
- command palette and frequent-folders jump
- tags
- Spotlight search

**Later:**
- SFTP/S3
- Git badges and an integrated terminal
- plugins and themes
- duplicate finder

---

## Sources
- Tauri vs Electron 2026 benchmarks: https://tech-insider.org/tauri-vs-electron-2026/ · https://vanja.io/tauri-2-new-default/
- Tauri: https://v2.tauri.app/develop/calling-frontend/#channels · https://v2.tauri.app/distribute/sign/macos/ · https://v2.tauri.app/plugin/updater/
- Drag-out: https://docs.crabnebula.dev/plugins/drag-rs/
- Crates: https://crates.io/crates/trash · https://crates.io/crates/notify · https://crates.io/crates/objc2-app-kit
- Apple: https://developer.apple.com/documentation/quicklookthumbnailing/qlthumbnailgenerator · https://developer.apple.com/documentation/technotes/tn3150-getting-ready-for-dataless-files · https://developer.apple.com/documentation/coreservices/file_system_events · https://developer.apple.com/documentation/foundation/nsmetadataquery · https://developer.apple.com/documentation/foundation/urlresourcekey · https://developer.apple.com/documentation/security/app_sandbox
- Homebrew cask rules: https://docs.brew.sh/Acceptable-Casks
- Landscape: https://forums.macrumors.com/threads/best-finder-alternatives-file-managers.2258057/ · https://alternativeto.net/software/forklift/ · https://mjtsai.com/blog/2021/11/30/little-annoyances-in-macos-12-0-1/ · https://macmost.com/how-to-fix-these-20-mac-finder-annoyances.html
- Projects: https://github.com/mikekazakov/nimble-commander · https://github.com/spacedriveapp/spacedrive · https://github.com/files-community/Files · https://github.com/sxyazi/yazi
