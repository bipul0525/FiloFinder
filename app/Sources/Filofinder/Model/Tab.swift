import Foundation

/// One tab = a location on disk plus its navigation history.
/// Tabs browse the whole Mac; there is no "opened folder" restriction.
final class Tab {
    let id = UUID()
    var path: String
    var back: [String] = []
    var forward: [String] = []
    var listing: ListingHandle?
    /// Rows fetched from Rust so far, filled lazily as views scroll.
    var rows: [EntryRow?] = []
    var selection = Set<String>()
    var query = ""
    var loading = false
    /// Bumped per listing request; stale results for this tab are dropped.
    var generation = 0
    /// macOS refused to list this folder (privacy protection).
    var accessDenied = false
    /// "list 3 ms · sort 1 ms · 9 ms total" for the status bar.
    var timing = ""

    static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    init(path: String = Tab.home) {
        self.path = path
    }

    /// A tag-results tab ("tag:Red"): rows are files from anywhere.
    var isVirtual: Bool { Tags.tag(fromPath: path) != nil }

    static var trashPath: String {
        (try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false))?.path
            ?? (home as NSString).appendingPathComponent(".Trash")
    }
    var isTrash: Bool { path == Tab.trashPath }

    var name: String {
        if let tag = Tags.tag(fromPath: path) { return tag }
        if isTrash { return "Trash" }
        if path == "/" { return volumeName("/") }
        if path == Tab.home { return NSUserName() }
        return (path as NSString).lastPathComponent
    }

    func row(_ i: Int) -> EntryRow? {
        guard i >= 0, i < rows.count else { return nil }
        if let r = rows[i] { return r }
        let r = listing?.row(index: UInt32(i))
        rows[i] = r
        return r
    }

    /// Call after the listing's view (filter/sort) changed.
    func resetRows() {
        rows = Array(repeating: nil, count: Int(listing?.count() ?? 0))
    }

    func fullPath(_ name: String) -> String {
        // Virtual listings already name rows by their absolute path.
        if isVirtual || name.hasPrefix("/") { return name }
        return (path as NSString).appendingPathComponent(name)
    }

    func duplicate() -> Tab {
        let t = Tab(path: path)
        t.back = back
        t.forward = forward
        return t
    }
}

/// "Macintosh HD" for /, the volume name for mount points.
func volumeName(_ path: String) -> String {
    let url = URL(fileURLWithPath: path)
    return (try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName) ?? (path == "/" ? "Macintosh HD" : url.lastPathComponent)
}

/// The two panes of split view (captools: left = blue, right = amber).
enum Side {
    case left, right

    var tone: Tone { self == .left ? .left : .right }
    var other: Side { self == .left ? .right : .left }
}

enum ViewMode: String {
    case list, grid
}
