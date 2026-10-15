import AppKit
import Quartz

/// captools SplitStatusBar, single-mode variant (UI-SPEC §10).
final class StatusBarView: NSView {
    private let count = UI.label("", size: 10)
    private let selected = Chip()
    private let info = UI.label("", size: 10, color: .tertiaryLabelColor)

    override init(frame: NSRect) {
        super.init(frame: frame)
        count.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        info.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = UI.hstack([count, selected, spacer, info], spacing: 8)
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    func update(tab: Tab, timing: String, tone: Tone = .left) {
        guard let listing = tab.listing else {
            count.stringValue = ""
            selected.isHidden = true
            info.stringValue = ""
            return
        }
        let visible = Int(listing.count()), total = Int(listing.total())
        let c = listing.counts()
        // captools says "images" when every entry is an image.
        let noun = (c.images > 0 && c.files == 0 && c.folders == 0) ? "image" : "item"
        let plural = total == 1 ? noun : noun + "s"
        count.stringValue = visible == total ? "\(total.formatted()) \(plural)" : "\(visible.formatted()) of \(total.formatted()) \(plural)"
        selected.isHidden = tab.selection.isEmpty
        selected.set("\(tab.selection.count.formatted()) selected", tone: tone)
        info.stringValue = "\(c.images.formatted()) images · \(c.files.formatted()) files · \(c.folders.formatted()) folders   \(timing)"
    }
}

/// Tone-coloured pill ("N selected").
final class Chip: NSView {
    private let label = UI.label("", size: 10, weight: .semibold, color: .white)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 7
        addSubview(label)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 15),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func set(_ text: String, tone: Tone) {
        label.stringValue = text
        layer?.backgroundColor = tone.color.cgColor
    }
}

/// Preview pane (captools layout: counter, name, preview, prev/next, close)
/// showing the system Quick Look preview, so every file type renders
/// exactly as in Finder: images, PDF, video, audio, text, Office, code…
final class PreviewPaneView: NSView {
    private unowned let fm: FileManagerWindowController
    private let counter = UI.label("Preview", size: 10)
    private let name = UI.label("", size: 13, weight: .semibold, color: .labelColor)
    private let ql: QLPreviewView
    private let placeholder = UI.label("Select a file to preview", size: 12, color: .tertiaryLabelColor)
    private var shownPath: String?

    init(fm: FileManagerWindowController) {
        self.fm = fm
        ql = QLPreviewView(frame: .zero, style: .normal)!
        super.init(frame: .zero)
        ql.autostarts = false
        ql.shouldCloseWithWindow = false
        counter.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        placeholder.alignment = .center
        name.lineBreakMode = .byTruncatingMiddle
        let close = UI.iconButton("xmark", "Close Preview", target: fm, action: #selector(FileManagerWindowController.togglePreview(_:)), size: 22)
        let titles = NSStackView(views: [counter, name])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 1
        titles.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let header = UI.hstack([titles, spacer, close], spacing: 6)
        let prev = UI.iconButton("chevron.left", "Previous item", target: self, action: #selector(prevItem), size: 28)
        let next = UI.iconButton("chevron.right", "Next item", target: self, action: #selector(nextItem), size: 28)
        let open = UI.iconButton("arrow.up.forward.app", "Open with default app", target: self, action: #selector(openItem), size: 28)
        let nav = UI.hstack([prev, open, next], spacing: 8)
        for v in [header, ql, placeholder, nav] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            ql.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            ql.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            ql.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            ql.bottomAnchor.constraint(equalTo: nav.topAnchor, constant: -8),
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
            nav.centerXAnchor.constraint(equalTo: centerXAnchor),
            nav.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
    }

    func update() {
        let tab = fm.activeTab
        guard let previewName = fm.previewName, let index = tab.listing?.indexOf(name: previewName) else {
            counter.stringValue = "Preview"
            name.stringValue = ""
            placeholder.isHidden = false
            ql.isHidden = true
            if shownPath != nil { ql.previewItem = nil; shownPath = nil }
            return
        }
        placeholder.isHidden = true
        ql.isHidden = false
        counter.stringValue = "\(Int(index) + 1) / \(tab.rows.count)"
        name.stringValue = previewName
        let path = tab.fullPath(previewName)
        guard shownPath != path else { return }
        shownPath = path
        ql.previewItem = URL(fileURLWithPath: path) as NSURL
    }

    /// Stops media playback when the pane hides.
    func stop() {
        ql.previewItem = nil
        shownPath = nil
    }

    @objc private func prevItem() { fm.stepPreview(-1) }
    @objc private func nextItem() { fm.stepPreview(1) }
    @objc private func openItem() {
        if let n = fm.previewName { NSWorkspace.shared.open(URL(fileURLWithPath: fm.activeTab.fullPath(n))) }
    }
}
