# Filofinder — UI Spec

**Rule (PLAN D3):** the layout, controls, order, labels, tooltips, shortcuts and behaviour are the **same as the captools file manager**. Only the *styling* is native macOS.

Source of truth: the captools source at `~/Documents/Yupcha Office/CODE/captools/src/components/tools/filemanager/` (FM = `FileManager.tsx`, C/ = `components/`). Captools has no screenshots, so this spec was extracted from its TSX.

---

## 1. Style translation: captools → macOS

| captools | Filofinder (macOS) |
|---|---|
| Dark-first navy/teal theme ("liquid glass") | Follows the system light/dark setting; the accent colour comes from System Settings |
| Glass / blur cards | `NSVisualEffectView` materials: `.sidebar`, `.headerView`, `.popover`, `.hudWindow` |
| Keycap 3D buttons (`KEYCAP_NEUTRAL`, 28×28, glyph-coloured) | Native bordered buttons with SF Symbols (14 pt), toolbar style; *on* state uses the accent tint |
| `key3d(tone)` round tone buttons (24px) | Small round buttons tinted with the system tone colour |
| `CloseButton` (rose circle ×) | Small round `xmark` button, tinted red |
| `DANGER_PILL` (rose labelled pill) | Bordered button with `.hasDestructiveAction` / red tint |
| Panel identity: left = blue, right = amber, bin = rose, previewing = yellow | `systemBlue`, `systemOrange`, `systemPink`, `systemYellow` |
| Positive / cross-panel drop | `systemGreen` |
| Lucide icons | SF Symbols (mapping in §8) |
| Tailwind sizes (9–12px chrome text) | System font at 10–12 pt, monospaced digits for counts |
| shadcn dialogs | Native sheets (`NSAlert` / custom sheet windows) |
| Toasts (sonner) | A small transient HUD at the bottom of the window |
| HTML `<select>` tab picker | `NSPopUpButton` |

---

## 2. Window layout (FM:3477-3910)

```
┌ Toolbar (36) ─────────────────────────────────────────────────────────────────┐
│ [Tree][|][ZIP][Folder][|][Split][Bin n]  [ ACTION CLUSTER ]  ⟷  [View controls][|][Clear] │
├ TabBar (28) — hidden in split mode ───────────────────────────────────────────┤
├ Breadcrumbs (32): ← → ⟳ | ⌂ › crumb › crumb      [🔍 filter] — hidden in split  │
├ Content ──────────────────────────────────────────────────────────────────────┤
│ No folder open → Empty state                                                   │
│ Single: [Tree 220 (80–540)] │ [Main panel] │ [Preview 400 (200–700)]             │
│ Split / bin: Left 50% │ Right 50% (each ≥ 20%)                                   │
│   Left = header(36, blue) / main panel / stats(24)                             │
│   Right = header(36, amber) / split panel or empty state / stats(24), or Bin (rose)│
├ Status bar (24) — single mode only ───────────────────────────────────────────┤
```

**Focus:** the focused split panel gets a 2 px inset ring in its tone colour. Hovering a panel focuses it.

---

## 3. Toolbar (C/Toolbar.tsx)

**Left zone**
1. **Folder Tree:** `sidebar.left`. Tooltip "Toggle Folder Tree". In split or bin mode it is disabled, with the tooltip "Folder Tree is available in full-screen view only".
2. Separator.
3. **Open ZIP:** `archivebox`. Tooltip "Open & browse a ZIP file".
4. **Open directory:** `folder`. Tooltip "Open a local directory".
5. Separator.
6. **Split View:** `rectangle.split.2x1`. Tooltip "Split View" / "Exit Split View", shortcut ⌘M. Shown highlighted when on.
7. **Recycle Bin pill:** `trash` plus the count (only when above 0). Tooltip "Open Recycle Bin" / "Close Recycle Bin". Inverted colours while open.

**Action cluster** (only when a folder is open)
- Shown as a rounded group with a left strip in the target panel's tone.
- Buttons, in order:
  1. **New Folder:** `folder.badge.plus`.
  2. |
  3. **Multi-select:** `square` / `checkmark.square`. Tooltip "Enable multi-select" / "Disable multi-select" (S).
  4. **Select All:** `checklist`. ⌘A.
  5. |
  6. **Copy:** `doc.on.doc`. ⌘C.
  7. **Cut:** `scissors`. ⌘X.
  8. **Paste:** `doc.on.clipboard`. ⌘V.
  9. |
  10. **Undo:** `arrow.uturn.backward`. ⌘Z.
  11. **Redo:** `arrow.uturn.forward`. ⇧⌘Z.
  12. *(split/bin only)* | **Preview:** `eye` / `eye.slash`.
  13. |
  14. **Move to Recycle Bin:** `trash`. Del.
  15. **Delete permanently:** `xmark.bin`, red. ⌘Del.
