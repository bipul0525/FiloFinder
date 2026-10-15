import AppKit
import Quartz
import QuickLookThumbnailing

/// The main panel (captools MainPanel): grid or list of the active tab.
/// Both views ask the tab for visible rows only (the listing stays in Rust).
final class FilePanel: NSView {
    private unowned let fm: FileManagerWindowController
    let side: Side
    /// The tab this panel shows (left = tab-bar tab, right = split tab).
    private var tab: Tab { fm.tab(for: side) }
    let gridScroll = NSScrollView()
    let listScroll = NSScrollView()
    let grid = GridCollectionView()
    let list = ListTableView()
    private let layout = CaptoolsGridLayout()
    private let emptyLabel = UI.label("", size: 13, color: .tertiaryLabelColor)
    private let spinner = NSProgressIndicator()
    private var syncingSelection = false
    private let badge = SelectionBadge()
    private lazy var accessView = AccessNeededView(fm: fm)
    /// Items the selection box currently covers / uncovers (not yet committed).
    private var pendingSelect = Set<Int>()
    private var pendingDeselect = Set<Int>()

    init(fm: FileManagerWindowController, side: Side) {
        self.fm = fm
        self.side = side
        super.init(frame: .zero)
        buildGrid()
        buildList()
        emptyLabel.alignment = .center
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        for v in [gridScroll, listScroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: leadingAnchor), v.trailingAnchor.constraint(equalTo: trailingAnchor),
                v.topAnchor.constraint(equalTo: topAnchor), v.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        addSubview(emptyLabel)
        addSubview(spinner)
        addSubview(badge)
        accessView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(accessView)
        NSLayoutConstraint.activate([
            accessView.centerXAnchor.constraint(equalTo: centerXAnchor),
            accessView.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
            accessView.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40),
        ])
        grid.onBoxSelect = { [weak self] info in self?.boxSelect(info, from: self?.grid) }
        list.onBoxSelect = { [weak self] info in self?.boxSelect(info, from: self?.list) }
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: gridScroll.contentView)
        gridScroll.contentView.postsBoundsChangedNotifications = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func buildGrid() {
        layout.zoom = fm.zoom
        layout.labelSize = fm.textSize
        grid.collectionViewLayout = layout
        grid.dataSource = self
        grid.delegate = self
        grid.isSelectable = true
        grid.allowsMultipleSelection = true
        grid.backgroundColors = [.clear]
        grid.register(GridTile.self, forItemWithIdentifier: GridTile.id)
        grid.fm = fm
        grid.side = side
        grid.registerForDraggedTypes([.fileURL])
        grid.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        grid.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: false)
        gridScroll.documentView = grid
        gridScroll.hasVerticalScroller = true
        gridScroll.drawsBackground = false
        gridScroll.automaticallyAdjustsContentInsets = false
    }

    private func buildList() {
        for (id, title, width, field) in [("check", "", 22.0, nil), ("name", "Name", 420.0, SortField.name),
                                          ("type", "Type", 70.0, SortField.kind), ("size", "Size", 80.0, SortField.size)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = width
            if id == "check" { c.minWidth = 22; c.maxWidth = 22 } else { c.minWidth = 50 }
            if id == "type" || id == "size" { c.headerCell.alignment = .right }
            if let field { c.sortDescriptorPrototype = NSSortDescriptor(key: "\(field)", ascending: true) }
            list.addTableColumn(c)
        }
        list.style = .fullWidth
        list.rowHeight = 36
        list.intercellSpacing = NSSize(width: 6, height: 0)
        list.usesAlternatingRowBackgroundColors = false
        list.allowsMultipleSelection = true
        list.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        list.dataSource = self
        list.delegate = self
        list.target = fm
        list.doubleAction = #selector(FileManagerWindowController.openClicked(_:))
        list.fm = fm
        list.side = side
        list.registerForDraggedTypes([.fileURL])
        list.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        list.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: false)
        list.draggingDestinationFeedbackStyle = .regular
        listScroll.documentView = list
        listScroll.hasVerticalScroller = true
        listScroll.drawsBackground = false
    }

    // MARK: - Updates

    /// Full reload after navigation, filter or sort changes.
    func reload() {
        let tab = self.tab
        layout.zoom = fm.zoom
        layout.labelSize = fm.textSize
        // List rows grow with the name size (captools default: 36 pt at 12 pt text).
        list.rowHeight = max(28, (ListCell.nameSize(fm.textSize) * 1.4).rounded() + 20)
        gridScroll.isHidden = fm.viewMode != .grid
        listScroll.isHidden = fm.viewMode != .list
        list.tableColumn(withIdentifier: .init("check"))?.isHidden = !fm.multiSelect
        if tab.loading && tab.listing == nil { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        if fm.viewMode == .grid {
            layout.invalidateLayout()
            grid.reloadData()
        } else {
            list.reloadData()
        }
        let empty = tab.listing != nil && tab.rows.isEmpty
        emptyLabel.stringValue = tab.query.isEmpty ? "This folder is empty" : "No matching files"
        emptyLabel.isHidden = !empty || tab.accessDenied
        accessView.isHidden = !tab.accessDenied
        if tab.accessDenied { accessView.show(for: tab) }
        applySelection()
        scrolled()
    }

    /// Repaints visible cells (e.g. after cut marks changed).
    func reloadVisible() {
        if fm.viewMode == .grid {
            grid.reloadItems(at: grid.indexPathsForVisibleItems())
        } else {
            let r = list.rows(in: list.visibleRect)
            list.reloadData(forRowIndexes: IndexSet(integersIn: r.location..<NSMaxRange(r)),
                            columnIndexes: IndexSet(integersIn: 0..<list.numberOfColumns))
        }
        applySelection()
    }

    func scrollToTop() {
        gridScroll.contentView.scroll(to: .zero)
        listScroll.contentView.scroll(to: .zero)
        gridScroll.reflectScrolledClipView(gridScroll.contentView)
        listScroll.reflectScrolledClipView(listScroll.contentView)
    }

    /// Pushes tab.selection (names) into the visible view.
    func applySelection() {
        let tab = self.tab
        syncingSelection = true
        defer { syncingSelection = false }
        var indexes = IndexSet()
        if !tab.selection.isEmpty, let listing = tab.listing {
            if tab.selection.count > 2000 {
                for i in 0..<tab.rows.count where tab.row(i).map({ tab.selection.contains($0.name) }) ?? false { indexes.insert(i) }
            } else {
                for name in tab.selection { if let i = listing.indexOf(name: name) { indexes.insert(Int(i)) } }
            }
        }
        if fm.viewMode == .grid {
            grid.selectionIndexPaths = Set(indexes.map { IndexPath(item: $0, section: 0) })
        } else {
            list.selectRowIndexes(indexes, byExtendingSelection: false)
        }
    }

    func selectedIndexes() -> IndexSet {
        fm.viewMode == .grid ? IndexSet(grid.selectionIndexPaths.map(\.item)) : list.selectedRowIndexes
    }

    /// Scroll position → captools "cur/total" page label.
    @objc private func scrolled() {
        let clip = gridScroll.contentView
        let pageH = max(clip.bounds.height, 1)
        let total = max(1, Int(ceil(grid.frame.height / pageH)))
        let current = min(total, Int(clip.bounds.minY / pageH) + 1)
        if fm.focused == side { fm.pageChanged(current: current, total: total) }
    }

    func page(_ direction: Int) {
        let scroll = fm.viewMode == .grid ? gridScroll : listScroll
        let clip = scroll.contentView
        let docH = scroll.documentView?.frame.height ?? 0
        // captools pages by (rows − 1) so one row stays visible for context.
        let step = max(clip.bounds.height - (fm.viewMode == .grid ? layout.rowHeight : list.rowHeight), 40)
        let y = min(max(0, clip.bounds.minY + CGFloat(direction) * step), max(0, docH - clip.bounds.height))
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            clip.animator().setBoundsOrigin(NSPoint(x: 0, y: y))
        }
        scroll.reflectScrolledClipView(clip)
    }

    /// Shows "N selected" next to the pointer while a selection box is drawn,
    /// and keeps the status bar counting live.
    private func boxSelect(_ info: (Int, NSPoint)?, from view: NSView?) {
        guard let (count, p) = info, let view else {
            badge.isHidden = true
            pendingSelect.removeAll()
            pendingDeselect.removeAll()
            return
        }
        badge.show(count: count, at: convert(p, from: view), in: bounds)
        selectionChanged()
    }

    fileprivate func selectionChanged() {
        guard !syncingSelection else { return }
        let tab = self.tab
        tab.selection = Set(selectedIndexes().compactMap { tab.row($0)?.name })
        fm.focus(side)
        fm.selectionDidChange()
    }

    var focusTarget: NSView { fm.viewMode == .grid ? grid : list }

    /// Where a drop lands: the folder under the cursor if it accepts the
    /// files, otherwise the current folder.
    fileprivate func dropTarget(folderAt index: Int?, info: NSDraggingInfo) -> (item: Int?, dest: String, operation: NSDragOperation) {
        if tab.isVirtual && index == nil { return (nil, tab.path, []) } // tag views aren't folders
        if let index, let folder = folderPath(at: index) {
            let op = DragDrop.operation(for: info, into: folder)
            if !op.isEmpty { return (index, folder, op) }
        }
        let here = tab.path
        let op = DragDrop.operation(for: info, into: here)
        DragDrop.log.debug("hover index=\(index ?? -1) folder=\(index.flatMap { self.folderPath(at: $0) } ?? "-", privacy: .public) → here op=\(op.rawValue)")
        return (nil, here, op)
    }

    fileprivate func acceptDrop(_ info: NSDraggingInfo, folderAt index: Int?) -> Bool {
        let target = dropTarget(folderAt: index, info: info)
        DragDrop.log.notice("drop into \(target.dest, privacy: .public) op=\(target.operation.rawValue) items=\(DragDrop.paths(from: info).count)")
        return DragDrop.perform(info, into: target.dest, fm: fm)
    }

    fileprivate func fileURL(at index: Int) -> NSURL? {
        guard let e = tab.row(index) else { return nil }
        return URL(fileURLWithPath: tab.fullPath(e.name)) as NSURL
    }

    /// Path of the folder at `index` (folders and links to folders), else nil.
    fileprivate func folderPath(at index: Int) -> String? {
        guard index >= 0, let e = tab.row(index) else { return nil }
        let path = tab.fullPath(e.name)
        if e.kind == .folder { return path }
        var isDir: ObjCBool = false
        if e.kind == .symlink, FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue { return path }
        return nil
    }
}

