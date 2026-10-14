import AppKit

/// ⌃⌥V anywhere pastes the last dictation again — for the one that went to the wrong place, or was cleared with the
/// message it was in. A global listener (Accessibility is already needed for dictation); it never consumes the key, so
/// an app that uses the same chord still gets it. Switch: Settings ▸ Dictation ▸ Learning, `pasteLastShortcut`.
final class PasteLastShortcut {
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: "pasteLastShortcut") as? Bool ?? true }

    private var monitor: Any?
    var onTrigger: () -> Void = {}

    /// The V key.
    private static let keyCode: UInt16 = 9

    /// Whether `flags` are exactly Control and Option — not ⌘, ⇧ or Fn alongside, which are other shortcuts.
    static func matches(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        let held = flags.intersection([.control, .option, .command, .shift, .function])
        return keyCode == Self.keyCode && held == [.control, .option]
    }

    func start() {
        stop()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard Self.isEnabled, !event.isARepeat, Self.matches(keyCode: event.keyCode, flags: event.modifierFlags)
            else { return }
            self?.onTrigger()
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    static func runSelfTest() -> Bool {
        var passed = true
        func check(_ ok: Bool, _ label: String) {
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): paste last: \(label)")
        }
        check(matches(keyCode: 9, flags: [.control, .option]), "⌃⌥V is the shortcut")
        check(!matches(keyCode: 9, flags: [.control, .option, .command]) && !matches(keyCode: 9, flags: [.option])
              && !matches(keyCode: 9, flags: [.control, .option, .shift]) && !matches(keyCode: 8, flags: [.control, .option]),
              "⌘, ⇧ or another key alongside is something else")
        return passed
    }
}
