import AppKit
import Sparkle

/// Auto-updates via Sparkle: checks GitHub Releases (appcast.xml) every 6 h,
/// verifies each update's EdDSA signature, and installs on relaunch.
enum Updater {
    static let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
}
