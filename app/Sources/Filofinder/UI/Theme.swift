import AppKit

/// captools' panel identity colours, as macOS system colours (UI-SPEC §1).
enum Tone {
    case left, right, bin, preview

    var color: NSColor {
        switch self {
        case .left: .systemBlue
        case .right: .systemOrange
        case .bin: .systemPink
        case .preview: .systemYellow
        }
    }
}

/// Native replacements for captools' keycap buttons, separators and pills.
enum UI {
    /// captools `KEYCAP_NEUTRAL` icon button (28×28, glyph-coloured) →
    /// a native toolbar-style button with an SF Symbol.
    static func iconButton(_ symbol: String, _ tooltip: String, target: AnyObject?, action: Selector?,
                           toggle: Bool = false, size: CGFloat = 28) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) ?? NSImage()
        let b = NSButton(image: image, target: target, action: action)
        b.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        if #available(macOS 14.0, *) {
            b.bezelStyle = .toolbar
        } else {
            b.bezelStyle = .texturedRounded
        }
        b.setButtonType(toggle ? .pushOnPushOff : .momentaryPushIn)
        b.toolTip = tooltip
        b.setAccessibilityLabel(tooltip)
        b.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            b.widthAnchor.constraint(equalToConstant: size),
            b.heightAnchor.constraint(equalToConstant: size - 4),
        ])
        return b
    }

    /// Labelled pill (captools Recycle Bin pill, Clear danger pill).
    static func pillButton(_ title: String, symbol: String?, tooltip: String, target: AnyObject?, action: Selector?,
                           destructive: Bool = false) -> NSButton {
        let b = NSButton(title: title, target: target, action: action)
        if let symbol {
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
            b.imagePosition = .imageLeading
            b.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        }
        b.bezelStyle = .rounded
        b.controlSize = .regular
        b.font = .systemFont(ofSize: 11, weight: destructive ? .semibold : .regular)
        b.toolTip = tooltip
        if destructive {
            b.hasDestructiveAction = true
            b.contentTintColor = .systemRed
        }
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }

    /// captools 1×16 separator.
    static func separator(height: CGFloat = 16) -> NSView {
        let v = NSBox()
        v.boxType = .custom
        v.borderWidth = 0
        v.fillColor = .separatorColor
        v.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            v.widthAnchor.constraint(equalToConstant: 1),
            v.heightAnchor.constraint(equalToConstant: height),
        ])
        return v
    }

    static func label(_ text: String, size: CGFloat = 11, weight: NSFont.Weight = .regular,
                      color: NSColor = .secondaryLabelColor) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.lineBreakMode = .byTruncatingTail
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }

    static func hstack(_ views: [NSView], spacing: CGFloat = 4) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.alignment = .centerY
        s.spacing = spacing
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }

    /// Fixed-height bar with a background material.
    static func bar(material: NSVisualEffectView.Material, height: CGFloat) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .withinWindow
        v.state = .followsWindowActiveState
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: height).isActive = true
        return v
    }

    /// Bottom-of-window transient message (replaces captools' toasts).
    static func hud(_ text: String, in window: NSWindow?) {
        guard let content = window?.contentView else { return }
        let hud = NSVisualEffectView()
        hud.material = .hudWindow
        hud.state = .active
        hud.wantsLayer = true
        hud.layer?.cornerRadius = 10
        let l = label(text, size: 12, weight: .medium, color: .labelColor)
        hud.addSubview(l)
        hud.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(hud)
        NSLayoutConstraint.activate([
            l.leadingAnchor.constraint(equalTo: hud.leadingAnchor, constant: 14),
            l.trailingAnchor.constraint(equalTo: hud.trailingAnchor, constant: -14),
            l.topAnchor.constraint(equalTo: hud.topAnchor, constant: 8),
            l.bottomAnchor.constraint(equalTo: hud.bottomAnchor, constant: -8),
            hud.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            hud.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -40),
        ])
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; hud.animator().alphaValue = 0 },
                                                completionHandler: { hud.removeFromSuperview() })
        }
    }
}

