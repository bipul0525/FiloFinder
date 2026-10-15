import AppKit

/// Finder-style context menus: one for items, one for empty space.
/// Plain titles (no icons), Finder's ordering and wording, ⌥ alternates.
final class ContextMenuBuilder: NSObject {
    private unowned let fm: FileManagerWindowController
    private var paths: [String] = []

    init(fm: FileManagerWindowController) {
        self.fm = fm
    }

    // MARK: Item menu

    func itemMenu(for paths: [String]) -> NSMenu {
        self.paths = paths
        let menu = NSMenu()
        menu.autoenablesItems = false
        let single = paths.count == 1
        let name = (paths.first.map { ($0 as NSString).lastPathComponent }) ?? ""
        let label = single ? "“\(name)”" : "\(paths.count) Items"
        let isFolder = single && isDirectory(paths[0])

        let zips = paths.allSatisfy(FileManagerWindowController.isZip)
        add(menu, zips ? "Extract Here" : "Open", #selector(open))
        if let openWith = openWithMenu() {
            let item = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
            item.submenu = openWith
            menu.addItem(item)
        }
        menu.addItem(.separator())

        if fm.activeTab.isTrash {
            // Inside the Trash (Finder): put back or erase.
            add(menu, "Put Back", #selector(putBack)).isEnabled = paths.allSatisfy { TrashBook.original(for: $0) != nil }
            add(menu, "Delete Immediately…", #selector(deleteNow))
        } else {
            add(menu, "Move to Trash", #selector(trash))
            // Hold ⌥ (Finder): Move to Trash becomes Delete Immediately…
            let delete = add(menu, "Delete Immediately…", #selector(deleteNow))
            delete.isAlternate = true
            delete.keyEquivalentModifierMask = .option
        }
        menu.addItem(.separator())

        add(menu, "Rename…", #selector(rename)).isEnabled = single
        add(menu, "Duplicate", #selector(duplicate))
        add(menu, "Quick Look \(label)", #selector(quickLook))
        menu.addItem(.separator())

        add(menu, "Copy \(label)", #selector(copyAction))
        add(menu, "Cut \(label)", #selector(cut))
        if fm.ops.canPaste {
            add(menu, fm.ops.cutPaths.isEmpty ? "Paste Item" + (fm.ops.pendingCount == 1 ? "" : "s") : "Move Items Here",
                #selector(paste))
        }
        add(menu, "Copy Path", #selector(copyPath))
        menu.addItem(.separator())

        let tags = NSMenuItem()
        tags.view = TagStrip(paths: paths)
        menu.addItem(tags)
        menu.addItem(.separator())

        add(menu, "Show in Finder", #selector(showInFinder))
        if isFolder { add(menu, "Open in Terminal", #selector(openTerminal)) }
        return menu
    }

    // MARK: Background menu

    func backgroundMenu() -> NSMenu {
        paths = []
        let menu = NSMenu()
        menu.autoenablesItems = false
        if fm.activeTab.isTrash {
            add(menu, "Empty Trash…", #selector(emptyTrash))
            menu.addItem(.separator())
        } else {
            add(menu, "New Folder", #selector(newFolder))
            menu.addItem(.separator())
        }
        if fm.ops.canPaste {
            add(menu, fm.ops.cutPaths.isEmpty ? "Paste Item" + (fm.ops.pendingCount == 1 ? "" : "s") : "Move Items Here",
                #selector(paste))
            menu.addItem(.separator())
        }
        add(menu, "Select All", #selector(selectAll))
        add(menu, "Invert Selection", #selector(invert))
        menu.addItem(.separator())

        let sort = NSMenu()
        for (title, field) in [("Name", SortField.name), ("Kind", .kind), ("Size", .size)] {
            let i = add(sort, title, #selector(sortBy(_:)))
            i.representedObject = field == .name ? "name" : field == .kind ? "kind" : "size"
            i.state = fm.currentSort == field ? .on : .off
        }
        let sortItem = NSMenuItem(title: "Sort By", action: nil, keyEquivalent: "")
        sortItem.submenu = sort
        menu.addItem(sortItem)

        let view = NSMenu()
        add(view, "Grid", #selector(asGrid)).state = fm.viewMode == .grid ? .on : .off
        add(view, "List", #selector(asList)).state = fm.viewMode == .list ? .on : .off
        let viewItem = NSMenuItem(title: "View As", action: nil, keyEquivalent: "")
        viewItem.submenu = view
        menu.addItem(viewItem)
        add(menu, "Show Hidden Files", #selector(toggleHidden)).state = fm.showsHidden ? .on : .off
        menu.addItem(.separator())
        add(menu, "Refresh", #selector(refresh))
        add(menu, "Open in Terminal", #selector(openTerminalHere))
        add(menu, "Show in Finder", #selector(showFolderInFinder))
        return menu
    }

    // MARK: Helpers

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    private func isDirectory(_ path: String) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &d) && d.boolValue
    }

    private var urls: [URL] { paths.map { URL(fileURLWithPath: $0) } }

    private func openWithMenu() -> NSMenu? {
        guard let first = urls.first, !isDirectory(first.path) || first.pathExtension == "app" else { return nil }
        let ws = NSWorkspace.shared
        let apps = ws.urlsForApplications(toOpen: first)
        guard !apps.isEmpty else { return nil }
        let menu = NSMenu()
        let preferred = ws.urlForApplication(toOpen: first)
        let ordered = (preferred.map { [$0] } ?? []) + apps.filter { $0 != preferred }
        for (i, app) in ordered.prefix(20).enumerated() {
            var title = FileManager.default.displayName(atPath: app.path)
            if i == 0, preferred != nil { title += " (default)" }
            let item = NSMenuItem(title: title, action: #selector(openWithApp(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = app
            let icon = ws.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
            if i == 0, preferred != nil { menu.addItem(.separator()) }
        }
        menu.addItem(.separator())
        let other = NSMenuItem(title: "Other…", action: #selector(openWithOther), keyEquivalent: "")
        other.target = self
        menu.addItem(other)
        return menu
    }

    // MARK: Actions

    @objc private func open() { fm.openPaths(paths) }
    @objc private func trash() { fm.ops.moveToTrash(paths) }
    @objc private func putBack() { fm.ops.putBack(paths) }
    @objc private func emptyTrash() { fm.ops.emptyTrash() }
    @objc private func deleteNow() { fm.ops.deletePermanently(paths) }
    @objc private func rename() { if let p = paths.first { fm.ops.rename(p) } }
    @objc private func duplicate() { fm.ops.duplicate(paths) }
    @objc private func quickLook() { fm.quickLook.toggle() }
    @objc private func copyAction() { fm.copyItems(nil) }
    @objc private func cut() { fm.cutItems(nil) }
    @objc private func paste() { fm.pasteItems(nil) }
    @objc private func newFolder() { fm.newFolder(nil) }
    @objc private func selectAll() { fm.selectAllItems(nil) }
    @objc private func invert() { fm.invertSelection(nil) }
    @objc private func asGrid() { fm.setGridView(nil) }
    @objc private func asList() { fm.setListView(nil) }
    @objc private func toggleHidden() { fm.toggleHidden(nil) }
    @objc private func refresh() { fm.refresh(nil) }

    @objc private func sortBy(_ sender: NSMenuItem) {
        let field: SortField = (sender.representedObject as? String) == "kind" ? .kind
            : (sender.representedObject as? String) == "size" ? .size : .name
        fm.setSort(field, descending: false)
    }

    @objc private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
        UI.hud(paths.count == 1 ? "Path copied" : "\(paths.count) paths copied", in: fm.window)
    }

    @objc private func showInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc private func showFolderInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: fm.activeTab.path)])
    }

    @objc private func openTerminal() {
        if let p = paths.first { Self.terminal(at: p) }
    }

    @objc private func openTerminalHere() {
        Self.terminal(at: fm.activeTab.path)
    }

    static func terminal(at path: String) {
        let ws = NSWorkspace.shared
        guard let terminal = ws.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        ws.open([URL(fileURLWithPath: path)], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func openWithApp(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func openWithOther() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "Open"
        let targets = urls
        guard let window = fm.window else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let app = panel.url else { return }
            NSWorkspace.shared.open(targets, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

/// Finder's row of colour tag dots. Click a dot to add that tag to every
/// selected item, or remove it if they all have it already.
final class TagStrip: NSView {
    static let tags: [(String, NSColor)] = [
        ("Red", .systemRed), ("Orange", .systemOrange), ("Yellow", .systemYellow), ("Green", .systemGreen),
        ("Blue", .systemBlue), ("Purple", .systemPurple), ("Gray", .systemGray),
    ]
    private let paths: [String]

    init(paths: [String]) {
        self.paths = paths
        super.init(frame: NSRect(x: 0, y: 0, width: 230, height: 28))
        let current = Set(paths.flatMap(Self.tagNames(of:)))
        var x: CGFloat = 20
        for (name, color) in Self.tags {
            let dot = TagDot(name: name, color: color, on: current.contains(name)) { [weak self] in self?.toggle(name) }
            dot.frame = NSRect(x: x, y: 5, width: 18, height: 18)
            addSubview(dot)
            x += 26
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static func tagNames(of path: String) -> [String] {
        ((try? URL(fileURLWithPath: path).resourceValues(forKeys: [.tagNamesKey]))?.tagNames) ?? []
    }

    private func toggle(_ tag: String) {
        let allHave = paths.allSatisfy { Self.tagNames(of: $0).contains(tag) }
        for p in paths {
            var tags = Self.tagNames(of: p)
            if allHave { tags.removeAll { $0 == tag } } else if !tags.contains(tag) { tags.append(tag) }
            try? (URL(fileURLWithPath: p) as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
        }
        NotificationCenter.default.post(name: Tags.changed, object: nil)
        enclosingMenuItem?.menu?.cancelTracking()
    }
}

private final class TagDot: NSView {
    private let color: NSColor
    private let on: Bool
    private let action: () -> Void
    private var hover = false

    init(name: String, color: NSColor, on: Bool, action: @escaping () -> Void) {
        self.color = color
        self.on = on
        self.action = action
        super.init(frame: .zero)
        toolTip = name
        setAccessibilityLabel("\(name) tag")
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hover = false; needsDisplay = true }
    override func mouseUp(with event: NSEvent) { action() }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: hover ? 0.5 : 2, dy: hover ? 0.5 : 2)
        color.setFill()
        NSBezierPath(ovalIn: r).fill()
        if on {
            NSColor.white.setStroke()
            let check = NSBezierPath()
            check.lineWidth = 1.8
            check.move(to: NSPoint(x: r.minX + r.width * 0.28, y: r.midY))
            check.line(to: NSPoint(x: r.minX + r.width * 0.45, y: r.minY + r.height * 0.3))
            check.line(to: NSPoint(x: r.minX + r.width * 0.74, y: r.minY + r.height * 0.72))
            check.stroke()
        }
    }
}
