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
        let header = UI.hstack([title, spacer, refresh, newFolder], spacing: 2)

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
            cell.imageView?.image = NSImage(systemSymbolName: node.symbol, accessibilityDescription: nil)
            cell.imageView?.contentTintColor = .controlAccentColor
        }
        (cell as? TreeCell)?.addButton.isEnabled = Tags.tag(fromPath: node.path) == nil
        cell.toolTip = node.path
        cell.onNewFolder = { [weak self] in self?.fm.ops.newFolder(in: node.path) }
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
            image.symbolConfiguration = .init(pointSize: 12, weight: .regular)
            image.contentTintColor = .controlAccentColor
            image.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image)
            cell.imageView = image
            let add = (cell as! TreeCell).addButton
            cell.addSubview(add)
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
                text.trailingAnchor.constraint(lessThanOrEqualTo: add.leadingAnchor, constant: -2),
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
