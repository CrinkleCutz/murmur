import AppKit
import Foundation

struct Snippet: Codable, Identifiable, Equatable {
    var id = UUID()
    /// What you say during dictation.
    var trigger: String
    /// What gets inserted instead (exact casing preserved).
    var expansion: String
    /// How many times this snippet has actually expanded into a real
    /// dictation — incremented by `SnippetStore.hold(in:)`, shown on
    /// each row so a snippet's own real payoff (or lack of one) is
    /// visible, not just guessed at.
    var useCount: Int = 0

    init(id: UUID = UUID(), trigger: String, expansion: String, useCount: Int = 0) {
        self.id = id
        self.trigger = trigger
        self.expansion = expansion
        self.useCount = useCount
    }

    private enum CodingKeys: String, CodingKey { case id, trigger, expansion, useCount }

    /// `useCount` didn't exist before this field shipped — decode it
    /// leniently (defaulting to 0) rather than with the compiler's own
    /// synthesized `Decodable`, which requires every key to be present and
    /// would otherwise fail the *whole array's* decode the moment one
    /// saved snippet predates this field, silently losing every snippet
    /// rather than just starting their counts at zero.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        trigger = try container.decode(String.self, forKey: .trigger)
        expansion = try container.decode(String.self, forKey: .expansion)
        useCount = try container.decodeIfPresent(Int.self, forKey: .useCount) ?? 0
    }
}

/// Voice shortcuts: saying a phrase anywhere in a dictation pastes the saved text in its place — like Wispr Flow's
/// Snippets.
///
/// Rebuilt 2026-10-01. The saved text used to be put in *before* the clean-up, and the clean-up then edited it like
/// any other words: measured, it deleted a saved signature and a saved instruction (and its own guard then threw the
/// whole clean-up away), and grammar added commas around links. VoiceInk has the same order. Now the phrase is swapped
/// for a plain marker word (`SNIPPET1` — measured to come through the clean-up, templates and Harper untouched, where
/// bracket markers lost their brackets), every later step works on the user's own words only, and the saved text goes
/// back in, exactly as written, at the very end (`Hold.restore`). Matching ignores case, punctuation and hyphens
/// ("My calendar-link," still matches), and works for any language.
enum SnippetStore {
    static var fileURL: URL {
        // MURMUR_SNIPPETS_FILE (command line only): try snippets without touching the real ones.
        if let path = ProcessInfo.processInfo.environment["MURMUR_SNIPPETS_FILE"] { return URL(fileURLWithPath: path) }
        return AppPaths.supportDirectory.appendingPathComponent("snippets.json")
    }

    static func load() -> [Snippet] {
        guard let data = try? Data(contentsOf: fileURL),
              let snippets = try? JSONDecoder().decode([Snippet].self, from: data)
        else { return [] }
        return snippets
    }

    static func save(_ snippets: [Snippet]) {
        if let data = try? JSONEncoder().encode(snippets) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: - Values filled in when it's pasted

    /// A part of the saved text that's worked out at the moment it's pasted (Espanso has the same idea). Written into
    /// the text as plain words in braces, so it reads clearly and can be typed by hand too.
    enum Value: CaseIterable {
        case date, time, clipboard

        var token: String {
            switch self {
            case .date: return "{today’s date}"
            case .time: return "{time}"
            case .clipboard: return "{what I copied}"
            }
        }

        var label: String {
            switch self {
            case .date: return "Today’s date"
            case .time: return "Time"
            case .clipboard: return "What I copied"
            }
        }

        /// Matches the token whatever the apostrophe or case: `{today's date}`, `{Today’s Date}`.
        fileprivate var pattern: String {
            switch self {
            case .date: return "(?i)\\{\\s*today['’]?s\\s+date\\s*\\}"
            case .time: return "(?i)\\{\\s*time\\s*\\}"
            case .clipboard: return "(?i)\\{\\s*what\\s+i\\s+copied\\s*\\}"
            }
        }
    }

    /// The saved text with its values filled in.
    static func fill(_ expansion: String, now: Date = Date(), locale: Locale = .current,
                     clipboard: () -> String? = { NSPasteboard.general.string(forType: .string) }) -> String {
        var result = expansion
        for value in Value.allCases {
            guard let regex = try? NSRegularExpression(pattern: value.pattern),
                  regex.firstMatch(in: result, range: NSRange(result.startIndex..., in: result)) != nil else { continue }
            let filled: String
            switch value {
            case .date:
                let formatter = DateFormatter()
                formatter.locale = locale
                formatter.dateStyle = .long
                formatter.timeStyle = .none
                filled = formatter.string(from: now)
            case .time:
                let formatter = DateFormatter()
                formatter.locale = locale
                formatter.dateStyle = .none
                formatter.timeStyle = .short
                filled = formatter.string(from: now)
            case .clipboard:
                filled = clipboard()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result),
                withTemplate: NSRegularExpression.escapedTemplate(for: filled))
        }
        return result
    }

