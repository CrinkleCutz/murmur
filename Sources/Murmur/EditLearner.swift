import AppKit
import ApplicationServices

/// A correction Murmur just learned from an edit, with what is needed to take it back.
struct LearnedNotice {
    let heard: String
    let intended: String
    let receipt: LearnReceipt
}

/// Learns from the corrections the user makes right after a dictation lands — Wispr Flow's "Auto-add to Dictionary",
/// VoiceInk's "Auto Learn". Follows VoiceInk's open-source design: right after the paste, find the dictation in the
/// field and note the text on either side of it, so it can be found again however the field changes around it; stop
/// when the user moves on. One addition: most dictations go into chat boxes, where a fixed word is followed by Return
/// and the box empties, so the field is read every 0.2 s while it's watched and the last steady reading before it
/// emptied is what counts. A word the user changed into a name or an unusual word ("Manrog" → "Manrope") is learned
/// exactly like a History edit (`LearnedStore.extractCorrections`: spelled at least somewhat alike, up to four words);
/// rewording, added words and grammar are ignored, and nothing is kept but the learned pair. The watch ends when the
/// field loses focus, the dictation disappears from it (sent or deleted), the next dictation starts, or after a minute.
/// `defaults write local.murmur learnFromEdits -bool false` turns it off.
enum EditLearner {
    /// The field a dictation is about to be pasted into.
    struct Target {
        let element: AXUIElement
        let pid: pid_t
    }

    private struct Session {
        let element: AXUIElement
        /// The dictation as it landed in the field.
        let inserted: String
        /// Up to 16 characters on each side of it, to find it again after edits.
        let before: String
        let after: String
        let started: Date
        /// The newest reading, and the newest one that was the same two readings in a row.
        var latest: String
        var steady: String?
        /// Where this dictation came from, for `EditRecordStore`.
        var draft: EditRecordDraft?
        /// The app's process, for `TypingEvidence`.
        var pid: pid_t = 0
        /// Each steady reading and when it became steady — so readings from the moment the box was being emptied on
        /// send can be set aside (`settledBeforeSending`).
        var steadyHistory: [(at: Date, text: String)] = []
    }

    /// A box being emptied on send can be read half-cleared ("Evaluate…" read back as "valuate…", 2026-10-15) — and
    /// twice alike, so it looks steady. Readings from the last `sendSettle` seconds before the box emptied or the
    /// dictation left it are set aside: what counts is the last reading from before that, or none.
    static let sendSettle: TimeInterval = 0.6

    private static func settledBeforeSending(_ watched: inout Session) {
        let cutoff = Date().addingTimeInterval(-sendSettle)
        let earlier = watched.steadyHistory.last { $0.at <= cutoff }?.text
        watched.steady = earlier
        watched.latest = earlier ?? watched.inserted
    }

    static var isEnabled: Bool { UserDefaults.standard.object(forKey: "learnFromEdits") as? Bool ?? true }
    /// How long a field is watched at most.
    static let watchLimit: TimeInterval = 60
    /// Fields longer than this aren't watched (a whole document is read each time).
    static let maximumFieldLength = 100_000
    /// Called on the main queue with whatever was learned.
    nonisolated(unsafe) static var onLearned: (([LearnedNotice]) -> Void)?

    private static let queue = DispatchQueue(label: "local.murmur.edit-learner", qos: .utility)
    // Only touched on `queue`.
    nonisolated(unsafe) private static var session: Session?
    nonisolated(unsafe) private static var generation = 0

    /// The focused field right before a paste, whether or not learning is on — for checking the paste landed.
    static func focusedTarget() -> Target? {
        guard let element = focusedElement() else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return Target(element: element, pid: pid)
    }

    /// Whether `inserted` is now in that field: true or false when the field can be read, nil when it can't (Codex).
    static func landed(_ inserted: String, in target: Target) -> Bool? {
        AXUIElementSetMessagingTimeout(target.element, 0.2)
        guard let field = text(of: target.element) else { return nil }
        let wanted = inserted.trimmingCharacters(in: .whitespacesAndNewlines)
        return wanted.isEmpty || field.contains(wanted)
    }

