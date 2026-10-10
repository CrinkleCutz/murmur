import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Which physical key types a shortcut letter in the keyboard layout the user has right now.
///
/// Murmur presses ⌘V (paste), ⌘C (copy the selection) and ⌘Z (undo a Transform) on the user's behalf. Those were
/// hard-coded to the key positions of a US keyboard (V = 9, C = 8, Z = 6), which is only right on layouts that keep
/// the letters where QWERTY has them. On Dvorak, key 9 types "K": the "paste" became ⌘K — a chat app's quick
/// switcher, a browser's "insert link" — instead of pasting. macOS decides what a ⌘-shortcut means from the
/// character a key produces under the current layout (or under the ASCII-capable layout, when the current one can't
/// type Latin letters — Russian, Greek, Arabic), so this asks the same layouts, in the same order.
enum ShortcutKeys {
    static var paste: Int { keyCode(for: "v", ansiFallback: kVK_ANSI_V) }
    static var copy: Int { keyCode(for: "c", ansiFallback: kVK_ANSI_C) }
    static var undo: Int { keyCode(for: "z", ansiFallback: kVK_ANSI_Z) }

    /// The key code that types `letter` with ⌘ held, or `ansiFallback` (the US position) when no layout can say.
    static func keyCode(for letter: Character, ansiFallback: Int) -> Int {
        let target = String(letter).lowercased()
        let found: Int? = onMainThread {
            for source in candidateLayouts() {
                if let code = keyCode(for: target, in: source) { return code }
            }
            return nil
        }
        return found ?? ansiFallback
    }

    /// The text-input APIs are main-thread only; everything that posts a shortcut already runs there.
    private static func onMainThread<T>(_ work: () -> T) -> T {
        Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work)
    }

    /// The current layout first, then the ASCII-capable one macOS falls back to for ⌘-shortcuts.
    private static func candidateLayouts() -> [TISInputSource] {
        var sources: [TISInputSource] = []
        if let current = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() { sources.append(current) }
        if let ascii = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() { sources.append(ascii) }
        return sources
    }

    /// The key that types `target` (lowercase) with ⌘ held under `source`. Translating with the Command modifier
    /// matters: "Dvorak – QWERTY ⌘" types Dvorak letters normally but keeps ⌘-shortcuts at the QWERTY positions, and
    /// the layout's own ⌘ table is what says so.
    static func keyCode(for target: String, in source: TISInputSource) -> Int? {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        let keyboardType = UInt32(LMGetKbdType())
        let commandState = UInt32(cmdKey >> 8) & 0xFF
        for code in 0..<128 {
            var deadKeys: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                layout, UInt16(code), UInt16(kUCKeyActionDown), commandState, keyboardType,
                OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeys, characters.count, &length, &characters)
            guard status == noErr, length == 1 else { continue }
            if String(utf16CodeUnits: characters, count: 1).lowercased() == target { return code }
        }
        return nil
    }

    /// An installed keyboard layout by its system ID ("com.apple.keylayout.Dvorak"), enabled or not.
    static func layout(withID id: String) -> TISInputSource? {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource] else { return nil }
        return list.first
    }

    // MARK: - Self test

    @MainActor
    static func runSelfTest() -> Bool {
        var passed = true
        func check(_ ok: Bool, _ label: String) {
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): shortcut keys: \(label)")
        }
        // The current layout always yields a real key code for the three shortcuts Murmur presses.
        for (name, code) in [("paste", paste), ("copy", copy), ("undo", undo)] {
            check((0..<128).contains(code), "\(name) resolves to a key code under the current layout (\(code))")
        }
        // Known layouts, when this Mac has them: the answer must match what the layout itself types.
        if let us = layout(withID: "com.apple.keylayout.US") {
            check(keyCode(for: "v", in: us) == kVK_ANSI_V, "US: V is where QWERTY has it")
            check(keyCode(for: "c", in: us) == kVK_ANSI_C, "US: C is where QWERTY has it")
            check(keyCode(for: "z", in: us) == kVK_ANSI_Z, "US: Z is where QWERTY has it")
            // A character no key types has no answer, so callers fall back to the US position.
            check(keyCode(for: "\u{1F600}", in: us) == nil, "a character no key types has no code")
        }
        if let dvorak = layout(withID: "com.apple.keylayout.Dvorak") {
            let code = keyCode(for: "v", in: dvorak)
            check(code != nil && code != kVK_ANSI_V, "Dvorak: V has moved off the QWERTY position (\(code.map(String.init) ?? "nil"))")
        }
        if let qwertyCommand = layout(withID: "com.apple.keylayout.DVORAK-QWERTYCMD") {
            check(keyCode(for: "v", in: qwertyCommand) == kVK_ANSI_V, "Dvorak – QWERTY ⌘: ⌘V stays at the QWERTY position")
        }
        return passed
    }
}
