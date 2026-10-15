import AppKit

/// captools Toolbar (UI-SPEC §3), same controls in the same order.
/// It sits in the unified titlebar, right of the window buttons.
final class ToolbarView: DraggableBackgroundView {
    private unowned let fm: FileManagerWindowController

    // Left zone
    private var treeButton: NSButton!
    private var zipButton: NSButton!
    private var splitButton: NSButton!
    private var optionsButton: NSButton!
    private var trashButton: NSButton!
    // Action cluster
    private let cluster = ActionCluster()
    private var leftZone: NSStackView!
    private var trailingZone: NSStackView!
    private var clusterLeading: NSLayoutConstraint!
    private var lastFocus: Side?
    private var newFolderButton: NSButton!
    private var multiButton: NSButton!
    private var selectAllButton: NSButton!
    private var copyButton: NSButton!
    private var cutButton: NSButton!
    private var pasteButton: NSButton!
    private var undoButton: NSButton!
    private var redoButton: NSButton!
    private var binActionButton: NSButton!
    private var deleteButton: NSButton!
    // View controls
    private var viewControls: NSStackView!
    private var listButton: NSButton!
    private var gridButton: NSButton!
    private var zoomOutButton: NSButton!
    private var zoomInButton: NSButton!
    private var textSmallerButton: NSButton!
    private var textLargerButton: NSButton!
    private var pageGroup: NSStackView!
    private var pageLabel: NSTextField!
    private var previewGroup: NSStackView!
    private var previewButton: NSButton!
    private var zipGroup: NSStackView!
    private var createZipButton: NSButton!

