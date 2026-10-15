import AppKit

/// One side of the window: [header (split only)] / file panel / status bar.
/// In split view the focused pane gets a ring in its tone (captools: blue
/// left, amber right), and hovering a pane focuses it.
final class PaneView: NSView {
    let side: Side
    let header: PanelHeader
    let panel: FilePanel
    let footer = StatusBarView()
    private unowned let fm: FileManagerWindowController
    private let ring = NSView()
    private var tracking: NSTrackingArea?

    init(fm: FileManagerWindowController, side: Side) {
        self.fm = fm
        self.side = side
        header = PanelHeader(fm: fm, side: side)
        panel = FilePanel(fm: fm, side: side)
        super.init(frame: .zero)
        footer.translatesAutoresizingMaskIntoConstraints = false
        let column = NSStackView(views: [header, panel, footer])
        column.orientation = .vertical
        column.spacing = 0
        column.distribution = .fill
        column.translatesAutoresizingMaskIntoConstraints = false
        for v in column.arrangedSubviews {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        header.heightAnchor.constraint(equalToConstant: 36).isActive = true
        footer.heightAnchor.constraint(equalToConstant: 24).isActive = true
        panel.setContentHuggingPriority(.init(1), for: .vertical)
        addSubview(column)

        ring.wantsLayer = true
        ring.layer?.borderWidth = 2
        ring.layer?.cornerRadius = 2
        ring.translatesAutoresizingMaskIntoConstraints = false
        addSubview(ring)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor), column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor), column.bottomAnchor.constraint(equalTo: bottomAnchor),
            ring.leadingAnchor.constraint(equalTo: leadingAnchor), ring.trailingAnchor.constraint(equalTo: trailingAnchor),
            ring.topAnchor.constraint(equalTo: topAnchor), ring.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update() {
        let split = fm.splitMode
        header.isHidden = !split
        if split { header.update() }
        let focused = split && fm.focused == side
        ring.isHidden = !focused
        ring.layer?.borderColor = side.tone.color.withAlphaComponent(0.7).cgColor
        panel.reload()
    }

    /// The ring never intercepts clicks.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === ring ? nil : hit
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) {
        if fm.splitMode { fm.focus(side) }
    }
}

/// captools split-panel header (UI-SPEC §6): tone strip · ← → ⟳ · folder ·
/// breadcrumbs · filter · tab picker · close.
final class PanelHeader: NSView {
    private unowned let fm: FileManagerWindowController
    private let side: Side
    private let strip = NSView()
    private let backButton: NSButton
    private let forwardButton: NSButton
    private let refreshButton: NSButton
    private let crumbs = UI.hstack([], spacing: 2)
    let search: PanelSearch
    private let tabPicker = NSPopUpButton()
    private let closeButton: NSButton

