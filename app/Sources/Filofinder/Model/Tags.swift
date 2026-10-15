import AppKit
import CoreServices

/// Finder colour tags: reading them per file, finding tagged files with
/// Spotlight, and notifying views when tags change.
enum Tags {
    static let colors: [(name: String, color: NSColor)] = [
        ("Red", .systemRed), ("Orange", .systemOrange), ("Yellow", .systemYellow), ("Green", .systemGreen),
        ("Blue", .systemBlue), ("Purple", .systemPurple), ("Gray", .systemGray),
    ]
    static let changed = Notification.Name("FilofinderTagsChanged")

    /// Pseudo-path for a tag's results tab ("tag:Red").
    static func path(for tag: String) -> String { "tag:" + tag }
    static func tag(fromPath path: String) -> String? { path.hasPrefix("tag:") ? String(path.dropFirst(4)) : nil }

    static func color(named name: String) -> NSColor? {
        let n = name.lowercased() == "grey" ? "gray" : name.lowercased()
        return colors.first { $0.name.lowercased() == n }?.color
    }

    private static let cache: NSCache<NSString, NSArray> = {
        let c = NSCache<NSString, NSArray>()
        c.countLimit = 5000
        return c
    }()

    static func clearCache() { cache.removeAllObjects() }

    /// Colours of a file's tags (non-colour tags are ignored), cached.
    static func colorsFor(_ path: String) -> [NSColor] {
        if let hit = cache.object(forKey: path as NSString) as? [NSColor] { return hit }
        let names = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
        let result = names.compactMap(color(named:))
        cache.setObject(result as NSArray, forKey: path as NSString)
        return result
    }

    /// Every item on this Mac carrying `tag`, via the Spotlight index
    /// (blocking — call off the main thread).
    static func search(_ tag: String) -> [String] {
        let escaped = tag.replacingOccurrences(of: "\"", with: "\\\"")
        guard let query = MDQueryCreate(kCFAllocatorDefault, "kMDItemUserTags == \"\(escaped)\"c" as CFString, nil, nil)
        else { return [] }
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }
        var paths: [String] = []
        for i in 0..<MDQueryGetResultCount(query) {
            guard let raw = MDQueryGetResultAtIndex(query, i) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            if let path = MDItemCopyAttribute(item, kMDItemPath) as? String { paths.append(path) }
        }
        return paths
    }

    /// "● ● Name": coloured dots before a name, as Finder shows tagged items.
    static func label(_ name: String, colors: [NSColor], font: NSFont, textColor: NSColor,
                      alignment: NSTextAlignment) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.alignment = alignment
        para.lineBreakMode = alignment == .center ? .byWordWrapping : .byTruncatingMiddle
        let s = NSMutableAttributedString()
        for c in colors.prefix(3) {
            s.append(NSAttributedString(string: "●", attributes: [.foregroundColor: c, .font: font]))
        }
        if !colors.isEmpty { s.append(NSAttributedString(string: "\u{202F}", attributes: [.font: font])) }
        s.append(NSAttributedString(string: name, attributes: [.foregroundColor: textColor, .font: font]))
        s.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: s.length))
        return s
    }
}
