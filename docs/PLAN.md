# Filofinder — Master Plan (v2)

Revised 2026-10-10, after an architecture review: an adversarial edge-case review plus a fact-check of the signing and update path.
This plan supersedes the stack sections of `RESEARCH.md`. **Status:** planning only. No production code until §0 is confirmed and Phase 0 passes.

Changes since v1 are listed in **Appendix B**.

---

## 0. Decisions

| # | Decision | Status |
|---|---|---|
| D1 | Free, open source (MIT). No paid tier, telemetry or account. | ✅ |
| D2 | Built from scratch. Only ideas and lessons come from captools; no captools code. | ✅ |
| D3 | **Layout, buttons and controls the same as the captools file manager. Only the styling (colours, materials, effects, fonts) is macOS-native.** Changed 2026-10-10; this replaces "Windows Explorer layout". §3.1's diagram will be replaced by the captools layout spec (`docs/UI-SPEC.md`). | ✅ |
| D4 | Speed first, for both the UI and file operations (ZIP included). | ✅ |
| D5 | ZIP makes clean archives using captools-style exclusion rules (made precise in §7.1). Never use Archive Utility or `ditto`. | ✅ |
| D6 | No paid Apple certificate: one long-lived self-signed certificate, a one-time `xattr` step, and Sparkle updates. **Fallback is the $99 account if Phase 0 test S2 fails.** | ✅ (conditional) |
| D7 | A Rust core does every filesystem, ZIP, thumbnail and search operation. | ✅ |
| D8 | UI in native **Swift + AppKit**. SwiftUI only for Settings. | ⚠️ confirm |
| D9 | macOS 13+, **Apple Silicon only (arm64)**. Intel can't be tested here, and Tahoe (26) is the last macOS for Intel. | ✅ |
| D13 | **No Xcode.** Command Line Tools only: SwiftPM builds the app, a script assembles the `.app` bundle, and macOS's built-in CLI tools handle profiling (see §10). | ✅ |
| D14 | **No GitHub repo for now.** Everything is built and tested locally; Phase 0 test S2 serves its update feed from a local web server. GitHub, CI and Releases come later. | ✅ |
| D10 | Delete uses the **real macOS Trash**. Undo comes from our own journal. | proposed |
| D11 | **v0.1 is small**: tabs (no dual pane), copy/move/rename/trash, undo, the conflict dialog and updates. Everything else follows in later versions. | proposed (from the review) |
| D12 | Whole-disk search uses **Spotlight** (`NSMetadataQuery`), not our own index, until at least 1.0. | proposed (from the review) |

---

## 1. Goals, non-goals, principles

**Goals:** feel instant; be safer than Finder; give Explorer-level productivity; feel native on a Mac.

**Non-goals before 1.0:** remote locations (SFTP/S3), Windows or Linux builds, plugins, content search, our own filename index, Zstd-in-ZIP, 7z/tar/RAR, the Mac App Store, and a privileged helper for admin-protected operations (it needs Developer ID).

**Principles**
1. The UI thread never touches the disk.
2. Every change goes through one job engine.
3. Identity = volume UUID + file ID. Never array indexes or bare names.
4. **Check before acting:** every job runs a preflight before writing a byte.
5. **No silent failure:** every skip, failure or exclusion is reported.
6. **Never cause permission prompts or downloads the user didn't ask for:** no background crawling, and no reading the contents of cloud placeholder files.
7. Measure everything. Speed numbers come from benchmarks, not opinions.

---

## 2. UI decision (D8): Swift + AppKit