    init(fm: FileManagerWindowController, side: Side) {
        self.fm = fm
        self.side = side
        backButton = UI.iconButton("arrow.left", "Back", target: nil, action: nil, size: 24)
        forwardButton = UI.iconButton("arrow.right", "Forward", target: nil, action: nil, size: 24)
        refreshButton = UI.iconButton("arrow.clockwise", side == .left ? "Refresh" : "Refresh right panel", target: nil, action: nil, size: 24)
        closeButton = UI.iconButton("xmark", "Close this panel", target: nil, action: nil, size: 22)
        search = PanelSearch(tone: side.tone, width: 150)
        super.init(frame: .zero)
        wantsLayer = true

        for (b, sel) in [(backButton, #selector(back)), (forwardButton, #selector(forward)),
                         (refreshButton, #selector(refresh)), (closeButton, #selector(closePane))] {
            b.target = self
            b.action = sel
        }
        closeButton.contentTintColor = .systemRed
        search.onChange = { [weak self] q in
            guard let self else { return }
            self.fm.focus(self.side)
            self.fm.setQuery(q)
        }
        tabPicker.controlSize = .small
        tabPicker.font = .systemFont(ofSize: 11)
        tabPicker.target = self
        tabPicker.action = #selector(pickTab)
        tabPicker.toolTip = side == .left ? "Switch left panel tab" : "Switch right panel tab"
        tabPicker.widthAnchor.constraint(lessThanOrEqualToConstant: 150).isActive = true

        strip.wantsLayer = true
        strip.translatesAutoresizingMaskIntoConstraints = false
        let folder = NSImageView(image: NSImage(systemSymbolName: "folder", accessibilityDescription: nil) ?? NSImage())
        folder.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        folder.contentTintColor = side.tone.color
        let crumbsClip = NSView()
        crumbsClip.translatesAutoresizingMaskIntoConstraints = false
        crumbsClip.addSubview(crumbs)
        crumbsClip.wantsLayer = true
        crumbsClip.layer?.masksToBounds = true
        crumbsClip.setContentHuggingPriority(.init(1), for: .horizontal)
        crumbsClip.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        NSLayoutConstraint.activate([
            crumbs.trailingAnchor.constraint(equalTo: crumbsClip.trailingAnchor).withPriority(.defaultLow),
            crumbs.leadingAnchor.constraint(greaterThanOrEqualTo: crumbsClip.leadingAnchor).withPriority(.init(100)),
            crumbs.leadingAnchor.constraint(equalTo: crumbsClip.leadingAnchor).withPriority(.init(90)),
            crumbs.centerYAnchor.constraint(equalTo: crumbsClip.centerYAnchor),
            crumbsClip.heightAnchor.constraint(equalToConstant: 24),
        ])
        let row = UI.hstack([backButton, forwardButton, refreshButton, folder, crumbsClip, search, tabPicker, closeButton], spacing: 4)
        addSubview(strip)
        addSubview(row)
        NSLayoutConstraint.activate([
            strip.leadingAnchor.constraint(equalTo: leadingAnchor),
            strip.topAnchor.constraint(equalTo: topAnchor),
            strip.bottomAnchor.constraint(equalTo: bottomAnchor),
            strip.widthAnchor.constraint(equalToConstant: 4),
            row.leadingAnchor.constraint(equalTo: strip.trailingAnchor, constant: 6),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let focused = fm.focused == side
        layer?.backgroundColor = (focused ? NSColor.controlBackgroundColor : NSColor.windowBackgroundColor).cgColor
        strip.layer?.backgroundColor = side.tone.color.withAlphaComponent(focused ? 1 : 0.25).cgColor
    }

    override func draw(_ dirtyRect: NSRect) {
        side.tone.color.withAlphaComponent(fm.focused == side ? 0.8 : 0.2).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 2).fill()
    }

    func update() {
        let tab = fm.tab(for: side)
        let focused = fm.focused == side
        backButton.isEnabled = !tab.back.isEmpty
        forwardButton.isEnabled = !tab.forward.isEmpty
        for b in [backButton, forwardButton, refreshButton] { b.alphaValue = focused ? 1 : 0.6 }
        search.show(tab.query)
        search.setMatchCount(tab.listing.map { Int($0.count()) })

        crumbs.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let comps = tab.path.split(separator: "/").map(String.init)
        var acc = ""
        var parts: [(String, String)] = [(volumeName("/"), "/")]
        for c in comps { acc += "/" + c; parts.append((c, acc)) }
        // Compact: keep the last few crumbs, like captools' 11 pt header crumbs.
        let shown = parts.count > 4 ? [("…", parts[parts.count - 4].1)] + parts.suffix(3) : parts
        for (i, part) in shown.enumerated() {
            if i > 0 {
                let chevron = NSImageView(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil) ?? NSImage())
                chevron.symbolConfiguration = .init(pointSize: 8, weight: .semibold)
                chevron.contentTintColor = .tertiaryLabelColor
                crumbs.addArrangedSubview(chevron)
            }
            let last = i == shown.count - 1
            let b = NSButton(title: part.0, target: self, action: #selector(crumbClicked(_:)))
            b.isBordered = false
            b.identifier = NSUserInterfaceItemIdentifier(part.1)
            b.toolTip = part.1
            b.attributedTitle = NSAttributedString(string: part.0, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: last ? .semibold : .regular),
                .foregroundColor: last ? NSColor.labelColor : NSColor.secondaryLabelColor,
            ])
            crumbs.addArrangedSubview(b)
        }

        tabPicker.removeAllItems()
        // Added as menu items directly: addItem(withTitle:) drops duplicate
        // titles, and two tabs can show folders with the same name.
        for (i, t) in fm.tabs.enumerated() {
            let item = NSMenuItem(title: t.name, action: nil, keyEquivalent: "")
            item.tag = i
            item.toolTip = t.path
            tabPicker.menu?.addItem(item)
        }
        if let i = fm.tabs.firstIndex(where: { $0 === tab }) { tabPicker.selectItem(at: i) }
        tabPicker.isHidden = fm.tabs.count < 2
        needsDisplay = true
        needsLayout = true
        updateLayer()
    }

    private func act(_ action: () -> Void) {
        fm.focus(side)
        action()
    }

    @objc private func back() { act { fm.goBack(nil) } }
    @objc private func forward() { act { fm.goForward(nil) } }
    @objc private func refresh() { act { fm.refresh(nil) } }
    @objc private func closePane() { fm.closePane(side) }
    @objc private func crumbClicked(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        act { fm.navigate(to: path) }
    }
    @objc private func pickTab() {
        guard let i = tabPicker.selectedItem?.tag, i < fm.tabs.count else { return }
        fm.assign(fm.tabs[i], to: side)
    }
}

extension NSLayoutConstraint {
    func withPriority(_ p: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
        priority = p
        return self
    }
}