// MARK: - Grid

extension FilePanel: NSCollectionViewDataSource, NSCollectionViewDelegate {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        tab.rows.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let tile = collectionView.makeItem(withIdentifier: GridTile.id, for: indexPath) as! GridTile
        let tab = self.tab
        if let entry = tab.row(indexPath.item) {
            tile.labelSize = fm.textSize
            tile.configure(entry: entry, path: tab.fullPath(entry.name), cell: layout.cellWidth,
                           previewing: fm.previewName == entry.name)
            if fm.isCut(tab.fullPath(entry.name)) { tile.view.alphaValue = 0.45 }
        }
        return tile
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { selectionChanged() }

    /// Live selection-box feedback: AppKit reports which tiles the box covers
    /// before the selection is committed; tiles light up from their
    /// highlightState, and the count pill follows the pointer.
    func collectionView(_ collectionView: NSCollectionView, didChangeItemsAt indexPaths: Set<IndexPath>,
                        to highlightState: NSCollectionViewItem.HighlightState) {
        for ip in indexPaths {
            switch highlightState {
            case .forSelection: pendingSelect.insert(ip.item); pendingDeselect.remove(ip.item)
            case .forDeselection: pendingDeselect.insert(ip.item); pendingSelect.remove(ip.item)
            default: pendingSelect.remove(ip.item); pendingDeselect.remove(ip.item)
            }
        }
        guard NSEvent.pressedMouseButtons & 1 == 1, let window = grid.window,
              !pendingSelect.isEmpty || !pendingDeselect.isEmpty else { return }
        let committed = Set(grid.selectionIndexPaths.map(\.item))
        let count = committed.union(pendingSelect).subtracting(pendingDeselect).count
        let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        badge.show(count: count, at: p, in: bounds)
    }