    /// Right before a paste: the focused field, or nil when there's nothing to watch (a password field, no field).
    static func watchBeforePaste() -> Target? {
        guard isEnabled else { return nil }
        guard let element = focusedElement() else {
            dictationLog.notice("edit learning: the app in front has no field Murmur can read")
            return nil
        }
        // Murmur's own fields (Scratchpad) are edited in Murmur, where History already learns.
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid != ProcessInfo.processInfo.processIdentifier
        else { return nil }
        return Target(element: element, pid: pid)
    }

    /// The paste landed: whatever an earlier dictation's field shows now is final, and this one is watched.
    static func track(_ target: Target, inserted: String, draft: EditRecordDraft? = nil) {
        queue.async {
            finish(readAgain: true, reason: "next paste")
            generation += 1
            let current = generation
            // Once the app has had a moment to show the pasted text, and again a little later for a slow one.
            for delay in [0.15, 0.6] {
                queue.asyncAfter(deadline: .now() + delay) {
                    guard current == generation, session == nil else { return }
                    begin(target.element, pid: target.pid, inserted: inserted, draft: draft, generation: current,
                          lastTry: delay == 0.6)
                }
            }
        }
    }

    /// A new dictation is starting: what the last one's field shows now is final.
    static func dictationStarted() {
        queue.async { finish(readAgain: true, reason: "next dictation") }
    }

    // MARK: - Watching

    private static func begin(_ element: AXUIElement, pid: pid_t, inserted: String, draft: EditRecordDraft?,
                              generation current: Int, lastTry: Bool) {
        AXUIElementSetMessagingTimeout(element, 0.2)
        guard let field = text(of: element), let caret = caretEnd(of: element),
              let range = pastedRange(of: inserted, in: field, caret: caret) else {
            if lastTry { dictationLog.notice("edit learning: the dictation couldn't be found in the field") }
            return
        }
        let ns = field as NSString
        let beforeStart = max(0, range.location - 16)
        let before = ns.substring(with: ns.rangeOfComposedCharacterSequences(
            for: NSRange(location: beforeStart, length: range.location - beforeStart)))
        let afterStart = NSMaxRange(range)
        let after = ns.substring(with: ns.rangeOfComposedCharacterSequences(
            for: NSRange(location: afterStart, length: min(16, ns.length - afterStart))))
        let landed = ns.substring(with: range)
        session = Session(element: element, inserted: landed, before: before, after: after, started: Date(),
                          latest: landed, steady: landed, draft: draft, pid: pid, steadyHistory: [(Date(), landed)])
        dictationLog.notice("edit learning: watching the field")
        schedulePoll(generation: current, fieldLength: ns.length)
    }