    // MARK: - Matching

    /// The phrase as a pattern that ignores case, punctuation and hyphens between its words, and an optional
    /// apostrophe ("today's" / "today’s" / "todays"). Whole words only: "calendar" doesn't match "calendars".
    static func pattern(for trigger: String) -> String? {
        let words = trigger.split { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "’") }
            .map { word in
                word.map { character -> String in
                    character == "'" || character == "’"
                        ? "['’]?" : NSRegularExpression.escapedPattern(for: String(character))
                }.joined()
            }
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        return "(?i)(?<![\\p{L}\\p{N}])" + words.joined(separator: "[\\s\\-‐‑–—_.,:;]*") + "(?![\\p{L}\\p{N}])"
    }

    /// What the phrases found in one dictation were swapped for, so the saved text can go back in after every other
    /// step has run on the user's own words.
    struct Hold {
        /// The dictation with each phrase replaced by its marker.
        var text: String
        /// Marker → the saved text (values already filled in).
        var slots: [(marker: String, text: String)] = []
        /// Every snippet that matched, and how many times.
        var matches: [UUID: Int] = [:]
        /// The dictation was nothing but snippet phrases: paste just the saved text — no full stop, no capital.
        var isWholeDictation = false

        var isEmpty: Bool { slots.isEmpty }
        var useCount: Int { matches.values.reduce(0, +) }
        var markers: [String] { slots.map(\.marker) }

        /// Whether `processed` still has every marker — a later step that lost one is not used.
        func keepsAll(_ processed: String) -> Bool {
            slots.allSatisfy { Self.markerRegex($0.marker).firstMatch(
                in: processed, range: NSRange(processed.startIndex..., in: processed)) != nil }
        }

        /// The saved text back in place of each marker, exactly as written. `startsWithSnippet` tells the paste not to
        /// lower-case the first word when the text continues a sentence — it's the user's own text.
        func restore(_ processed: String) -> (text: String, startsWithSnippet: Bool) {
            guard !slots.isEmpty else { return (processed, false) }
            if isWholeDictation { return (slots.map(\.text).joined(separator: " "), true) }
            var result = processed
            for slot in slots {
                let multiline = slot.text.contains("\n")
                let endsInPunctuation = slot.text.last.map { ".,!?:;".contains($0) } ?? false
                let regex = Self.markerRegex(slot.marker)
                // Last to first, so the positions of the earlier ones stay put.
                for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
                    guard var range = Range(match.range, in: result) else { continue }
                    // A full stop the formatter put after the phrase, when the saved text has its own ending or is
                    // several lines (a signature): "Best regards,\nJanis." is wrong.
                    if multiline || endsInPunctuation, range.upperBound < result.endIndex,
                       result[range.upperBound] == "." {
                        let next = result.index(after: range.upperBound)
                        if next == result.endIndex || result[next].isWhitespace {
                            range = range.lowerBound..<next
                        }
                    }
                    // Several lines after a finished sentence start on their own paragraph, the way a sign-off does.
                    // At the very end, a comma the clean-up joined it on with ("…went well, Best regards,") ends the
                    // sentence instead. After a word ("send it to my address") it stays in the sentence.
                    if multiline {
                        var start = range.lowerBound
                        while start > result.startIndex, result[result.index(before: start)] == " " {
                            start = result.index(before: start)
                        }
                        if start < range.lowerBound, start > result.startIndex {
                            let mark = result.index(before: start)
                            let atEnd = result[range.upperBound...].allSatisfy(\.isWhitespace)
                            if ".!?".contains(result[mark]) {
                                result.replaceSubrange(start..<range.upperBound, with: "\n\n" + slot.text)
                                continue
                            }
                            if atEnd, ",;".contains(result[mark]) {
                                result.replaceSubrange(mark..<range.upperBound, with: ".\n\n" + slot.text)
                                continue
                            }
                        }
                    }
                    result.replaceSubrange(range, with: slot.text)
                }
            }
            let startsWithSnippet = slots.contains { slot in
                processed.trimmingCharacters(in: .whitespacesAndNewlines).range(
                    of: slot.marker, options: [.caseInsensitive, .anchored]) != nil
            }
            return (result, startsWithSnippet)
        }

        fileprivate static func markerRegex(_ marker: String) -> NSRegularExpression {
            // swiftlint:disable:next force_try — a fixed, escaped pattern
            try! NSRegularExpression(pattern: "(?i)(?<![\\p{L}\\p{N}])"
                + NSRegularExpression.escapedPattern(for: marker) + "(?![\\p{L}\\p{N}])")
        }
    }

    /// Finds every snippet phrase in `text` and swaps it for a marker — longest phrases first, so "my address at work"
    /// wins over "my address". Records a use against each snippet that matched (not for previews).
    static func hold(in text: String, snippets: [Snippet]? = nil, now: Date = Date(), locale: Locale = .current,
                     clipboard: @escaping () -> String? = { NSPasteboard.general.string(forType: .string) },
                     recordUse: Bool = true) -> Hold {
        let all = (snippets ?? load()).filter { !$0.trigger.trimmingCharacters(in: .whitespaces).isEmpty }
        var hold = Hold(text: text)
        guard !all.isEmpty else { return hold }
        let ordered = all.sorted {
            let left = $0.trigger.split(separator: " ").count, right = $1.trigger.split(separator: " ").count
            return left != right ? left > right : $0.trigger.count > $1.trigger.count
        }
        var clipboardText: String??
        let readClipboard: () -> String? = {
            if clipboardText == nil { clipboardText = .some(clipboard()) }
            return clipboardText!
        }
        var next = 1
        for snippet in ordered {
            guard let pattern = pattern(for: snippet.trigger),
                  let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            // Found once, then replaced last to first — a phrase can never match its own marker again.
            let found = regex.matches(in: hold.text, range: NSRange(hold.text.startIndex..., in: hold.text))
                .filter { match in
                    guard let range = Range(match.range, in: hold.text) else { return false }
                    return !hold.markers.contains { hold.text[range].caseInsensitiveCompare($0) == .orderedSame }
                }
            var markers: [String] = []
            for _ in found {
                // A marker the dictation can't already contain.
                var marker = "SNIPPET\(next)"
                while hold.text.range(of: marker, options: .caseInsensitive) != nil { next += 1; marker = "SNIPPET\(next)" }
                next += 1
                markers.append(marker)
            }
            for (match, marker) in zip(found, markers).reversed() {
                guard let range = Range(match.range, in: hold.text) else { continue }
                hold.text.replaceSubrange(range, with: marker)
            }
            for marker in markers {
                hold.slots.append((marker, fill(snippet.expansion, now: now, locale: locale, clipboard: readClipboard)))
            }
            let count = markers.count
            if count > 0 { hold.matches[snippet.id] = count }
        }
        if !hold.slots.isEmpty {
            var rest = hold.text
            for marker in hold.markers {
                rest = Hold.markerRegex(marker).stringByReplacingMatches(
                    in: rest, range: NSRange(rest.startIndex..., in: rest), withTemplate: "")
            }
            hold.isWholeDictation = !rest.contains { $0.isLetter || $0.isNumber }
            if recordUse { recordUsage(hold.matches) }
        }
        return hold
    }

    /// Phrases swapped and put straight back — for the command line and the New snippet preview.
    static func expand(in text: String, snippets: [Snippet]? = nil, recordUse: Bool = false) -> String {
        let held = hold(in: text, snippets: snippets, recordUse: recordUse)
        return held.restore(held.text).text
    }

    // MARK: - Choosing a phrase

    /// Why a phrase would fire when the user didn't mean it — nil when it's a good one.
    static func accidentalTriggerWarning(for phrase: String,
                                         isKnownWord: (String) -> Bool = HarperChecker.isKnownEnglishWord) -> String? {
        let words = phrase.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "’") }
        guard !words.isEmpty else { return nil }
        if words.count == 1, let word = words.first, word.count < 4 || isKnownWord(String(word)) {
            return "\u{201c}\(phrase)\u{201d} is an everyday word, so it would paste your text every time you say it. "
                + "Try two or three words, like \u{201c}my calendar link\u{201d}."
        }
        return nil
    }

    private static func recordUsage(_ matchCounts: [UUID: Int]) {
        var all = load()
        var changed = false
        for index in all.indices {
            if let matches = matchCounts[all[index].id] {
                all[index].useCount += matches
                changed = true
            }
        }
        guard changed else { return }
        save(all)
    }

    // MARK: - Self-test

    static func runSelfTest() -> Bool {
        var passed = true
        func check(_ ok: Bool, _ label: String) {
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): snippets: \(label)")
        }
        let link = Snippet(trigger: "my calendar link", expansion: "https://cal.com/janis/30min")
        let signOff = Snippet(trigger: "my sign-off", expansion: "Best regards,\nJanis")
        let address = Snippet(trigger: "my address", expansion: "14 Elm Road\nLondon N1 7GU")
        let work = Snippet(trigger: "my address at work", expansion: "1 Office Park")
        let today = Snippet(trigger: "today's date", expansion: "{today's date}")
        let copied = Snippet(trigger: "paste my clip", expansion: "Copied: {what I copied}")
        let latvian = Snippet(trigger: "mana adrese", expansion: "Brīvības iela 1, Rīga")
        let calendar = Snippet(trigger: "calendar", expansion: "X")
        let snippets = [link, signOff, address, work, today, copied, latvian, calendar]
        let day = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: .current,
                                 year: 2026, month: 10, day: 1, hour: 15, minute: 30).date!
        let british = Locale(identifier: "en_GB")
        func held(_ text: String) -> Hold {
            hold(in: text, snippets: snippets, now: day, locale: british, clipboard: { "the copied bit" },
                 recordUse: false)
        }
        func run(_ text: String) -> String { let h = held(text); return h.restore(h.text).text }

        let mid = held("Here's my calendar link, pick any time that works.")
        check(mid.text == "Here's SNIPPET1, pick any time that works.", "the phrase is swapped for a marker")
        check(mid.restore(mid.text).text == "Here's https://cal.com/janis/30min, pick any time that works.",
              "and the saved text goes back in exactly")
        check(run("Here's My Calendar-Link, thanks.") == "Here's https://cal.com/janis/30min, thanks.",
              "case and a hyphen don't stop a match")
        check(run("Use my sign off.") == "Use Best regards,\nJanis" && run("Use my signoff.") == "Use Best regards,\nJanis",
              "\"sign off\" and \"signoff\" both match \"sign-off\"")
        let whole = held("My calendar link.")
        check(whole.isWholeDictation && whole.restore(whole.text).text == "https://cal.com/janis/30min",
              "just the phrase: just the saved text, no full stop")
        check(run("Thanks again. My sign-off.") == "Thanks again.\n\nBest regards,\nJanis",
              "a signature after a sentence goes on its own paragraph, without a full stop")
        check(held("Thanks again. My sign-off.").restore("Thanks again, SNIPPET1").text
              == "Thanks again.\n\nBest regards,\nJanis",
              "a sign-off the clean-up joined on with a comma still gets its own paragraph")
        check(run("Send it to my address.") == "Send it to 14 Elm Road\nLondon N1 7GU",
              "an address after a word stays in the sentence, as written")
        check(run("Send it to my address at work please.") == "Send it to 1 Office Park please.",
              "the longest phrase wins")
        check(run("The calendars are full.") == "The calendars are full.", "whole words only")
        check(run("Today's date.") == "1 October 2026" && run("Todays date") == "1 October 2026",
              "today's date, with or without the apostrophe")
        check(run("Paste my clip now.") == "Copied: the copied bit now.", "what I copied is read when it's pasted")
        check(fill("{time}", now: day, locale: british, clipboard: { nil }) == "15:30", "the time")
        check(run("Mana adrese ir šeit.") == "Brīvības iela 1, Rīga ir šeit.", "any language")
        let lost = held("Here's my calendar link.")
        check(!lost.keepsAll("Here's the link.") && lost.keepsAll("Here's snippet1."),
              "a step that dropped the marker is noticed; a lower-cased one isn't a loss")
        check(lost.restore("Here's snippet1.").text == "Here's https://cal.com/janis/30min.",
              "a marker the clean-up lower-cased still goes back")
        let leading = held("My calendar link is below.")
        check(leading.restore(leading.text).startsWithSnippet, "a dictation that starts with the saved text says so")
        let ten = hold(in: (1...10).map { _ in "my calendar link" }.joined(separator: " and "), snippets: [link],
                       recordUse: false)
        check(ten.restore(ten.text).text.components(separatedBy: "https://").count == 11,
              "SNIPPET1 and SNIPPET10 are told apart")
        check(accidentalTriggerWarning(for: "calendar", isKnownWord: { $0 == "calendar" }) != nil
              && accidentalTriggerWarning(for: "my calendar link", isKnownWord: { _ in true }) == nil
              && accidentalTriggerWarning(for: "ok", isKnownWord: { _ in false }) != nil,
              "an everyday single word is flagged, a short phrase isn't")
        return passed
    }
}
