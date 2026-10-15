import AppKit

/// One Filofinder window: captools' File Manager layout (UI-SPEC §2).
/// Owns all state; views read it and call back into the action methods.
final class FileManagerWindowController: NSWindowController, NSWindowDelegate, NSSplitViewDelegate {
    static let zoomRange: ClosedRange<CGFloat> = 0.5...2.5

    // MARK: State

    private(set) var tabs: [Tab] = []
    /// The tab-bar tab (left pane, or the only pane).
    private(set) var leftTab: Tab
    /// The right pane's tab in split view.
    private(set) var rightTab: Tab?
    private(set) var splitMode = false
    private(set) var focused: Side = .left
    private(set) var previewName: String?

    /// The tab every action applies to: the focused pane's.
    var activeTab: Tab { tab(for: splitMode ? focused : .left) }

    func tab(for side: Side) -> Tab {
        side == .right ? (rightTab ?? leftTab) : leftTab
    }
    var multiSelect = false

    var viewMode: ViewMode {
        get { ViewMode(rawValue: UserDefaults.standard.string(forKey: "viewMode") ?? "") ?? .grid }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "viewMode") }
    }
    var zoom: CGFloat {
        get { CGFloat(UserDefaults.standard.object(forKey: "zoom") as? Double ?? 1.0) }
        set { UserDefaults.standard.set(Double(newValue), forKey: "zoom") }
    }
    static let textSizeRange: ClosedRange<CGFloat> = 8...20
    /// Size of file/folder names, separate from icon zoom (default 10 pt, captools).
    var textSize: CGFloat {
        get { CGFloat(UserDefaults.standard.object(forKey: "textSize") as? Double ?? 10) }
        set { UserDefaults.standard.set(Double(newValue), forKey: "textSize") }
    }
    var showTree: Bool {
        get { UserDefaults.standard.object(forKey: "showTree") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showTree") }
    }
    var showPreview: Bool {
        get { UserDefaults.standard.bool(forKey: "showPreview") }
        set { UserDefaults.standard.set(newValue, forKey: "showPreview") }
    }
    private var showHidden = false
    private var sortField: SortField = .name
    private var sortDescending = false

    // MARK: Views

    private var toolbar: ToolbarView!
    private var tabBar: TabBarView!
    private var breadcrumbs: BreadcrumbBar!
    private var tree: TreeSidebar!
    private var leftPane: PaneView!
    private var rightPane: PaneView!
    private let panes = NSSplitView()
    /// The focused pane's file view.
    private var panel: FilePanel { (splitMode && focused == .right ? rightPane : leftPane).panel }
    private var preview: PreviewPaneView!
    private(set) lazy var ops = FileOps(fm: self)
    private(set) lazy var quickLook = QuickLookController(fm: self)
    private var activity: String?
    private let split = NSSplitView()
    private let frameMonitor = FrameMonitor()
    private var frameText = ""

    init(path: String?) {
        let first = Tab(path: path ?? Tab.home)
        leftTab = first
        tabs = [first]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.tabbingMode = .disallowed // captools has its own tab bar
        window.minSize = NSSize(width: 900, height: 480)
        window.setFrameAutosaveName("FilofinderMain")
        if window.frame.origin == .zero { window.center() }
        super.init(window: window)
        window.delegate = self
        buildLayout()
        load(leftTab)
        refreshAll()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    private func buildLayout() {
        guard let content = window?.contentView else { return }
        toolbar = ToolbarView(fm: self)
        tabBar = TabBarView(fm: self)
        breadcrumbs = BreadcrumbBar(fm: self)
        tree = TreeSidebar(fm: self)
        leftPane = PaneView(fm: self, side: .left)
        rightPane = PaneView(fm: self, side: .right)
        preview = PreviewPaneView(fm: self)
        panes.isVertical = true
        panes.dividerStyle = .thick
        panes.delegate = self
        panes.addArrangedSubview(leftPane)
        panes.addArrangedSubview(rightPane)

        let top = UI.bar(material: .titlebar, height: 40)
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        top.addSubview(toolbar)
        pin(toolbar, to: top)

        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        split.addArrangedSubview(tree)
        split.addArrangedSubview(panes)
        split.addArrangedSubview(preview)
        split.setHoldingPriority(.init(260), forSubviewAt: 0)
        split.setHoldingPriority(.init(200), forSubviewAt: 1)
        split.setHoldingPriority(.init(250), forSubviewAt: 2)

        let body = NSView()
        split.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(split)
        pin(split, to: body)

        let line = NSBox()
        line.boxType = .separator
        tabBar.heightAnchor.constraint(equalToConstant: 28).isActive = true
        breadcrumbs.heightAnchor.constraint(equalToConstant: 34).isActive = true

        let column = NSStackView(views: [top, tabBar, breadcrumbs, line, body])
        column.orientation = .vertical
        column.spacing = 0
        column.distribution = .fill
        column.translatesAutoresizingMaskIntoConstraints = false
        for v in column.arrangedSubviews {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        body.setContentHuggingPriority(.init(1), for: .vertical)
        content.addSubview(column)
        pin(column, to: content)

        // Tags changed (context menu): refresh dots everywhere.
        NotificationCenter.default.addObserver(forName: Tags.changed, object: nil, queue: .main) { [weak self] _ in
            Tags.clearCache()
            guard let self else { return }
            self.leftPane.panel.reloadVisible()
            if self.splitMode { self.rightPane.panel.reloadVisible() }
            if self.activeTab.isVirtual { self.refresh(nil) }
        }

        frameMonitor.onReport = { [weak self] r in
            self?.frameText = String(format: "· %.0f fps @ %.0f Hz · dropped %d", r.fps, r.refreshHz, r.dropped)
            self?.updateStatus()
        }

        // The old AppKit autosave stored a 0-width tree after split view hid it.
        UserDefaults.standard.removeObject(forKey: "NSSplitView Subview Frames FilofinderSplit")
    }

    // Side panel widths are remembered by us, only while visible, so hiding
    // a panel (split view) can never save it as 0 px wide.
    private var treeWidth: CGFloat {
        get { CGFloat(UserDefaults.standard.object(forKey: "treeWidth") as? Double ?? 220) }
        set { UserDefaults.standard.set(Double(newValue), forKey: "treeWidth") }
    }
    private var previewWidth: CGFloat {
        get { CGFloat(UserDefaults.standard.object(forKey: "previewWidth") as? Double ?? 400) }
        set { UserDefaults.standard.set(Double(newValue), forKey: "previewWidth") }
    }
    private var restoringWidths = false

    /// Gives visible side panels their remembered width (captools defaults:
    /// tree 220, preview 400) whenever they appear.
    private func restoreSideWidths() {
        restoringWidths = true
        defer { restoringWidths = false }
        split.layoutSubtreeIfNeeded()
        if !tree.isHidden, tree.frame.width < 80 || abs(tree.frame.width - treeWidth) > 1 {
            split.setPosition(min(max(treeWidth, 80), 540), ofDividerAt: 0)
        }
        if !preview.isHidden, preview.frame.width < 200 || abs(preview.frame.width - previewWidth) > 1 {
            split.setPosition(split.bounds.width - min(max(previewWidth, 200), 700) - split.dividerThickness, ofDividerAt: 1)
        }
    }

    private func pin(_ v: NSView, to parent: NSView) {
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: parent.leadingAnchor), v.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            v.topAnchor.constraint(equalTo: parent.topAnchor), v.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
        ])
    }

    // Tree 80–540, preview 200–700; split panes at least 20% each (captools limits).
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        if splitView === panes { return splitView.bounds.width * 0.2 }
        return index == 0 ? 80 : max(proposed, splitView.bounds.width - 700)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        if splitView === panes { return splitView.bounds.width * 0.8 }
        return index == 0 ? 540 : min(proposed, splitView.bounds.width - 200)
    }

    // MARK: Refresh

    func refreshAll() {
        // captools: split view hides the tab bar, breadcrumbs, tree and
        // preview pane; each pane gets its own header and status bar.
        tabBar.isHidden = splitMode
        breadcrumbs.isHidden = splitMode
        tree.isHidden = splitMode || !showTree
        preview.isHidden = splitMode || !showPreview
        rightPane.isHidden = !splitMode
        split.adjustSubviews()
        panes.adjustSubviews()
        restoreSideWidths()
        toolbar.update()
        if !splitMode {
            tabBar.update()
            breadcrumbs.update()
            breadcrumbs.search.show(leftTab.query)
        }
        if showTree && !splitMode { tree.update() }
        leftPane.update()
        if splitMode { rightPane.update() }
        if showPreview && !splitMode { preview.update() }
        updateStatus()
        window?.title = activeTab.name
        window?.representedURL = URL(fileURLWithPath: activeTab.path)
    }

    private func updateStatus() {
        let hiddenNote = showHidden ? "Hidden files shown · " : ""
        leftPane.footer.update(tab: leftTab, timing: (focused == .left ? activity : nil) ?? (hiddenNote + leftTab.timing + frameText), tone: .left)
        if splitMode, let r = rightTab {
            rightPane.footer.update(tab: r, timing: (focused == .right ? activity : nil) ?? r.timing, tone: .right)
        }
        breadcrumbs.search.setMatchCount(leftTab.listing.map { Int($0.count()) })
    }

    func debugTreeClick(row: Int) { tree.debugClick(row: row) }

    /// A pane's frame in window coordinates (the toolbar aligns to it).
    func paneFrameInWindow(_ side: Side) -> NSRect? {
        let pane: NSView = side == .right ? rightPane : leftPane
        guard !pane.isHidden, pane.window != nil else { return nil }
        return pane.convert(pane.bounds, to: nil)
    }

    /// Divider drags and window resizes move the panes; keep the cluster aligned.
    func splitViewDidResizeSubviews(_ notification: Notification) {
        toolbar?.positionCluster(animated: false)
        // Remember widths the user sets by dragging (visible panels only).
        guard (notification.object as? NSSplitView) === split, !restoringWidths else { return }
        if let tree, !tree.isHidden, tree.frame.width >= 80 { treeWidth = tree.frame.width }
        if let preview, !preview.isHidden, preview.frame.width >= 200 { previewWidth = preview.frame.width }
    }

    /// Makes `side` the target of toolbar actions (click or hover, captools).
    func focus(_ side: Side) {
        let side = splitMode ? side : .left
        guard side != focused else { return }
        focused = side
        toolbar.update()
        leftPane.update()
        if splitMode { rightPane.update() }
        quickLook.selectionChanged()
        window?.title = activeTab.name
    }

    var focusTarget: NSView { panel.focusTarget }

    func selectionDidChange() {
        if showPreview { syncPreviewToSelection() }
        quickLook.selectionChanged()
        toolbar.update()
        updateStatus()
    }

    func pageChanged(current: Int, total: Int) {
        toolbar.updatePage(current: current, total: total)
    }

    // MARK: Loading

    /// Lists the tab's folder off the main thread. A newer request bumps
    /// `generation`, so a slow older listing never overwrites a newer one.
    /// Lists `path` (default: the tab's folder) off the main thread. The
    /// current folder stays on screen until the new one is ready (Finder
    /// behaviour); `onSuccess` runs only if the new folder opened.
    private func load(_ tab: Tab, path target: String? = nil, keepSelection: Bool = false, onSuccess: (() -> Void)? = nil) {
        let path = target ?? tab.path
        tab.generation += 1
        let gen = tab.generation
        let started = CACurrentMediaTime()
        let hidden = showHidden, field = sortField, desc = sortDescending, query = target == nil ? tab.query : ""
        tab.loading = true
        // A slow open is almost always macOS checking privacy permission
        // (Desktop, Documents, Downloads, drives). Say so instead of looking frozen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, tab.loading, tab.generation == gen, self.pane(showing: tab) != nil else { return }
            let name = (path as NSString).lastPathComponent
            self.setActivity("Opening “\(name)”… if macOS is asking for permission, click Allow")
        }
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let result = Result { () -> ListingHandle in
                // Tag tabs list Spotlight results instead of a folder.
                let l = try Tags.tag(fromPath: path).map { listPaths(paths: Tags.search($0), title: path, showHidden: hidden) }
                    ?? listDir(path: path, showHidden: hidden, backend: .bulk)
                if field != .name || desc || !query.isEmpty { l.setView(field: field, descending: desc, query: query) }
                return l
            }
            DispatchQueue.main.async {
                guard let self, gen == tab.generation else { return }
                tab.loading = false
                if self.activity?.hasPrefix("Opening “") == true { self.setActivity(nil) }
                switch result {
                case .success(let listing):
                    Tags.clearCache()
                    tab.accessDenied = false
                    if !keepSelection { tab.selection = [] }
                    if target != nil { tab.query = "" }
                    onSuccess?()
                    tab.listing = listing
                    tab.path = listing.path()
                    tab.resetRows()
                    let s = listing.stats()
                    tab.timing = String(format: "list %.0f ms · sort %.0f ms · %.0f ms total",
                                         Double(s.listMicros) / 1000, Double(s.sortMicros) / 1000,
                                         (CACurrentMediaTime() - started) * 1000)
                    if let pane = self.pane(showing: tab) {
                        if !keepSelection { pane.panel.scrollToTop() }
                        self.refreshAll()
                    }
                case .failure(let error):
                    let denied = "\(error)".contains("not permitted") || "\(error)".contains("Permission denied")
                    if denied {
                        // Open the folder anyway and explain in place (Finder
                        // does the same), instead of silently staying put.
                        onSuccess?()
                        tab.path = path
                        tab.listing = nil
                        tab.rows = []
                        tab.selection = []
                        tab.accessDenied = true
                        tab.timing = ""
                    } else {
                        UI.hud("⚠︎ \(error)", in: self.window)
                        NSSound.beep()
                    }
                    self.refreshAll()
                }
            }
        }
    }

    /// The pane currently displaying `tab`, if any.
    private func pane(showing tab: Tab) -> PaneView? {
        if tab === leftTab { return leftPane }
        if splitMode, tab === rightTab { return rightPane }
        return nil
    }

    func navigate(to path: String) {
        let tab = activeTab
        let target = (path as NSString).standardizingPath
        guard target != tab.path else { return }
        let from = tab.path
        go(tab, to: target) {
            tab.back.append(from)
            tab.forward.removeAll()
        }
    }

    private func go(_ tab: Tab, to path: String, onSuccess: @escaping () -> Void) {
        load(tab, path: path) { [weak self] in
            self?.previewName = nil
            onSuccess()
        }
    }

    // MARK: Tabs

    func switchTo(_ tab: Tab) {
        guard tab !== leftTab else { return }
        if tab === rightTab { rightTab = leftTab } // never show one tab twice
        leftTab = tab
        focused = .left
        previewName = nil
        if tab.listing == nil { load(tab) }
        leftPane.panel.scrollToTop()
        refreshAll()
    }

    /// Split-panel tab picker: show `tab` in `side` (swaps if it's on the other side).
    func assign(_ tab: Tab, to side: Side) {
        focused = side
        if side == .left {
            if tab === rightTab { rightTab = leftTab }
            leftTab = tab
        } else {
            if tab === leftTab { leftTab = rightTab ?? leftTab }
            rightTab = tab
        }
        if tab.listing == nil { load(tab) }
        refreshAll()
    }

    @objc func newTab(_ sender: Any?) {
        let tab = Tab()
        tabs.append(tab)
        switchTo(tab)
    }

    func close(_ tab: Tab) {
        guard tabs.count > 1, let i = tabs.firstIndex(where: { $0 === tab }) else { return }
        tabs.remove(at: i)
        if tab === rightTab { rightTab = nil; splitMode = false; focused = .left }
        if tab === leftTab {
            leftTab = tabs[min(i, tabs.count - 1)]
            if leftTab === rightTab { rightTab = nil; splitMode = false; focused = .left }
            previewName = nil
        }
        if leftTab.listing == nil { load(leftTab) }
        refreshAll()
    }

    func duplicate(_ tab: Tab) {
        let copy = tab.duplicate()
        tabs.insert(copy, at: (tabs.firstIndex(where: { $0 === tab }) ?? tabs.count - 1) + 1)
        switchTo(copy)
    }

    func closeOthers(than tab: Tab) {
        tabs = [tab]
        rightTab = nil
        splitMode = false
        focused = .left
        if tab !== leftTab { switchTo(tab) }
        refreshAll()
    }

    func closeTabsRight(of tab: Tab) {
        guard let i = tabs.firstIndex(where: { $0 === tab }) else { return }
        let removed = tabs[(i + 1)...]
        tabs.removeSubrange((i + 1)...)
        if let r = rightTab, removed.contains(where: { $0 === r }) { rightTab = nil; splitMode = false; focused = .left }
        if removed.contains(where: { $0 === leftTab }) { switchTo(tab) }
        refreshAll()
    }

    // MARK: Toolbar actions

    @objc func toggleTree(_ sender: Any?) {
        showTree.toggle()
        refreshAll()
    }

    @objc func openDirectory(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: activeTab.path)
        panel.prompt = "Go"
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.navigate(to: url.path)
        }
    }

    @objc func openZip(_ sender: Any?) { notYet("ZIP browsing arrives in v0.2") }
    /// ⌘M. Opens a second pane with another open tab, or a duplicate of the
    /// current tab when it's the only one (captools behaviour).
    @objc func toggleSplit(_ sender: Any?) {
        if splitMode {
            splitMode = false
            focused = .left
        } else {
            let other: Tab
            if let r = rightTab, tabs.contains(where: { $0 === r }), r !== leftTab {
                other = r
            } else if let t = tabs.first(where: { $0 !== leftTab }) {
                other = t
            } else {
                other = leftTab.duplicate()
                tabs.append(other)
            }
            rightTab = other
            splitMode = true
            if other.listing == nil { load(other) }
        }
        refreshAll()
        if splitMode {
            DispatchQueue.main.async { self.panes.setPosition(self.panes.bounds.width / 2, ofDividerAt: 0) }
        }
    }

    /// Close button in a split header: closing the left pane promotes the
    /// right one; closing the right pane leaves split view.
    func closePane(_ side: Side) {
        guard splitMode else { return }
        if side == .left, let r = rightTab { leftTab = r }
        splitMode = false
        focused = .left
        refreshAll()
    }
    var showsHidden: Bool { showHidden }

    /// The real macOS Trash. Listing it needs Full Disk Access; without it,
    /// Finder's Trash window opens instead.
    @objc func openTrash(_ sender: Any?) {
        // Always in-app. Without Full Disk Access the panel explains how to
        // allow it instead of throwing the user over to Finder.
        navigate(to: Tab.trashPath)
    }
    @objc func redoAction(_ sender: Any?) { notYet("Redo arrives in a later build") }
    @objc func createZip(_ sender: Any?) { notYet("Create ZIP arrives in v0.2") }

    // MARK: File operations (FileOps → Rust core)

    /// Full paths of the selected items, in display order.
    func selectedPaths() -> [String] {
        let tab = activeTab
        return panel.selectedIndexes().compactMap { tab.row($0).map { tab.fullPath($0.name) } }
    }

    private func requireSelection() -> [String]? {
        let paths = selectedPaths()
        if paths.isEmpty { NSSound.beep(); return nil }
        return paths
    }

    /// Tag results aren't a folder: nothing can be created or pasted there.
    private func requireRealFolder() -> Bool {
        guard activeTab.isVirtual else { return true }
        UI.hud("This is a tag view — open a folder to add items", in: window)
        return false
    }

    @objc func newFolder(_ sender: Any?) { if requireRealFolder() { ops.newFolder(in: activeTab.path) } }
    @objc func copyItems(_ sender: Any?) { if let p = requireSelection() { ops.copy(p); panel.reloadVisible(); toolbar.update() } }
    @objc func cutItems(_ sender: Any?) { if let p = requireSelection() { ops.cut(p); leftPane.panel.reloadVisible(); rightPane.panel.reloadVisible(); toolbar.update() } }
    @objc func pasteItems(_ sender: Any?) { if requireRealFolder() { ops.paste(into: activeTab.path) } }
    @objc func undoAction(_ sender: Any?) { ops.undo() }
    @objc func moveToBin(_ sender: Any?) {
        guard let p = requireSelection() else { return }
        if activeTab.isTrash { ops.deletePermanently(p) } else { ops.moveToTrash(p) }
    }
    @objc func deletePermanently(_ sender: Any?) { if let p = requireSelection() { ops.deletePermanently(p) } }
    @objc func duplicateItems(_ sender: Any?) { if let p = requireSelection() { ops.duplicate(p) } }
    @objc func renameItem(_ sender: Any?) {
        let paths = selectedPaths()
        guard paths.count == 1 else { NSSound.beep(); return }
        ops.rename(paths[0])
    }

    /// Paths currently cut (shown faded, like Windows Explorer).
    func isCut(_ path: String) -> Bool {
        ops.cutPaths.contains(path)
    }

    func setActivity(_ text: String?) {
        activity = text
        toolbar.update()
        updateStatus()
    }

    /// After any operation: re-list the folder and select what just landed.
    func operationFinished(select names: [String]) {
        if !names.isEmpty { activeTab.selection = Set(names) }
        load(activeTab, keepSelection: true)
        // The other pane may show the source or destination folder.
        if splitMode { load(tab(for: focused.other), keepSelection: true) }
        tree.refreshExpanded()
        toolbar.update()
    }

    private func notYet(_ message: String) {
        UI.hud(message, in: window)
    }

    @objc func toggleMultiSelect(_ sender: Any?) {
        multiSelect.toggle()
        refreshAll()
    }

    @objc func selectAllItems(_ sender: Any?) {
        let tab = activeTab
        tab.selection = Set((0..<tab.rows.count).compactMap { tab.row($0)?.name })
        panel.applySelection()
        selectionDidChange()
    }

    @objc func invertSelection(_ sender: Any?) {
        let tab = activeTab
        let all = Set((0..<tab.rows.count).compactMap { tab.row($0)?.name })
        tab.selection = all.subtracting(tab.selection)
        panel.applySelection()
        selectionDidChange()
    }

    @objc func setListView(_ sender: Any?) {
        viewMode = .list
        refreshAll()
    }

    @objc func setGridView(_ sender: Any?) {
        viewMode = .grid
        refreshAll()
    }

    @objc func zoomOut(_ sender: Any?) { zoomBy(-0.2) }
    @objc func zoomIn(_ sender: Any?) { zoomBy(0.2) }

    func zoomBy(_ delta: CGFloat) {
        let z = min(max(zoom + delta, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        guard abs(z - zoom) > 0.001 else { return }
        zoom = (z * 10).rounded() / 10
        leftPane.panel.reload()
        if splitMode { rightPane.panel.reload() }
        toolbar.update()
    }

    @objc func textSmaller(_ sender: Any?) { textSizeBy(-1) }
    @objc func textLarger(_ sender: Any?) { textSizeBy(1) }

    private func textSizeBy(_ delta: CGFloat) {
        let t = min(max(textSize + delta, Self.textSizeRange.lowerBound), Self.textSizeRange.upperBound)
        guard t != textSize else { NSSound.beep(); return }
        textSize = t
        leftPane.panel.reload()
        if splitMode { rightPane.panel.reload() }
        toolbar.update()
        UI.hud("Name text: \(Int(t)) pt", in: window)
    }

    @objc func pageUpAction(_ sender: Any?) { panel.page(-1) }
    @objc func pageDownAction(_ sender: Any?) { panel.page(1) }

    @objc func togglePreview(_ sender: Any?) {
        showPreview.toggle()
        if showPreview { syncPreviewToSelection() } else { previewName = nil; preview.stop() }
        refreshAll()
    }

    // MARK: Navigation actions

    @objc func goBack(_ sender: Any?) {
        let tab = activeTab
        guard let previous = tab.back.last else { return }
        let from = tab.path
        go(tab, to: previous) {
            tab.back.removeLast()
            tab.forward.append(from)
        }
    }

    @objc func goForward(_ sender: Any?) {
        let tab = activeTab
        guard let next = tab.forward.last else { return }
        let from = tab.path
        go(tab, to: next) {
            tab.forward.removeLast()
            tab.back.append(from)
        }
    }

    @objc func goUp(_ sender: Any?) {
        guard let parent = activeTab.listing?.parent() else { return }
        navigate(to: parent)
    }

    @objc func goHome(_ sender: Any?) {
        navigate(to: Tab.home)
    }

    @objc func refresh(_ sender: Any?) {
        load(activeTab, keepSelection: true)
    }

    @objc func reload(_ sender: Any?) { refresh(sender) }

    @objc func toggleHidden(_ sender: Any?) {
        showHidden.toggle()
        refresh(nil)
        if splitMode { load(tab(for: focused.other), keepSelection: true) }
        toolbar.update()
    }

    @objc func focusPath(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Go to Folder"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.stringValue = activeTab.path
        alert.accessoryView = field
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        guard let window else { return }
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let path = (field.stringValue.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
                UI.hud("Folder not found", in: self?.window)
                return
            }
            self?.navigate(to: path)
        }
    }

    @objc func toggleFrameMonitor(_ sender: Any?) {
        if frameText.isEmpty {
            frameText = "· measuring…"
            frameMonitor.start(on: panel)
        } else {
            frameMonitor.stop()
            frameText = ""
        }
        updateStatus()
    }

    // MARK: Filter & sort

    func setQuery(_ query: String) {
        let tab = activeTab
        guard let listing = tab.listing, query != tab.query else { return }
        tab.query = query
        listing.setView(field: sortField, descending: sortDescending, query: query)
        tab.resetRows()
        pane(showing: tab)?.update()
        updateStatus()
    }

    func setSort(_ field: SortField, descending: Bool) {
        sortField = field
        sortDescending = descending
        guard let listing = activeTab.listing else { return }
        listing.setView(field: field, descending: descending, query: activeTab.query)
        activeTab.resetRows()
        pane(showing: activeTab)?.panel.reload()
    }

    // MARK: Opening

    @objc func openClicked(_ sender: Any?) {
        guard let table = sender as? NSTableView, table.clickedRow >= 0 else { return }
        open(index: table.clickedRow)
    }

    func open(index: Int) {
        let tab = activeTab
        guard let entry = tab.row(index) else { return }
        let path = tab.fullPath(entry.name)
        var isDir: ObjCBool = false
        let folderLike = entry.kind == .folder
            || (entry.kind == .symlink && FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue)
        if folderLike {
            navigate(to: path)
        } else if Self.isZip(path) {
            ops.extract(path) // our engine; Archive Utility stays under Open With
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }

    private func openSelection() {
        let indexes = panel.selectedIndexes()
        guard let first = indexes.first else { return }
        if let entry = activeTab.row(first), entry.kind == .folder || indexes.count == 1 {
            open(index: first)
        } else {
            for i in indexes { open(index: i) }
        }
    }

    // MARK: Preview

    private func syncPreviewToSelection() {
        previewName = panel.selectedIndexes().first.flatMap { activeTab.row($0)?.name }
        preview.update()
    }

    func stepPreview(_ delta: Int) {
        let tab = activeTab
        guard !tab.rows.isEmpty else { return }
        let current = previewName.flatMap { tab.listing?.indexOf(name: $0) }.map(Int.init) ?? -1
        let next = (current + delta + tab.rows.count) % tab.rows.count
        guard let name = tab.row(next)?.name else { return }
        tab.selection = [name]
        previewName = name
        panel.applySelection()
        if viewMode == .grid {
            panel.grid.scrollToItems(at: [IndexPath(item: next, section: 0)], scrollPosition: .nearestHorizontalEdge)
        } else {
            panel.list.scrollRowToVisible(next)
        }
        preview.update()
        quickLook.selectionChanged()
        updateStatus()
    }

    // MARK: Keyboard (captools shortcuts, UI-SPEC §14)

    func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .option, .shift, .control])
        let chars = event.charactersIgnoringModifiers ?? ""
        switch (event.keyCode, mods) {
        case (36, []), (76, []): openSelection(); return true                      // Return
        case (51, []), (117, []): moveToBin(nil); return true                       // ⌫ / Del
        case (51, [.command]), (117, [.command]): deletePermanently(nil); return true
        case (123, [.option]): goBack(nil); return true                             // ⌥←
        case (124, [.option]): goForward(nil); return true                          // ⌥→
        case (126, [.command]): goUp(nil); return true                              // ⌘↑
        case (125, [.command]): openSelection(); return true                        // ⌘↓
        case (96, []): refresh(nil); return true                                    // F5
        case (120, []): renameItem(nil); return true                                // F2
        case (53, []): activeTab.selection = []; panel.applySelection(); selectionDidChange(); return true // Esc
        case (49, []): quickLook.toggle(); return true                              // Space = Quick Look
        case (48, []) where splitMode:                                              // ⇥ = other pane
            focus(focused.other)
            window?.makeFirstResponder(panel.focusTarget)
            return true
        case (121, []): panel.page(1); return true                                  // Page Down
        case (116, []): panel.page(-1); return true                                 // Page Up
        default: break
        }
        if mods.isEmpty, chars == "s" { toggleMultiSelect(nil); return true }
        return false
    }

    private lazy var contextMenus = ContextMenuBuilder(fm: self)

    /// Right-click: Finder's item menu when over items, else the folder menu.
    func contextMenu(onItems: Bool) -> NSMenu {
        let paths = selectedPaths()
        return onItems && !paths.isEmpty ? contextMenus.itemMenu(for: paths) : contextMenus.backgroundMenu()
    }

    var currentSort: SortField { sortField }

    @objc func sortMenuChosen(_ sender: NSMenuItem) {
        setSort(sender.tag == 1 ? .kind : sender.tag == 2 ? .size : .name, descending: false)
    }

    static func isZip(_ path: String) -> Bool {
        (path as NSString).pathExtension.lowercased() == "zip"
    }

    /// Opens files with their default app; a single folder opens in place.
    func openPaths(_ paths: [String]) {
        var isDir: ObjCBool = false
        if paths.count == 1, FileManager.default.fileExists(atPath: paths[0], isDirectory: &isDir), isDir.boolValue,
           (paths[0] as NSString).pathExtension != "app" {
            navigate(to: paths[0])
            return
        }
        for p in paths {
            if Self.isZip(p) { ops.extract(p) } else { NSWorkspace.shared.open(URL(fileURLWithPath: p)) }
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleHidden(_:)): item.state = showHidden ? .on : .off
        case #selector(toggleFrameMonitor(_:)): item.state = frameText.isEmpty ? .off : .on
        case #selector(toggleTree(_:)): item.state = showTree ? .on : .off; return !splitMode
        case #selector(toggleSplit(_:)): item.state = splitMode ? .on : .off
        case #selector(togglePreview(_:)): item.state = showPreview ? .on : .off
        case #selector(setListView(_:)): item.state = viewMode == .list ? .on : .off
        case #selector(setGridView(_:)): item.state = viewMode == .grid ? .on : .off
        case #selector(pasteItems(_:)): return ops.canPaste && !ops.busy
        case #selector(undoAction(_:)):
            item.title = ops.undoTitle.map { "Undo \($0)" } ?? "Undo"
            return ops.canUndo
        case #selector(redoAction(_:)): return false
        case #selector(copyItems(_:)), #selector(cutItems(_:)), #selector(moveToBin(_:)),
             #selector(deletePermanently(_:)), #selector(duplicateItems(_:)):
            return !activeTab.selection.isEmpty && !ops.busy
        case #selector(renameItem(_:)): return activeTab.selection.count == 1 && !ops.busy
        case #selector(goBack(_:)): return !activeTab.back.isEmpty
        case #selector(goForward(_:)): return !activeTab.forward.isEmpty
        default: break
        }
        return true
    }

    func windowDidBecomeKey(_ notification: Notification) {
        window?.makeFirstResponder(panel.focusTarget)
    }

    func windowWillClose(_ notification: Notification) {
        frameMonitor.stop()
    }
}