    // Drag source: real file URLs, so drops work in Finder, Mail, Slack…
    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
        true
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        fileURL(at: indexPath.item)
    }

    // Drop target: onto a folder tile = into that folder; elsewhere = this folder.
    // The target is computed from the cursor position itself rather than
    // AppKit's proposal, so a folder under the pointer always wins.
    func collectionView(_ collectionView: NSCollectionView, validateDrop info: NSDraggingInfo,
                        proposedIndexPath ptr: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation op: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        let point = collectionView.convert(info.draggingLocation, from: nil)
        let target = dropTarget(folderAt: collectionView.indexPathForItem(at: point)?.item, info: info)
        if let item = target.item {
            ptr.pointee = IndexPath(item: item, section: 0) as NSIndexPath
            op.pointee = .on
        } else {
            ptr.pointee = IndexPath(item: tab.rows.count, section: 0) as NSIndexPath
            op.pointee = .before
        }
        return target.operation
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop info: NSDraggingInfo, indexPath: IndexPath,
                        dropOperation: NSCollectionView.DropOperation) -> Bool {
        let point = collectionView.convert(info.draggingLocation, from: nil)
        return acceptDrop(info, folderAt: collectionView.indexPathForItem(at: point)?.item)
    }
}

// MARK: - List

extension FilePanel: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        tab.rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        guard let column = tableColumn, let entry = tab.row(index) else { return nil }
        let id = column.identifier
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? ListCell ?? ListCell(id: id)
        switch id.rawValue {
        case "check":
            cell.setCheck(tableView.isRowSelected(index))
        case "name":
            cell.nameFontSize = ListCell.nameSize(fm.textSize)
            cell.tagColors = Tags.colorsFor(tab.fullPath(entry.name))
            cell.setName(displayName(entry, path: tab.fullPath(entry.name)), icon: Icons.icon(for: entry, path: tab.fullPath(entry.name)), hidden: entry.hidden || fm.isCut(tab.fullPath(entry.name)))
        case "type":
            cell.setText(entry.kind == .folder ? "Folder" : (entry.name as NSString).pathExtension.uppercased())
        default:
            cell.setText(entry.kind == .folder ? "--" : ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rv = ListRowView()
        rv.previewing = tab.row(row)?.name == fm.previewName
        return rv
    }

    // Drag-selecting rows: live count while the mouse is still down.
    func tableViewSelectionIsChanging(_ notification: Notification) {
        guard NSEvent.pressedMouseButtons & 1 == 1, let window = list.window, list.numberOfSelectedRows > 1 else { return }
        list.onBoxSelect((list.numberOfSelectedRows, list.convert(window.mouseLocationOutsideOfEventStream, from: nil)))
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if fm.multiSelect, let col = list.tableColumn(withIdentifier: .init("check")).flatMap({ list.column(withIdentifier: $0.identifier) }) {
            let visible = list.rows(in: list.visibleRect)
            list.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<NSMaxRange(visible)), columnIndexes: [col])
        }
        selectionChanged()
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let d = tableView.sortDescriptors.first, let key = d.key else { return }
        let field: SortField = key == "\(SortField.kind)" ? .kind : key == "\(SortField.size)" ? .size : .name
        fm.setSort(field, descending: !d.ascending)
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        fileURL(at: row)
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        let point = tableView.convert(info.draggingLocation, from: nil)
        let hit = tableView.row(at: point)
        let target = dropTarget(folderAt: hit >= 0 ? hit : nil, info: info)
        // A folder row lights up; otherwise the whole list (= this folder).
        tableView.setDropRow(target.item ?? -1, dropOperation: .on)
        return target.operation
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        let point = tableView.convert(info.draggingLocation, from: nil)
        let hit = tableView.row(at: point)
        return acceptDrop(info, folderAt: hit >= 0 ? hit : nil)
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        tableColumn?.identifier.rawValue == "name" ? tab.row(row)?.name : nil
    }
}

