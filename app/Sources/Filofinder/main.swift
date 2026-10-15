import AppKit

// No storyboard or nib: the app is built entirely in code (no Xcode, PLAN D13).
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
