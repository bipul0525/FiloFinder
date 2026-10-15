import AppKit
import Quartz
import os

/// Feeds the system Quick Look panel (Space) with the selected items, so
/// every file type previews exactly like in Finder.
final class QuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private unowned let fm: FileManagerWindowController
    private var items: [URL] = []

    init(fm: FileManagerWindowController) {
        self.fm = fm
    }

    func toggle() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
        } else {
            refreshItems()
            guard !items.isEmpty else { NSSound.beep(); return }
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Call when the selection changes; keeps an open panel in sync.
    func selectionChanged() {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible,
              panel.dataSource === self else { return }
        refreshItems()
        panel.reloadData()
    }

    private func refreshItems() {
        items = fm.selectedPaths().map { URL(fileURLWithPath: $0) }
    }

    func begin(_ panel: QLPreviewPanel) {
        refreshItems()
        panel.dataSource = self
        panel.delegate = self
    }

    func end(_ panel: QLPreviewPanel) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        items.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        items[index] as NSURL
    }

    /// Arrow keys in the panel move the selection in the file view (Finder behaviour).
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, [123, 124, 125, 126].contains(event.keyCode) else { return false }
        fm.focusTarget.keyDown(with: event)
        return true
    }
}

// MARK: - Drag & drop rules (shared by grid, list and sidebar)

enum DragDrop {
    /// `log stream --predicate 'subsystem == "app.filofinder"'` shows drag decisions.
    static let log = Logger(subsystem: "app.filofinder", category: "dnd")

    /// File paths on a drag pasteboard (from Filofinder, Finder or any app).
    static func paths(from info: NSDraggingInfo) -> [String] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                       options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return urls?.map(\.path) ?? []
    }

    /// Finder semantics: same volume → move, other volume → copy, ⌥ → copy.
    static func operation(for info: NSDraggingInfo, into dest: String) -> NSDragOperation {
        let sources = paths(from: info)
        guard !sources.isEmpty else {
            log.notice("refused: no file URLs on pasteboard \(info.draggingPasteboard.types?.map(\.rawValue) ?? [], privacy: .public)")
            return []
        }
        // Never into itself, never onto its own folder as a no-op move.
        for src in sources where dest == src || dest.hasPrefix(src + "/") { return [] }
        let allowed = info.draggingSourceOperationMask
        let wantsCopy = NSEvent.modifierFlags.contains(.option) || !sameVolume(sources[0], dest)
        if wantsCopy, allowed.contains(.copy) { return .copy }
        if sources.allSatisfy({ ($0 as NSString).deletingLastPathComponent == dest }) { return [] } // already here
        if allowed.contains(.move) || allowed.contains(.generic) { return .move }
        return allowed.contains(.copy) ? .copy : []
    }

    static func perform(_ info: NSDraggingInfo, into dest: String, fm: FileManagerWindowController) -> Bool {
        let op = operation(for: info, into: dest)
        let sources = paths(from: info)
        guard !op.isEmpty, !sources.isEmpty else { return false }
        fm.ops.transfer(sources, mode: op == .copy ? .copy : .cut, into: dest)
        return true
    }

    static func sameVolume(_ a: String, _ b: String) -> Bool {
        let key: Set<URLResourceKey> = [.volumeIdentifierKey]
        let va = try? URL(fileURLWithPath: a).resourceValues(forKeys: key).volumeIdentifier as? NSObject
        let vb = try? URL(fileURLWithPath: b).resourceValues(forKeys: key).volumeIdentifier as? NSObject
        guard let va, let vb else { return true }
        return va.isEqual(vb)
    }
}
