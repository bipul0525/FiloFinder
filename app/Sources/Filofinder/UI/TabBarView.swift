import AppKit

/// captools TabBar (UI-SPEC §4): folder icon · name · close-on-hover · "+".
final class TabBarView: NSView {
    private unowned let fm: FileManagerWindowController
    private let stack = UI.hstack([], spacing: 2)

    init(fm: FileManagerWindowController) {
        self.fm = fm
        super.init(frame: .zero)
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
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            doc.heightAnchor.constraint(equalTo: scroll.heightAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 3),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for tab in fm.tabs {
            stack.addArrangedSubview(TabChip(tab: tab, fm: fm, active: tab === fm.activeTab, canClose: fm.tabs.count > 1))
        }
        let plus = UI.iconButton("plus", "New Tab (⌘T)", target: fm, action: #selector(FileManagerWindowController.newTab(_:)), size: 24)
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
        close = UI.iconButton("xmark", "Close tab", target: nil, action: nil, size: 18)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = tab.path ?? tab.name

        let icon = NSImageView(image: NSImage(systemSymbolName: "folder", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        icon.contentTintColor = active ? .controlAccentColor : .secondaryLabelColor
        let name = UI.label(tab.name, size: 12, weight: active ? .medium : .regular,
                            color: active ? .labelColor : .secondaryLabelColor)
        name.widthAnchor.constraint(lessThanOrEqualToConstant: 120).isActive = true
        close.target = self
        close.action = #selector(closeTab)
        close.isHidden = true
        close.isEnabled = canClose
        let row = UI.hstack([icon, name, close], spacing: 6)
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 26),
            close.widthAnchor.constraint(equalToConstant: 18),
        ])
        if !canClose { close.removeFromSuperview() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = active ? NSColor.controlBackgroundColor.cgColor : NSColor.clear.cgColor
        layer?.borderWidth = active ? 1 : 0
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { close.isHidden = false }
    override func mouseExited(with event: NSEvent) { close.isHidden = true }

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
