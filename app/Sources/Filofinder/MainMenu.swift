import AppKit
import Sparkle

/// The menu bar, built in code. Items target the first responder, so the
/// key window's controller handles them. Shortcuts follow captools (UI-SPEC §14).
enum MainMenu {
    private typealias FM = FileManagerWindowController

    static func build() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Filofinder", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let updates = NSMenuItem(title: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                                 keyEquivalent: "")
        updates.target = Updater.controller
        appMenu.addItem(updates)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Default File Browser…", action: #selector(AppDelegate.toggleDefaultFileBrowser(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Filofinder", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Filofinder", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(appMenu, titled: "Filofinder", to: main)

        let file = NSMenu(title: "File")
        file.addItem(withTitle: "New Window", action: #selector(AppDelegate.newWindow(_:)), keyEquivalent: "n")
        file.addItem(withTitle: "New Tab", action: #selector(FM.newTab(_:)), keyEquivalent: "t")
        file.addItem(withTitle: "Open Directory…", action: #selector(FM.openDirectory(_:)), keyEquivalent: "o")
        file.addItem(.separator())
        file.addItem(withTitle: "New Folder", action: #selector(FM.newFolder(_:)), keyEquivalent: "")
        file.addItem(withTitle: "Duplicate", action: #selector(FM.duplicateItems(_:)), keyEquivalent: "d")
        file.addItem(.separator())
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        add(file, titled: "File", to: main)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: #selector(FM.undoAction(_:)), keyEquivalent: "z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(FM.cutItems(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(FM.copyItems(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(FM.pasteItems(_:)), keyEquivalent: "v")
        let copyPath = NSMenuItem(title: "Copy Path", action: #selector(FM.copyPathAction(_:)), keyEquivalent: "c")
        copyPath.keyEquivalentModifierMask = [.command, .option]
        edit.addItem(copyPath)
        edit.addItem(withTitle: "Select All", action: #selector(FM.selectAllItems(_:)), keyEquivalent: "a")
        edit.addItem(withTitle: "Invert Selection", action: #selector(FM.invertSelection(_:)), keyEquivalent: "")
        add(edit, titled: "Edit", to: main)

        let view = NSMenu(title: "View")
        view.addItem(withTitle: "List View", action: #selector(FM.setListView(_:)), keyEquivalent: "1")
        view.addItem(withTitle: "Grid View", action: #selector(FM.setGridView(_:)), keyEquivalent: "2")
        view.addItem(.separator())
        view.addItem(withTitle: "Zoom In", action: #selector(FM.zoomIn(_:)), keyEquivalent: "+")
        view.addItem(withTitle: "Zoom Out", action: #selector(FM.zoomOut(_:)), keyEquivalent: "-")
        let bigger = NSMenuItem(title: "Bigger Name Text", action: #selector(FM.textLarger(_:)), keyEquivalent: "+")
        bigger.keyEquivalentModifierMask = [.command, .option]
        view.addItem(bigger)
        let smaller = NSMenuItem(title: "Smaller Name Text", action: #selector(FM.textSmaller(_:)), keyEquivalent: "-")
        smaller.keyEquivalentModifierMask = [.command, .option]
        view.addItem(smaller)
        view.addItem(.separator())
        let tree = NSMenuItem(title: "Folder Tree", action: #selector(FM.toggleTree(_:)), keyEquivalent: "s")
        tree.keyEquivalentModifierMask = [.command, .control]
        view.addItem(tree)
        let preview = NSMenuItem(title: "Preview Pane", action: #selector(FM.togglePreview(_:)), keyEquivalent: "p")
        preview.keyEquivalentModifierMask = [.command, .option]
        view.addItem(preview)
        let splitItem = NSMenuItem(title: "Split View", action: #selector(FM.toggleSplit(_:)), keyEquivalent: "m")
        view.addItem(splitItem)
        view.addItem(.separator())
        let hidden = NSMenuItem(title: "Show Hidden Files", action: #selector(FM.toggleHidden(_:)), keyEquivalent: ".")
        hidden.keyEquivalentModifierMask = [.command, .shift]
        view.addItem(hidden)
        view.addItem(withTitle: "Refresh", action: #selector(FM.refresh(_:)), keyEquivalent: "r")
        view.addItem(.separator())
        let fps = NSMenuItem(title: "Show Frame Monitor", action: #selector(FM.toggleFrameMonitor(_:)), keyEquivalent: "f")
        fps.keyEquivalentModifierMask = [.command, .option]
        view.addItem(fps)
        add(view, titled: "View", to: main)

        let go = NSMenu(title: "Go")
        go.addItem(withTitle: "Back", action: #selector(FM.goBack(_:)), keyEquivalent: "[")
        go.addItem(withTitle: "Forward", action: #selector(FM.goForward(_:)), keyEquivalent: "]")
        go.addItem(withTitle: "Enclosing Folder", action: #selector(FM.goUp(_:)), keyEquivalent: String(UnicodeScalar(NSUpArrowFunctionKey)!))
        let home = NSMenuItem(title: "Home", action: #selector(FM.goHome(_:)), keyEquivalent: "h")
        home.keyEquivalentModifierMask = [.command, .shift]
        go.addItem(home)
        let goto = NSMenuItem(title: "Go to Folder…", action: #selector(FM.focusPath(_:)), keyEquivalent: "g")
        goto.keyEquivalentModifierMask = [.command, .shift]
        go.addItem(goto)
        add(go, titled: "Go", to: main)

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.items.last?.keyEquivalentModifierMask = [.command, .control]
        add(window, titled: "Window", to: main)
        NSApp.windowsMenu = window

        return main
    }

    private static func add(_ submenu: NSMenu, titled title: String, to main: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        main.addItem(item)
    }
}
