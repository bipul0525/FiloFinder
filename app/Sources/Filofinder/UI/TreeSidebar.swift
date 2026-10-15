import AppKit

/// Folder tree sidebar ("EXPLORER", captools layout) covering the whole Mac:
/// Favorites + Locations (startup disk and mounted drives). Every folder
/// expands lazily. Uses the sidebar vibrancy material.
final class TreeSidebar: NSVisualEffectView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    final class Node {
        let path: String
        let name: String
        let symbol: String
        let isGroup: Bool
        var children: [Node]?
        /// First few images inside (folder previews); nil until looked up.
        var previews: [String]?
        init(path: String, name: String, symbol: String = "folder", isGroup: Bool = false, children: [Node]? = nil) {
            self.path = path
            self.name = name
            self.symbol = symbol
            self.isGroup = isGroup
            self.children = children
        }
    }

    private unowned let fm: FileManagerWindowController
    private let outline = NSOutlineView()
    private var groups: [Node] = []
    private var isSyncing = false

    init(fm: FileManagerWindowController) {
        self.fm = fm
        super.init(frame: .zero)
        material = .sidebar
        blendingMode = .behindWindow
        state = .followsWindowActiveState

        let title = UI.label("EXPLORER", size: 10, weight: .semibold, color: .secondaryLabelColor)
        let refresh = UI.iconButton("arrow.clockwise", "Refresh tree", target: self, action: #selector(refreshTree), size: 22)
        let newFolder = UI.iconButton("folder.badge.plus", "New Folder", target: fm,
                                      action: #selector(FileManagerWindowController.newFolder(_:)), size: 22)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let header = UI.hstack([title, spacer, smallerButton, largerButton, previewsButton, refresh, newFolder], spacing: 2)

        let column = NSTableColumn(identifier: .init("tree"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .small
        outline.floatsGroupRows = false
        outline.indentationPerLevel = 8
        outline.dataSource = self
        outline.delegate = self
        outline.backgroundColor = .clear
        outline.registerForDraggedTypes([.fileURL])
        outline.draggingDestinationFeedbackStyle = .sourceList
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        addSubview(header)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            header.heightAnchor.constraint(equalToConstant: 24),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 2),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        for (b, sel) in [(previewsButton, #selector(togglePreviews)), (smallerButton, #selector(smallerPreviews)),
                         (largerButton, #selector(largerPreviews))] as [(NSButton, Selector)] {
            b.target = self
            b.action = sel
        }
        updatePreviewButtons()
        buildGroups()
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(volumesChanged), name: NSWorkspace.didMountNotification, object: nil)
        ws.addObserver(self, selector: #selector(volumesChanged), name: NSWorkspace.didUnmountNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func buildGroups() {
        let home = Tab.home
        let fmgr = FileManager.default
        var favorites = [Node(path: home, name: NSUserName(), symbol: "house")]
        for (folder, symbol) in [("Desktop", "menubar.dock.rectangle"), ("Documents", "doc"), ("Downloads", "arrow.down.circle"),
                                 ("Pictures", "photo"), ("Movies", "film"), ("Music", "music.note")] {
            let p = (home as NSString).appendingPathComponent(folder)
            if fmgr.fileExists(atPath: p) { favorites.append(Node(path: p, name: folder, symbol: symbol)) }
        }
        favorites.insert(Node(path: "/Applications", name: "Applications", symbol: "square.grid.3x3"), at: 1)

        var locations = [Node(path: "/", name: volumeName("/"), symbol: "internaldrive")]
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsRemovableKey, .volumeIsLocalKey]
        for url in fmgr.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [] where url.path != "/" {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let symbol = values?.volumeIsLocal == false ? "network" : values?.volumeIsRemovable == true ? "externaldrive" : "internaldrive"
            locations.append(Node(path: url.path, name: values?.volumeLocalizedName ?? url.lastPathComponent, symbol: symbol))
        }
        let trash = (Tab.home as NSString).appendingPathComponent(".Trash")
        locations.append(Node(path: trash, name: "Trash", symbol: "trash", children: []))
        let tags = Tags.colors.map { Node(path: Tags.path(for: $0.name), name: $0.name, symbol: "circle.fill", children: []) }
        groups = [
            Node(path: "", name: "Favorites", isGroup: true, children: favorites),
            Node(path: "", name: "Locations", isGroup: true, children: locations),
            Node(path: "", name: "Tags", isGroup: true, children: tags),
        ]
        outline.reloadData()
        groups.forEach { outline.expandItem($0) }
    }

    @objc private func volumesChanged() {
        buildGroups()
        update()
    }

    @objc private func refreshTree() {
        buildGroups()
        update()
    }

    // MARK: Folder previews (captools): thumbnails of a folder's first images

    private let previewsButton = HoverButton(symbol: "photo.on.rectangle", tooltip: "Show folder previews", target: nil,
                                             action: nil, size: 24, pointSize: 11.5)
    private let smallerButton = HoverButton(symbol: "minus.magnifyingglass", tooltip: "Smaller previews", target: nil,
                                            action: nil, size: 24, pointSize: 11.5)
    private let largerButton = HoverButton(symbol: "plus.magnifyingglass", tooltip: "Larger previews", target: nil,
                                           action: nil, size: 24, pointSize: 11.5)
    private let previewQueue = DispatchQueue(label: "app.filofinder.tree-previews", qos: .utility)

    private var showPreviews: Bool {
        get { UserDefaults.standard.object(forKey: "treePreviews") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "treePreviews") }
    }
    private var previewSize: CGFloat {
        get { CGFloat(UserDefaults.standard.object(forKey: "treePreviewSize") as? Double ?? 22) }
        set { UserDefaults.standard.set(Double(newValue), forKey: "treePreviewSize") }
    }

    private func updatePreviewButtons() {
        previewsButton.toolTip = showPreviews ? "Hide folder previews" : "Show folder previews"
        previewsButton.image = NSImage(systemSymbolName: showPreviews ? "photo.on.rectangle.angled" : "photo.on.rectangle",
                                       accessibilityDescription: previewsButton.toolTip)
        previewsButton.contentTintColor = showPreviews ? .controlAccentColor : nil
        smallerButton.isHidden = !showPreviews
        largerButton.isHidden = !showPreviews
        smallerButton.isEnabled = previewSize > 16
        largerButton.isEnabled = previewSize < 48
    }

    @objc private func togglePreviews() {
        showPreviews.toggle()
        updatePreviewButtons()
        reloadVisibleRows()
    }

    @objc private func smallerPreviews() { previewSize = max(16, previewSize - 4); updatePreviewButtons(); reloadVisibleRows() }
    @objc private func largerPreviews() { previewSize = min(48, previewSize + 4); updatePreviewButtons(); reloadVisibleRows() }

    /// Row heights and cells change with the preview size; keep expansion.
    private func reloadVisibleRows() {
        let all = IndexSet(integersIn: 0..<outline.numberOfRows)
        outline.noteHeightOfRows(withIndexesChanged: all)
        outline.reloadData(forRowIndexes: all, columnIndexes: [0])
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let node = item as? Node, !node.isGroup else { return 24 }
        return showPreviews && (node.previews?.isEmpty == false) ? max(24, previewSize + 6) : 24
    }

    /// Looks up a folder's first 3 images in the background, then updates
    /// its row (only rows on screen ask, so this stays cheap).
    private func loadPreviews(for node: Node) {
        node.previews = [] // mark as in-flight
        let path = node.path
        previewQueue.async { [weak self] in
            var found: [String] = []
            if let listing = try? listDir(path: path, showHidden: false, backend: .bulk) {
                for i in 0..<listing.count() where found.count < 3 {
                    guard let r = listing.row(index: i), r.kind == .file, isImageName(name: r.name) else { continue }
                    found.append((path as NSString).appendingPathComponent(r.name))
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                node.previews = found
                guard !found.isEmpty else { return }
                let row = self.outline.row(forItem: node)
                guard row >= 0 else { return }
                self.outline.noteHeightOfRows(withIndexesChanged: [row])
                (self.outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? TreeCell)?
                    .setPreviews(found, size: self.previewSize)
            }
        }
    }

    /// Nodes this sidebar expanded to reveal the current folder; collapsed
    /// again when you leave them (folders you open yourself stay open).
    private var autoExpanded: [Node] = []

    /// captools-style: the disk tree opens down to the current folder, and
    /// that folder is expanded to show its subfolders.
    func update() {
        let path = fm.activeTab.path
        isSyncing = true
        defer { isSyncing = false }
        if Tags.tag(fromPath: path) != nil,
           let node = groups.first(where: { $0.name == "Tags" })?.children?.first(where: { $0.path == path }) {
            outline.selectRowIndexes([outline.row(forItem: node)], byExtendingSelection: false)
            return
        }
        for n in autoExpanded.reversed() where !isAncestorOrSelf(n.path, of: path) {
            outline.collapseItem(n)
        }
        autoExpanded.removeAll { !isAncestorOrSelf($0.path, of: path) }
        guard let target = reveal(path) else { outline.deselectAll(nil); return }
        expand(target)
        let row = outline.row(forItem: target)
        if row >= 0 {
            outline.selectRowIndexes([row], byExtendingSelection: false)
            outline.scrollRowToVisible(row)
        }
    }

    private func isAncestorOrSelf(_ a: String, of path: String) -> Bool {
        a == "/" || path == a || path.hasPrefix(a + "/")
    }

    private func expand(_ n: Node) {
        guard !outline.isItemExpanded(n) else { return }
        outline.expandItem(n)
        autoExpanded.append(n)
    }

    /// Walks down to `path` from the closest starting point: the deepest
    /// Favorite containing it (Desktop, Documents…), else its volume. This
    /// keeps the tree shallow — no Macintosh HD › Users › you › … chains.
    private func reveal(_ path: String) -> Node? {
        let roots = groups.filter { $0.name != "Tags" }.flatMap { $0.children ?? [] }
            .filter { $0.symbol != "trash" && isAncestorOrSelf($0.path, of: path) }
        // Deepest match wins; Favorites win ties (they're listed first).
        guard var node = roots.reduce(nil as Node?, { best, n in
            guard let best else { return n }
            return n.path.count > best.path.count ? n : best
        }) else { return nil }
        let rest = node.path == "/" ? path : String(path.dropFirst(node.path.count))
        for comp in rest.split(separator: "/") {
            guard let child = children(of: node).first(where: { $0.name == String(comp) }) else { break }
            expand(node)
            node = child
        }
        return node
    }

    /// Re-lists every expanded folder (after copy/move/new folder), keeping
    /// existing nodes so expansion and selection survive.
    func refreshExpanded() {
        func refresh(_ n: Node) {
            guard let old = n.children else { return }
            if !n.isGroup {
                let fresh = listFolders(n.path)
                n.children = fresh.map { name in
                    old.first { $0.name == name } ?? Node(path: (n.path as NSString).appendingPathComponent(name), name: name)
                }
                outline.reloadItem(n, reloadChildren: true)
            }
            for c in n.children ?? [] where outline.isItemExpanded(c) { refresh(c) }
        }
        isSyncing = true
        groups.forEach(refresh)
        isSyncing = false
        update()
    }

    private func listFolders(_ path: String) -> [String] {
        var names: [String] = []
        if let listing = try? listDir(path: path, showHidden: false, backend: .bulk) {
            for i in 0..<listing.count() {
                guard let r = listing.row(index: i), r.kind == .folder else { break } // folders sort first
                names.append(r.name)
            }
        }
        return names
    }

    private func children(of node: Node) -> [Node] {
        if let c = node.children { return c }
        let result = listFolders(node.path).map { Node(path: (node.path as NSString).appendingPathComponent($0), name: $0) }
        node.children = result
        return result
    }

    // MARK: Outline data

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? Node else { return groups.count }
        return children(of: node).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? Node else { return groups[index] }
        return children(of: node)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? Node else { return false }
        if node.isGroup { return true }
        // Unknown until listed; the chevron disappears once found empty.
        return node.children.map { !$0.isEmpty } ?? true
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? Node)?.isGroup == true
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? Node)?.isGroup != true
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        if node.isGroup {
            let cell = outlineView.makeView(withIdentifier: .init("group"), owner: self) as? NSTableCellView ?? makeCell(group: true)
            cell.textField?.stringValue = node.name
            return cell
        }
        let cell = outlineView.makeView(withIdentifier: .init("node"), owner: self) as? TreeCell ?? makeCell(group: false) as! TreeCell
        cell.textField?.stringValue = node.name
        if let tagColor = Tags.tag(fromPath: node.path).flatMap(Tags.color(named:)) {
            // Pre-coloured (non-template) dot: the sidebar style would recolour a template image.
            let dot = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: node.name)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .regular).applying(.init(paletteColors: [tagColor])))
            dot?.isTemplate = false
            cell.imageView?.image = dot
            cell.imageView?.contentTintColor = nil
        } else {
            // Each place has its own colour; subfolders inherit it (Downloads → green…).
            // Muted: top-level places get a soft tint; subfolders an even softer outline.
            let sub = node.symbol == "folder"
            cell.imageView?.image = PlaceColor.icon(node.symbol,
                                                    color: PlaceColor.muted(PlaceColor.color(for: node.path),
                                                                            strength: sub ? 0.3 : 0.5))
            cell.imageView?.contentTintColor = nil
        }
        (cell as? TreeCell)?.addButton.isEnabled = Tags.tag(fromPath: node.path) == nil
        cell.toolTip = node.path
        cell.onNewFolder = { [weak self] in self?.fm.ops.newFolder(in: node.path) }
        let previewable = showPreviews && Tags.tag(fromPath: node.path) == nil && node.symbol != "trash"
        cell.setPreviews(previewable ? (node.previews ?? []) : [], size: previewSize)
        if previewable && node.previews == nil { loadPreviews(for: node) }
        return cell
    }

    private func makeCell(group: Bool) -> NSTableCellView {
        let cell: NSTableCellView = group ? NSTableCellView() : TreeCell()
        cell.identifier = .init(group ? "group" : "node")
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingMiddle
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.textField = text
        if group {
            text.font = .systemFont(ofSize: 11, weight: .semibold)
            text.textColor = .secondaryLabelColor
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        } else {
            text.font = .systemFont(ofSize: 12.5)
            let image = NSImageView()
            image.symbolConfiguration = .init(pointSize: 12.5, weight: .regular)
            image.contentTintColor = .secondaryLabelColor
            image.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image)
            cell.imageView = image
            let add = (cell as! TreeCell).addButton
            let thumbs = (cell as! TreeCell).previewStack
            cell.addSubview(add)
            cell.addSubview(thumbs)
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
                text.trailingAnchor.constraint(lessThanOrEqualTo: thumbs.leadingAnchor, constant: -6),
                thumbs.trailingAnchor.constraint(lessThanOrEqualTo: add.leadingAnchor, constant: -2),
                thumbs.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                add.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                add.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        return cell
    }

    // Drop files onto any sidebar folder (Desktop, a drive, a subfolder…).
    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        guard let node = item as? Node, !node.isGroup else { return [] }
        outlineView.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return DragDrop.operation(for: info, into: node.path)
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let node = item as? Node, !node.isGroup else { return false }
        return DragDrop.perform(info, into: node.path, fm: fm)
    }

    /// Test hook: simulates a real mouse click on `row` (in-process events,
    /// no accessibility permission needed).
    /// Test hook: selects `row` exactly as a click does (same delegate path).
    func debugClick(row: Int) {
        outline.selectRowIndexes([row], byExtendingSelection: false)
        FileHandle.standardError.write(Data("[tree] selected row \(row) (\((outline.item(atRow: row) as? Node)?.path ?? "?"))\n".utf8))
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        FileHandle.standardError.write(Data("[tree] selectionDidChange row=\(outline.selectedRow) syncing=\(isSyncing)\n".utf8))
        guard !isSyncing, let node = outline.item(atRow: outline.selectedRow) as? Node, !node.isGroup else { return }
        if node.symbol == "trash" { fm.openTrash(nil); return }
        fm.navigate(to: node.path)
    }
}

