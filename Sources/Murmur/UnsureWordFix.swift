import Foundation

/// Fixes a name the recognizer wasn't sure of. Both engines rate every word they write; a wrong name ("Manrog",
/// "Parricate", "Murma") is almost always one they were unsure of (measured 2026-09-19: the least-certain word is the
/// wrong one in 19 of 21 errors on Parakeet, AUROC 0.91–0.95 across engines). So only an unsure word — or a short
/// stretch containing one — is compared with the user's names and unusual words, by spelling and by sound, and replaced
/// when it is clearly the same word. A word the recognizer was sure of is never touched, and neither is an ordinary
/// English word, so "cloud", "manual" or "wrap" can't turn into "Claude", "Manrope" or "Warp".
///
/// Unlike an exact list of known mishearings (tested 2026-09-29: no gain — real voices mishear each name a dozen
/// different ways) this judges each word on its own, and unlike a language model reading the text it only acts where
/// the recognizer itself flagged doubt (a model with the name list doubled errors, 2026-09-28).
enum UnsureWordFix {
    struct Word: Equatable {
        var text: String
        var confidence: Float
    }

    /// Below this, a word counts as unsure.
    static let unsureBelow: Float = 0.6

    /// Measured 2026-09-29 on the Deepgram test set (150 realistic recordings, accented voices): whisper.cpp errors
    /// 3.45% → 3.36%, names 179 → 183 of 240; Parakeet v2 3.80% → 3.61%, names 152 → 163; every changed recording
    /// better, none worse. On unless `MURMUR_NAMEFIX=0` (command line, for comparing) or
    /// `defaults write local.murmur unsureWordFix -bool false`.
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["MURMUR_NAMEFIX"] != "0"
            && (UserDefaults.standard.object(forKey: "unsureWordFix") as? Bool ?? true)
    }

    /// whisper.cpp tokens in order: a token that starts with a space starts a word. Punctuation-only tokens join the
    /// word before them and don't count toward its certainty.
    static func words(fromTokens tokens: [(text: String, p: Float)]) -> [Word] {
        var words: [Word] = []
        for token in tokens where !token.text.isEmpty {
            let isPunctuation = token.text.allSatisfy { $0.isPunctuation || $0.isWhitespace }
            if token.text.hasPrefix(" ") || words.isEmpty {
                let text = token.text.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                words.append(Word(text: text, confidence: isPunctuation ? 1 : token.p))
            } else {
                words[words.count - 1].text += token.text
                if !isPunctuation { words[words.count - 1].confidence = min(words[words.count - 1].confidence, token.p) }
            }
        }
        return words
    }

    /// Parakeet's word pieces in order: "▁" starts a word.
    static func words(fromPieces pieces: [(text: String, p: Float)]) -> [Word] {
        words(fromTokens: pieces.map { (text: $0.text.replacingOccurrences(of: "▁", with: " "), p: $0.p) })
    }

    /// `text` — the recognizer's own — with every clearly misheard name replaced in place, or nil when nothing
    /// changed. Only the replaced words are touched: the rest keeps the recognizer's exact spacing and punctuation.
    /// `screenNames`: the names on screen for this dictation (`ScreenContext`), used only when none of the user's own
    /// words fits, and only when spelled closely — a screen can hold hundreds of names, not a few dozen.
    static func fix(
        _ text: String, words: [Word], terms: [String], screenNames: [String]? = nil,
        isKnownWord: (String) -> Bool = HarperChecker.isKnownEnglishWord
    ) -> (text: String, changes: [(heard: String, name: String)])? {
        // Debug only (command line): as if none of the user's words were known, to measure the names on screen alone.
        let terms = ProcessInfo.processInfo.environment["MURMUR_NAMEFIX_USER_TERMS"] == "0" ? [] : terms
        let screenNames = screenNames ?? ScreenContext.current
        // Debug only (command line): the words and their certainty as the engine reported them.
        if ProcessInfo.processInfo.environment["MURMUR_NAMEFIX_WORDS"] != nil {
            FileHandle.standardError.write(Data(("WORDS " + words.map { "\($0.text)(\(String(format: "%.2f", $0.confidence)))" }
                .joined(separator: " ") + "\n").utf8))
        }
        guard let replacements = replacements(in: words, terms: terms, screenNames: screenNames, isKnownWord: isKnownWord)
        else { return nil }
        var result = text
        var searchFrom = result.startIndex
        var changes: [(heard: String, name: String)] = []
        for replacement in replacements {
            let pattern = replacement.words.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "\\s+")
            guard let range = result.range(of: pattern, options: .regularExpression, range: searchFrom..<result.endIndex)
            else { continue }
            result.replaceSubrange(range, with: replacement.with)
            searchFrom = result.index(range.lowerBound, offsetBy: replacement.with.count)
            changes.append((replacement.words.joined(separator: " "), replacement.with))
        }
        return changes.isEmpty ? nil : (result, changes)
    }

    /// Which words to replace, in order: the words as the recognizer wrote them (punctuation included) and what
    /// replaces them (the name, with that punctuation kept).
    /// A name on screen gets the same rule as the user's own words, with one more condition for a loose spelling match
    /// (below 0.5): the sound skeletons must be identical and at least two sounds long. A screen can hold a hundred
    /// names, and with that many a one-sound-off or one-consonant match finds a wrong one ("Fliss" → "Vilnius" 0.43,
    /// "EOS" → "Cesis" 0.40, measured 2026-09-30) — while every right one kept its place ("Parricate" → "Parakeet"
    /// 0.44 sounds exactly alike, PRKT).
    static func screenNameAllowed(similarity: Double, spanKey: String, nameKey: String) -> Bool {
        similarity >= 0.5 || (spanKey == nameKey && spanKey.count >= 2)
    }

    static func replacements(
        in words: [Word], terms: [String], screenNames: [String] = [], isKnownWord: (String) -> Bool
    ) -> [(words: [String], with: String)]? {
        func candidate(_ term: String, fromScreen: Bool)
            -> (term: String, letters: String, key: String, words: Int, fromScreen: Bool) {
            (term, letters(term), phoneticKey(term), term.split(separator: " ").count, fromScreen)
        }
        let own = terms
            .filter { WhisperPrompt.isWorthMentioning($0, isKnownWord: isKnownWord) }
            .map { candidate($0, fromScreen: false) }
            .filter { $0.letters.count >= 3 }
        let ownLetters = Set(own.map(\.letters))
        let candidates = own + screenNames.map { candidate($0, fromScreen: true) }
            .filter { $0.letters.count >= 3 && !ownLetters.contains($0.letters) }
        guard !candidates.isEmpty, words.contains(where: { $0.confidence < unsureBelow }) else { return nil }
        var found: [(words: [String], with: String)] = []
        var index = 0
        while index < words.count {
            var best: (length: Int, term: String, similarity: Double, fromScreen: Bool)?
            for length in stride(from: min(3, words.count - index), through: 1, by: -1) {
                let span = Array(words[index..<index + length])
                guard span.contains(where: { $0.confidence < unsureBelow }) else { continue }
                // A web address or an email is never a misheard name.
                guard !span.contains(where: { $0.text.contains("@") || $0.text.range(
                    of: "\\.(" + ProtectedSpans.topLevelDomains + ")\\b", options: [.regularExpression, .caseInsensitive]) != nil })
                else { continue }
                let bare = span.map { $0.text.trimmingCharacters(in: .punctuationCharacters) }
                let spanLetters = letters(bare.joined(separator: " "))
                guard spanLetters.count >= 3 else { continue }
                let known = bare.map { isOrdinaryWord($0, isKnownWord: isKnownWord) }
                let allKnown = known.allSatisfy { $0 }
                // Already one of the user's names: nothing to fix, and never "fix" it into a similar-sounding one.
                guard !candidates.contains(where: { $0.letters == spanLetters }) else { continue }
                let spanKey = phoneticKey(bare.joined(separator: " "))
                for candidate in candidates where abs(candidate.words - length) <= 1 && candidate.letters != spanLetters {
                    let similarity = LearnedStore.spellingSimilarity(spanLetters, candidate.letters)
                    // A one-sound skeleton ("you've" and "Vue" are both just F) says nothing on its own: then the
                    // spelling must be at least half alike too (measured 2026-09-30: "you've" → "Vue" at 0.40 on
                    // whisper.cpp; "Hutt" → "HUD" at 0.50 is a real fix).
                    let soundsAlike = (keyDistance(spanKey, candidate.key) == 0
                        || (keyDistance(spanKey, candidate.key) == 1 && max(spanKey.count, candidate.key.count) >= 4))
                        && (spanKey.count >= 2 || similarity >= 0.5)
                    // A stretch with the name's own number of words: close in spelling or in sound. One that also
                    // takes in a neighbouring word (a name split in two, "Plan Refy") must be spelled very close, or
                    // "which are Wispr Flow" would lose its "are".
                    // And a stretch of several words that includes an ordinary one ("up Whisperflow", where the
                    // recognizer ran the name together) must be spelled almost exactly like the name.
                    var accepted = candidate.words == length && !(length > 1 && known.contains(true))
                        ? similarity >= 0.72 || (soundsAlike && similarity >= 0.4)
                        : similarity >= 0.85
                    if allKnown && similarity < 0.9 { accepted = false }
                    if candidate.fromScreen,
                       !screenNameAllowed(similarity: similarity, spanKey: spanKey, nameKey: candidate.key) {
                        accepted = false
                    }
                    // The user's own word beats any name on screen; otherwise the closer spelling wins.
                    let better = best.map { ($0.fromScreen && !candidate.fromScreen)
                        || ($0.fromScreen == candidate.fromScreen && similarity > $0.similarity) } ?? true
                    if accepted, better { best = (length, candidate.term, similarity, candidate.fromScreen) }
                }
            }
            if let best {
                let span = words[index..<index + best.length]
                let leading = String(span.first!.text.prefix { $0.isPunctuation })
                let trailing = String(span.last!.text.reversed().prefix { $0.isPunctuation }.reversed())
                found.append((span.map(\.text), leading + best.term + trailing))
                index += best.length
            } else {
                index += 1
            }
        }
        return found.isEmpty ? nil : found
    }

    /// An ordinary English word, contractions included: "you've", "they're" and "don't" lose their apostrophe in a
    /// letters-only lookup ("youve"), which the dictionary doesn't know — so the word before the apostrophe is checked.
    static func isOrdinaryWord(_ word: String, isKnownWord: (String) -> Bool) -> Bool {
        let lower = word.lowercased().replacingOccurrences(of: "’", with: "'")
        if isKnownWord(lower.filter(\.isLetter)) { return true }
        let parts = lower.split(separator: "'", maxSplits: 1)
        guard parts.count == 2, ["s", "ve", "re", "ll", "d", "t", "m"].contains(String(parts[1]).filter(\.isLetter))
        else { return false }
        let stem = String(parts[0]).filter(\.isLetter)
        return isKnownWord(stem) || (parts[1] == "t" && stem.hasSuffix("n") && isKnownWord(String(stem.dropLast())))
    }

    static func letters(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// A rough sound skeleton: consonants only, similar sounds merged — "Parricate" and "Parakeet" are both PRKT,
    /// "Versal" and "Vercel" both FRSL.
    static func phoneticKey(_ text: String) -> String {
        var s = letters(text).folding(options: .diacriticInsensitive, locale: nil)
        for (from, to) in [("ph", "f"), ("ck", "k"), ("ce", "se"), ("ci", "si"), ("cy", "sy"), ("qu", "k"), ("x", "ks")] {
            s = s.replacingOccurrences(of: from, with: to)
        }
        let map: [Character: Character] = ["c": "k", "q": "k", "g": "k", "j": "k", "z": "s", "v": "f",
                                           "d": "t", "b": "p"]
        var key = ""
        for character in s {
            guard !"aeiouyhw".contains(character) else { continue }
            let mapped = map[character] ?? character
            if key.last != mapped { key.append(mapped) }
        }
        return key.uppercased()
    }

    static func keyDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var row = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var previous = row[0]
            row[0] = i
            for j in 1...max(b.count, 1) where !b.isEmpty {
                let current = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = current
            }
        }
        return a.isEmpty ? b.count : row[b.count]
    }

    static func runSelfTest() -> Bool {
        var passed = true
        func check(_ ok: Bool, _ label: String) {
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): unsure words: \(label)")
        }
        let known: Set<String> = ["we", "use", "the", "font", "in", "app", "cloud", "manual", "is", "faster", "plan", "on",
                                  "check", "and", "push", "to", "wrap", "it", "for", "checkout", "yes", "i", "will", "be",
                                  "using", "mormon", "murmur", "look", "up"]
        let isKnown: (String) -> Bool = { known.contains($0) }
        let terms = ["Manrope", "Parakeet", "Murmur", "Vercel", "Claude", "Warp", "Wispr Flow", "Planrify", "Stripe"]
        func sample(_ spec: [(String, Float)]) -> [Word] { spec.map { Word(text: $0.0, confidence: $0.1) } }
        func run(_ spec: [(String, Float)]) -> String? {
            fix(spec.map(\.0).joined(separator: " "), words: sample(spec), terms: terms, isKnownWord: isKnown)?.text
        }

        check(run([("We", 0.9), ("use", 0.9), ("the", 0.9), ("Manrog", 0.3), ("font.", 0.9)])
              == "We use the Manrope font.", "an unsure misspelt name is fixed (Manrog → Manrope)")
        check(run([("Parricate", 0.4), ("is", 0.9), ("faster.", 0.9)]) == "Parakeet is faster.",
              "by sound when the spelling is far (Parricate → Parakeet)")
        check(run([("Check", 0.9), ("Versal,", 0.2), ("and", 0.9)]) == "Check Vercel, and",
              "punctuation stays where it was (Versal, → Vercel,)")
        check(run([("We", 0.9), ("use", 0.9), ("Manrog", 0.95), ("font.", 0.9)]) == nil,
              "a word the recognizer was sure of is never touched")
        check(run([("The", 0.9), ("cloud", 0.2), ("is", 0.9)]) == nil, "an ordinary word is never turned into a name")
        check(run([("A", 0.9), ("manual", 0.3), ("app", 0.9)]) == nil, "manual stays manual")
        check(run([("Mormon", 0.3), ("app", 0.9)]) == nil, "a real word that sounds close stays")
        check(run([("Plan", 0.9), ("Refy", 0.3), ("is", 0.9)]) == "Planrify is",
              "a name split in two comes back as one (Plan Refy → Planrify)")
        check(run([("Yes,", 0.9), ("I", 0.9), ("will", 0.9), ("be", 0.9), ("using", 0.9), ("Streq", 0.3), ("for", 0.9)])
              == "Yes, I will be using Stripe for", "Streq → Stripe")
        check(run([("which", 0.9), ("are", 0.4), ("Wispr", 0.9), ("Flow.", 0.9)]) == nil,
              "a neighbouring word is never swallowed into a name")
        check(run([("look", 0.9), ("up", 0.5), ("Whisperflow", 0.4), ("and", 0.9)]) == nil,
              "…not even when the recognizer ran the name together (up Whisperflow)")
        check(fix("Runs on whisper.cpp now", words: sample([("Runs", 0.9), ("on", 0.9), ("whisper.cpp", 0.3), ("now", 0.9)]),
                  terms: terms + ["whisper.cpp", "WhisperKit"], isKnownWord: isKnown) == nil,
              "a word that already is one of the names is never swapped for a similar one")
        check(fix("the critical  edge of Manrog", words: sample([("the", 0.9), ("criticaledge", 0.9), ("of", 0.9),
                                                                 ("Manrog", 0.2)]), terms: terms, isKnownWord: isKnown)?.text
              == "the critical  edge of Manrope", "only the name changes; the rest keeps the recognizer's own text")
        check(words(fromTokens: [(" Man", 0.9), ("rog", 0.2), (",", 0.1), (" font", 0.9)])
              == [Word(text: "Manrog,", confidence: 0.2), Word(text: "font", confidence: 0.9)],
              "whisper.cpp tokens become words; a comma's own certainty doesn't count")
        check(words(fromPieces: [("▁Man", 0.9), ("rog", 0.2), ("▁font", 0.9)]).map(\.text) == ["Manrog", "font"],
              "Parakeet pieces become words")
        check(phoneticKey("Parricate") == phoneticKey("Parakeet") && phoneticKey("Versal") == phoneticKey("Vercel"),
              "sound skeletons: Parricate = Parakeet, Versal = Vercel")
        // A contraction is an ordinary word, and a one-sound match isn't enough (the live "you've" → "Vue").
        check(fix("after you've done the research", words: sample([("after", 0.9), ("you've", 0.3), ("done", 0.9),
                                                                     ("the", 0.9), ("research", 0.9)]),
                  terms: ["Vue", "Vercel"], isKnownWord: isKnown) == nil,
              "\"you've\" is never swapped for a name (Vue)")
        check(isOrdinaryWord("you've", isKnownWord: { $0 == "you" }) && isOrdinaryWord("don’t", isKnownWord: { $0 == "do" })
              && !isOrdinaryWord("Manrog", isKnownWord: { _ in false }), "contractions count as ordinary words")
        // Names on screen: used when none of the user's words fits; a loose spelling needs an exact sound skeleton.
        check(fix("We moved to Superbase", words: sample([("We", 0.9), ("moved", 0.9), ("to", 0.9), ("Superbase", 0.3)]),
                  terms: [], screenNames: ["Supabase", "Vilnius"], isKnownWord: isKnown)?.text == "We moved to Supabase",
              "a name on screen fixes an unsure word the user never taught")
        check(fix("the Manrog font", words: sample([("the", 0.9), ("Manrog", 0.2), ("font", 0.9)]),
                  terms: ["Manrope"], screenNames: ["Manrog2", "Manrose"], isKnownWord: isKnown)?.text == "the Manrope font",
              "…and the user's own word comes first")
        check(fix("the Fliss test", words: sample([("the", 0.9), ("Fliss", 0.3), ("test", 0.9)]),
                  terms: [], screenNames: ["Vilnius"], isKnownWord: isKnown) == nil
              && fix("on EOS", words: sample([("on", 0.9), ("EOS", 0.3)]),
                     terms: [], screenNames: ["Cesis"], isKnownWord: isKnown) == nil,
              "…but a loose match to one of many names on screen is not taken (Fliss → Vilnius, EOS → Cesis)")
        check(fix("on Parricate", words: sample([("on", 0.9), ("Parricate", 0.3)]),
                  terms: [], screenNames: ["Parakeet"], isKnownWord: isKnown)?.text == "on Parakeet",
              "…while one that sounds exactly alike is (Parricate → Parakeet)")
        return passed
    }
}

