import CoreFoundation
import Foundation

/// Whether the main thread has been running smoothly, so features that depend on it answering quickly can choose a
/// safer path when it hasn't.
///
/// Watches the main run loop: an iteration that takes longer than `slowThreshold` marks the thread busy for
/// `window`. The cost is two tiny callbacks per run-loop iteration.
///
/// The reason it exists: a clipboard PROMISE (see `TextInserter`) is answered by the main thread, so if Murmur's
/// main thread is stalled at the instant another app pastes, that app's paste stalls with it — measured at exactly
/// the length of the stall. When the thread has been janky, paste the traditional way instead.
enum MainThreadHealth {
    /// A run-loop iteration longer than this counts as a stall.
    static var slowThreshold: CFTimeInterval = 0.025
    /// How long a stall keeps the thread marked busy.
    static var window: CFTimeInterval = 2

    // Main thread only.
    private static var iterationStart: CFAbsoluteTime = 0
    private static var lastStallEnd: CFAbsoluteTime = 0
    private static var observer: CFRunLoopObserver?

    /// Installs the observer once. Call from the main thread.
    static func start() {
        guard observer == nil else { return }
        let activities: CFRunLoopActivity = [.afterWaiting, .beforeWaiting]
        let created = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, activities.rawValue, true, 0) { _, activity in
            let now = CFAbsoluteTimeGetCurrent()
            if activity.contains(.afterWaiting) {
                iterationStart = now
            } else if iterationStart > 0, now - iterationStart > slowThreshold {
                lastStallEnd = now
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), created, .commonModes)
        observer = created
    }

    /// True when the main thread stalled within `window`, or is in the middle of a long iteration right now.
    static var isBusy: Bool {
        guard observer != nil else { return false }
        let now = CFAbsoluteTimeGetCurrent()
        if iterationStart > 0, now - iterationStart > slowThreshold { return true }
        return now - lastStallEnd < window
    }

    // MARK: - Self test

    @MainActor
    static func runSelfTest() -> Bool {
        var passed = true
        func check(_ ok: Bool, _ label: String) {
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): main-thread health: \(label)")
        }
        func pump(_ seconds: TimeInterval) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
        }
        let savedWindow = window
        window = 0.4
        defer { window = savedWindow }
        start()
        pump(0.6)
        check(!isBusy, "a quiet main thread is not busy")
        DispatchQueue.main.async { Thread.sleep(forTimeInterval: 0.08) }
        pump(0.15)
        check(isBusy, "an 80 ms stall marks the thread busy")
        pump(0.6)
        check(!isBusy, "…and it clears once the window has passed")
        return passed
    }
}