- Copy, Cut, Delete and Move to Bin are disabled when nothing is selected. Paste is disabled when the clipboard is empty.

**View controls** (only when a folder is open)
1. **List View:** `list.bullet`.
2. **Grid View:** `square.grid.2x2`.
3. |
4. **Zoom Out:** `minus.magnifyingglass`. Range 0.5–2.5, step 0.2.
5. **Zoom In:** `plus.magnifyingglass`. Same range and step.
6. *(grid, single mode only)* | **Page Up:** `chevron.up`, then a "cur/total" label, then **Page Down:** `chevron.down`.
7. *(single mode only)* | **Preview pane:** `eye`. Tooltip "Show Preview Pane" / "Hide Preview Pane".
8. *(not in ZIP mode)* | **Create ZIP:** `doc.zipper`. Tooltip "Create ZIP from selected files".

**Far right**
- Separator, then the **Clear** button (destructive): `trash` + "Clear". It asks to confirm:
  - title "Reset Everything"
  - message "This will close all tabs, clear the bin, and free all memory. This cannot be undone."
  - button "Reset"

## 4. TabBar (C/TabBar.tsx)
- **Each tab:** `folder` icon (12) · name (max 120, truncated) · `lock` (shown when access needs restoring).
  - On hover: `rectangle.righthalf.inset.filled` "Open in right panel" (split mode) and × "Close tab" (only when there's more than one tab).
  - Then a **+** button: "New Tab".
- **Active tab:** filled. In split mode the left tab is tinted blue and the right tab orange.
- **Double-click** copies the folder name and shows the HUD "Copied folder name".
- **Dragging:** hovering a tab for 400 ms during a drag switches to it, with a progress line growing along its bottom.
- **Right-click menu:** Duplicate Tab | Close Tab · Close Other Tabs · Close Tabs to Right.

## 5. Breadcrumbs (C/Breadcrumbs.tsx)
- **Buttons:**
  - **Back:** `arrow.left`. Tooltip "Back (⌘[ or ⌥←)".
  - **Forward:** `arrow.right`. Tooltip "Forward (⌘] or ⌥→)".
  - **Refresh:** `arrow.clockwise`. Tooltip "Refresh (F5)".
  - | `house`, then the crumbs separated by `chevron.right`.
- **Crumb styles:** the last crumb is primary text, medium weight. Earlier crumbs are secondary and take the accent colour on hover.
- **Dragging:** hovering a crumb for 600 ms opens it.
- **PanelSearch** sits at the right (200 px).

## 6. Split panel headers (C/SplitPanelHeader.tsx)
- 36 px tall, with a tone strip and dot. Contents in order:
  1. round Back, Forward and Refresh buttons
  2. a folder icon
  3. compact breadcrumbs (11 pt)
  4. PanelSearch (150)
  5. the tab picker (`NSPopUpButton`)
  6. Close panel
- The right panel shows italic "No folder" when it has no folder open.

## 7. PanelSearch (C/PanelSearch.tsx)
- **Collapsed:** a `magnifyingglass` button. Tooltip "Search / filter this panel".
- **Expanded:** a field with placeholder "Filter…", the match count, and a clear button (×).
- **While a filter is active:** the field gets a ring in the panel's tone and stays expanded.
- **Esc** clears the filter and collapses the field.

## 8. File items (C/FileItem.tsx, lib/gridLayout.ts)

**Grid geometry**
- Base tile = 100 × zoom. Gap 6, padding 8.
- Columns = ⌊(W − 16 + 6)/(base + 6)⌋. Tiles stretch to fill the row.
- Row height = cell × 0.75 + 34.

**Grid tile**
- **Thumbnail area:** cell × 0.75 high, on a light fill.
  - Images: the thumbnail, aspect-fit.
  - Folders: the folder icon at 46%.
  - Other files: a file glyph at 34%.
- **Name:** 10 pt, centred, truncated.
- **States:**
  - Selected: accent at 10% fill plus a 2 px accent ring.
  - Hover: a subtle fill.
  - Previewing: a yellow ring.
  - Folder drag-over: accent fill. After 600 ms the folder springs open, with a progress line.
- **Quick-bin:** a 16 px round trash button at the top-left, shown on hover (files only).
- **Just moved:** a pulsing accent dot at the bottom centre.

**List row** (36 px)
- **Columns:** checkbox (only in multi-select) · icon (16) · name · Type ("Folder" or the upper-case extension, 64 wide) · Size (64).
- **Selected:** accent fill, with a 6 px accent left edge.
- **Header:** Name | Type | Size, sortable, with `chevron.up.chevron.down` on the sorted column.
- **Wide windows:** the list flows into several columns. Column width fits the longest name (minimum 190, at most 8 columns).

**Other**
- **NameWithCopy:** hovering a name for 3 s shows a popover with the full name and a "Copy name" button.
- **PanelInfoFooter:** fills the space below the items.
  - The folder name as a faint large watermark.
  - Coloured counts: "N images" (blue), "N files" (grey), "N folders" (orange).

## 9. Tree sidebar (C/TreeSidebar.tsx)
- **Header:** "EXPLORER". Buttons:
  - Smaller previews / Larger previews (only while previews are on)
  - Show folder previews
  - Refresh tree
  - New folder at root
- **Root row:** `house` + the root name. Filled with the accent colour while you're at the root.
- **Node rows:** chevron · `folder` · name. On hover: + New Folder, preview thumbnails, and a child-count pill.
- **Row states:**
  - Active: accent tint.
  - In the active path: a subtle fill.
  - Empty folder: shows "No subfolders".
- **Right-click menu:** New Folder, Refresh | Rename | Delete.
- Background: the sidebar vibrancy material.

## 10. Status bar (C/SplitStatusBar.tsx), 24 px, 10 pt
- Contents, left to right:
  1. **Count:** "{n} items", or "{filtered} of {total} items". It says "images" when every item is an image.
  2. A "{n} selected" chip in the panel's tone.
  3. "Select moved ({n})".
  4. "ZIP Mode".
  5. The SortTimer, at the right.

## 11. Empty state (C/EmptyState.tsx)
- A large faint folder icon over an accent halo.
- **Title:** "Open a dataset".
- **Body:** "Sort thousands of images without uploading anything — the files never leave this machine."
- **Buttons:** [Open ZIP] (primary), [Open Directory].
- **Hint:** "Or drop .zip files anywhere here — each opens in its own tab."

## 12. Context menu (C/ContextMenu.tsx)
- New Folder · Refresh (F5)
- |
- Copy (⌘C) · Cut (⌘X) · Paste (⌘V) · Rename (F2) · Duplicate (⌘D) · Invert Selection
- | Create ZIP
- |
- Move to Bin (Del) · Delete Permanently (red)

## 13. Dialogs
These are defined in captools and to be built natively as sheets: ConflictDialog, ZipSaveModal, ZipCompleteDialog, ZipIssueDialog, ProgressOverlay (segmented meter), BinPanel and the floating preview popup.

## 14. Keyboard shortcuts
| Keys | Action |
|---|---|
| ⌘C / ⌘X / ⌘V | Copy / Cut / Paste |
| ⌘A | Select All |
| ⌘D | Duplicate |
| S | Toggle multi-select |
| ⌘Z / ⇧⌘Z | Undo / Redo |
| ⌘M | Split view |
| F2 | Rename |
| F5 | Refresh |
| ⌘[ / ⌥← | Back |
| ⌘] / ⌥→ | Forward |
| Del / ⌫ | Move to bin |
| ⌘Del / ⌘⌫ | Delete permanently |
| Esc | Deselect / cancel |
| Space / ⇧Space | Page down / page up |
| ⌘ + scroll | Zoom |

**Changes from PLAN §3.3 (Explorer keys):** captools' keys win. ⌫ moves to the bin, as in captools, and Return opens.

---

## Build order
1. **Iteration 1 (now):**
   - Window shell: toolbar, tab bar, breadcrumbs, tree sidebar, main panel (grid and list, zoom), status bar, empty state, preview pane, PanelSearch.
   - Navigation, tabs, selection, multi-select, filtering, open directory.
   - The action buttons are placed but disabled until the job engine exists.
2. **Iteration 2:** the job engine (copy, cut/paste, move, new folder, rename, duplicate, bin, undo/redo), the conflict dialog and the progress overlay.
3. **Iteration 3:** split view, the bin panel, drag and drop, spring-loading, tab hover-switching, the context menu.
4. **Iteration 4 (v0.2):** ZIP open, browse, extract and create, the ZIP dialogs and the sort timer.
