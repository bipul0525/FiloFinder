import AppKit

/// "Make Filofinder the default file browser": macOS sends "Show in Finder"
/// requests from other apps (Safari/Chrome downloads, Xcode, …) to the app named
/// in the global `NSFileViewer` preference. Finder itself, the Desktop and
/// system Open/Save windows are unaffected.
enum DefaultBrowser {
    private static let key = "NSFileViewer" as CFString

    static var isDefault: Bool {
        (CFPreferencesCopyValue(key, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            as? String) == Bundle.main.bundleIdentifier
    }

    static func set(_ on: Bool) {
        let value = on ? Bundle.main.bundleIdentifier as CFString? : nil
        CFPreferencesSetValue(key, value, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    /// Handle the "reveal" Apple Event ('misc'/'mvis') that NSWorkspace sends
    /// to the file viewer; its direct object is a list of files.
    static func installRevealHandler(_ handler: @escaping ([String]) -> Void) {
        RevealReceiver.shared.handler = handler
        NSAppleEventManager.shared().setEventHandler(RevealReceiver.shared,
                                                     andSelector: #selector(RevealReceiver.handle(_:reply:)),
                                                     forEventClass: AEEventClass(kAEMiscStandards),
                                                     andEventID: AEEventID(kAEMakeObjectsVisible))
    }
}

private final class RevealReceiver: NSObject {
    static let shared = RevealReceiver()
    var handler: (([String]) -> Void)?

    @objc func handle(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let list = event.paramDescriptor(forKeyword: keyDirectObject) else { return }
        var paths: [String] = []
        let items = list.numberOfItems > 0 ? (1...list.numberOfItems).compactMap { list.atIndex($0) } : [list]
        for item in items {
            if let url = item.coerce(toDescriptorType: typeFileURL)?.fileURLValue { paths.append(url.path) }
        }
        if !paths.isEmpty { handler?(paths) }
    }
}