- **Frame rate:** WKWebView (Tauri) is capped at 60 fps on ProMotion (WebKit #294338). AppKit renders at 120 Hz.
- **Mac look and features:** AppKit gives the real Mac look plus Quick Look, drag-out, VoiceOver, IME and type-select for free.
- **SwiftUI:** `Table` and `List` stall at large row counts (regressions in macOS 15.5 and 26), so they're excluded for file lists.
- **Alternative:** Tauri + SolidJS. See Appendix A.

---

## 3. Product specification

### 3.1 Layout
```
● ● ●  [ Downloads ✕ ][ Projects ✕ ][+]                        native window tabs
‹  ›  ↑  ⟳ │ Home › bipul › Downloads ▾             │ 🔍 Search Downloads
New ▾ │ ✂ ⧉ 📋 │ ✎ 🗑 │ Sort ▾  View ▾ │ ⓘ Details                    command bar
┌ Sidebar (vibrancy) ─┬ Name ▲           Date modified    Kind     Size ┬ Details/Preview ┐
│ ⌂ Home              │ 📁 Invoices      Today 10:41      Folder     —  │                 │
│ ★ Quick access      │ 🖼 photo.jpg     Yesterday 18:02  JPEG   2.1 MB │                 │
│ 💻 This Mac / drives│                                                 │                 │
│ ☁ Cloud (iCloud…)   │                                                 │                 │
│ 🗑 Trash            │                                                 │                 │
└─────────────────────┴─────────────────────────────────────────────────┴─────────────────┘
 1,284 items · 3 selected (6.2 MB) · 214 GB free                                    ☰  ⊞
```
- **Views:** Details (sortable, resizable columns), List, and Icons (S/M/L). Group-by and reorderable columns come after v0.2.
- **Dual pane comes in v0.2.** It doubles the focus, keyboard and drop-target state, so it waits until single-pane is solid.
- **Address bar:**
  - breadcrumbs with a dropdown per segment
  - click to edit the path; `~` expands
  - unreachable paths show inline errors
- **Display names:** localised names (`localizedNameKey`, `.localized` folders) are shown, but every operation uses the real name.

### 3.2 Releases and their features

| Version | Contents |
|---|---|
| **v0.1** | Window and tabs, sidebar, Details/List/Icons, address bar, folder filter, live refresh, thumbnails, Quick Look. New folder, rename, copy, cut/paste, move, duplicate, trash. **Undo** (no redo yet). Conflict dialog, job panel, Finder clipboard interop, drag in and out, onboarding, updates. |
| v0.2 | Dual pane, ZIP create/extract/browse, preview/details pane, folder sizes, tags, sort timer, redo |
| v0.3 | Batch rename with preview, Spotlight search, Open With and Services, group-by, command palette |
| 1.0 | Hardening, localisation, docs, FAQ |
| Later | 7z/tar, own filename index, SFTP/S3, Git badges, terminal, themes, plugins, privileged helper |

### 3.3 Keyboard: Mac modifiers, Explorer behaviour, documented in-app

| Key | Action | Notes |
|---|---|---|
| ↵ | **Open** | Settings can switch it to Finder's "rename". In a rename field, ↵ **commits**. |
| F2 | Rename | |
| ⌘⌫ **and** ⌦ | Move to Trash | Bare ⌫ = Back (Explorer). "⌫ trashes" is opt-in. |
| ⌥⌘⌫ | Delete permanently | Always confirms. |
| ⌘X → ⌘V, **⌘⌥V** | Move | ⌘⌥V matches Finder's own move. |
| ⌘C ⌘V ⌘D ⌘Z | Copy / paste / duplicate / undo | |
| ⌘[ ⌘] ⌘↑ ⌘↓ | Back / forward / up / open | ⌘↓ matches Finder. |
| ⌘L, ⌘F | Edit path, filter | |
| ⌘T ⌘W ⌃⇥ | New / close / next tab | |
| ⇥ | Switch pane | **Only in dual pane with focus in a list.** Otherwise it's normal focus navigation, for VoiceOver. |
| Space | Quick Look | |
| ⌘⇧. | Hidden files | |
| ⌘1–4 | View modes | Same meaning as Finder. |
| letters | Type-select | |

---

## 4. Architecture

```
┌──────────── Filofinder.app (Swift / AppKit) ────────────┐
│ Windows/Tabs · PaneController · NSTableView/NSCollectionView │
│ Sidebar · Toolbar · CommandBar · JobsPanel · ConflictSheet  │
│ Preflight sheet · Onboarding · QuickLook · Pasteboard · Sparkle │
└───────────────┬───────────────────────────▲───────────────┘
       UniFFI calls                 UniFFI callbacks → coalesced → main queue
┌───────────────▼───────────────────────────┴───────────────┐
│ filofinder-core (Rust, statically linked)                  │
│ volumes   capability probe, mount/unmount, per-volume I/O  │
│ listing   getattrlistbulk · sort (ICU4X collator) · cache  │
│ watch     FSEvents · storm coalescing · rescan fallback    │
│ jobs      preflight · scheduler · path locks · journal     │
│ ops       clonefile/fcopyfile · renamex_np · trash · chflags │
│ archive   rawzip · zlib-rs/libdeflate · safety limits      │
│ thumbs    ImageIO → QL fallback → bounded cache            │
│ store     3 × SQLite: settings · journal · cache           │
│ macos     objc2: trash, tags, TCC/FDA, File Provider, QoS  │
└────────────────────────────────────────────────────────────┘
```

### 4.1 UI ↔ core contract
- **Listings stay in Rust.** The UI asks for visible rows only, by index, through a `ListingHandle`.
- **Updates are batched** into `{inserted, removed, updated}` diffs, at most one per frame (16 ms or 8 ms).
- **Generation tokens per pane:** results from older navigations are dropped.
- **Callbacks** arrive on core threads. One Swift dispatcher coalesces them and hops to the main queue once per frame. Core code never calls back into the UI synchronously.
- **1M-entry folders:** columnar storage of about 40 bytes per entry plus a name arena, roughly 60 MB. That's acceptable, and the listing is released when the tab closes.

### 4.2 Threading and volume isolation
- **Per-volume I/O executors:** a hung SMB share or a pulled USB drive blocks **only that volume's** threads. A watchdog marks the volume "unresponsive" after 5 s, and the UI stays live.
- **Pools:** interactive (visible folder, thumbnails on screen), jobs, and background. Each is tagged with a macOS QoS.
- **Cancellation:** cooperative, checked between files and between chunks. A cancel issued during an uninterruptible kernel call takes effect when that call returns, and the UI shows "Cancelling…".
- **Never `stat` volume roots on the UI path.** Sidebar free space is fetched asynchronously with a timeout.

### 4.3 FSEvents
- **Streams:** one stream per *visible* folder's volume, with 150 ms latency and file-level events.
- **Floods** (`npm install`, `git checkout`): more than 500 events for one folder in a batch means drop the per-file diff and **re-list once**.
- **Flags:** `MustScanSubDirs`, `RootChanged` and dropped-event flags trigger a re-list.
- **No volume-wide watching in v1.** It only matters once there's our own index, which is deferred (D12).

---

## 5. Job engine and safety model

### 5.1 Lifecycle of every job
`queued → preflight → (user resolves issues) → running ⇄ paused → done | failed | cancelled → journaled`

### 5.2 Preflight: one dialog before any byte moves
Before anything is written, the preflight checks:
- **Destination capabilities**:
  - filesystem type (`statfs`)
  - name limits (`pathconf _PC_NAME_MAX`, 255 *bytes* measured after normalisation)
  - case sensitivity
  - xattr support
  - Trash support
  - read-only (NTFS is read-only in macOS)
- **FAT32:** files larger than 4 GB are blocked.
- **exFAT, FAT and SMB:** illegal characters (`: \ * ? " < > |`, a trailing dot or space) are flagged, with an offer to **Rename-sanitize** or Skip.
- **Case-only clashes** when copying from a case-sensitive volume to a case-insensitive one (`A.txt` and `a.txt`).
- **Space:** `volumeAvailableCapacityForImportantUsage` compared with the total. Within one APFS volume, clones need almost no space.
- **Permissions:** `EACCES`/`EPERM` and locked files (`uchg`).
  - Offer "**Unlock and continue**" for files the user owns.
  - Root-owned and SIP paths: "Requires admin — open in Finder". (A privileged helper needs Developer ID, so it comes later.)
- **Self-nesting:** a move into itself or a descendant, checked by (dev, ino).
- **Conflicts:** name collisions, using NFC + case-fold on case-insensitive volumes.
- **Busy or in-flight files:** `.crdownload`, `.part` and `.download` are skipped with a warning.
- **Special locations:** Time Machine `Backups.backupdb` is read-only. File Provider folders: see §6.

The result is **one sheet** listing every issue, grouped, with bulk actions. A job never fails an hour in at file 80,000 because of something we could have checked first.

### 5.3 Copy and move mechanics
- **Atomic placement.** Every destination file is first written as `.<name>.ffpartial-<jobid>` (hidden in listings), then renamed into place with `renamex_np(RENAME_EXCL)`. So:
  - a crash never leaves a half-written file under the real name
  - cleanup just deletes the partial files
- **Ordering.** For each file, the journal entry is written (and fsynced) before the operation runs: `planned → copied → verified → placed → source-removed`. Resume after a crash is therefore exact.
- **Same volume:** `rename()` for moves (atomic); `clonefile` for copies (instant).
- **Cross-volume moves are done per file:** copy → verify → place → delete that source file. If the job stops partway, the summary says exactly "moved N, M still at source". There are no orphaned duplicates.
- **Verification:** size plus mtime always. Optional SHA-256 ("Verify copies" in Settings; on by default for removable and network volumes). External drives get `F_FULLFSYNC` at the end of the job.
- **Fidelity:**
  - `COPYFILE_ALL` (xattrs, ACLs, tags, dates) when the destination supports it; otherwise data only.
  - `COPYFILE_DATA_SPARSE` keeps sparse files (VM disks) from inflating to full size.
  - A hard-link table keyed by (dev, ino) re-creates hard links, so pnpm or Time Machine trees don't multiply in size.
  - Symlinks are copied as links and never followed.
- **Files changing during a copy:** size and mtime are re-checked after the copy. If they changed, the copy is redone once, then the file is flagged "changed during copy".
- **Volume disappears** (unmount or eject notification, or `ENXIO`/`EIO`): the job becomes **"Paused — drive disconnected"** and resumes automatically when the same volume UUID returns. A DiskArbitration "will unmount" request asks before allowing an eject during a job.
- **Two jobs touching the same files:** jobs **lock their source and destination paths**. A conflicting job waits ("Waiting for job #3"). Jobs targeting the same disk run one at a time by default.
- **Very large selections (100k):** batched pasteboard writes, one journal transaction, summarised conflict dialogs and a sampled drag image.

### 5.4 Delete, Trash and undo
- **Delete:** `trashItem(at:resultingItemURL:)`. The resulting URL, file ID and volume UUID are recorded.
- **Volumes without a Trash** (network, FAT, read-only): the only option is a permanent delete, through an explicit "**cannot be undone**" dialog.
- **Before undo**, all of these are checked:
  - the item still exists at its recorded location (Trash URL or destination)
  - same file ID
  - same volume UUID (the volume must be mounted)
  - unchanged size and mtime
  - If any check fails, the entry is greyed out with the reason.
  - If the Trash was emptied, the entry says so.
- **Journal retention:** the last 1,000 operations or 30 days, then pruned and vacuumed.
- **The in-app Trash view needs Full Disk Access** (reading `~/.Trash` requires it). Without it, the Trash entry opens Finder's Trash.

---

## 6. macOS realities (permissions, cloud, volumes)

- **TCC (privacy permissions) without prompt storms:**
  - First run shows onboarding that explains Full Disk Access, with a deep link to `…Privacy_AllFiles`.
  - **Without FDA:** no background work touches Desktop, Documents, Downloads, removable or network volumes, iCloud, or other protected locations. No prefetching, no sizes, no thumbnails until the user opens them.
  - Session restore opens only the active tab eagerly.
- **File Provider folders** (iCloud Drive, Dropbox, Google Drive, OneDrive under `~/Library/CloudStorage`):
  - Detected with `isUbiquitousItem`, the dataless flag, or the path.
  - Never read placeholder file contents: no thumbnails (icon plus cloud badge instead) and no folder sizes.
  - Moves use `NSFileCoordinator`.
  - Provider errors are shown verbatim.
- **Firmlinks:** `/System/Volumes/Data` duplicates are de-duplicated by file ID, and SIP paths are shown read-only.
- **Network volumes:**
  - every call has a timeout
  - thumbnails and sizes are off by default
  - manual refresh, since FSEvents is unreliable there
- **App Translocation:** detected at launch (`SecTranslocateIsTranslocatedURL`). The app then shows a blocking screen with the `xattr` command and a "Move to Applications" button.
- **Session restore:** a vanished folder falls back to its nearest existing ancestor. An unmounted network path becomes an "Unavailable" tab and never blocks launch.
- **Clipboard interop with Finder:**
  - Copying writes `public.file-url` items, written lazily for large selections.
  - Pasting accepts files copied in Finder. Cut state is tracked privately, so Finder sees a plain copy.
  - ⌘⌥V moves, the same as in Finder.

---

## 7. ZIP (v0.2)

### 7.1 Exclusion rules, made precise and tested
- **Always skipped, both when zipping and when extracting:**
  - `.DS_Store`, `__MACOSX/`, `Icon\r`
  - `.Spotlight-V100`, `.fseventsd`, `.Trashes`, `.TemporaryItems`
  - `Thumbs.db`, `desktop.ini`
- **`._X` AppleDouble files:** skipped **only if `X` exists in the same folder**, or, when extracting, if the content has an AppleDouble header. A genuine file named `._config` is kept.
- **Never excluded, with a unit test:** `.env`, `.gitignore`, `.git/`, `.htaccess`, `.npmrc`, `.editorconfig`, and every other dotfile.
- **Override:** "Extract everything (including system files)" on a per-archive basis.
- **Reporting:** the summary shows "N system files skipped" and lists them on request.

### 7.2 Creating a ZIP
- **STORE (no compression):** jpg, jpeg, heic, heif, png, gif, webp, avif, jxl, mp4, mov, m4v, mp3, aac, m4a, zip, 7z, rar, gz, bz2, xz, zst, lz4, br, dmg, pkg, apk, docx, xlsx, pptx.
- **Everything else, PDF included:** a 64 KB probe at level 1; STORE if the saving is under 5%.
- **Compression:** parallel per entry with zlib-rs at level 6 ("Fast" = level 1), and one ordered writer.
- **ZIP64 only when needed:** more than 65,535 entries or more than 4 GB. Above that threshold, warn that old unzip tools may fail.
- **Names:** UTF-8 flag on, normalised to NFC.
- **Timestamps:** extended timestamp `0x5455` (UTC) plus DOS time.
- **File modes:** Unix permissions go in the external attributes, so `+x` survives.
- **Symlinks** are stored as Unix symlink entries.
- **`.app` and other bundles:** warn "may not run after zipping (code signature)".
- **Cut from the plan:** Zstd-in-ZIP and pigz-style splitting of single files.

### 7.3 Extracting a ZIP
- **Default target folder:** "Extract" creates `name/` unless the archive has a single top-level folder. "Extract here" is an explicit choice.
- **Validation before anything is written:**
  - no `..`, absolute paths or backslash tricks
  - no overlapping entries
  - fits in free space
- **During extraction:**
  - an entry that writes more than its declared size is stopped
  - total output is capped at ratio × 100 with a prompt
- **Writing:**
  - parallel workers (4–8), largest files first, partial names then rename
  - CRC checks
  - symlinks created last, only if they point inside the destination folder
  - Unix modes and timestamps restored (preferring `0x5455`/NTFS times)
- **Encodings:** without the UTF-8 flag, names are detected (`chardetng`: CP437, Shift-JIS, GBK, CP1252), with a re-encode picker in browse view.
- **Passwords:** ZipCrypto and AES prompt for a password (extract only).
- **Split archives** (`.z01`, `.zip.001`): detected, with a clear "not supported yet" message.
- **Browsing** inside a ZIP reads the table of contents with rawzip. Opening a single file extracts only that entry.

### 7.4 Speed targets (Phase 0 benchmark S3)

| Task | Target |
|---|---|
| Listing a 100k-entry ZIP | < 50 ms |
| Unzipping photos | ≥ 1.5 GB/s |
| Zipping a photo folder | ≥ 2 GB/s |
| Zipping compressible data | ≥ 0.5 GB/s (level 6) |

Baselines: Archive Utility, `ditto` and captools.

---

## 8. Data and storage
- **Three separate SQLite databases** in `~/Library/Application Support/Filofinder` (thumbnails go in `~/Library/Caches`):
  - `settings.db`
  - `journal.db`
  - `thumbs.db` (cache)
  - A corrupt cache never takes undo down with it.
- **Every schema is versioned**, and migrations are forward-only.
  - **Before migrating**, the old database is copied to `*.bak-vN`.
  - **Opening a newer schema** (after a downgrade): settings and journal open read-only with a banner, and the cache is moved aside and rebuilt.
- **Startup:** if opening fails, run `PRAGMA integrity_check`. If it fails, the cache is rebuilt, and settings and journal are restored from the last `.bak`.
- **Thumbnail cache:**
  - LRU-capped at 500 MB (adjustable)
  - entries are dropped when the item is trashed or deleted
  - nothing is cached for encrypted disk images, network volumes or excluded folders
  - "Clear cache" in Settings
- **One app instance:** a lock file on the data folder means a second copy of the app running (for example one in Downloads) opens read-only.
- **Sorting:** natural, locale-aware (ICU4X collator with numeric ordering), matching `localizedStandardCompare`.

---

## 9. Install, signing and the update process

### 9.1 Signing (verified against Apple DTS and Sparkle source; Phase 0 test S2 confirms)
- **One self-signed code-signing certificate, valid for 20 years**, created once.
  - **Why it works:** TCC remembers an app by its code-signing "designated requirement", which for a non-Apple certificate is `identifier "app.filofinder" and certificate leaf = H"<sha1>"`. That stays stable as long as the certificate never changes, so permissions survive updates.
  - **If the certificate is ever changed,** every user's Full Disk Access and folder grants reset once.
  - **Backups:** the certificate's `.p12` and the Sparkle EdDSA key are each stored in **two offline backups** plus GitHub Secrets.
- **Hardened runtime is not enabled.** It's only required for notarisation, and leaving it off avoids library-validation crashes with a self-signed identity. The Rust core is **statically linked**. Hardened runtime is turned on when or if we move to Developer ID.
- **The DMG itself is signed** too: Apple's mitigation against translocation.
- **CI checks:** `codesign -dr - Filofinder.app` must show the leaf-hash requirement, and the build fails otherwise.

### 9.2 First install (README plus an in-app guard)
1. Download the DMG from GitHub Releases and drag the app to **/Applications**.
2. Run `xattr -dr com.apple.quarantine /Applications/Filofinder.app`, **or** use System Settings → Privacy & Security → "Open Anyway". Note: on some 15.x builds that button doesn't appear, so the Terminal command is the primary method.
3. Open the app. The onboarding then asks for Full Disk Access.
4. **In-app guards:**
   - if the app is translocated, or running from the DMG or Downloads, it shows a blocking screen with the command and a "Move to Applications" button
   - if Full Disk Access is missing, it shows a non-blocking banner
5. **Trust signals:**
   - SHA-256 checksums
   - **GitHub artifact attestations** (build provenance, free for public repos)
   - releases are built only in public CI
- **Homebrew:** official casks are impossible. Homebrew 5 disabled unsigned casks that fail Gatekeeper as of September 2026. A **personal tap** is optional and still needs the `xattr` step.

### 9.3 Update lifecycle (Sparkle 2)
- **Check:** at launch and every 6 h, from an appcast on **GitHub Pages** (not the GitHub API, so no rate limits). Users can switch checks off.
- **Download:** silently, in the background. Sparkle validates the **EdDSA signature**, and also that the new app's code signature matches or is a valid rotation. Sparkle **removes the quarantine flag** from installed updates, so Gatekeeper shouldn't prompt again (S2 confirms).
- **Install is guarded.** It is deferred while:
  - any job is running or paused
  - any journal entry is incomplete
  - the app is translocated, or its location isn't writable (the user is told why; Sparkle won't say by default)
  - Otherwise: "Restart to update". Never forced, except for a security-flagged critical update.