    init(fm: FileManagerWindowController) {
        self.fm = fm
        super.init(frame: .zero)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func b(_ symbol: String, _ tip: String, _ action: Selector, toggle: Bool = false) -> NSButton {
        UI.iconButton(symbol, tip, target: fm, action: action, toggle: toggle)
    }

    private func build() {
        treeButton = b("sidebar.left", "Toggle Folder Tree", #selector(FileManagerWindowController.toggleTree(_:)), toggle: true)
        zipButton = b("archivebox", "Open & browse a ZIP file", #selector(FileManagerWindowController.openZip(_:)))
        splitButton = b("rectangle.split.2x1", "Split View (⌘M)", #selector(FileManagerWindowController.toggleSplit(_:)), toggle: true)
        let left = UI.hstack([treeButton, UI.separator(), splitButton])
        leftZone = left
        // The floating cluster must never squash these buttons.
        left.setContentCompressionResistancePriority(.required, for: .horizontal)

        newFolderButton = b("folder.badge.plus", "New Folder", #selector(FileManagerWindowController.newFolder(_:)))
        multiButton = b("square", "Enable multi-select (S)", #selector(FileManagerWindowController.toggleMultiSelect(_:)), toggle: true)
        selectAllButton = b("checklist", "Select All (⌘A)", #selector(FileManagerWindowController.selectAllItems(_:)))
        copyButton = b("doc.on.doc", "Copy (⌘C)", #selector(FileManagerWindowController.copyItems(_:)))
        cutButton = b("scissors", "Cut (⌘X)", #selector(FileManagerWindowController.cutItems(_:)))
        pasteButton = b("doc.on.clipboard", "Paste (⌘V)", #selector(FileManagerWindowController.pasteItems(_:)))
        undoButton = b("arrow.uturn.backward", "Undo (⌘Z)", #selector(FileManagerWindowController.undoAction(_:)))
        redoButton = b("arrow.uturn.forward", "Redo (⇧⌘Z)", #selector(FileManagerWindowController.redoAction(_:)))
        binActionButton = b("trash", "Move to Recycle Bin (Del)", #selector(FileManagerWindowController.moveToBin(_:)))
        deleteButton = b("xmark.bin", "Delete permanently (⌘Del)", #selector(FileManagerWindowController.deletePermanently(_:)))
        deleteButton.contentTintColor = .systemRed
        cluster.setViews([
            newFolderButton, UI.separator(),
            multiButton, selectAllButton, UI.separator(),
            copyButton, cutButton, pasteButton, UI.separator(),
            undoButton, redoButton, UI.separator(),
            binActionButton, deleteButton,
        ])

        listButton = b("list.bullet", "List View", #selector(FileManagerWindowController.setListView(_:)), toggle: true)
        gridButton = b("square.grid.2x2", "Grid View", #selector(FileManagerWindowController.setGridView(_:)), toggle: true)
        zoomOutButton = b("minus.magnifyingglass", "Zoom Out", #selector(FileManagerWindowController.zoomOut(_:)))
        zoomInButton = b("plus.magnifyingglass", "Zoom In", #selector(FileManagerWindowController.zoomIn(_:)))
        pageLabel = UI.label("1/1", size: 10)
        pageLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        pageGroup = UI.hstack([UI.separator(),
                               b("chevron.up", "Page Up", #selector(FileManagerWindowController.pageUpAction(_:))),
                               pageLabel,
                               b("chevron.down", "Page Down", #selector(FileManagerWindowController.pageDownAction(_:)))])
        previewButton = b("sidebar.right", "Show Preview Pane", #selector(FileManagerWindowController.togglePreview(_:)), toggle: true)
        previewGroup = UI.hstack([previewButton])
        createZipButton = b("doc.zipper", "Create ZIP from selected files", #selector(FileManagerWindowController.createZip(_:)))
        zipGroup = UI.hstack([UI.separator(), createZipButton])
        textSmallerButton = b("textformat.size.smaller", "Smaller Name Text (⌥⌘−)", #selector(FileManagerWindowController.textSmaller(_:)))
        textLargerButton = b("textformat.size.larger", "Larger Name Text (⌥⌘+)", #selector(FileManagerWindowController.textLarger(_:)))
        viewControls = UI.hstack([listButton, gridButton, UI.separator(), zoomOutButton, zoomInButton,
                                  UI.separator(), textSmallerButton, textLargerButton,
                                  pageGroup, zipGroup])

        // Mac app, not a browser tool: no "Clear storage" button and no private
        // recycle bin — deletes go to the real macOS Trash (with Put Back).
        // View settings live in one menu (Finder-style "View Options"); the
        // preview pane is a panel toggle at the far right, mirroring the
        // folder-tree toggle at the far left.
        optionsButton = UI.iconButton("slider.horizontal.3", "View Options", target: self, action: #selector(showViewOptions(_:)))
        trashButton = b("trash.circle", "Open Trash", #selector(FileManagerWindowController.openTrash(_:)))
        let trailing = UI.hstack([viewControls, UI.separator(), optionsButton, trashButton, UI.separator(), previewGroup], spacing: 10)
        trailingZone = trailing
        addSubview(left)
        addSubview(trailing)
        addSubview(cluster)
        // The action cluster floats: it sits above the focused pane and
        // slides when focus moves (captools "spacer A").
        clusterLeading = cluster.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0)
        NSLayoutConstraint.activate([
            // Room for the window's close/minimise/zoom buttons.
            left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 80),
            left.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
            cluster.centerYAnchor.constraint(equalTo: centerYAnchor),
            cluster.leadingAnchor.constraint(greaterThanOrEqualTo: left.trailingAnchor, constant: 10),
            cluster.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -10).withPriority(.init(900)),
            clusterLeading.withPriority(.init(800)),
        ])
    }

    override func layout() {
        super.layout()
        positionCluster(animated: false)
    }

    /// Puts the cluster over the focused pane: after the left buttons in
    /// single view or for the left pane; at the right pane's edge when the
    /// right pane is focused.
    func positionCluster(animated: Bool) {
        guard let window, let leftZone else { return }
        var x = leftZone.frame.maxX + 10
        if fm.splitMode, let paneRect = fm.paneFrameInWindow(fm.focused) {
            let paneX = convert(paneRect, from: nil).minX + 8
            x = max(x, paneX)
        }
        _ = window
        if ProcessInfo.processInfo.environment["FILOFINDER_DEBUG"] != nil {
            FileHandle.standardError.write(Data("[cluster] split=\(fm.splitMode) focus=\(fm.focused) leftMax=\(leftZone.frame.maxX) pane=\(String(describing: fm.paneFrameInWindow(fm.focused))) x=\(x) const=\(clusterLeading.constant) clusterFrame=\(cluster.frame)\n".utf8))
        }
        guard abs(clusterLeading.constant - x) > 0.5 else { return }
        // Set the final value first, then animate the frame change. Animating
        // the constraint itself let relayouts stop the slide half-way.
        clusterLeading.constant = x
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.allowsImplicitAnimation = true
                layoutSubtreeIfNeeded()
            }
        }
    }

    /// Re-reads state from the controller (enabled flags, toggles, labels).
    func update() {
        let tab = fm.activeTab
        let hasSel = !tab.selection.isEmpty
        let idle = !fm.ops.busy

        treeButton.state = fm.showTree ? .on : .off
        treeButton.image = NSImage(systemSymbolName: fm.showTree ? "sidebar.left" : "sidebar.squares.left",
                                   accessibilityDescription: "Toggle Folder Tree")
        treeButton.isEnabled = !fm.splitMode
        treeButton.toolTip = fm.splitMode ? "Folder Tree is available in full-screen view only" : "Toggle Folder Tree"
        zipButton.isEnabled = false
        zipButton.toolTip = "Open & browse a ZIP file — coming in v0.2"
        splitButton.isEnabled = true
        splitButton.state = fm.splitMode ? .on : .off
        splitButton.toolTip = fm.splitMode ? "Exit Split View (⌘M)" : "Split View (⌘M)"
        optionsButton.contentTintColor = fm.showsHidden ? .controlAccentColor : nil

        cluster.tone = fm.splitMode ? fm.focused.tone : .left
        let focus: Side = fm.splitMode ? fm.focused : .left
        positionCluster(animated: lastFocus != nil && lastFocus != focus)
        lastFocus = focus
        multiButton.state = fm.multiSelect ? .on : .off
        multiButton.image = NSImage(systemSymbolName: fm.multiSelect ? "checkmark.square" : "square",
                                    accessibilityDescription: "Multi-select")
        multiButton.toolTip = fm.multiSelect ? "Disable multi-select (S)" : "Enable multi-select (S)"
        newFolderButton.isEnabled = idle
        for button: NSButton in [copyButton!, cutButton!, binActionButton!, deleteButton!] {
            button.isEnabled = hasSel && idle
        }
        pasteButton.isEnabled = fm.ops.canPaste && idle
        undoButton.isEnabled = fm.ops.canUndo
        undoButton.toolTip = fm.ops.undoTitle.map { "Undo \($0) (⌘Z)" } ?? "Undo (⌘Z)"
        redoButton.isEnabled = false
        binActionButton.toolTip = "Move to Trash (Del)"

        listButton.state = fm.viewMode == .list ? .on : .off
        gridButton.state = fm.viewMode == .grid ? .on : .off
        zoomOutButton.isEnabled = fm.zoom > FileManagerWindowController.zoomRange.lowerBound + 0.001
        zoomInButton.isEnabled = fm.zoom < FileManagerWindowController.zoomRange.upperBound - 0.001
        textSmallerButton.isEnabled = fm.textSize > FileManagerWindowController.textSizeRange.lowerBound
        textLargerButton.isEnabled = fm.textSize < FileManagerWindowController.textSizeRange.upperBound
        pageGroup.isHidden = fm.viewMode != .grid || fm.splitMode
        previewGroup.isHidden = fm.splitMode
        previewButton.state = fm.showPreview ? .on : .off
        previewButton.contentTintColor = fm.showPreview ? .controlAccentColor : nil
        previewButton.image = NSImage(systemSymbolName: "sidebar.right",
                                      accessibilityDescription: "Preview")
        previewButton.toolTip = fm.showPreview ? "Hide Preview Pane" : "Show Preview Pane"
        createZipButton.isEnabled = false
        createZipButton.toolTip = "Create ZIP from selected files — coming in v0.2"
    }

    /// Finder-style View Options menu: every display setting in one place.
    @objc private func showViewOptions(_ sender: NSButton) {
        typealias FM = FileManagerWindowController
        let menu = NSMenu()
        func item(_ title: String, _ action: Selector, on: Bool? = nil, key: String = "", mods: NSEvent.ModifierFlags = [.command]) {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = fm
            if let on { i.state = on ? .on : .off }
            menu.addItem(i)
        }
        item("Show Hidden Files", #selector(FM.toggleHidden(_:)), on: fm.showsHidden, key: ".", mods: [.command, .shift])
        menu.addItem(.separator())
        item("Folder Tree", #selector(FM.toggleTree(_:)), on: fm.showTree)
        item("Preview Pane", #selector(FM.togglePreview(_:)), on: fm.showPreview)
        menu.addItem(.separator())
        item("Grid", #selector(FM.setGridView(_:)), on: fm.viewMode == .grid, key: "2")
        item("List", #selector(FM.setListView(_:)), on: fm.viewMode == .list, key: "1")
        menu.addItem(.separator())
        let sort = NSMenu()
        for (title, field, tag) in [("Name", SortField.name, 0), ("Kind", SortField.kind, 1), ("Size", SortField.size, 2)] {
            let i = NSMenuItem(title: title, action: #selector(FM.sortMenuChosen(_:)), keyEquivalent: "")
            i.target = fm
            i.tag = tag
            i.state = fm.currentSort == field ? .on : .off
            sort.addItem(i)
        }
        let sortItem = NSMenuItem(title: "Sort By", action: nil, keyEquivalent: "")
        sortItem.submenu = sort
        menu.addItem(sortItem)
        menu.addItem(.separator())
        item("Bigger Name Text", #selector(FM.textLarger(_:)), key: "+", mods: [.command, .option])
        item("Smaller Name Text", #selector(FM.textSmaller(_:)), key: "-", mods: [.command, .option])
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    func updatePage(current: Int, total: Int) {
        let cur = NSAttributedString(string: "\(current)", attributes: [.foregroundColor: NSColor.labelColor])
        let rest = NSAttributedString(string: "/\(total)", attributes: [.foregroundColor: NSColor.tertiaryLabelColor])
        let s = NSMutableAttributedString(attributedString: cur)
        s.append(rest)
        s.addAttribute(.font, value: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                       range: NSRange(location: 0, length: s.length))
        pageLabel.attributedStringValue = s
    }
}

/// captools action-cluster pill: a rounded group whose left strip shows the
/// target panel's colour.
final class ActionCluster: NSView {
    private let stack = UI.hstack([], spacing: 2)
    private let strip = NSView()
    var tone: Tone = .left { didSet { needsDisplay = true; strip.layer?.backgroundColor = tone.color.cgColor } }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        strip.wantsLayer = true
        strip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(strip)
        addSubview(stack)
        NSLayoutConstraint.activate([
            strip.leadingAnchor.constraint(equalTo: leadingAnchor),
            strip.topAnchor.constraint(equalTo: topAnchor),
            strip.bottomAnchor.constraint(equalTo: bottomAnchor),
            strip.widthAnchor.constraint(equalToConstant: 4),
            stack.leadingAnchor.constraint(equalTo: strip.trailingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setViews(_ views: [NSView]) {
        views.forEach(stack.addArrangedSubview)
    }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.08).cgColor
        layer?.borderColor = tone.color.withAlphaComponent(0.45).cgColor
        strip.layer?.backgroundColor = tone.color.cgColor
    }

    override var wantsUpdateLayer: Bool { true }
}
