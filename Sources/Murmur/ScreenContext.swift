import ApplicationServices
import AppKit

/// The names on screen while the user dictates. Wispr Flow and VoiceInk read the app being dictated into so that a name
/// the user can see comes out spelled right; Murmur does the same through Accessibility — the permission it already has
/// for pasting (VoiceInk takes a screenshot, which needs Screen Recording) — from the focused window only, at key-down,
/// in the background while the user talks, within half a second. Only name-like words are kept ("Supabase",
/// "RevenueCat", "whisper.cpp", "Wispr Flow"), never everyday words, and only for this one dictation, by the name fix
/// alone (`UnsureWordFix`): a word the recognizer was unsure of that is clearly one of them is written that way, and a
/// name from the user's own vocabulary always comes first. Nothing is stored or sent anywhere. Not given to the clean-up
/// model (handed a list of names, it swaps correct words for them — measured 2026-09-28) nor to whisper.cpp's prompt
/// (long word lists there hurt). `defaults write local.murmur screenNames -bool false` turns it off.
enum ScreenContext {
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: "screenNames") as? Bool ?? true }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var names: [String] = []
    nonisolated(unsafe) private static var generation = 0

    /// The names read for the dictation in progress.
    static var current: [String] {
        lock.lock()
        defer { lock.unlock() }
        return names
    }

    /// Key-down: forget the last dictation's names and read the ones on screen now, in the background.
    static func refresh(pid: pid_t?) {
        lock.lock()
        names = []
        generation += 1
        let mine = generation
        lock.unlock()
        guard isEnabled, let pid, pid != ProcessInfo.processInfo.processIdentifier else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let learned = LearnedStore.load()
            let own = Set((learned.terms + learned.corrections.map(\.intended)).map(UnsureWordFix.letters))
            let found = ScreenContext.names(in: visibleTexts(pid: pid).texts).filter { !own.contains(UnsureWordFix.letters($0)) }
            lock.lock()
            if mine == generation { names = found }
            lock.unlock()
        }
    }

    /// Command line only: names given directly, as if they'd been on screen.
    static func set(_ list: [String]) {
        lock.lock()
        names = list
        lock.unlock()
    }

    // MARK: - Reading the window

    /// The texts of the focused window of `pid`, walked in reading order until the time or element budget runs out.
    static func visibleTexts(pid: pid_t, budget: TimeInterval = 0.5, maxElements: Int = 5_000)
        -> (texts: [String], elements: Int, finished: Bool) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        // Electron apps (Claude, ChatGPT, Slack, VS Code…) keep their Accessibility tree switched off until asked.
        if let url = NSRunningApplication(processIdentifier: pid)?.bundleURL, FileManager.default.fileExists(
            atPath: url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path) {
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return ([], 0, true) }
        let attributes = [kAXRoleAttribute, kAXSubroleAttribute, kAXValueAttribute, kAXTitleAttribute,
                          kAXDescriptionAttribute, kAXChildrenAttribute, "AXChildrenInNavigationOrder"] as CFArray
        let deadline = Date().addingTimeInterval(budget)
        var texts: [String] = []
        var visited = 0
        var stack: [(element: AXUIElement, depth: Int)] = [(window as! AXUIElement, 0)]
        while let (element, depth) = stack.popLast() {
            guard visited < maxElements, Date() < deadline else { return (texts, visited, false) }
            visited += 1
            AXUIElementSetMessagingTimeout(element, 0.1)
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element, attributes, [], &values) == .success,
                  let list = values as? [AnyObject], list.count == 7 else { continue }
            let role = list[0] as? String ?? ""
            if role == kAXMenuBarRole as String { continue }
            if (list[1] as? String) != (kAXSecureTextFieldSubrole as String) {
                for index in 2...4 {
                    if let text = list[index] as? String, !text.isEmpty { texts.append(String(text.prefix(20_000))) }
                }
            }
            var children = list[5] as? [AXUIElement] ?? []
            if children.isEmpty { children = list[6] as? [AXUIElement] ?? [] }
            if depth < 80 { stack.append(contentsOf: children.reversed().map { ($0, depth + 1) }) }
        }
        return (texts, visited, true)
    }

    // MARK: - Picking the names (pure, self-tested)

    /// The name-like words and two-word names in `texts`, most frequent first: a capital letter inside or at the start,
    /// a digit, or a dot inside ("whisper.cpp") — and not an ordinary English word. Two neighbouring capitalised words
    /// are also kept together when one of them is a name ("Wispr Flow").
    static func names(in texts: [String], isKnownWord: (String) -> Bool = HarperChecker.isKnownEnglishWord,
                      limit: Int = 300) -> [String] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        func note(_ name: String) {
            if counts[name] == nil { order.append(name) }
            counts[name, default: 0] += 1
        }
        let separators = CharacterSet(charactersIn: ",;:!?()[]{}\"“”‘’<>|*`#=+…•·—–\n\t")
        for text in texts {
            for stretch in text.components(separatedBy: separators) {
                let tokens = stretch.split(separator: " ").map { raw -> String in
                    var token = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: ".-'/~"))
                    for possessive in ["'s", "’s"] where token.hasSuffix(possessive) { token.removeLast(2) }
                    return token
                }
                var previous: (token: String, isName: Bool)?
                for token in tokens {
                    let isName = looksLikeName(token, isKnownWord: isKnownWord)
                    if isName { note(token) }
                    // A name and the capitalised word after it ("Wispr Flow") — not a label before a name ("Idle
                    // Planra", "Behind Wispr").
                    if let previous, previous.isName, token.first?.isUppercase == true, token.count >= 2 {
                        note(previous.token + " " + token)
                    }
                    previous = token.isEmpty ? nil : (token, isName)
                }
            }
        }
        return order.enumerated()
            .sorted { (counts[$0.element]!, -$0.offset) > (counts[$1.element]!, -$1.offset) }
            .prefix(limit).map(\.element)
    }

    static func looksLikeName(_ token: String, isKnownWord: (String) -> Bool) -> Bool {
        let letters = token.filter(\.isLetter)
        guard letters.count >= 3, token.count <= 24, token.first?.isLetter == true,
              !token.contains("@"), !token.contains("_"), !token.contains("/"),
              !token.contains("'"), !token.contains("’"),
              token.range(of: "\\.(" + ProtectedSpans.topLevelDomains + ")$",
                          options: [.regularExpression, .caseInsensitive]) == nil
        else { return false }
        let hasCapital = token.contains(where: \.isUppercase)
        let hasDigit = token.contains(where: \.isNumber)
        let innerDot = token.dropLast().contains(".")
        guard hasCapital || hasDigit || innerDot else { return false }
        // A long all-capitals word is a heading or a label ("WARNING", "CHANGELOG"), not a name.
        if !token.contains(where: \.isLowercase), letters.count > 5 { return false }
        // Everyday words joined by hyphens ("Speech-to-text", "Open-source") aren't a name either.
        let parts = token.split(separator: "-")
        if parts.count > 1, parts.allSatisfy({ isKnownWord($0.lowercased().filter(\.isLetter)) }) { return false }
        return !isKnownWord(token.lowercased().filter(\.isLetter))
    }

    static func runSelfTest() -> Bool {
        var passed = true
        func check(_ ok: Bool, _ label: String) {
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): names on screen: \(label)")
        }
        let known: Set<String> = ["we", "moved", "the", "database", "to", "and", "shipped", "it", "with", "flow", "today",
                                  "send", "a", "note", "about", "warning", "hello", "team", "i", "use", "claude",
                                  "code", "for", "this", "on"]
        let isKnown: (String) -> Bool = { known.contains($0) }
        let found = names(in: ["We moved the database to Supabase and shipped it with Wispr Flow today.",
                               "Send a note to jane@example.com about RevenueCat's team, see murmurmac.com.",
                               "WARNING: whisper.cpp on iOS 27", "Hello team, I use Claude Code for this",
                               "Idle Supabase", "Speech-to-text", "I've seen it"],
                          isKnownWord: { known.union(["idle", "speech", "text"]).contains($0) })
        check(found.contains("Supabase") && found.contains("RevenueCat") && found.contains("whisper.cpp")
              && found.contains("iOS") && found.contains("Wispr"), "names are picked up: \(found)")
        check(found.contains("Wispr Flow"), "…and a two-word name when one word of it is a name")
        check(!found.contains("Claude Code") && !found.contains("Hello") && !found.contains("WARNING")
              && !found.contains("Send") && !found.contains("Idle Supabase") && !found.contains("Speech-to-text")
              && !found.contains("RevenueCat's") && !found.contains("I've"),
              "ordinary words, headings, labels, hyphenated everyday words and names that are everyday words are not")
        check(!found.contains(where: { $0.contains("@") || $0.contains("murmurmac") }), "…nor emails and web addresses")
        check(names(in: ["Supabase Supabase RevenueCat"], isKnownWord: isKnown).first == "Supabase",
              "the most frequent name comes first")
        return passed
    }
}
