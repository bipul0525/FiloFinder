import AppKit
import ImageIO
import QuickLookThumbnailing

/// Image thumbnails via ImageIO: uses the embedded EXIF thumbnail when one
/// exists, else a subsampled decode (PLAN §4 thumbs; moves into the Rust
/// core with a disk cache later). Never reads iCloud placeholders.
final class ThumbnailLoader {
    static let shared = ThumbnailLoader()

    private let cache = NSCache<NSString, NSImage>()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 6
        q.qualityOfService = .userInitiated
        return q
    }()

    init() {
        cache.countLimit = 3000
    }

    func cached(_ path: String, pixels: Int) -> NSImage? {
        cache.object(forKey: key(path, pixels))
    }

    /// Loads off the main thread; `done` runs on the main thread.
    /// Cancel the returned operation when the cell is reused.
    @discardableResult
    func load(_ path: String, pixels: Int, done: @escaping (NSImage?) -> Void) -> Operation? {
        let k = key(path, pixels)
        if let hit = cache.object(forKey: k) {
            done(hit)
            return nil
        }
        let op = BlockOperation()
        op.addExecutionBlock { [weak op, cache] in
            guard let op, !op.isCancelled else { return }
            let image = Self.makeThumbnail(path, pixels: pixels)
            if let image { cache.setObject(image, forKey: k) }
            OperationQueue.main.addOperation {
                if !op.isCancelled { done(image) }
            }
        }
        queue.addOperation(op)
        return op
    }

    /// Thumbnails for everything that isn't a plain image (PDF, video,
    /// documents, apps…) from the system Quick Look generator — the same
    /// previews Finder shows. Returns the request so it can be cancelled.
    @discardableResult
    func loadQuickLook(_ path: String, side: CGFloat, scale: CGFloat,
                       done: @escaping (NSImage?) -> Void) -> QLThumbnailGenerator.Request? {
        let k = "ql|\(Int(side * scale))|\(path)" as NSString
        if let hit = cache.object(forKey: k) {
            done(hit)
            return nil
        }
        let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: CGSize(width: side, height: side),
                                                   scale: scale, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [cache] rep, _ in
            let image = rep?.nsImage
            if let image { cache.setObject(image, forKey: k) }
            DispatchQueue.main.async { done(image) }
        }
        return request
    }

    func cancel(_ request: QLThumbnailGenerator.Request?) {
        if let request { QLThumbnailGenerator.shared.cancel(request) }
    }

    func image(_ path: String, maxPixels: Int, done: @escaping (NSImage?) -> Void) {
        queue.addOperation {
            let image = Self.makeThumbnail(path, pixels: maxPixels)
            OperationQueue.main.addOperation { done(image) }
        }
    }

    private func key(_ path: String, _ pixels: Int) -> NSString {
        "\(pixels)|\(path)" as NSString
    }

    private static func makeThumbnail(_ path: String, pixels: Int) -> NSImage? {
        let url = URL(fileURLWithPath: path)
        // Reading a cloud placeholder would download the whole file.
        if let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus,
           status != .current {
            return nil
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

/// Icons as Finder shows them.
enum Icons {
    private static var byType: [String: NSImage] = [:]
    private static let byPath: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 4000
        return c
    }()

    /// Folders and packages (apps, bundles) get their *own* icon — app logos,
    /// Desktop/Documents/Downloads symbols, custom folder icons. Plain files
    /// share one icon per type, which is far cheaper.
    static func icon(for entry: EntryRow, path: String) -> NSImage {
        switch entry.kind {
        case .folder, .package, .symlink:
            if let hit = byPath.object(forKey: path as NSString) { return hit }
            let image = NSWorkspace.shared.icon(forFile: path)
            byPath.setObject(image, forKey: path as NSString)
            return image
        default:
            return icon(for: entry)
        }
    }

    static func icon(for entry: EntryRow) -> NSImage {
        let ext = (entry.name as NSString).pathExtension.lowercased()
        let key = (entry.kind == .package ? "pkg." : "") + ext
        if entry.kind == .folder { return NSWorkspace.shared.icon(for: .folder) }
        if let hit = byType[key] { return hit }
        let image = NSWorkspace.shared.icon(for: .init(filenameExtension: ext) ?? .data)
        byType[key] = image
        return image
    }
}