- **Standard (non-admin) users:** Sparkle asks for an admin password to replace an app in `/Applications`. The README says so, and installing into `~/Applications` is supported as an alternative.
- **Format:** DMG/ZIP archives, **never `.pkg`**, which always needs admin. Sparkle's XPC services are removed, since the app isn't sandboxed.
- **Phased rollout:** `sparkle:phasedRolloutInterval` spreads each release over about 3 days, so a bad build reaches few people.
- **Bad release / kill switch:**
  - publish a fixed higher version immediately, marked critical
  - remove the bad item from the appcast
  - all previous DMGs stay downloadable for a manual rollback
  - `minimumAutoupdateVersion` forces old broken versions to update
- **Downgrade safety:** after a manual rollback, the older app opens newer databases read-only (§8). It never crashes or corrupts them.
- **Channels:** stable, plus an opt-in beta through `sparkle:channel`.
- **Minimum OS bumps:** `sparkle:minimumSystemVersion`. Users on older macOS stay on the last compatible version and are told why.
- **Release notes** are shown in the update dialog and generated from the changelog.

### 9.4 Release pipeline and supply-chain safety
- **Until GitHub exists (D14),** `scripts/release.sh` runs the same steps locally.
- **Tag `vX.Y.Z`** triggers the build: core (arm64) → bindings → `swift build -c release` + bundle script → sign app and DMG → DR check → EdDSA sign → appcast → checksums and attestation → GitHub Release.
- **Secrets** live only in a protected `release` environment that needs **your manual approval**. PR workflows never see secrets.
- **Third-party Actions** are pinned to commit SHAs.
- **Dependencies:** `cargo-deny` blocks GPL and unvetted licences. Dependabot is on.
- **Rotation rules:** never rotate the certificate and the EdDSA key in the same release (Sparkle's rule). Key-loss procedures are documented in `docs/RELEASING.md`.

### 9.5 Failure modes and responses

| Failure | Result | Response |
|---|---|---|
| Certificate lost | Permissions reset once for everyone; updates still work | Ship the new certificate; release notes explain re-granting |
| EdDSA key lost | Auto-update permanently broken (no Developer ID fallback) | Prevented by two offline backups; if lost, a manual-reinstall announcement |
| Quarantine still set | App translocated; updates fail silently | Launch guard (§9.2) |
| Standard user | Admin prompt on update | Documented; `~/Applications` install supported |
| Bad release | Users hit a bug | Phased rollout plus a critical fixed release plus rollback DMGs |
| S2 fails on some macOS versions | Permission resets or Gatekeeper prompts | Switch to the $99 Developer ID (CI-only change) |

---

## 10. Performance budget
- **Targets** are the same as v1: launch < 300 ms, 100k-item folder first rows < 100 ms, 120 fps scrolling, keypress < 8 ms, idle RAM < 60 MB, app < 15 MB.
- **How we measure without Xcode or Instruments (D13):**
  - **Frame rate:** a debug FPS/frame-time overlay inside the app, driven by `NSView.displayLink` (macOS 14+) or `CVDisplayLink`. It logs every frame over budget (8.3 ms at 120 Hz).
  - **Timings:** `os_signpost` and `os_log` intervals, read with `log stream`.
  - **Hangs:** `sample` and `spindump`, built into macOS.
  - **Memory:** `leaks`, `heap`, `vmmap` and `footprint`, built into macOS.
  - **Core:** `criterion` and `hyperfine`.
- **Enforcement:** while there's no CI, these run locally before each release. Later, CI enforces only deterministic checks: app size, and core benchmarks against a baseline with 15% tolerance.

---

## 11. Quality, support, accessibility and localisation

**Testing**
- **Unit and property tests:** path rules, name normalisation, the conflict matrix and the exclusion rules.
- **Filesystem matrix:** `hdiutil` disk images for APFS, case-sensitive APFS, HFS+, exFAT and FAT32, plus a full disk image for `ENOSPC`.
- **Fault injection:** `EIO`, unmount mid-job, process kill mid-job.
- **Parser fuzzing:** `cargo-fuzz` on the ZIP and table-of-contents parsers.
- **Manual checks per release:** an SMB share, a USB stick pulled mid-copy, iCloud/Dropbox folders.
- **Install and update matrix (Phase 0 test S2 and every minor release):**
  - **Real hardware:** your Apple Silicon Mac (macOS 15.4.1), as an admin user and as a separate **standard user account**.
  - **Optional VMs:** macOS 13/14/26 in free macOS virtual machines (UTM, or Apple's Virtualization framework).
- **UI tests:** there are no automated UI tests without Xcode. Coverage comes from core tests plus a written manual checklist per release.

**Accessibility**
- Rows expose proper accessibility roles.
- "Increase contrast" and "Reduce transparency" are respected (vibrancy falls back to solid).
- Full keyboard path; VoiceOver pass per release.

**Localisation**
- All user-facing text goes through `String(localized:)` with plain `.strings` files from day one (English first). String Catalogs need Xcode, so they're skipped (D13).
- The app icon is built with the built-in `iconutil`.
- Leading/trailing layout throughout, ready for right-to-left languages.

**Support without telemetry**
- "Copy diagnostics" collects logs, `.ips` crash files and system info, then opens a prefilled GitHub issue.
- An FAQ written **before** release, led by "can't open the app" and "folders look empty / Full Disk Access".

---

## 12. Licensing and legal
- **Licensing:** the app is MIT. Dependencies must be MIT, Apache or BSD (checked by `cargo-deny`). No GPL. RAR is deferred.
- **Branding:** SF Symbols and SF Pro are fine in a native app. Copy only the Explorer *layout*: no Microsoft icons or names. Use "Finder" only descriptively, and run a trademark check on "Filofinder" before 1.0.
- **Privacy:** no telemetry. Network use is limited to update checks (opt-out), and the privacy statement in the README says so.

---

## 13. Risks

| Risk | Mitigation |
|---|---|
| Swift and AppKit learning curve | Rust core first; thin AppKit layer; Nimble Commander as reference; small milestones |
| S2 fails on some macOS versions | A hard decision point after Phase 0: buy the $99 account if needed (CI-only change) |
| Scope or timeline overruns (realistically **6–12 months to 1.0**, solo) | D11 small v0.1; gate features on daily-use data-loss metrics |
| Data loss from bugs | The §5 mechanics; fuzzing and fault injection; dogfood for 2 weeks before each release |
| UniFFI hot-path overhead | Visible rows only, flat records; benchmarked in S1 |
| Hung network volumes | Per-volume executors plus a watchdog |
| Support load (Gatekeeper, Full Disk Access) | Launch guards, onboarding, FAQ, diagnostics button |

---

## 14. Roadmap

**Phase 0: proof tests (about 2 weeks, throwaway)**

| # | Test | Pass condition |
|---|---|---|
| S0 | Build toolchain without Xcode: SwiftPM + Rust static lib + bundle script → a runnable, self-signed `.app`; also check whether XCTest runs with the Command Line Tools | Builds and launches with one command |
| S1 | Rust lister + UniFFI + NSTableView, 100k-file folder | First rows < 100 ms; frame-time overlay shows no frames over budget while scrolling |
| S2 | Self-signed certificate + Sparkle, with the appcast served from **localhost**: install v0.0.1 → grant Full Disk Access and Documents access → update to v0.0.2. Matrix: your Mac as admin and as a standard user (VMs optional) | No Gatekeeper prompt after the update; grants kept; translocation guard works |
| S3 | ZIP benchmark on your photo ZIPs vs Archive Utility, `ditto` and captools | Meets §7.4 or we learn the real ceiling |
| S4 | ImageIO thumbnails on 5k photos | ≥ 200 thumbnails/s |
| S5 | Quick Look + drag-out to Mail/Slack + Finder clipboard round trip | Works |
| S6 | Pull a USB stick mid-copy; disconnect SMB mid-listing | UI stays responsive; job pauses |

**Decision point after Phase 0:** keep the free signing approach or buy the $99 account; confirm or adjust the speed targets.

**Phase 1 → v0.1** (§3.2). Exit: two weeks of daily use with zero data-loss bugs, §10 met, and the S2 matrix passes on the real pipeline.

**Phase 2 → v0.2, Phase 3 → v0.3, then 1.0** (§3.2).

---

## 15. Open questions for you
1. **D8:** confirm Swift + AppKit.
2. ~~Xcode~~: decided, no Xcode (D13).
3. **D11:** accept the smaller v0.1 (no dual pane, no ZIP, no redo until v0.2)?
4. **D12:** Spotlight for whole-disk search until 1.0?
5. **Return key:** opens (proposed) or renames? And bare ⌫: Back (proposed) or Trash?
6. ~~GitHub repo~~: decided, not for now (D14).
7. ~~Testing hardware~~: decided, Apple Silicon only (D9).
8. **Draft cleanup:** delete the Tauri draft in this folder when building starts, keeping `docs/`?

---

## Appendix A: if the UI is Tauri + SolidJS
- **UI:** SolidJS with a custom fixed-height virtualiser.
- **Data path:** columnar binary listings over Tauri Channels; thumbnails through a `thumb://` protocol.
- **Native features:** native menus through the Tauri Menu API; `window-vibrancy`; objc2 glue for Quick Look and drag-out.
- **Updates:** tauri-plugin-updater instead of Sparkle. The same signing, translocation and rollout rules apply; `latest.json` is hosted on GitHub Pages.
- **Frame rate:** accept a **60 fps ceiling**.
- Everything else in this plan is unchanged.

## Appendix B: what changed from v1 (review findings)

**Critical:**
- Self-signed signing and the updater are now specified precisely:
  - hardened runtime off
  - static linking
  - DMG signing
  - S2 matrix across OS versions, CPU types and user types
  - an explicit $99 decision point
- Cross-volume moves now work per file, with partial names, a journal written before each step, and exact resume.
- Undo now checks file ID, volume UUID and the Trash URL; the journal has retention limits.
- Hung or ejected volumes: per-volume executors, a watchdog, and pause/resume by volume UUID.
- A preflight was added: FAT32 4 GB limit, illegal characters, 255-byte names, case-only clashes, read-only NTFS, space, permissions, locked files.
- Admin and protected paths are handled with clear messages and "Unlock" for files the user owns.

**High:**
- ZIP exclusions made precise (the AppleDouble rule, dotfiles protected, an override).
- ZIP now keeps Unix modes and symlinks, adds name-encoding detection, passwords, split-archive detection, UTC timestamps, ZIP64 only when needed, a smart extract folder and enforced bomb limits.
- Hard links, sparse files and files changing mid-copy are handled.
- File Provider folders (Dropbox, Google Drive, OneDrive) are treated like iCloud.
- No permission-prompt storms; FSEvents floods handled.
- Session restore copes with missing folders; clipboard interop with Finder.

**Updates:**
- Install guarded while jobs run; translocation detected.
- Standard-user admin prompts handled; no `.pkg`.
- Phased rollout, a kill switch and rollback DMGs; downgrade-safe databases.
- Appcast on GitHub Pages; protected release environment; key backups.
- The Homebrew reality (official casks impossible).

**Medium:**
- Keyboard collisions fixed (⌘⌫ and ⌦; bare ⌫ = Back; Tab only in dual pane).
- Locale-aware natural sort and display names.
- Thumbnail cache privacy and caps; three separate databases; schema versioning.
- Path locks between jobs; large-selection batching; accessibility and localisation groundwork; diagnostics without telemetry.

**Cut or deferred:**
- Dual pane → v0.2. Redo → v0.2. Group-by and reorderable columns → later.
- Zstd-in-ZIP and pigz-style splitting are dropped. 7z/tar → after 1.0.
- Own search index → Spotlight. CI-enforced frame-rate targets → local benchmarks.
