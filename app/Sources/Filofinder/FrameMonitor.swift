import AppKit
import QuartzCore

/// Measures real frame pacing without Instruments (PLAN §10, D13).
///
/// A display link fires once per screen refresh. If the main thread was busy,
/// callbacks arrive late; any gap longer than 1.5 refresh intervals counts
/// as a dropped frame. Reports once per second.
final class FrameMonitor {
    struct Report {
        let fps: Double
        let refreshHz: Double
        let dropped: Int
        let worstMs: Double
    }

    var onReport: ((Report) -> Void)?

    private var link: AnyObject?
    private var last: CFTimeInterval = 0
    private var windowStart: CFTimeInterval = 0
    private var frames = 0
    private var dropped = 0
    private var worst: CFTimeInterval = 0
    private var interval: CFTimeInterval = 1.0 / 60.0

    func start(on view: NSView) {
        stop()
        if #available(macOS 14.0, *) {
            let l = view.displayLink(target: self, selector: #selector(tick(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        }
    }

    func stop() {
        if #available(macOS 14.0, *) {
            (link as? CADisplayLink)?.invalidate()
        }
        link = nil
        last = 0
    }

    @available(macOS 14.0, *)
    @objc private func tick(_ l: CADisplayLink) {
        let now = l.timestamp
        let expected = l.targetTimestamp - l.timestamp
        if expected > 0 { interval = expected }
        if last > 0 {
            let gap = now - last
            frames += 1
            worst = max(worst, gap)
            if gap > interval * 1.5 { dropped += Int((gap / interval).rounded()) - 1 }
        } else {
            windowStart = now
        }
        last = now
        if now - windowStart >= 1.0 {
            onReport?(Report(fps: Double(frames) / (now - windowStart), refreshHz: 1.0 / interval,
                             dropped: dropped, worstMs: worst * 1000))
            windowStart = now
            frames = 0
            dropped = 0
            worst = 0
        }
    }
}
