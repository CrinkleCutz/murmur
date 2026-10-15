import AppKit

/// Whether the user really typed in an app during a stretch of time — the evidence edit learning needs before it
/// treats a changed box as the user's correction. Two wrong lessons in two days had none: "valuate" was a box read
/// half-cleared as a message was sent (no keys pressed at all), and "Manrope" → "Mamloop" was another dictation app
/// pasting its own version (one ⌘V). Typing here means letters, digits, punctuation, Space, Delete or Forward Delete
/// pressed without ⌘ or ⌃ — not Return, Tab, Esc, arrows or shortcuts.
///
/// Only when and in which app (by process) each key went down is kept, for the last few minutes — never which key.
/// A global listener, as for ⌃⌥V; it never consumes a key.
enum TypingEvidence {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var presses: [(at: Date, pid: pid_t)] = []
    nonisolated(unsafe) private static var monitor: Any?

    static func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            guard counts(keyCode: event.keyCode, flags: event.modifierFlags, characters: event.characters),
                  let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
            lock.lock()
            presses.append((Date(), pid))
            let cutoff = Date().addingTimeInterval(-600)
            if presses.count > 2_000 || presses.first.map({ $0.at < cutoff }) == true {
                presses.removeAll { $0.at < cutoff }
            }
            lock.unlock()
        }
    }

    /// Keys pressed in the app with this process since `date` (and up to `until`).
    static func count(pid: pid_t, since date: Date, until end: Date = .distantFuture) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return presses.filter { $0.pid == pid && $0.at >= date && $0.at <= end }.count
    }

    /// A key that edits text, as opposed to sending, moving or a shortcut.
    static func counts(keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String?) -> Bool {
        if !flags.intersection([.command, .control]).isEmpty { return false }
        switch keyCode {
        case 51, 117: return true                      // Delete, Forward Delete
        case 36, 76, 48, 53, 123, 124, 125, 126: return false   // Return, Enter, Tab, Esc, arrows
        default: break
        }
        guard let characters, let scalar = characters.unicodeScalars.first else { return false }
        return !CharacterSet.controlCharacters.contains(scalar)
            && !(0xF700...0xF8FF).contains(scalar.value)   // function keys and the like
    }

    static func runSelfTest() -> Bool {
        var passed = true
        func check(_ ok: Bool, _ label: String) {
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): typing evidence: \(label)")
        }
        check(counts(keyCode: 0, flags: [], characters: "a") && counts(keyCode: 51, flags: [], characters: "\u{7F}")
              && counts(keyCode: 49, flags: [.shift], characters: " "), "letters, Delete and Space count")
        check(!counts(keyCode: 9, flags: [.command], characters: "v") && !counts(keyCode: 36, flags: [], characters: "\r")
              && !counts(keyCode: 123, flags: [], characters: "\u{F702}") && !counts(keyCode: 9, flags: [.control], characters: "v"),
              "a paste, Return, arrows and shortcuts don't")
        return passed
    }
}