// MARK: - Shared input behaviour (captools keys, multi-select clicks, ⌘-scroll zoom)

extension NSEvent {
    /// Multi-select mode ("S"): plain clicks behave like ⌘-clicks (toggle),
    /// using AppKit's own handling so dragging keeps working.
    func addingCommand() -> NSEvent {
        NSEvent.mouseEvent(with: type, location: locationInWindow, modifierFlags: modifierFlags.union(.command),
                           timestamp: timestamp, windowNumber: windowNumber, context: nil, eventNumber: eventNumber,
                           clickCount: clickCount, pressure: pressure) ?? self
    }
}

final class ListTableView: NSTableView {
    weak var fm: FileManagerWindowController?
    var side: Side = .left

    override func keyDown(with event: NSEvent) {
        if fm?.handleKey(event) != true { super.keyDown(with: event) }
    }

    var onBoxSelect: ((Int, NSPoint)?) -> Void = { _ in }

    override func mouseDown(with event: NSEvent) {
        fm?.focus(side)
        super.mouseDown(with: fm?.multiSelect == true ? event.addingCommand() : event)
        onBoxSelect(nil) // drag-select finished
    }

    // Quick Look (Space) for the selected rows.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { fm?.quickLook.begin(panel) }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { fm?.quickLook.end(panel) }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) { fm?.zoomBy(event.scrollingDeltaY > 0 ? 0.1 : -0.1); return }
        super.scrollWheel(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        fm?.focus(side)
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, !selectedRowIndexes.contains(row) {
            selectRowIndexes([row], byExtendingSelection: false)
        }
        return fm?.contextMenu(onItems: row >= 0)
    }
}

final class GridCollectionView: NSCollectionView {
    weak var fm: FileManagerWindowController?
    var side: Side = .left

    override func keyDown(with event: NSEvent) {
        if fm?.handleKey(event) != true { super.keyDown(with: event) }
    }

    /// Live box-selection feedback: (count, pointer in this view), nil = hide.
    var onBoxSelect: ((Int, NSPoint)?) -> Void = { _ in }

    override func mouseDown(with event: NSEvent) {
        fm?.focus(side)
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2, let ip = indexPathForItem(at: point) {
            fm?.open(index: ip.item)
            return
        }
        super.mouseDown(with: fm?.multiSelect == true ? event.addingCommand() : event)
        // AppKit's tracking loop (click or selection box) has finished.
        onBoxSelect(nil)
    }

