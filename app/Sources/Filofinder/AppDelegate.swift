import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windows: [FileManagerWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        // A folder passed on the command line opens in the first tab;
        // otherwise start at the empty state, like captools.
        let start = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("-") }
        openWindow(path: start)
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        askForDiskAccessIfNeeded()
    }

    private var accessSheet: DiskAccessSheet?

    /// Filofinder browses the whole disk, so ask for Full Disk Access up front.
    private func askForDiskAccessIfNeeded() {
        let env = ProcessInfo.processInfo.environment
        guard !DiskAccess.isGranted, !DiskAccess.dontAskAgain, env["FILOFINDER_SNAPSHOT"] == nil,
              let main = windows.first, let window = main.window else { return }
        let sheet = DiskAccessSheet()
        sheet.onGranted = { [weak main] in
            UI.hud("Full Disk Access is on — every folder is available", in: main?.window)
            main?.refresh(nil)
        }
        accessSheet = sheet
        DispatchQueue.main.async { sheet.present(on: window) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Clicking the Dock icon with no visible window opens one (Finder behaviour).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openWindow(path: nil) }
        return true
    }

    @objc func newWindow(_ sender: Any?) {
        openWindow(path: nil)
    }

    private func openWindow(path: String?) {
        let controller = FileManagerWindowController(path: path)
        windows.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        #if DEBUG
        installTestHooks(controller)
        #endif
    }

    #if DEBUG
    /// Development-only hooks used for automated checks (not in release builds).
    private func installTestHooks(_ controller: FileManagerWindowController) {
        // FILOFINDER_SPLIT=1 opens straight into split view.
        let env = ProcessInfo.processInfo.environment
        if env["FILOFINDER_SPLIT"] == "1" { controller.toggleSplit(nil) }
        if env["FILOFINDER_FOCUS"] == "right" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { controller.focus(.right) }
        }
        // Test hook: FILOFINDER_TREE_CLICK=<row> clicks a sidebar row.
        if let row = env["FILOFINDER_TREE_CLICK"].flatMap(Int.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { controller.debugTreeClick(row: row) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                FileHandle.standardError.write(Data("[tree] now showing \(controller.activeTab.path)\n".utf8))
            }
        }
        // FILOFINDER_TOGGLE_TREE=N toggles the folder tree N times.
        if let n = env["FILOFINDER_TOGGLE_TREE"].flatMap(Int.init) {
            for i in 0..<n {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 + Double(i) * 0.4) { controller.toggleTree(nil) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                FileHandle.standardError.write(Data(controller.debugDumpLayout().utf8))
            }
        }
        // FILOFINDER_FLIP_APPEARANCE=dark|light switches appearance while running.
        if let mode = env["FILOFINDER_FLIP_APPEARANCE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                NSApp.appearance = NSAppearance(named: mode == "dark" ? .darkAqua : .aqua)
            }
        }
        if env["FILOFINDER_SELECT_ALL"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { controller.selectAllItems(nil) }
        }
        // Test hook: FILOFINDER_SNAPSHOT=/path.png renders this window to a
        // PNG (no screen-recording permission needed), then quits.
        if let out = env["FILOFINDER_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                if let view = controller.window?.contentView?.superview ?? controller.window?.contentView,
                   let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                }
                NSApp.terminate(nil)
            }
        }
    }
    #endif
}