/// What the name fix changed in real dictations, most recent last (up to 200) — kept on this Mac only
/// (`~/Library/Application Support/Murmur/name_fixes.json`), so how well it does can be checked as Murmur is used.
/// Written by the app only (`isRecording`, set at launch), never by the command line's test runs.
enum NameFixLog {
    struct Entry: Codable {
        let date: Date
        let heard: String
        let name: String
        let engine: String
        /// The name came from the screen (`ScreenContext`), not the user's own vocabulary.
        var fromScreen: Bool?
    }

    nonisolated(unsafe) static var isRecording = false
    static let limit = 200
    private static let queue = DispatchQueue(label: "local.murmur.name-fix-log")

    static var fileURL: URL { AppPaths.supportDirectory.appendingPathComponent("name_fixes.json") }

    static func record(_ changes: [(heard: String, name: String)], engine: String) {
        guard isRecording, !changes.isEmpty else { return }
        let now = Date()
        let onScreen = Set(ScreenContext.current)
        queue.async {
            var entries = load()
            entries += changes.map {
                Entry(date: now, heard: $0.heard, name: $0.name, engine: engine,
                      fromScreen: onScreen.contains($0.name) ? true : nil)
            }
            if entries.count > limit { entries.removeFirst(entries.count - limit) }
            if let data = try? JSONEncoder().encode(entries) { try? data.write(to: fileURL, options: .atomic) }
        }
    }

    static func load() -> [Entry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }
}
