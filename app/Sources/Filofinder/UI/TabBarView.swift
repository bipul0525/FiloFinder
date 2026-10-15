import AppKit

/// captools TabBar (UI-SPEC §4): folder icon · name · close-on-hover · "+".
final class TabBarView: NSVisualEffectView {
    private unowned let fm: FileManagerWindowController
    private let stack = UI.hstack([], spacing: 4)

    init(fm: FileManagerWindowController) {
        self.fm = fm
        super.init(frame: .zero)
        // Same material as the toolbar, so the header reads as one surface.
        material = .titlebar
        blendingMode = .withinWindow
        state = .followsWindowActiveState
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        scroll.documentView = doc
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            doc.heightAnchor.constraint(equalTo: scroll.heightAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: doc.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for tab in fm.tabs {
            stack.addArrangedSubview(TabChip(tab: tab, fm: fm, active: tab === fm.activeTab, canClose: fm.tabs.count > 1))
        }
        let plus = HoverButton(symbol: "plus", tooltip: "New Tab (⌘T)", target: fm,
                               action: #selector(FileManagerWindowController.newTab(_:)), size: 26, pointSize: 12)
        stack.addArrangedSubview(plus)
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class TabChip: NSView {
    private let tab: Tab
    private unowned let fm: FileManagerWindowController
    private let active: Bool
    private let close: NSButton
    private var tracking: NSTrackingArea?

    init(tab: Tab, fm: FileManagerWindowController, active: Bool, canClose: Bool) {
        self.tab = tab
        self.fm = fm
        self.active = active
        close = HoverButton(symbol: "xmark", tooltip: "Close tab", target: nil, action: nil, size: 18, pointSize: 9,
                            weight: .bold)
        (close as? HoverButton)?.cornerRadius = 4
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.shadowOffset = CGSize(width: 0, height: -0.5)
        layer?.shadowRadius = 1.5
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = tab.path ?? tab.name

        // Active: filled folder in the place's colour; inactive: grey outline.
        let icon = NSImageView(image: (active
            ? PlaceColor.icon("folder.fill", color: PlaceColor.muted(PlaceColor.color(for: tab.path), strength: 0.85),
                              size: 13, weight: .semibold)
            : NSImage(systemSymbolName: "folder", accessibilityDescription: nil)) ?? NSImage())
        icon.symbolConfiguration = active ? nil : .init(pointSize: 13, weight: .regular)
        icon.contentTintColor = active ? nil : .secondaryLabelColor
        let name = UI.label(tab.name, size: 12.5, weight: active ? .semibold : .regular,
                            color: active ? .labelColor : .secondaryLabelColor)
        name.widthAnchor.constraint(lessThanOrEqualToConstant: 160).isActive = true
        close.target = self
        close.action = #selector(closeTab)
        close.isHidden = true
        close.isEnabled = canClose
        let row = UI.hstack([icon, name, close], spacing: 6)
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 28),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 96),
            close.widthAnchor.constraint(equalToConstant: 18),
        ])
        if !canClose { close.removeFromSuperview() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    private var hovering = false { didSet { updateLayer() } }

    /// Active: a raised card (content colour, hairline, soft shadow).
    /// Inactive: flat, with a faint wash on hover.
    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        if active {
            layer?.backgroundColor = (dark ? NSColor.white.withAlphaComponent(0.12) : NSColor.controlBackgroundColor).cgColor
            layer?.borderWidth = 0.5
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.shadowOpacity = dark ? 0 : 0.12
        } else {
            layer?.backgroundColor = (hovering ? NSColor.labelColor.withAlphaComponent(0.06) : .clear).cgColor
            layer?.borderWidth = 0
            layer?.shadowOpacity = 0
        }
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { close.isHidden = false; hovering = true }
    override func mouseExited(with event: NSEvent) { close.isHidden = true; hovering = false }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            // captools: double-click copies the folder name.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(tab.name, forType: .string)
            UI.hud("Copied folder name", in: window)
        } else {
            fm.switchTo(tab)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(item("Duplicate Tab", "plus.square.on.square", #selector(duplicateTab)))
        if fm.tabs.count > 1 {
            menu.addItem(.separator())
            menu.addItem(item("Close Tab", "xmark", #selector(closeTab)))
            menu.addItem(item("Close Other Tabs", "xmark.circle", #selector(closeOthers)))
            if fm.tabs.last !== tab {
                menu.addItem(item("Close Tabs to Right", "arrow.right.to.line", #selector(closeRight)))
            }
        }
        return menu
    }

    private func item(_ title: String, _ symbol: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return i
    }

    @objc private func closeTab() { fm.close(tab) }
    @objc private func duplicateTab() { fm.duplicate(tab) }
    @objc private func closeOthers() { fm.closeOthers(than: tab) }
    @objc private func closeRight() { fm.closeTabsRight(of: tab) }
}
