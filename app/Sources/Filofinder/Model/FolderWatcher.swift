import Foundation

/// Live refresh: watches one folder for changes made by anything (another
/// app, Finder, a finishing download) and reports them, coalesced, so a
/// burst of changes (npm install, unzipping) causes a single refresh.
final class FolderWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private(set) var path: String?
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    deinit { stop() }

    /// Starts watching `path` (no-op if already watching it).
    func watch(_ path: String?) {
        guard path != self.path else { return }
        stop()
        guard let path, path.hasPrefix("/") else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        self.path = path
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .attrib],
                                                            queue: .main)
        src.setEventHandler { [weak self] in self?.schedule() }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    func stop() {
        pending?.cancel()
        pending = nil
        source?.cancel()
        source = nil
        path = nil
    }

    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}
