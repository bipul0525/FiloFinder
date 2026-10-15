import AppKit

/// Full Disk Access: detection and the launch-time welcome sheet.
///
/// macOS has no API to *request* Full Disk Access — the user must switch it
/// on in System Settings. So Filofinder checks at launch, explains why, opens
/// the right settings page, and closes the sheet by itself once granted.
enum DiskAccess {
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    /// True when protected locations (the Trash, Safari data) are readable —
    /// the observable effect of Full Disk Access. Never triggers a prompt.
    static var isGranted: Bool {
        let fm = FileManager.default
        let probes = [Tab.trashPath, (Tab.home as NSString).appendingPathComponent("Library/Safari")]
        return probes.contains { (try? fm.contentsOfDirectory(atPath: $0)) != nil }
    }

    static var dontAskAgain: Bool {
        get { UserDefaults.standard.bool(forKey: "skipDiskAccessSheet") }
        set { UserDefaults.standard.set(newValue, forKey: "skipDiskAccessSheet") }
    }
}

final class DiskAccessSheet: NSWindowController {
    private var observer: NSObjectProtocol?
    private let dontAsk = NSButton(checkboxWithTitle: "Don’t show this again", target: nil, action: nil)
    var onGranted: () -> Void = {}

    init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
                            styleMask: [.titled, .docModalWindow], backing: .buffered, defer: false)
        super.init(window: panel)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        guard let content = window?.contentView else { return }
        let icon = NSImageView(image: NSImage(systemSymbolName: "externaldrive.badge.checkmark", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 40, weight: .light)
        icon.contentTintColor = .controlAccentColor
        let title = UI.label("Let Filofinder work with your whole disk", size: 17, weight: .semibold, color: .labelColor)
        let body = UI.label("""
            Filofinder is a file manager, so it needs Full Disk Access to show every folder — including the \
            Trash, Mail and other protected places — without macOS asking again and again.
            """, size: 12, color: .secondaryLabelColor)
        body.lineBreakMode = .byWordWrapping
        body.maximumNumberOfLines = 4
        body.preferredMaxLayoutWidth = 440
        let steps = UI.label("""
            1.  Click “Open Settings”.
            2.  Turn on Filofinder in the Full Disk Access list.
                 (Not listed? Click +, then choose Filofinder.)
            3.  Come back — this window closes by itself.
            """, size: 12, color: .labelColor)
        steps.lineBreakMode = .byWordWrapping
        steps.maximumNumberOfLines = 6
        steps.preferredMaxLayoutWidth = 440

        let open = NSButton(title: "Open Settings", target: self, action: #selector(openSettings))
        open.keyEquivalent = "\r"
        open.bezelStyle = .rounded
        let reveal = NSButton(title: "Show Filofinder App", target: self, action: #selector(revealApp))
        reveal.bezelStyle = .rounded
        reveal.toolTip = "Shows the app in Finder so you can drag it into the Full Disk Access list"
        let later = NSButton(title: "Later", target: self, action: #selector(later))
        later.bezelStyle = .rounded
        later.keyEquivalent = "\u{1b}"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = UI.hstack([dontAsk, spacer, later, reveal, open], spacing: 8)

        let stack = NSStackView(views: [icon, title, body, steps, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(20, after: steps)
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 20, right: 28)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -56),
        ])
    }

    /// Presents on `parent` and watches for the grant whenever the app
    /// becomes active again (e.g. returning from System Settings).
    func present(on parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window)
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            guard DiskAccess.isGranted else { return }
            self?.close(granted: true)
        }
    }

    private func close(granted: Bool) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        DiskAccess.dontAskAgain = dontAsk.state == .on
        if let window, let parent = window.sheetParent { parent.endSheet(window) }
        if granted { onGranted() }
    }

    @objc private func openSettings() { NSWorkspace.shared.open(DiskAccess.settingsURL) }
    @objc private func revealApp() { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
    @objc private func later() { close(granted: false) }
}