/// Tree row with captools' hover-only "New Folder" button.
final class TreeCell: NSTableCellView {
    var onNewFolder: (() -> Void)?
    let addButton: NSButton
    /// Folder preview thumbnails (captools tree previews).
    let previewStack: NSStackView = {
        let s = NSStackView()
        s.orientation = .horizontal
        s.spacing = 3
        s.translatesAutoresizingMaskIntoConstraints = false
        s.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        return s
    }()
    private var shownPreviews: [String] = []
    private var shownSize: CGFloat = 0

    func setPreviews(_ paths: [String], size: CGFloat) {
        guard paths != shownPreviews || size != shownSize else { return }
        shownPreviews = paths
        shownSize = size
        previewStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        previewStack.isHidden = paths.isEmpty
        for path in paths { previewStack.addArrangedSubview(TreeThumb(path: path, size: size)) }
    }
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        addButton = UI.iconButton("folder.badge.plus", "New Folder", target: nil, action: nil, size: 20)
        super.init(frame: frame)
        addButton.isBordered = false
        addButton.target = self
        addButton.action = #selector(add)
        addButton.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func add() { onNewFolder?() }

    /// Selected row: icon and text at full strength; otherwise a soft grey icon.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            guard imageView?.image?.isTemplate != false else { return } // keep tag dots coloured
            imageView?.contentTintColor = backgroundStyle == .emphasized ? .labelColor : .secondaryLabelColor
        }
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { addButton.isHidden = false }
    override func mouseExited(with event: NSEvent) { addButton.isHidden = true }
    override func prepareForReuse() {
        super.prepareForReuse()
        addButton.isHidden = true
    }
}

