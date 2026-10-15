import AppKit

/// captools Breadcrumbs (UI-SPEC §5): ← → ⟳ | ⌂ › crumbs … [filter].
final class BreadcrumbBar: NSVisualEffectView {
    private unowned let fm: FileManagerWindowController
    private let backButton: NSButton
    private let forwardButton: NSButton
    private let refreshButton: NSButton
    private let crumbs = UI.hstack([], spacing: 2)
    let search: PanelSearch

    init(fm: FileManagerWindowController) {
        self.fm = fm
        backButton = HoverButton(symbol: "chevron.left", tooltip: "Back (⌘[ or ⌥←)", target: fm,
                                 action: #selector(FileManagerWindowController.goBack(_:)), size: 30, weight: .semibold)
        forwardButton = HoverButton(symbol: "chevron.right", tooltip: "Forward (⌘] or ⌥→)", target: fm,
                                    action: #selector(FileManagerWindowController.goForward(_:)), size: 30, weight: .semibold)
        refreshButton = HoverButton(symbol: "arrow.clockwise", tooltip: "Refresh (F5)", target: fm,
                                    action: #selector(FileManagerWindowController.refresh(_:)), size: 28, pointSize: 12.5)
        search = PanelSearch(tone: .left, width: 200)
        super.init(frame: .zero)
        // Same material as the toolbar: toolbar, tabs and path read as one header.
        material = .titlebar
        blendingMode = .withinWindow
        state = .followsWindowActiveState
        search.onChange = { [weak fm] q in fm?.setQuery(q) }

        let home = HoverButton(symbol: "house", tooltip: "Home (⇧⌘H)", target: fm,
                               action: #selector(FileManagerWindowController.goHome(_:)), size: 28, pointSize: 12.5)
        crumbs.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let crumbsClip = NSView()
        crumbsClip.translatesAutoresizingMaskIntoConstraints = false
        crumbsClip.addSubview(crumbs)
        crumbsClip.setContentHuggingPriority(.init(1), for: .horizontal)
        crumbsClip.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        NSLayoutConstraint.activate([
            crumbs.leadingAnchor.constraint(equalTo: crumbsClip.leadingAnchor),
            crumbs.centerYAnchor.constraint(equalTo: crumbsClip.centerYAnchor),
            crumbsClip.heightAnchor.constraint(equalToConstant: 24),
        ])
        crumbsClip.wantsLayer = true
        crumbsClip.layer?.masksToBounds = true

        let nav = NavCapsule(backButton, forwardButton)
        let row = UI.hstack([nav, refreshButton, home, crumbsClip, search], spacing: 6)
        row.setCustomSpacing(10, after: nav)
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update() {
        let tab = fm.activeTab
        backButton.isEnabled = !tab.back.isEmpty
        forwardButton.isEnabled = !tab.forward.isEmpty
        crumbs.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let pseudo: [String]? = Tags.tag(fromPath: tab.path).map { ["Tags", $0] } ?? (tab.isTrash ? ["Trash"] : nil)
        if let pseudo {
            for (i, text) in pseudo.enumerated() {
                if i > 0 {
                    let chevron = NSImageView(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil) ?? NSImage())
                    chevron.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
                    chevron.contentTintColor = .tertiaryLabelColor
                    crumbs.addArrangedSubview(chevron)
                }
                let last = i == pseudo.count - 1
                crumbs.addArrangedSubview(UI.label(text, size: 12, weight: last ? .medium : .regular,
                                                   color: last ? .labelColor : .secondaryLabelColor))
            }
            return
        }
        // Macintosh HD › Users › bipul › Downloads
        var parts: [(String, String)] = [(volumeName("/"), "/")]
        var acc = ""
        for comp in tab.path.split(separator: "/") {
            acc += "/" + comp
            parts.append((String(comp), acc))
        }
        for (i, part) in parts.enumerated() {
            if i > 0 {
                let chevron = NSImageView(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil) ?? NSImage())
                chevron.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
                chevron.contentTintColor = .tertiaryLabelColor
                crumbs.addArrangedSubview(chevron)
            }
            let crumb = CrumbButton(title: part.0, path: part.1, last: i == parts.count - 1) { [weak fm] p in fm?.navigate(to: p) }
            crumbs.addArrangedSubview(crumb)
        }
    }
}

private final class CrumbButton: NSButton {
    private let go: (String) -> Void
    private let path: String

    init(title: String, path: String, last: Bool, go: @escaping (String) -> Void) {
        self.go = go
        self.path = path
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        font = .systemFont(ofSize: 12, weight: last ? .medium : .regular)
        contentTintColor = last ? .labelColor : .secondaryLabelColor
        attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: last ? NSColor.labelColor : NSColor.secondaryLabelColor,
            .font: NSFont.systemFont(ofSize: 12, weight: last ? .medium : .regular),
        ])
        toolTip = path
        target = self
        action = #selector(click)
        lineBreakMode = .byTruncatingMiddle
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func click() { go(path) }
}

/// captools PanelSearch (UI-SPEC §7): a search button that expands into a
/// filter field with a match count; stays open while a filter is active.
final class PanelSearch: NSView, NSSearchFieldDelegate {
    var onChange: ((String) -> Void)?
    private let button: NSButton
    private let field = NSSearchField()
    private let count = UI.label("", size: 10)
    private let tone: Tone
    private var widthConstraint: NSLayoutConstraint!
    private let expandedWidth: CGFloat

    init(tone: Tone, width: CGFloat) {
        self.tone = tone
        expandedWidth = width
        button = HoverButton(symbol: "magnifyingglass", tooltip: "Search / filter this panel", target: nil, action: nil,
                             size: 28, pointSize: 12.5)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        button.target = self
        button.action = #selector(expand)
        field.placeholderString = "Filter…"
        field.font = .systemFont(ofSize: 11)
        field.controlSize = .small
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.target = self
        field.action = #selector(changed)
        field.translatesAutoresizingMaskIntoConstraints = false
        count.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        let row = UI.hstack([button, field, count], spacing: 4)
        addSubview(row)
        widthConstraint = field.widthAnchor.constraint(equalToConstant: width)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthConstraint,
        ])
        collapse()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var query: String { field.stringValue }

    @objc func expand() {
        button.isHidden = true
        field.isHidden = false
        window?.makeFirstResponder(field)
    }

    private func collapse() {
        field.isHidden = true
        count.isHidden = true
        button.isHidden = false
    }

    /// Mirrors a tab's current filter (after switching tabs or navigating).
    func show(_ query: String) {
        guard field.stringValue != query else { return }
        field.stringValue = query
        if query.isEmpty { collapse() } else { button.isHidden = true; field.isHidden = false }
    }

    func clear() {
        field.stringValue = ""
        collapse()
        onChange?("")
    }

    func setMatchCount(_ n: Int?) {
        if let n, !field.stringValue.isEmpty {
            count.stringValue = n.formatted()
            count.textColor = tone.color
            count.isHidden = false
        } else {
            count.isHidden = true
        }
    }

    @objc private func changed() {
        onChange?(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            clear()
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // A live filter must never hide behind a collapsed button.
        if field.stringValue.isEmpty { collapse() }
    }
}
