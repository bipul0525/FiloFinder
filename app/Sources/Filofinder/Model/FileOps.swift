import AppKit

/// Cut / copy / paste, rename, new folder, duplicate, Trash and undo.
/// All disk work runs on one background queue through the Rust core, which
/// never overwrites and never leaves half-copied files (PLAN §5).
final class FileOps {
    enum Mode { case copy, cut }

    struct Clipboard {
        let mode: Mode
        let paths: [String]
        /// NSPasteboard change count when we wrote it; if Finder copies
        /// something later, the system pasteboard wins.
        let changeCount: Int
    }

    /// A reversible operation, recorded after it ran (undo applies the inverse).
    enum Undo {
        case moved([(from: String, to: String)])
        case created([String])
        case renamed(from: String, to: String)
        case trashed([(original: String, trashed: String)])
    }

    private(set) var clipboard: Clipboard?
    private(set) var undoStack: [(title: String, op: Undo)] = []
    private(set) var busy = false
    private let queue = DispatchQueue(label: "app.filofinder.jobs", qos: .userInitiated)
    private unowned let fm: FileManagerWindowController

    init(fm: FileManagerWindowController) {
        self.fm = fm
    }

    var cutPaths: Set<String> {
        guard let c = clipboard, c.mode == .cut, c.changeCount == NSPasteboard.general.changeCount else { return [] }
        return Set(c.paths)
    }

    var canPaste: Bool {
        if let c = clipboard, c.changeCount == NSPasteboard.general.changeCount { return true }
        return !pasteboardFiles().isEmpty
    }

    /// Items a paste would bring in (for "Paste Item" vs "Paste Items").
    var pendingCount: Int {
        if let c = clipboard, c.changeCount == NSPasteboard.general.changeCount { return c.paths.count }
        return pasteboardFiles().count
    }

    var canUndo: Bool { !undoStack.isEmpty && !busy }
    var undoTitle: String? { undoStack.last?.title }

    // MARK: Clipboard

    func copy(_ paths: [String]) { put(paths, mode: .copy) }
    func cut(_ paths: [String]) { put(paths, mode: .cut) }

    private func put(_ paths: [String], mode: Mode) {
        guard !paths.isEmpty else { return }
        // Also on the system pasteboard, so Finder and other apps can paste copies.
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(paths.map { URL(fileURLWithPath: $0) as NSURL })
        clipboard = Clipboard(mode: mode, paths: paths, changeCount: pb.changeCount)
        UI.hud(mode == .cut ? "Cut \(count(paths.count)) — paste to move" : "Copied \(count(paths.count))", in: fm.window)
    }

    private func pasteboardFiles() -> [String] {
        let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return urls?.map(\.path) ?? []
    }

    // MARK: Paste

    func paste(into dest: String) {
        guard !busy else { return }
        let sources: [String]
        let mode: Mode
        if let c = clipboard, c.changeCount == NSPasteboard.general.changeCount {
            sources = c.paths
            mode = c.mode
        } else {
            sources = pasteboardFiles() // copied in Finder or another app
            mode = .copy
        }
        guard !sources.isEmpty else { return }
        transfer(sources, mode: mode, into: dest) { [weak self] in
            if mode == .cut { self?.clipboard = nil }
        }
    }

    /// Shared by paste and drag-and-drop: move or copy `sources` into `dest`,
    /// asking about name conflicts first.
    func transfer(_ sources: [String], mode: Mode, into dest: String, done: (() -> Void)? = nil) {
        guard !busy else { NSSound.beep(); return }
        // Moving items into the folder they already live in does nothing.
        let pending = mode == .cut ? sources.filter { ($0 as NSString).deletingLastPathComponent != dest } : sources
        guard !pending.isEmpty else { done?(); return }

        // Conflicts: same name already in the destination (copies into their
        // own folder are just duplicates and always "keep both").
        let fmgr = FileManager.default
        let conflicts = pending.filter { src in
            let sameFolder = (src as NSString).deletingLastPathComponent == dest
            return !sameFolder && fmgr.fileExists(atPath: (dest as NSString).appendingPathComponent((src as NSString).lastPathComponent))
        }
        resolveConflicts(conflicts, dest: dest) { [weak self] resolution in
            guard let self, let resolution else { return }
            self.runPaste(pending, mode: mode, dest: dest, resolution: resolution, conflicts: Set(conflicts), done: done)
        }
    }

    enum Resolution { case keepBoth, replace, skip }