    // Quick Look (Space) for the selected tiles.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { fm?.quickLook.begin(panel) }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { fm?.quickLook.end(panel) }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) { fm?.zoomBy(event.scrollingDeltaY > 0 ? 0.1 : -0.1); return }
        super.scrollWheel(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        fm?.focus(side)
        let ip = indexPathForItem(at: convert(event.locationInWindow, from: nil))
        if let ip, !selectionIndexPaths.contains(ip) {
            let old = selectionIndexPaths
            selectionIndexPaths = [ip]
            delegate?.collectionView?(self, didSelectItemsAt: selectionIndexPaths.subtracting(old))
        }
        return fm?.contextMenu(onItems: ip != nil)
    }
}

// MARK: - Grid layout (captools lib/gridLayout.ts)

/// Fixed-size tiles computed arithmetically, so 100k items cost nothing:
/// base = 100 × zoom, gap 6, padding 8, tiles stretch to fill each row,
/// row height = cell × 0.75 + 34.
final class CaptoolsGridLayout: NSCollectionViewLayout {
    var zoom: CGFloat = 1
    /// Name text size; independent of tile zoom.
    var labelSize: CGFloat = 10
    private(set) var cellWidth: CGFloat = 100
    private(set) var rowHeight: CGFloat = 109
    private var columns = 1
    private var count = 0
    private let gap: CGFloat = 6
    private let pad: CGFloat = 8

    override func prepare() {
        super.prepare()
        guard let cv = collectionView else { return }
        count = cv.numberOfSections > 0 ? cv.numberOfItems(inSection: 0) : 0
        let width = cv.enclosingScrollView?.contentView.bounds.width ?? cv.bounds.width
        let base = (100 * zoom).rounded()
        let usable = max(width - pad * 2, base)
        columns = max(1, Int((width - 16 + gap) / (base + gap)))
        cellWidth = max(base, ((usable - CGFloat(columns - 1) * gap) / CGFloat(columns)).rounded(.down))
        // captools: cell × 0.75 + 34 at 10 pt labels; taller labels add room.
        rowHeight = (cellWidth * 0.75 + 20 + GridTile.labelHeight(labelSize)).rounded()
    }

    override var collectionViewContentSize: NSSize {
        let rows = (count + columns - 1) / columns
        let width = collectionView?.enclosingScrollView?.contentView.bounds.width ?? 0
        return NSSize(width: width, height: pad * 2 + CGFloat(rows) * rowHeight + CGFloat(max(rows - 1, 0)) * gap)
    }

    private func frame(for item: Int) -> NSRect {
        let row = item / columns, col = item % columns
        return NSRect(x: pad + CGFloat(col) * (cellWidth + gap), y: pad + CGFloat(row) * (rowHeight + gap),
                      width: cellWidth, height: rowHeight)
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        guard count > 0 else { return [] }
        let firstRow = max(0, Int((rect.minY - pad) / (rowHeight + gap)))
        let lastRow = Int((rect.maxY - pad) / (rowHeight + gap))
        let first = firstRow * columns
        let last = min(count - 1, (lastRow + 1) * columns - 1)
        guard first <= last else { return [] }
        return (first...last).map { attributes(for: $0) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        indexPath.item < count ? attributes(for: indexPath.item) : nil
    }

    private func attributes(for item: Int) -> NSCollectionViewLayoutAttributes {
        let a = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: item, section: 0))
        a.frame = frame(for: item)
        return a
    }

    /// Drop targeting: the tile under the pointer (→ "drop on"), or the end
    /// of the list (→ drop into the current folder).
    override func layoutAttributesForDropTarget(at point: NSPoint) -> NSCollectionViewLayoutAttributes? {
        let col = Int((point.x - pad) / (cellWidth + gap)), row = Int((point.y - pad) / (rowHeight + gap))
        let item = row * columns + col
        if col >= 0, col < columns, row >= 0, item < count, frame(for: item).contains(point) {
            return attributes(for: item)
        }
        let gapAttrs = NSCollectionViewLayoutAttributes(forInterItemGapBefore: IndexPath(item: count, section: 0))
        gapAttrs.frame = .zero
        return gapAttrs
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        guard let cv = collectionView else { return false }
        return abs(newBounds.width - cv.bounds.width) > 0.5
    }
}

// MARK: - Grid tile (captools FileItem grid variant)