/// One small folder-preview thumbnail; hovering shows a large preview.
final class TreeThumb: NSImageView {
    private let path: String
    private var popover: NSPopover?

    init(path: String, size: CGFloat) {
        self.path = path
        super.init(frame: .zero)
        imageScaling = .scaleProportionallyUpOrDown
        wantsLayer = true
        layer?.cornerRadius = 3
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: size), heightAnchor.constraint(equalToConstant: size)])
        toolTip = (path as NSString).lastPathComponent
        ThumbnailLoader.shared.load(path, pixels: Int(size * 2)) { [weak self] img in
            if let img { self?.image = img; return }
            // Formats ImageIO can't decode (SVG…): Quick Look renders them.
            ThumbnailLoader.shared.loadQuickLook(path, side: size, scale: 2) { self?.image = $0 }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.frame = NSRect(x: 0, y: 0, width: 224, height: 224)
        let label = NSTextField(labelWithString: (path as NSString).lastPathComponent)
        label.font = .systemFont(ofSize: 10)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.frame = NSRect(x: 8, y: 4, width: 224, height: 14)
        view.frame.origin = NSPoint(x: 8, y: 22)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 252))
        content.addSubview(view)
        content.addSubview(label)
        let vc = NSViewController()
        vc.view = content
        let p = NSPopover()
        p.contentViewController = vc
        p.behavior = .semitransient
        p.animates = false
        p.show(relativeTo: bounds, of: self, preferredEdge: .maxX)
        popover = p
        let path = self.path
        ThumbnailLoader.shared.load(path, pixels: 448) { img in
            if let img { view.image = img; return }
            ThumbnailLoader.shared.loadQuickLook(path, side: 224, scale: 2) { view.image = $0 }
        }
    }

    override func mouseExited(with event: NSEvent) {
        popover?.close()
        popover = nil
    }
}