    private func resolveConflicts(_ conflicts: [String], dest: String, then: @escaping (Resolution?) -> Void) {
        guard !conflicts.isEmpty, let window = fm.window else { then(.keepBoth); return }
        let alert = NSAlert()
        let first = (conflicts[0] as NSString).lastPathComponent
        alert.messageText = conflicts.count == 1
            ? "An item named “\(first)” already exists in this folder."
            : "\(conflicts.count) items with the same names already exist in this folder."
        alert.informativeText = "Replace moves the existing items to the Trash. Keep Both gives the new items a free name."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Keep Both")
        let replace = alert.addButton(withTitle: "Replace")
        replace.hasDestructiveAction = true
        alert.addButton(withTitle: "Skip")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            switch response {
            case .alertFirstButtonReturn: then(.keepBoth)
            case .alertSecondButtonReturn: then(.replace)
            case .alertThirdButtonReturn: then(.skip)
            default: then(nil)
            }
        }
    }

    private func runPaste(_ sources: [String], mode: Mode, dest: String, resolution: Resolution, conflicts: Set<String>,
                          done: (() -> Void)?) {
        let verb = mode == .cut ? "Moving" : "Copying"
        run(verb, total: sources.count) { progress in
            var moved: [(String, String)] = []
            var created: [String] = []
            var replacedTrash: [(String, String)] = []
            var errors: [String] = []
            for (i, src) in sources.enumerated() {
                progress(i)
                var name = (src as NSString).lastPathComponent
                if conflicts.contains(src) {
                    switch resolution {
                    case .skip: continue
                    case .keepBoth: name = uniqueName(dir: dest, name: name)
                    case .replace:
                        let existing = (dest as NSString).appendingPathComponent(name)
                        do {
                            var out: NSURL?
                            try FileManager.default.trashItem(at: URL(fileURLWithPath: existing), resultingItemURL: &out)
                            if let out {
                                replacedTrash.append((existing, out.path ?? ""))
                                TrashBook.record(trashed: out.path ?? "", original: existing)
                            }
                        } catch {
                            errors.append("\(name): couldn’t move the existing item to the Trash — \(error.localizedDescription)")
                            continue
                        }
                    }
                } else if (src as NSString).deletingLastPathComponent == dest {
                    name = uniqueName(dir: dest, name: name) // duplicate in place
                }
                do {
                    if mode == .cut {
                        let to = try moveItem(src: src, destDir: dest, name: name)
                        moved.append((src, to))
                    } else {
                        created.append(try copyItem(src: src, destDir: dest, name: name))
                    }
                } catch {
                    errors.append("\(error)")
                }
            }
            let landed = (moved.map { $0.1 } + created).map { ($0 as NSString).lastPathComponent }
            return Outcome(
                undo: mode == .cut ? (moved.isEmpty ? nil : ("Move", .moved(moved)))
                                   : (created.isEmpty ? nil : ("Copy", .created(created))),
                select: landed,
                errors: errors,
                summary: "\(mode == .cut ? "Moved" : "Copied") \(count(landed.count))"
                    + (replacedTrash.isEmpty ? "" : " · replaced \(replacedTrash.count) (in Trash)"))
        } done: {
            done?()
        }
    }

    // MARK: Single operations

    func newFolder(in dir: String) {
        run("Creating folder", total: 1) { _ in
            do {
                let path = try Filofinder.newFolder(dir: dir)
                return Outcome(undo: ("New Folder", .created([path])), select: [(path as NSString).lastPathComponent],
                               errors: [], summary: nil, renameAfter: path)
            } catch {
                return Outcome(undo: nil, select: [], errors: ["\(error)"], summary: nil)
            }
        }
    }

    func duplicate(_ paths: [String]) {
        run("Duplicating", total: paths.count) { progress in
            var created: [String] = []
            var errors: [String] = []
            for (i, src) in paths.enumerated() {
                progress(i)
                let dir = (src as NSString).deletingLastPathComponent
                do {
                    created.append(try copyItem(src: src, destDir: dir, name: uniqueName(dir: dir, name: (src as NSString).lastPathComponent)))
                } catch { errors.append("\(error)") }
            }
            return Outcome(undo: created.isEmpty ? nil : ("Duplicate", .created(created)),
                           select: created.map { ($0 as NSString).lastPathComponent }, errors: errors,
                           summary: "Duplicated \(count(created.count))")
        }
    }

    func rename(_ path: String) {
        guard let window = fm.window else { return }
        let old = (path as NSString).lastPathComponent
        let alert = NSAlert()
        alert.messageText = "Rename “\(old)”"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = old
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let new = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !new.isEmpty, new != old else { return }
            self.run("Renaming", total: 1) { _ in
                do {
                    let to = try renameItem(path: path, newName: new)
                    return Outcome(undo: ("Rename", .renamed(from: path, to: to)), select: [new], errors: [], summary: nil)
                } catch {
                    return Outcome(undo: nil, select: [old], errors: ["\(error)"], summary: nil)
                }
            }
        }
        // Select the name without its extension, like Finder.
        DispatchQueue.main.async {
            let ext = (old as NSString).pathExtension
            let length = ext.isEmpty ? old.utf16.count : old.utf16.count - ext.utf16.count - 1
            field.currentEditor()?.selectedRange = NSRange(location: 0, length: max(length, 0))
        }
    }

    /// Every delete asks first (the items can still be restored from the
    /// Trash or with ⌘Z, but nothing disappears by accident).
    func moveToTrash(_ paths: [String]) {
        guard let window = fm.window, !paths.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = paths.count == 1
            ? "Move “\((paths[0] as NSString).lastPathComponent)” to the Trash?"
            : "Move \(paths.count.formatted()) items to the Trash?"
        alert.informativeText = "You can put them back from the Trash, or undo with ⌘Z."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.performMoveToTrash(paths)
        }
    }

    private func performMoveToTrash(_ paths: [String]) {
        run("Moving to Trash", total: paths.count) { progress in
            var trashed: [(String, String)] = []
            var errors: [String] = []
            for (i, p) in paths.enumerated() {
                progress(i)
                do {
                    var out: NSURL?
                    try FileManager.default.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: &out)
                    trashed.append((p, out?.path ?? ""))
                    TrashBook.record(trashed: out?.path ?? "", original: p)
                } catch {
                    errors.append("\((p as NSString).lastPathComponent): \(error.localizedDescription)")
                }
            }
            return Outcome(undo: trashed.isEmpty ? nil : ("Move to Trash", .trashed(trashed)), select: [], errors: errors,
                           summary: "Moved \(count(trashed.count)) to the Trash")
        }
    }

    func deletePermanently(_ paths: [String]) {
        guard let window = fm.window, !paths.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = paths.count == 1
            ? "Delete “\((paths[0] as NSString).lastPathComponent)” permanently?"
            : "Delete \(paths.count) items permanently?"
        alert.informativeText = "This can’t be undone. The items won’t go to the Trash."
        alert.alertStyle = .critical
        let del = alert.addButton(withTitle: "Delete")
        del.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.run("Deleting", total: paths.count) { progress in
                var errors: [String] = []
                var done = 0
                for (i, p) in paths.enumerated() {
                    progress(i)
                    do { try Filofinder.deletePermanently(path: p); done += 1 } catch { errors.append("\(error)") }
                }
                return Outcome(undo: nil, select: [], errors: errors, summary: "Deleted \(count(done))")
            }
        }
    }

    /// Double-click on a .zip: extract next to it with Filofinder's engine.
    func extract(_ archive: String) {
        let dir = (archive as NSString).deletingLastPathComponent
        let name = (archive as NSString).lastPathComponent
        run("Extracting “\(name)”", total: 1) { _ in
            do {
                let r = try extractZip(archive: archive, destDir: dir)
                let out = (r.output as NSString).lastPathComponent
                var summary = "Extracted \(r.files.formatted()) files to “\(out)”"
                if r.skippedJunk > 0 { summary += " · \(r.skippedJunk) system files skipped" }
                var errors = r.failed
                if r.skippedUnsafe > 0 { errors.append("\(r.skippedUnsafe) unsafe entries were skipped (paths or links leaving the folder).") }
                return Outcome(undo: ("Extract", .created([r.output])), select: [out], errors: errors, summary: summary)
            } catch {
                return Outcome(undo: nil, select: [], errors: ["\(name): \(error)"], summary: nil)
            }
        }
    }

    // MARK: Trash

    /// Moves trashed items back to where Filofinder deleted them from.
    func putBack(_ paths: [String]) {
        run("Putting back", total: paths.count) { progress in
            var moved: [(String, String)] = []
            var errors: [String] = []
            for (i, p) in paths.enumerated() {
                progress(i)
                let name = (p as NSString).lastPathComponent
                guard let original = TrashBook.original(for: p) else {
                    errors.append("\(name): its original location is unknown (it wasn’t deleted with Filofinder). Use Finder’s Put Back.")
                    continue
                }
                let dir = (original as NSString).deletingLastPathComponent
                do {
                    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                    let to = try moveItem(src: p, destDir: dir, name: (original as NSString).lastPathComponent)
                    moved.append((p, to))
                    TrashBook.forget(p)
                } catch {
                    errors.append("\(name): \(error)")
                }
            }
            return Outcome(undo: moved.isEmpty ? nil : ("Put Back", .moved(moved)), select: [], errors: errors,
                           summary: "Put back \(count(moved.count))")
        }
    }

    /// Permanently erases everything in the Trash, after confirmation.
    func emptyTrash() {
        guard let window = fm.window else { return }
        let items = ((try? FileManager.default.contentsOfDirectory(atPath: Tab.trashPath)) ?? [])
            .filter { $0 != ".DS_Store" && $0 != ".localized" }
            .map { (Tab.trashPath as NSString).appendingPathComponent($0) }
        guard !items.isEmpty else { UI.hud("The Trash is empty", in: window); return }
        let alert = NSAlert()
        alert.messageText = "Permanently erase \(count(items.count)) in the Trash?"
        alert.informativeText = "You can’t undo this action."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Empty Trash").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.run("Emptying Trash", total: items.count) { progress in
                var errors: [String] = []
                for (i, p) in items.enumerated() {
                    progress(i)
                    do { try Filofinder.deletePermanently(path: p) } catch { errors.append("\(error)") }
                }
                TrashBook.forgetAll()
                return Outcome(undo: nil, select: [], errors: errors, summary: "Trash emptied")
            }
        }
    }

    // MARK: Undo

    func undo() {
        guard !busy, let last = undoStack.popLast() else { return }
        run("Undoing \(last.title)", total: 1) { _ in
            var errors: [String] = []
            func restore(_ current: String, to original: String) {
                do {
                    _ = try moveItem(src: current, destDir: (original as NSString).deletingLastPathComponent,
                                     name: (original as NSString).lastPathComponent)
                } catch { errors.append("\(error)") }
            }
            switch last.op {
            case .moved(let pairs):
                for (from, to) in pairs.reversed() { restore(to, to: from) }
            case .created(let paths):
                // Like Finder: undoing a copy moves the copy to the Trash.
                for p in paths {
                    do { try FileManager.default.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: nil) }
                    catch { errors.append("\((p as NSString).lastPathComponent): \(error.localizedDescription)") }
                }
            case .renamed(let from, let to):
                do { _ = try renameItem(path: to, newName: (from as NSString).lastPathComponent) } catch { errors.append("\(error)") }
            case .trashed(let pairs):
                for (original, trashed) in pairs where !trashed.isEmpty {
                    restore(trashed, to: original)
                    TrashBook.forget(trashed)
                }
            }
            return Outcome(undo: nil, select: [], errors: errors, summary: "Undid \(last.title)")
        }
    }

    // MARK: Job runner

    struct Outcome {
        var undo: (String, Undo)?
        var select: [String]
        var errors: [String]
        var summary: String?
        var renameAfter: String? = nil
    }

    private func run(_ verb: String, total: Int, work: @escaping (_ progress: @escaping (Int) -> Void) -> Outcome,
                     done: (() -> Void)? = nil) {
        busy = true
        fm.setActivity(total > 1 ? "\(verb) 0 of \(total)…" : "\(verb)…")
        queue.async { [weak self] in
            let outcome = work { i in
                guard total > 1 else { return }
                DispatchQueue.main.async { self?.fm.setActivity("\(verb) \(i + 1) of \(total)…") }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                if let u = outcome.undo { self.undoStack.append((u.0, u.1)) }
                done?()
                self.fm.setActivity(nil)
                self.fm.operationFinished(select: outcome.select)
                if let s = outcome.summary, outcome.errors.isEmpty { UI.hud(s, in: self.fm.window) }
                if !outcome.errors.isEmpty { self.showErrors(outcome.errors) }
                if let r = outcome.renameAfter { self.rename(r) }
            }
        }
    }

    private func showErrors(_ errors: [String]) {
        guard let window = fm.window else { return }
        let alert = NSAlert()
        alert.messageText = errors.count == 1 ? "The operation couldn’t be completed." : "\(errors.count) items couldn’t be completed."
        alert.informativeText = errors.prefix(8).joined(separator: "\n") + (errors.count > 8 ? "\n…and \(errors.count - 8) more" : "")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window)
    }
}

private func count(_ n: Int) -> String {
    n == 1 ? "1 item" : "\(n.formatted()) items"
}
