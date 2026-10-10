import AppKit
import Foundation

/// Watches the chosen modifier key globally.
/// - Hold = push-to-talk (release stops).
/// - Double-tap = hands-free toggle (tap again to stop).
/// Requires Accessibility permission for global key monitoring.
final class HotkeyMonitor {

    enum Hotkey: String, CaseIterable {
        case fn
        case rightOption
        case rightCommand
        case rightControl
        case rightShift

        // Right-side modifiers only, alongside fn — matching the reasoning
        // already established by shipping Right Option instead of Left:
        // left-side modifiers collide far more often with in-flight system
        // and app shortcuts (⌘-anything, ⌥-anything) than their right-side
        // twins do. Caps Lock is deliberately not offered here — it's a
        // stateful toggle with its own OS-level debounce, not a clean
        // press/release pair like every other case below.
        var displayName: String {
            switch self {
            case .fn: return "fn (Globe)"
            case .rightOption: return "Right Option (⌥)"
            case .rightCommand: return "Right Command (⌘)"
            case .rightControl: return "Right Control (⌃)"
            case .rightShift: return "Right Shift (⇧)"
            }
        }

        /// Short glyph for a keycap-sized chip — `displayName` is too long
        /// once its parenthesized symbol has to stand alone at cap size.
        var shortSymbol: String {
            switch self {
            case .fn: return "fn"
            case .rightOption: return "⌥"
            case .rightCommand: return "⌘"
            case .rightControl: return "⌃"
            case .rightShift: return "⇧"
            }
        }

        var keyCode: UInt16 {
            switch self {
            case .fn: return 63
            case .rightOption: return 61
            case .rightCommand: return 54
            case .rightControl: return 62
            case .rightShift: return 60
            }
        }

        var flag: NSEvent.ModifierFlags {
            switch self {
            case .fn: return .function
            case .rightOption: return .option
            case .rightCommand: return .command
            case .rightControl: return .control
            case .rightShift: return .shift
            }
        }
    }

    var hotkey: Hotkey
    var onStart: (() -> Void)?
    /// Called when dictation should stop and be transcribed.
    var onStop: (() -> Void)?
    /// Called when a too-short press should be discarded.
    var onCancel: (() -> Void)?
    var onHandsFreeChange: ((Bool) -> Void)?

    private(set) var isHandsFree = false
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var keyIsDown = false
    private var pressStartedAt: Date?
    private var lastTapEndedAt: Date?

    /// Presses shorter than this count as taps, not push-to-talk.
    private let tapThreshold: TimeInterval = 0.35
    private let doubleTapWindow: TimeInterval = 0.5

    init(hotkey: Hotkey = .fn) {
        self.hotkey = hotkey
    }

    func startMonitoring() {
        stopMonitoring()
        // A global monitor only receives events posted to *other*
        // applications — it stays silent for the hotkey when Murmur's own
        // window (e.g. Scratchpad, Transforms' try-it box) is what has
        // focus. A local monitor covers exactly that gap; both are needed
        // to catch the key regardless of which app is frontmost.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in
            self?.handle(event)
            return event
        }
    }

    func stopMonitoring() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        globalMonitor = nil
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        localMonitor = nil
    }

    private func handle(_ event: NSEvent) {
        guard event.keyCode == hotkey.keyCode else { return }
        let pressed = event.modifierFlags.contains(hotkey.flag)
        if pressed, !keyIsDown {
            keyIsDown = true
            keyDown()
        } else if !pressed, keyIsDown {
            keyIsDown = false
            keyUp()
        }
    }

    /// For a hands-free session ended by something other than a key press
    /// (auto-stop on a detected pause) — resets the same state `keyDown()`'s
    /// hands-free-stop branch does, minus `onStop?()` itself, which the
    /// caller has already triggered directly. Without this, this monitor's
    /// own `isHandsFree` would stay stuck true, and the next press would be
    /// swallowed as "stop the (already-stopped) session" instead of
    /// starting a new one.
    func resetHandsFree() {
        isHandsFree = false
        pressStartedAt = nil
        lastTapEndedAt = nil
    }

    /// A hands-free session started some other way — the nav bar's microphone — so the next press of the key stops it,
    /// exactly as if it had been double-tapped into.
    func enterHandsFree() {
        isHandsFree = true
        pressStartedAt = nil
        lastTapEndedAt = nil
    }

    private func keyDown() {
        if isHandsFree {
            // Any press while hands-free stops the session.
            isHandsFree = false
            onHandsFreeChange?(false)
            onStop?()
            pressStartedAt = nil
            lastTapEndedAt = nil
            return
        }
        pressStartedAt = Date()
        onStart?()
    }

    private func keyUp() {
        guard let startedAt = pressStartedAt else { return }
        pressStartedAt = nil
        let holdDuration = Date().timeIntervalSince(startedAt)

        if holdDuration >= tapThreshold {
            // Push-to-talk: release ends dictation.
            lastTapEndedAt = nil
            onStop?()
            return
        }

        // Short press: tap. Two taps in quick succession → hands-free.
        if let lastTap = lastTapEndedAt,
           Date().timeIntervalSince(lastTap) <= doubleTapWindow {
            lastTapEndedAt = nil
            isHandsFree = true
            onHandsFreeChange?(true)
            // Keep recording; it started on this key-down.
        } else {
            lastTapEndedAt = Date()
            onCancel?()
        }
    }
}