    private static func schedulePoll(generation current: Int, fieldLength: Int) {
        // A long document is read less often.
        let interval = fieldLength > 5_000 ? 1.0 : 0.2
        queue.asyncAfter(deadline: .now() + interval) {
            guard current == generation, var watched = session else { return }
            guard Date().timeIntervalSince(watched.started) < watchLimit else {
                finish(readAgain: true, reason: "a minute passed")
                return
            }
            guard isFocused(watched.element) else {
                finish(readAgain: true, reason: "the field lost focus")
                return
            }
            // Sent, cleared, undone or rewritten: the readings so far are all there is. Which of them it was is logged,
            // so a day's log shows whether the watch ends because the message was sent or because it lost its place.
            guard let field = text(of: watched.element) else {
                finish(readAgain: false, reason: "the field could no longer be read")
                return
            }
            guard !field.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                settledBeforeSending(&watched)
                session = watched
                finish(readAgain: false, reason: "the field was emptied (sent or deleted)")
                return
            }
            guard let region = region(in: field, before: watched.before, after: watched.after) else {
                finish(readAgain: false, reason: stillHolds(watched.inserted, in: field)
                    ? "the text around the dictation changed, though the dictation is still there"
                    : "the dictation left the field (sent or deleted)")
                return
            }
            guard stillHolds(watched.inserted, in: region) else {
                settledBeforeSending(&watched)
                session = watched
                finish(readAgain: false, reason: "the dictation left the field (sent or deleted)")
                return
            }
            if region == watched.latest, watched.steady != region {
                watched.steady = region
                watched.steadyHistory.append((Date(), region))
            }
            watched.latest = region
            session = watched
            schedulePoll(generation: current, fieldLength: (field as NSString).length)
        }
    }

    /// Ends the watch and learns from it. `readAgain`: the user moved on while the text is still there (another
    /// dictation, another field, time's up), so one more reading is the settled version.
    private static func finish(readAgain: Bool, reason: String) {
        guard var watched = session else { return }
        session = nil
        generation += 1
        if readAgain, let field = text(of: watched.element),
           let region = region(in: field, before: watched.before, after: watched.after),
           stillHolds(watched.inserted, in: region) {
            watched.latest = region
            watched.steady = region
        }
        dictationLog.notice("edit learning: stopped watching — \(reason, privacy: .public)")
        guard let steady = watched.steady else { return }
        // No typing in that app since the paste: whatever changed in the box wasn't the user correcting it.
        let typed = TypingEvidence.count(pid: watched.pid, since: watched.started)
        if typed == 0, steady != watched.inserted {
            dictationLog.notice("edit learning: the box changed but nothing was typed — not learned")
            if let draft = watched.draft { EditRecordStore.complete(draft, final: steady, reason: reason + ", no typing", learned: 0) }
            return
        }
        // Only the corrections Murmur now makes by itself are announced (a heard everyday word only teaches the name).
        var learned: [LearnedNotice] = agreedPairs(original: watched.inserted, steady: steady, latest: watched.latest)
            .compactMap { pair in
                LearnedStore.addTracked(heard: pair.heard, intended: pair.intended)
                    .map { LearnedNotice(heard: pair.heard, intended: pair.intended, receipt: $0) }
            }
        // A new word typed in where the dictation had something unlike it — kept only when both readings have it, so a
        // half-typed word isn't learned, and only while most of the dictation is still there.
        if stillHolds(watched.inserted, in: steady), !grewTooMuch(watched.inserted, steady) {
            let fresh = LearnedStore.addNewWordsTracked(original: watched.inserted, corrected: steady, alsoIn: watched.latest)
            learned += fresh.filter { new in !learned.contains { $0.intended.lowercased() == new.intended.lowercased() } }
        }
        if let draft = watched.draft {
            // The words the field held at the end — the same region the corrections were read from.
            EditRecordStore.complete(draft, final: steady, reason: reason, learned: learned.count)
        }
        guard !learned.isEmpty else { return }
        dictationLog.notice("edit learning: learned \(learned.count) correction(s) from an edit after pasting")
        DispatchQueue.main.async { onLearned?(learned) }
    }

    // MARK: - Deciding (pure, self-tested)

    /// Where the pasted text sits in the field: right before the caret as it should be, else the copy of it that ends
    /// nearest the caret.
    static func pastedRange(of inserted: String, in field: String, caret: Int) -> NSRange? {
        let ns = field as NSString
        let length = (inserted as NSString).length
        guard length > 0, length <= ns.length else { return nil }
        if caret >= length, caret <= ns.length {
            let candidate = NSRange(location: caret - length, length: length)
            if ns.substring(with: candidate) == inserted { return candidate }
        }
        var matches: [NSRange] = []
        var searchFrom = 0
        while searchFrom < ns.length {
            let found = ns.range(of: inserted, options: .literal,
                                 range: NSRange(location: searchFrom, length: ns.length - searchFrom))
            guard found.location != NSNotFound else { break }
            matches.append(found)
            searchFrom = found.location + 1
        }
        return matches.min { abs(NSMaxRange($0) - caret) < abs(NSMaxRange($1) - caret) }
            .flatMap { abs(NSMaxRange($0) - caret) <= max(length, 128) ? $0 : nil }
    }

    /// The part of the field between the text that surrounded the dictation when it landed, or nil when either side
    /// can't be found exactly once.
    static func region(in field: String, before: String, after: String) -> String? {
        func unique(_ anchor: String, from start: String.Index) -> Range<String.Index>? {
            guard let first = field.range(of: anchor, options: .literal, range: start..<field.endIndex) else { return nil }
            let next = field.index(after: first.lowerBound)
            guard next >= field.endIndex || field.range(of: anchor, options: .literal, range: next..<field.endIndex) == nil
            else { return nil }
            return first
        }
        var lower = field.startIndex
        if !before.isEmpty {
            guard let found = unique(before, from: field.startIndex) else { return nil }
            lower = found.upperBound
        }
        var upper = field.endIndex
        if !after.isEmpty {
            guard let found = unique(after, from: lower) else { return nil }
            upper = found.lowerBound
        }
        return String(field[lower..<upper])
    }

    /// Most of the dictation is still there — otherwise it was replaced, not corrected.
    static func stillHolds(_ dictation: String, in region: String) -> Bool {
        let dictated = words(dictation)
        let present = Set(words(region))
        return !dictated.isEmpty && Double(dictated.filter(present.contains).count) / Double(dictated.count) >= 0.6
    }

    /// The dictation's stretch of the field grew far beyond what a correction does — a second version pasted beside
    /// it (another dictation app on the same key, 2026-10-14), or a long passage typed on. Nothing is learned from it.
    static func grewTooMuch(_ dictation: String, _ region: String) -> Bool {
        let before = words(dictation).count, after = words(region).count
        return Double(after) > Double(before) * 1.6 + 8
    }

    /// The corrections worth learning: substitutions (`LearnedStore.extractCorrections`) whose new side is a name or an
    /// unusual word, while most of the dictation is still there.
    static func pairs(original: String, edited: String,
                      isKnownWord: (String) -> Bool = HarperChecker.isKnownEnglishWord) -> [(heard: String, intended: String)] {
        guard stillHolds(original, in: edited), !grewTooMuch(original, edited) else { return [] }
        return LearnedStore.extractCorrections(original: original, corrected: edited).filter { pair in
            WhisperPrompt.isWorthMentioning(pair.intended, isKnownWord: isKnownWord)
                && !isKnownWord(pair.intended.lowercased().filter(\.isLetter))
        }
    }

    /// Only what both the last steady reading and the very last reading agree on — so a word caught half-typed just
    /// before Return ("Manrog" → "Manr") is never learned.
    static func agreedPairs(original: String, steady: String, latest: String,
                            isKnownWord: (String) -> Bool = HarperChecker.isKnownEnglishWord)
        -> [(heard: String, intended: String)] {
        let settled = pairs(original: original, edited: steady, isKnownWord: isKnownWord)
        guard latest != steady else { return settled }
        let last = pairs(original: original, edited: latest, isKnownWord: isKnownWord)
        return settled.filter { pair in last.contains { $0.heard == pair.heard && $0.intended == pair.intended } }
    }

    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map { $0.lowercased().filter { $0.isLetter || $0.isNumber } }
            .filter { !$0.isEmpty }
    }

    // MARK: - Accessibility

    private static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.12)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.12)
        var subrole: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success,
           (subrole as? String) == (kAXSecureTextFieldSubrole as String) { return nil }
        return element
    }

    private static func isFocused(_ element: AXUIElement) -> Bool {
        if let focused = focusedElement(), CFEqual(focused, element) { return true }
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXFocusedAttribute as CFString, &value) == .success
            && (value as? NSNumber)?.boolValue == true
    }

    /// The whole field, or nil when it can't be read or is too long.
    private static func text(of element: AXUIElement) -> String? {
        var count: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &count) == .success,
           let total = (count as? NSNumber)?.intValue, total >= 0 {
            guard total <= maximumFieldLength else { return nil }
            var range = CFRange(location: 0, length: total)
            var text: CFTypeRef?
            if let rangeValue = AXValueCreate(.cfRange, &range),
               AXUIElementCopyParameterizedAttributeValue(
                element, kAXStringForRangeParameterizedAttribute as CFString, rangeValue, &text) == .success,
               let string = text as? String, total == 0 || !string.isEmpty {
                return string
            }
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              let string = value as? String, (string as NSString).length <= maximumFieldLength else { return nil }
        return string
    }

    /// Where the caret (or the end of the selection) is.
    private static func caretEnd(of element: AXUIElement) -> Int? {
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
        var selection = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &selection), selection.location >= 0 else { return nil }
        return selection.location + selection.length
    }

    static func runSelfTest() -> Bool {
        var passed = true
        func check(_ ok: Bool, _ label: String) {
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): edits after pasting: \(label)")
        }
        let known: Set<String> = ["we", "use", "the", "font", "send", "it", "to", "team", "whole", "today", "lets", "meet",
                                  "tomorrow", "on", "friday", "app", "application", "is", "great", "and", "more", "text",
                                  "i", "typed", "something", "else", "entirely", "here", "hi", "thanks"]
        let isKnown: (String) -> Bool = { known.contains($0) }
        func run(_ a: String, _ b: String) -> [String] {
            pairs(original: a, edited: b, isKnownWord: isKnown).map { "\($0.heard)→\($0.intended)" }
        }
        check(run("We use the Manrog font.", "We use the Manrope font.") == ["Manrog→Manrope"],
              "a misheard name corrected by hand is learned")
        check(run("Thanks Neve, send it to the team.", "Thanks Niamh, send it to the team.") == ["Neve→Niamh"],
              "…and so is a name spelled unlike it sounds")
        check(run("We use the Manrog font.", "We use the Manrope font. And more text I typed.") == ["Manrog→Manrope"],
              "…with other text after it")
        check(run("Send it to the team.", "Send it to the whole team today.").isEmpty, "added words aren't corrections")
        check(run("Let's meet tomorrow.", "Let's meet on Friday.").isEmpty, "a changed plan isn't a mishearing")
        check(run("The app is great.", "The application is great.").isEmpty, "grammar and wording aren't learned")
        check(run("We use the Manrog font.", "Something else entirely here.").isEmpty,
              "a dictation that was replaced teaches nothing")

        // Finding the dictation after the paste, and again after edits around it.
        let field = "Hi team, We use the Manrog font. Thanks"
        let pasted = "We use the Manrog font."
        let caret = ("Hi team, " + pasted as NSString).length
        check(pastedRange(of: pasted, in: field, caret: caret) == NSRange(location: 9, length: (pasted as NSString).length),
              "the pasted text is found right before the caret")
        check(pastedRange(of: pasted, in: field, caret: (field as NSString).length) != nil,
              "…and near it when the caret already moved on")
        check(pastedRange(of: "Not there.", in: field, caret: caret) == nil, "…and not at all when it isn't there")
        check(region(in: "Hi team, We use the Manrope font. Thanks", before: "Hi team, ", after: " Thanks")
              == "We use the Manrope font.", "the corrected dictation is found between the text around it")
        check(region(in: "Oh, hi team, We use the Manrope font. Thanks a lot", before: "Hi team, ", after: " Thanks") == nil,
              "…and not when the text around it changed")
        check(region(in: "We use the Manrope font. And more", before: "", after: "") == "We use the Manrope font. And more",
              "…the whole field when it filled an empty one")
        check(region(in: "", before: "", after: "").map { stillHolds(pasted, in: $0) } == false,
              "a sent (emptied) chat box no longer holds the dictation")

        // A word caught half-typed just before Return must not be learned.
        func agreed(_ steady: String, _ latest: String) -> [String] {
            agreedPairs(original: pasted, steady: steady, latest: latest, isKnownWord: isKnown)
                .map { "\($0.heard)→\($0.intended)" }
        }
        check(agreed("We use the Manrope font.", "We use the Manrope font.") == ["Manrog→Manrope"],
              "a correction that settled is learned")
        check(agreed("We use the Manr font.", "We use the Manrope font.").isEmpty,
              "a word caught half-typed is not")
        check(agreed("We use the Manrope font.", "We use the Manrope font. Thanks") == ["Manrog→Manrope"],
              "…while typing more afterwards doesn't undo a settled correction")
        return passed
    }
}