final class GridTile: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("GridTile")
    private let thumb = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let thumbBox = NSView()
    private let backdrop = NSView()
    private var op: Operation?
    private var qlRequest: QLThumbnailGenerator.Request?
    private var path = ""
    private var previewing = false
    var labelSize: CGFloat = 10
    private var labelHeightConstraint: NSLayoutConstraint?
    private var thumbHeightConstraint: NSLayoutConstraint?

    /// Names wrap onto up to two lines, like Finder, so larger text stays readable.
    static func labelHeight(_ size: CGFloat) -> CGFloat { (size * 1.25 * 2 + 2).rounded(.up) }

    private var hovered = false
    private var displayText = ""
    private var tagColors: [NSColor] = []

    override func loadView() {
        let root = HoverView()
        root.onHover = { [weak self] on in self?.hovered = on; self?.updateLook() }
        root.wantsLayer = true
        root.layer?.cornerRadius = 8
        thumbBox.wantsLayer = true
        thumbBox.layer?.cornerRadius = 8
        thumbBox.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        thumbBox.layer?.backgroundColor = NSColor.clear.cgColor // Finder: no card behind items
        thumb.imageScaling = .scaleProportionallyUpOrDown
        name.font = .systemFont(ofSize: 10)
        name.textColor = .labelColor.withAlphaComponent(0.8)
        name.alignment = .center
        name.lineBreakMode = .byWordWrapping
        name.maximumNumberOfLines = 2
        name.cell?.truncatesLastVisibleLine = true
        name.usesSingleLineMode = false
        for v in [thumbBox, thumb, name] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        root.addSubview(thumbBox)
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 8
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        thumbBox.addSubview(backdrop)
        thumbBox.addSubview(thumb)
        root.addSubview(name)
        NSLayoutConstraint.activate([
            thumbBox.topAnchor.constraint(equalTo: root.topAnchor),
            thumbBox.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            thumbBox.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            name.topAnchor.constraint(equalTo: thumbBox.bottomAnchor, constant: 4),
            // Finder: the selection backdrop hugs the icon, with a little padding.
            backdrop.centerXAnchor.constraint(equalTo: thumb.centerXAnchor),
            backdrop.centerYAnchor.constraint(equalTo: thumb.centerYAnchor),
            backdrop.widthAnchor.constraint(equalTo: thumb.widthAnchor, constant: 12).withPriority(.defaultHigh),
            backdrop.heightAnchor.constraint(equalTo: thumb.heightAnchor, constant: 12).withPriority(.defaultHigh),
            backdrop.widthAnchor.constraint(lessThanOrEqualTo: thumbBox.widthAnchor),
            backdrop.heightAnchor.constraint(lessThanOrEqualTo: thumbBox.heightAnchor),
            thumb.centerXAnchor.constraint(equalTo: thumbBox.centerXAnchor),
            thumb.centerYAnchor.constraint(equalTo: thumbBox.centerYAnchor),
            thumb.widthAnchor.constraint(lessThanOrEqualTo: thumbBox.widthAnchor, constant: -6),
            thumb.heightAnchor.constraint(lessThanOrEqualTo: thumbBox.heightAnchor, constant: -6),
            // Centred and hugging its text, so the selection pill wraps the name (Finder).
            name.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            name.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 6),
            name.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -6),
        ])
        // The thumbnail area has a fixed height (cell × 0.75); the name sits
        // below it and is only as tall as its text (1–2 lines), so the
        // selection pill hugs the name like Finder's.
        thumbHeightConstraint = thumbBox.heightAnchor.constraint(equalToConstant: 75)
        thumbHeightConstraint?.isActive = true
        labelHeightConstraint = name.heightAnchor.constraint(lessThanOrEqualToConstant: 14)
        labelHeightConstraint?.isActive = true
        view = root
        // AppKit builds the drag image (the "ghost") from these outlets.
        imageView = thumb
        textField = name
    }

    func configure(entry: EntryRow, path: String, cell: CGFloat, previewing: Bool) {
        if name.font?.pointSize != labelSize {
            name.font = .systemFont(ofSize: labelSize)
            labelHeightConstraint?.constant = Self.labelHeight(labelSize)
        }
        op?.cancel()
        ThumbnailLoader.shared.cancel(qlRequest)
        qlRequest = nil
        self.path = path
        self.previewing = previewing
        thumbHeightConstraint?.constant = (cell * 0.75).rounded()
        // Narrow no-break spaces pad the pill (Finder) without creating a line break.
        displayText = "\u{202F}" + displayName(entry, path: path) + "\u{202F}"
        tagColors = Tags.colorsFor(path)
        name.preferredMaxLayoutWidth = max(cell - 12, 20)
        view.alphaValue = entry.hidden ? 0.55 : 1
        let thumbH = cell * 0.75
        let scale = view.window?.backingScaleFactor ?? 2
        let quickLook = { [weak self] in
            guard let self else { return }
            self.qlRequest = ThumbnailLoader.shared.loadQuickLook(path, side: thumbH, scale: scale) { [weak self] image in
                guard let self, self.path == path, let image else { return }
                self.thumb.image = image
                self.setThumbSize(nil)
            }
        }
        if entry.kind == .file, isImageName(name: entry.name) {
            let px = Int(cell * scale)
            thumb.image = Icons.icon(for: entry)
            setThumbSize(thumbH * 0.34)
            op = ThumbnailLoader.shared.load(path, pixels: px) { [weak self] image in
                guard let self, self.path == path else { return }
                guard let image else { quickLook(); return } // e.g. SVG: ImageIO can't, Quick Look can
                self.thumb.image = image
                self.setThumbSize(nil)
            }
        } else {
            thumb.image = Icons.icon(for: entry, path: path)
            // captools: folder icon at 46% of the tile, other files 34%.
            setThumbSize(cell * (entry.kind == .folder ? 0.46 : 0.34))
            // Files get Quick Look thumbnails (PDF, video, docs…). Apps and
            // folders keep their real icon, as in Finder.
            if entry.kind == .file { quickLook() }
            else if entry.kind == .package { setThumbSize(cell * 0.5) }
        }
        updateLook()
    }

    private var sizeConstraints: [NSLayoutConstraint] = []

    private func setThumbSize(_ side: CGFloat?) {
        NSLayoutConstraint.deactivate(sizeConstraints)
        if let side {
            sizeConstraints = [thumb.widthAnchor.constraint(equalToConstant: side), thumb.heightAnchor.constraint(equalToConstant: side)]
        } else {
            sizeConstraints = [thumb.widthAnchor.constraint(equalTo: thumbBox.widthAnchor, constant: -6),
                               thumb.heightAnchor.constraint(equalTo: thumbBox.heightAnchor, constant: -6)]
        }
        sizeConstraints.forEach { $0.priority = .defaultHigh }
        NSLayoutConstraint.activate(sizeConstraints)
    }

    override var isSelected: Bool { didSet { updateLook() } }
    override var highlightState: NSCollectionViewItem.HighlightState { didSet { updateLook() } }

    private func updateLook() {
        guard let layer = view.layer else { return }
        let accent = NSColor.controlAccentColor
        // During a selection box AppKit only sets highlightState; treat it as
        // the selection the user will get on release.
        let selected = highlightState == .forSelection || (isSelected && highlightState != .forDeselection)
        name.wantsLayer = true
        name.layer?.cornerRadius = 5
        name.layer?.backgroundColor = selected ? accent.cgColor : NSColor.clear.cgColor
        name.attributedStringValue = Tags.label(displayText, colors: tagColors, font: .systemFont(ofSize: labelSize),
                                                textColor: selected ? .white : .labelColor.withAlphaComponent(0.85),
                                                alignment: .center)
        // Finder icon view: no borders and no card. State shows only as a
        // rounded backdrop behind the icon plus the blue name pill.
        layer.backgroundColor = NSColor.clear.cgColor
        layer.borderWidth = 0
        let fill: NSColor
        if highlightState == .asDropTarget {
            fill = accent.withAlphaComponent(0.3)
        } else if previewing {
            fill = Tone.preview.color.withAlphaComponent(0.25)
        } else if selected {
            fill = NSColor.labelColor.withAlphaComponent(0.14)
        } else if hovered {
            fill = NSColor.labelColor.withAlphaComponent(0.06)
        } else {
            fill = .clear
        }
        backdrop.layer?.backgroundColor = fill.cgColor
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        hovered = false
        op?.cancel()
        op = nil
        ThumbnailLoader.shared.cancel(qlRequest)
        qlRequest = nil
        thumb.image = nil
    }
}