/// A view that lets the window be dragged by its background (unified titlebar).
class DraggableBackgroundView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}

/// Borderless icon button with a soft rounded hover/press highlight — the
/// quieter, Safari/Finder-style control used in the tab and path rows.
final class HoverButton: NSButton {
    private var hovering = false { didSet { updateLayer() } }
    var cornerRadius: CGFloat = 6

    convenience init(symbol: String, tooltip: String, target: AnyObject?, action: Selector?, size: CGFloat = 26,
                     pointSize: CGFloat = 13, weight: NSFont.Weight = .medium) {
        self.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        symbolConfiguration = .init(pointSize: pointSize, weight: weight)
        imagePosition = .imageOnly
        isBordered = false
        self.target = target
        self.action = action
        toolTip = tooltip
        setAccessibilityLabel(tooltip)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size - 2),
        ])
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = cornerRadius
        let fill: NSColor = !isEnabled ? .clear
            : isHighlighted ? NSColor.labelColor.withAlphaComponent(0.14)
            : hovering ? NSColor.labelColor.withAlphaComponent(0.08) : .clear
        layer?.backgroundColor = fill.cgColor
        contentTintColor = isEnabled ? (hovering ? .labelColor : .secondaryLabelColor) : .tertiaryLabelColor
    }

    override var isEnabled: Bool { didSet { needsDisplay = true; updateLayer() } }
    override var isHighlighted: Bool { didSet { updateLayer() } }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
}

/// Back/Forward joined in one rounded capsule with a hairline between (Safari).
final class NavCapsule: NSView {
    init(_ left: NSButton, _ right: NSButton) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        let divider = NSView()
        divider.wantsLayer = true
        divider.translatesAutoresizingMaskIntoConstraints = false
        (left as? HoverButton)?.cornerRadius = 7
        (right as? HoverButton)?.cornerRadius = 7
        let row = UI.hstack([left, divider, right], spacing: 0)
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.heightAnchor.constraint(equalToConstant: 14),
        ])
        self.divider = divider
    }

    private var divider: NSView!

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 7
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor
        divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
    }
}

/// Colour of a place, shared by the sidebar and tabs: each top-level
/// location has its own hue and everything inside it inherits it.
enum PlaceColor {
    private static var table: [(String, NSColor)] {
        let home = Tab.home
        func h(_ p: String) -> String { (home as NSString).appendingPathComponent(p) }
        return [
            (h("Downloads"), .systemGreen), (h("Documents"), .systemBlue), (h("Desktop"), .systemTeal),
            (h("Pictures"), .systemOrange), (h("Movies"), .systemPink), (h("Music"), .systemRed),
            ("/Applications", .systemMint), (Tab.trashPath, .systemGray), (home, .systemYellow),
        ]
    }

    /// Deepest matching place wins (Downloads beats Home).
    static func color(for path: String) -> NSColor {
        table.filter { path == $0.0 || path.hasPrefix($0.0 + "/") }.max { $0.0.count < $1.0.count }?.1 ?? .systemGray
    }

    /// The place colour softened toward grey — a hint of colour, not a shout.
    /// `strength` 0 = grey, 1 = full colour.
    static func muted(_ color: NSColor, strength: CGFloat = 0.45) -> NSColor {
        // Solid grey (secondaryLabelColor is semi-transparent and washed icons out).
        let grey = NSColor.systemGray.usingColorSpace(.deviceRGB) ?? .gray
        let c = color.usingColorSpace(.deviceRGB) ?? color
        return grey.blended(withFraction: strength, of: c) ?? c
    }

    /// A solid single-colour SF Symbol in that colour, not recoloured by
    /// sidebar or selection styles.
    static func icon(_ symbol: String, color: NSColor, size: CGFloat = 12.5, weight: NSFont.Weight = .regular) -> NSImage? {
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight).applying(.init(paletteColors: [color])))
        img?.isTemplate = false
        return img
    }
}