// MARK: - List cells

final class ListCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let check = NSImageView()

    init(id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingMiddle
        label.font = .systemFont(ofSize: 12)
        // Outlets used by AppKit to draw the drag image for this row.
        textField = label
        if id.rawValue == "name" { imageView = icon }
        switch id.rawValue {
        case "check":
            check.translatesAutoresizingMaskIntoConstraints = false
            addSubview(check)
            NSLayoutConstraint.activate([check.centerXAnchor.constraint(equalTo: centerXAnchor),
                                         check.centerYAnchor.constraint(equalTo: centerYAnchor)])
        case "name":
            icon.translatesAutoresizingMaskIntoConstraints = false
            addSubview(icon)
            addSubview(label)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 18), icon.heightAnchor.constraint(equalToConstant: 18),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        default:
            label.alignment = .right
            label.textColor = .secondaryLabelColor
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// List names are one point larger than grid labels (captools 12 vs 10).
    static func nameSize(_ textSize: CGFloat) -> CGFloat { textSize + 2 }

    var nameFontSize: CGFloat = 12 {
        didSet { if label.font?.pointSize != nameFontSize { label.font = .systemFont(ofSize: nameFontSize) } }
    }

    var tagColors: [NSColor] = []

    func setName(_ name: String, icon image: NSImage, hidden: Bool) {
        label.attributedStringValue = Tags.label(name, colors: tagColors, font: .systemFont(ofSize: nameFontSize),
                                                 textColor: .labelColor, alignment: .left)
        icon.image = image
        alphaValue = hidden ? 0.55 : 1
    }

    func setText(_ text: String) { label.stringValue = text }

    func setCheck(_ on: Bool) {
        check.image = NSImage(systemSymbolName: on ? "checkmark.square.fill" : "square", accessibilityDescription: on ? "Selected" : "Not selected")
        check.contentTintColor = on ? .controlAccentColor : .tertiaryLabelColor
    }
}

/// captools list row: 6 px accent edge when selected, yellow when previewing.
final class ListRowView: NSTableRowView {
    var previewing = false
    private var hovered = false {
        didSet { if hovered != oldValue { needsDisplay = true } }
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func prepareForReuse() {
        super.prepareForReuse()
        hovered = false
    }

    override func drawSelection(in dirtyRect: NSRect) {
        let accent = previewing ? Tone.preview.color : NSColor.controlAccentColor
        accent.withAlphaComponent(0.16).setFill()
        bounds.fill()
        accent.setFill()
        NSRect(x: 0, y: 0, width: 4, height: bounds.height).fill()
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if previewing && !isSelected {
            Tone.preview.color.withAlphaComponent(0.1).setFill()
            bounds.fill()
        } else if hovered && !isSelected {
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
            bounds.fill()
        }
        NSColor.separatorColor.withAlphaComponent(0.4).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

/// The name as Finder shows it: no ".app", localized folder names, and the
/// user's "Show all filename extensions" setting. Operations always use the
/// real name.
func displayName(_ entry: EntryRow, path: String) -> String {
    entry.kind == .file ? (path as NSString).lastPathComponent : FileManager.default.displayName(atPath: path)
}

/// Root view of a grid tile that reports pointer enter/exit (hover effect).
final class HoverView: NSView {
    var onHover: (Bool) -> Void = { _ in }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }
}

/// "12 selected" pill that follows the pointer during box selection.
final class SelectionBadge: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.shadowOpacity = 0.25
        layer?.shadowRadius = 4
        layer?.shadowOffset = CGSize(width: 0, height: -1)
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        label.textColor = .white
        addSubview(label)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(count: Int, at p: NSPoint, in bounds: NSRect) {
        label.stringValue = count == 1 ? "1 selected" : "\(count.formatted()) selected"
        label.sizeToFit()
        let size = NSSize(width: label.frame.width + 18, height: 20)
        // Just below-right of the pointer, kept inside the panel.
        var origin = NSPoint(x: p.x + 14, y: p.y - size.height - 10)
        origin.x = min(max(origin.x, bounds.minX + 4), bounds.maxX - size.width - 4)
        origin.y = min(max(origin.y, bounds.minY + 4), bounds.maxY - size.height - 4)
        frame = NSRect(origin: origin, size: size)
        label.frame.origin = NSPoint(x: 9, y: (size.height - label.frame.height) / 2)
        layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        isHidden = false
    }
}

/// Shown in place of a folder macOS won't let us read (Trash, Mail, other
/// users' folders…): what's needed and a one-click way to allow it.
final class AccessNeededView: NSView {
    private unowned let fm: FileManagerWindowController
    private let title = UI.label("", size: 15, weight: .semibold, color: .labelColor)
    private let body = UI.label("", size: 12, color: .secondaryLabelColor)
    private var path = ""

    init(fm: FileManagerWindowController) {
        self.fm = fm
        super.init(frame: .zero)
        let icon = NSImageView(image: NSImage(systemSymbolName: "lock.shield", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 44, weight: .light)
        icon.contentTintColor = .secondaryLabelColor
        title.alignment = .center
        body.alignment = .center
        body.lineBreakMode = .byWordWrapping
        body.maximumNumberOfLines = 4
        body.preferredMaxLayoutWidth = 420
        let settings = NSButton(title: "Open Privacy Settings", target: self, action: #selector(openSettings))
        settings.bezelStyle = .rounded
        settings.keyEquivalent = "\r"
        let finder = NSButton(title: "Open in Finder", target: self, action: #selector(openFinder))
        finder.bezelStyle = .rounded
        let retry = NSButton(title: "Try Again", target: self, action: #selector(retry))
        retry.bezelStyle = .rounded
        let buttons = UI.hstack([finder, retry, settings], spacing: 10)
        let stack = NSStackView(views: [icon, title, body, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(18, after: body)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            body.widthAnchor.constraint(lessThanOrEqualToConstant: 440),
        ])
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(for tab: Tab) {
        path = tab.path
        let name = tab.isTrash ? "the Trash" : "“\(tab.name)”"
        title.stringValue = "Filofinder needs permission to show \(name)"
        body.stringValue = "macOS protects this location. In System Settings → Privacy & Security → Full Disk Access, "
            + "turn on Filofinder, then click Try Again. Filofinder only reads folders you open."
    }

    @objc private func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openFinder() { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
    @objc private func retry() { fm.refresh(nil) }
}
