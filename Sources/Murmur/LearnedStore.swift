import Foundation

struct LearnedCorrection: Codable, Identifiable, Equatable {
    var id = UUID()
    /// What the recognizer heard.
    var heard: String
    /// What the user actually said.
    var intended: String
    var timesSeen: Int = 1
}

struct LearnedData: Codable {
    var corrections: [LearnedCorrection] = []
    /// Words/phrases the user has taught (used for recognition biasing
    /// even when no correction mapping is needed).
    var terms: [String] = []
}

/// Murmur's pronunciation memory. Populated by the Voice Training page and
/// by corrections the user makes to transcripts in History. Used two ways:
/// 1. `apply(in:)` fixes known mishearings in every transcript.
/// 2. `biasTerms()` feeds the user's vocabulary into the speech model
///    before recognition (AnalysisContext contextual strings).
enum LearnedStore {
    static var fileURL: URL {
        AppPaths.supportDirectory.appendingPathComponent("learned.json")
    }

    /// Every term and every intended spelling comes back cleaned (`cleanedTerm`), whatever the file holds — so an
    /// entry saved as "Murmur." by the Voice Training page can't keep turning every "Murmur" into "Murmur." mid-sentence
    /// (it did, through the personal fuzzy match below, on every dictation that said the name).
    static func load() -> LearnedData {
        guard let data = try? Data(contentsOf: fileURL),
              var learned = try? JSONDecoder().decode(LearnedData.self, from: data)
        else { return LearnedData() }
        learned.terms = learned.terms.map(cleanedTerm)
        for index in learned.corrections.indices {
            learned.corrections[index].intended = cleanedTerm(learned.corrections[index].intended)
        }
        return learned
    }

    /// A term as it should be matched and written: no surrounding space, no sentence punctuation stuck to its end.
    /// Keeps the full stops of an abbreviation made of single letters ("U.S.", "e.g.") and anything inside the term
    /// ("whisper.cpp", "UI/UX").
    static func cleanedTerm(_ term: String) -> String {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.range(of: #"^([A-Za-z]\.)+$"#, options: .regularExpression) != nil { return trimmed }
        return String(trimmed.reversed().drop(while: { ".,!?;:".contains($0) }).reversed())
            .trimmingCharacters(in: .whitespaces)
    }

    static func save(_ learned: LearnedData) {
        if let data = try? JSONEncoder().encode(learned) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: - Recording new knowledge

    /// Adds one mapping (merging duplicates) and remembers the intended term. Returns whether the mapping was kept.
    /// Ordinary words swapped for ordinary words ("For action" → "Correction") are a rewording, not a mishearing: kept
    /// as a mapping they'd rewrite normal speech ("ready for action"), so nothing at all is learned from them.
    @discardableResult
    static func add(heard: String, intended: String) -> Bool {
        let heardTrimmed = normalizePhrase(heard)
        let intendedTrimmed = cleanedTerm(intended)
        if isRewording(heard: heardTrimmed, intended: intendedTrimmed) { return false }
        guard isUsefulMapping(heard: heardTrimmed, intended: intendedTrimmed) else {
            addTerm(intendedTrimmed)
            return false
        }
        var learned = load()
        if let index = learned.corrections.firstIndex(where: {
            $0.heard.lowercased() == heardTrimmed.lowercased()
                && $0.intended == intendedTrimmed
        }) {
            learned.corrections[index].timesSeen += 1
        } else {
            learned.corrections.append(LearnedCorrection(
                heard: heardTrimmed, intended: intendedTrimmed))
        }
        if learned.corrections.count > 300 {
            learned.corrections.removeFirst(learned.corrections.count - 300)
        }
        appendTerm(intendedTrimmed, to: &learned)
        save(learned)
        return true
    }

    /// Every word on both sides is an ordinary English word — a rewording, not a misheard name. A side with a number
    /// or a word the dictionary doesn't know ("1030" → "10:30", "par key" → "Parakeet") is never a rewording.
    static func isRewording(heard: String, intended: String,
                            isKnownWord: (String) -> Bool = HarperChecker.isKnownEnglishWord) -> Bool {
        func allKnown(_ phrase: String) -> Bool {
            let words = phrase.split(whereSeparator: { $0.isWhitespace || $0 == "/" || $0 == "-" })
            return !words.isEmpty && words.allSatisfy { word in
                let letters = word.lowercased().filter(\.isLetter)
                return !letters.isEmpty && letters.count == word.filter { $0.isLetter || $0.isNumber }.count
                    && isKnownWord(letters)
            }
        }
        return allKnown(heard) && allKnown(intended)
    }

    /// Remembers a term for recognition biasing without any mapping.
    static func addTerm(_ term: String) {
        let trimmed = cleanedTerm(term)
        guard !trimmed.isEmpty else { return }
        var learned = load()
        appendTerm(trimmed, to: &learned)
        save(learned)
    }

    private static func appendTerm(_ term: String, to learned: inout LearnedData) {
        guard !term.isEmpty,
              !learned.terms.contains(where: { $0.lowercased() == term.lowercased() })
        else { return }
        learned.terms.append(term)
        if learned.terms.count > 300 {
            learned.terms.removeFirst(learned.terms.count - 300)
        }
    }

    /// Learns from a user-corrected transcript: extracts word-level
    /// substitutions and stores each. Returns how many were learned.
    @discardableResult
    static func learn(original: String, corrected: String) -> Int {
        extractCorrections(original: original, corrected: corrected)
            .filter { add(heard: $0.heard, intended: $0.intended) }.count
    }

    // MARK: - Using the knowledge

    /// Fixes known mishearings (case-insensitive whole phrases, longest
    /// first so overlapping mappings behave predictably) — the user's own
    /// taught corrections, plus Murmur's built-in `DeveloperVocabulary`
    /// ones when `includeDeveloperVocabulary` says this app should get
    /// them. This runs unconditionally after transcription, so unlike
    /// `biasTerms()` it doesn't depend on an ASR engine's prompt-biasing
    /// actually working: it's the one mechanism in this pipeline that can
    /// genuinely guarantee a specific known mishearing gets fixed every
    /// time, since it doesn't care what the model was confident about.
    /// Personal corrections come first so a tie in phrase length resolves
    /// in favor of something this specific user actually taught over a
    /// generic built-in guess.
    ///
    /// No default for `includeDeveloperVocabulary`: every call site has a
    /// bundle ID (or explicitly doesn't) to resolve
    /// `AppProfileStore.developerVocabularyEnabled(forBundleID:)` against,
    /// and a silent default is exactly how `Main.swift`'s CLI debug paths
    /// drifted from the real dictation pipeline once already (they used to
    /// skip Harper entirely) — forcing every caller to pass this
    /// explicitly is what keeps the next new post-processing step from
    /// doing the same.
    ///
    /// `DeveloperVocabulary.fuzzyCorrect(in:against:)` runs last, after
    /// every exact-phrase correction above: it catches mis-hearing
    /// spellings close enough to a known term to fuzzy-match even when
    /// they're not one of the specific spellings enumerated above, and
    /// running it after exact matching means a match already found by name
    /// isn't re-examined by the fuzzier, costlier check.
    ///
    /// Two separate fuzzy passes, not one merged list, because they carry
    /// different risk profiles: `DeveloperVocabulary.fuzzyCorrectionTargets`
    /// is a small, shared, hand-vetted list (currently just "Supabase")
    /// gated to developer contexts because it was tuned against known
    /// false-positive collisions with ordinary English words — see its own
    /// doc comment. `personalFuzzyTargets` below is built fresh from
    /// whatever *this* user has actually taught Murmur, so it runs
    /// unconditionally, in every app and every kind of dictation — email,
    /// articles, chat, not just developer contexts — because a name or
    /// term someone specifically corrected once is exactly the case this
    /// mechanism exists for, regardless of what app they happen to be
    /// dictating into. It uses a stricter default threshold instead
    /// (0.85, not 0.68) precisely because it *can't* be individually
    /// vetted the way "Supabase" was — every future term the user teaches
    /// gets the same safe-by-default floor, not a case-by-case judgment
    /// call.
    static func apply(in text: String, includeDeveloperVocabulary: Bool) -> String {
        // Web addresses and emails are set aside first, so no taught word can land inside one ("murmurmac.com" was
        // turned into "Murmur mac.com" by the taught term "Murmur mac").
        let (masked, restore) = ProtectedSpans.mask(text)
        var result = masked
        let learned = load()
        let personal = learned.corrections.map { (heard: $0.heard, intended: $0.intended) }
        let builtIn = includeDeveloperVocabulary ? DeveloperVocabulary.corrections : []
        let corrections = (personal.map { ($0.heard, $0.intended, true) } + builtIn.map { ($0.heard, $0.intended, false) })
            .sorted { $0.0.count > $1.0.count }
        for (heard, intended, isPersonal) in corrections {
            // The user's own mishearings also match the same letters split or joined differently — the recognizer
            // wrote "Whisperflow" when it was taught and "Whisper Flow" today. Built-in ones stay exact, as tuned.
            let pattern = isPersonal ? flexiblePattern(for: heard)
                : "(?i)\\b" + NSRegularExpression.escapedPattern(for: heard) + "\\b"
            result = result.replacingOccurrences(
                of: pattern,
                with: NSRegularExpression.escapedTemplate(for: intended),
                options: .regularExpression)
        }
        result = DeveloperVocabulary.fuzzyCorrect(
            in: result, against: personalFuzzyTargets(from: personal))
        result = enforceCasing(in: result, terms: learned.terms + learned.corrections.map(\.intended))
        if includeDeveloperVocabulary {
            result = DeveloperVocabulary.fuzzyCorrect(
                in: result, against: DeveloperVocabulary.fuzzyCorrectionTargets)
        }
        return restore(result)
    }

    /// A whole-phrase, case-insensitive pattern for a mishearing that also matches its letters split or joined
    /// differently: "Whisperflow" matches "Whisper Flow" and "Whisper-flow", "revenue cut" matches "revenuecut".
    /// Only from 6 letters up — a short one like "KPA" or "IIS" stays exact, where a gap could land on real words.
    static func flexiblePattern(for heard: String) -> String {
        let characters = Array(heard)
        guard characters.filter(\.isLetter).count >= 6 else {
            return "(?i)\\b" + NSRegularExpression.escapedPattern(for: heard) + "\\b"
        }
        var pattern = ""
        for (index, character) in characters.enumerated() {
            if character == " " || character == "-" {
                pattern += "[ -]?"
                continue
            }
            pattern += NSRegularExpression.escapedPattern(for: String(character))
            if index + 1 < characters.count, character.isLetter, characters[index + 1].isLetter {
                pattern += "[ -]?"
            }
        }
        return "(?i)\\b" + pattern + "\\b"
    }

    /// Writes the user's own names the way they spelled them: "PlanRify" → "Planrify", "revenuecat" → "RevenueCat",
    /// "IOS" → "iOS". Only for terms with a capital in them (the capitals are the point) that aren't everyday words —
    /// "Murmur" and "Gemini" are also ordinary words, and a lowercase term like "dmg" would undo a sentence's capital.
    static func enforceCasing(in text: String, terms: [String],
                              isKnownWord: (String) -> Bool = HarperChecker.isKnownEnglishWord) -> String {
        var result = text
        var seen = Set<String>()
        for raw in terms {
            let term = cleanedTerm(raw)
            let key = term.lowercased()
            guard term.contains(where: \.isUppercase), !seen.contains(key) else { continue }
            seen.insert(key)
            let unusual = term.split(separator: " ").contains { word in
                let letters = word.filter(\.isLetter).lowercased()
                return !letters.isEmpty && !isKnownWord(letters)
            }
            guard unusual,
                  let regex = try? NSRegularExpression(
                    pattern: "(?i)(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: term) + "(?![\\p{L}\\p{N}])")
            else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range,
                                                    withTemplate: NSRegularExpression.escapedTemplate(for: term))
        }
        return result
    }

    /// The strict, safe-by-default floor for `personalFuzzyTargets` below —
    /// see `apply(in:includeDeveloperVocabulary:)`'s doc comment for why
    /// this can't reuse `DeveloperVocabulary.fuzzyCorrectionTargets`'
    /// looser, per-term-vetted 0.68. Matches `ParakeetEngine`'s own global
    /// CTC rescoring floor — the other place in this codebase that has to
    /// pick one number safe for terms nobody has individually tested.
    private static let personalFuzzyMatchThreshold: Float = 0.85

    /// Builds a fuzzy-match target list from the user's own corrections —
    /// every `intended` spelling they've ever taught Murmur, deduplicated
    /// case-insensitively, each at `personalFuzzyMatchThreshold`. Unlike
    /// `DeveloperVocabulary.fuzzyCorrectionTargets`, this list isn't
    /// curated in advance: it's built fresh from whatever this specific
    /// user has actually corrected, which is exactly why the threshold has
    /// to stay strict rather than being loosened per term the way
    /// "Supabase" was.
    ///
    /// Skips a single-word `intended` that's itself a known English word
    /// (Harper's dictionary — same check `isUsefulMapping` already runs on
    /// the *`heard`* side of a candidate correction, applied here to the
    /// *`intended`* side instead): a fuzzy floor loose enough to fix a real
    /// mis-hearing of an ordinary dictionary word is also loose enough to
    /// mis-fire on an unrelated, correctly-heard occurrence of that same
    /// word elsewhere in the transcript. In practice `isUsefulMapping`
    /// already keeps most of these out of `learned.corrections` in the
    /// first place (it runs the equivalent check on `heard`), but nothing
    /// upstream guarantees `intended` itself is never an ordinary word
    /// (a homophone correction could plausibly go the other way — heard an
    /// unusual word, intended a common one) — so this checks directly
    /// rather than relying on that as an implicit guarantee.
    private static func personalFuzzyTargets(
        from corrections: [(heard: String, intended: String)]
    ) -> [String: Float] {
        var targets: [String: Float] = [:]
        for correction in corrections {
            let intended = correction.intended
            guard !targets.keys.contains(where: {
                $0.caseInsensitiveCompare(intended) == .orderedSame
            }) else { continue }
            if !intended.contains(" "), HarperChecker.isKnownEnglishWord(intended) {
                continue
            }
            targets[intended] = personalFuzzyMatchThreshold
        }
        return targets
    }

    /// Vocabulary handed to the speech model before recognition: Murmur's
    /// own built-in developer vocabulary (when `includeDeveloperVocabulary`
    /// says this app should get it), then taught terms, learned spellings,
    /// dictionary spellings, and snippet triggers — the last four are the
    /// user's own, so they're never gated: only the shared, one-size list
    /// built for coding contexts is.
    ///
    /// Built-in terms go *first*, ahead of the user's own — this is the
    /// opposite of the "personal data should win" instinct, but personal
    /// terms have a second safety net the built-in list doesn't: even a
    /// personal term that gets dropped here for space is still fixed
    /// after the fact by `apply(in:)`'s exact-phrase correction, once it's
    /// actually been learned. The built-in list has no such fallback — if
    /// it doesn't make it into the engine's prompt, it does nothing at
    /// all. Confirmed this mattered in practice: with built-in terms
    /// appended last, 74 raw personal terms+corrections alone already
    /// exceeded the `prefix(60)` cutoff `WhisperEngine`/`WhisperCppEngine`
    /// apply when building the actual prompt string — "Supabase" never
    /// reached Whisper at all, not because it mis-heard it.
    ///
    /// No default for `includeDeveloperVocabulary` — see `apply(in:)`'s
    /// matching note; the same drift risk applies here.
    static func biasTerms(includeDeveloperVocabulary: Bool) -> [String] {
        var terms: [String] = []
        var seen = Set<String>()
        func insert(_ term: String) {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = trimmed.lowercased()
            guard !trimmed.isEmpty, trimmed.count > 1, !seen.contains(key)
            else { return }
            seen.insert(key)
            terms.append(trimmed)
        }
        if includeDeveloperVocabulary {
            DeveloperVocabulary.terms.forEach(insert)
        }
        let learned = load()
        learned.terms.forEach(insert)
        learned.corrections.map(\.intended).forEach(insert)
        TextFormatter.loadDictionary().values.forEach(insert)
        SnippetStore.load().map(\.trigger).forEach(insert)
        return Array(terms.prefix(300))
    }

    /// The user's own words (taught terms, learned spellings, dictionary spellings, snippet triggers), lowercased —
    /// `WhisperPrompt` puts these ahead of Murmur's built-in developer terms.
    static func personalTermKeys() -> Set<String> {
        let learned = load()
        let all = learned.terms + learned.corrections.map(\.intended)
            + Array(TextFormatter.loadDictionary().values) + SnippetStore.load().map(\.trigger)
        return Set(all.map { cleanedTerm($0).lowercased() })
    }

    // MARK: - Diff extraction

    /// Word-level diff between the original transcript and the user's
    /// correction. Returns substituted runs (up to 4 words long) as
    /// heard → intended pairs.
    static func extractCorrections(
        original: String, corrected: String) -> [(heard: String, intended: String)] {
        let originalWords = tokenize(original)
        let correctedWords = tokenize(corrected)
        guard !originalWords.isEmpty, !correctedWords.isEmpty else { return [] }

        // Longest common subsequence over normalized tokens.
        let n = originalWords.count
        let m = correctedWords.count
        var lcs = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                if originalWords[i].key == correctedWords[j].key {
                    lcs[i][j] = lcs[i + 1][j + 1] + 1
                } else {
                    lcs[i][j] = max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }

        // One word swapped for another and nothing else touched: the only edit `isRespelledName` is trusted on.
        let onlyOneWordChanged = n == m && zip(originalWords, correctedWords).filter { $0.key != $1.key }.count == 1

        var pairs: [(heard: String, intended: String)] = []
        var i = 0
        var j = 0
        while i < n, j < m {
            if originalWords[i].key == correctedWords[j].key {
                i += 1
                j += 1
                continue
            }
            // Collect one substituted run on each side.
            var removed: [String] = []
            var added: [String] = []
            while i < n, j < m, originalWords[i].key != correctedWords[j].key {
                if lcs[i + 1][j] >= lcs[i][j + 1] {
                    removed.append(originalWords[i].raw)
                    i += 1
                } else {
                    added.append(correctedWords[j].raw)
                    j += 1
                }
                // A pure insertion or deletion isn't a pronunciation fix.
                if i >= n || j >= m { break }
            }
            if !removed.isEmpty, !added.isEmpty,
               removed.count <= 4, added.count <= 4 {
                let heard = normalizePhrase(removed.joined(separator: " "))
                let intended = cleanedTerm(added.joined(separator: " ")
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ,")))
                if isUsefulMapping(heard: heard, intended: intended),
                   spellingSimilarity(heard, intended) >= minimumLearnedSimilarity
                    || (onlyOneWordChanged && isRespelledName(heard: heard, intended: intended)) {
                    pairs.append((heard, intended))
                }
            }
        }
        return pairs
    }

    /// How alike the two sides of a correction learned from a History edit must be spelled. A mishearing sounds like
    /// what was said, so it's spelled like it too — "revenue cut" → "RevenueCat" 0.90, "par key" → "Parakeet" 0.62 —
    /// while an edit made elsewhere in the text that the diff paired with unrelated words isn't: "and then through the"
    /// → "from Chat" 0.18, which then replaced that everyday phrase in every dictation. The Voice Training page's
    /// deliberate "say this word" pairs don't go through here.
    static let minimumLearnedSimilarity = 0.4

    /// 1 − edit distance ÷ longer length, over letters and digits only, ignoring case.
    static func spellingSimilarity(_ a: String, _ b: String) -> Double {
        let x = Array(a.lowercased().filter { $0.isLetter || $0.isNumber })
        let y = Array(b.lowercased().filter { $0.isLetter || $0.isNumber })
        guard max(x.count, y.count) > 0 else { return 1 }
        var previous = Array(0...y.count)
        for i in 1...max(1, x.count) where !x.isEmpty {
            var current = [i] + Array(repeating: 0, count: y.count)
            for j in stride(from: 1, through: y.count, by: 1) {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return 1 - Double(x.isEmpty ? y.count : previous[y.count]) / Double(max(x.count, y.count))
    }

    /// A name that isn't spelled the way it sounds — "Neve" → "Niamh" 0.20, "Shivon" → "Siobhan" 0.43 — is the
    /// correction this feature is for, and `minimumLearnedSimilarity` alone refuses it. So one word swapped for one
    /// capitalised word is also learned when the two start with the same sound and neither is an ordinary English
    /// word: a recogniser gets the start of a name right even when it has never seen the spelling. Only when that
    /// swap is the whole edit (`onlyOneWordChanged`), which is what the unrelated pairings the floor is there for
    /// never are.
    static func isRespelledName(heard: String, intended: String) -> Bool {
        let from = heard.lowercased().folding(options: .diacriticInsensitive, locale: nil).filter(\.isLetter)
        let to = intended.folding(options: .diacriticInsensitive, locale: nil).filter(\.isLetter)
        guard !heard.contains(" "), !intended.contains(" "), from.count >= 3, to.count >= 3,
              abs(from.count - to.count) <= 3, to.first?.isUppercase == true,
              let a = from.first, let b = to.lowercased().first,
              !HarperChecker.isKnownEnglishWord(from), !HarperChecker.isKnownEnglishWord(to.lowercased())
        else { return false }
        return a == b || sameOpeningSound.contains { $0.contains(a) && $0.contains(b) }
    }

    /// Letters that open a name with the same sound: any vowel for any other ("Eefa" → "Aoife"), and the hard
    /// consonants that share one.
    private static let sameOpeningSound: [Set<Character>] = [["a", "e", "i", "o", "u", "y"], ["c", "k", "q"], ["g", "j"], ["s", "z"]]

    private static func tokenize(_ text: String) -> [(raw: String, key: String)] {
        text.split(whereSeparator: { $0.isWhitespace }).map { token in
            let raw = String(token)
            let key = raw.lowercased()
                .trimmingCharacters(in: .punctuationCharacters)
            return (raw, key)
        }
    }

    private static func normalizePhrase(_ phrase: String) -> String {
        phrase
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:"))
    }

    /// Refuses to learn a correction whose *entire* trigger is one
    /// ordinary English word — found by auditing one real user's
    /// accumulated corrections and discovering `up → app`, `there → they`,
    /// `they → here` (the first two chained into `there` becoming
    /// `here`), `weight → white`, `tail → teal`, `whisper → Wispr`, and
    /// `team → theme` had all been learned, apparently from
    /// `extractCorrections` misattributing an edit made *elsewhere* in a
    /// correction round-trip to an unrelated short word it happened to
    /// land near in the diff. Once learned, `apply(in:)` runs
    /// unconditionally on every future dictation with no confidence gate
    /// at all — so a single bad learn silently breaks one of the most
    /// common words in the language, forever, until someone notices (the
    /// user only ever noticed "up").
    ///
    /// `HarperChecker.isKnownEnglishWord` — Harper's own dictionary — is
    /// the check, not a hand-kept list: a proper noun or brand name (the
    /// entire point of this feature) won't be in a general English
    /// dictionary, so genuine corrections pass through untouched, while
    /// real words the audit above found ("team", "whisper", ...) reliably
    /// don't. Confirmed against words this audit wasn't fully sure about
    /// too ("plaintiff", "fireworks", "germany") — all real dictionary
    /// words, all would have been silently corrupted the same way had
    /// they ever been mis-attributed as a correction. A multi-word
    /// `heard` phrase ("super base", "cloud code") doesn't carry this risk
    /// the same way — collision with a common *phrase* is far less likely
    /// than with a common single word — so only single words are checked.
    private static func isUsefulMapping(heard: String, intended: String) -> Bool {
        guard heard.count >= 2, !intended.isEmpty,
              heard.lowercased() != intended.lowercased()
        else { return false }
        if !heard.contains(" "), HarperChecker.isKnownEnglishWord(heard) {
            return false
        }
        return true
    }

    // MARK: - Self test

    static func runSelfTest() -> Bool {
        let cases: [(original: String, corrected: String,
                     expected: [(String, String)])] = [
            ("Send it to Soren today.", "Send it to Søren today.",
             [("Soren", "Søren")]),
            ("The base ten pipeline is fast.", "The Baseten pipeline is fast.",
             [("base ten", "Baseten")]),
            ("Hello world.", "Hello world.", []),
            ("I met so ren and Anna.", "I met Søren and Anna.",
             [("so ren", "Søren")]),
            // Regression case for the audit in `isUsefulMapping`'s doc
            // comment: a one-word diff against an ordinary English word
            // ("team") must not be learned as a correction, unlike the
            // proper-noun cases above.
            ("I need a new team.", "I need a new theme.", []),
        ]
        var passed = true
        for testCase in cases {
            let got = extractCorrections(
                original: testCase.original, corrected: testCase.corrected)
            let ok = got.count == testCase.expected.count
                && zip(got, testCase.expected).allSatisfy {
                    $0.0.heard == $0.1.0 && $0.0.intended == $0.1.1
                }
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): diff(\"\(testCase.original)\" → " +
                  "\"\(testCase.corrected)\") = \(got)")
        }

        func check(_ ok: Bool, _ label: String) {
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): \(label)")
        }

        // personalFuzzyTargets: a real proper-noun correction becomes a
        // fuzzy target at the strict personal floor.
        let basetenTargets = personalFuzzyTargets(from: [("base ten", "Baseten")])
        check(basetenTargets["Baseten"] == personalFuzzyMatchThreshold,
              "personalFuzzyTargets includes a taught proper noun")

        // Dedup is case-insensitive: two corrections that taught the same
        // name in different casing shouldn't produce two separate targets.
        let dedupedTargets = personalFuzzyTargets(
            from: [("x1", "Søren"), ("x2", "søren")])
        check(dedupedTargets.count == 1,
              "personalFuzzyTargets dedups an intended term case-insensitively")

        // A single-word `intended` that's itself an ordinary English word
        // is excluded, mirroring `isUsefulMapping`'s own check on the
        // `heard` side — this is a synthetic pair (not one `add()` would
        // necessarily produce) constructed specifically to exercise that
        // guard directly.
        check(personalFuzzyTargets(from: [("wispr", "whisper")]).isEmpty,
              "personalFuzzyTargets excludes an ordinary-dictionary-word intended term")

        // End-to-end: this is the mechanism `apply(in:includeDeveloperVocabulary:)`
        // now runs unconditionally, so a name the user taught Murmur gets
        // fuzzy-rescued in *any* app — an email, an article, anywhere —
        // not only in a developer context. "Basetin"/"Basten" are
        // realistic near-miss spellings of "Baseten" (0.857 similar,
        // computed directly) clearing the 0.85 floor.
        for variant in ["Basetin", "Basten"] {
            let result = DeveloperVocabulary.fuzzyCorrect(
                in: "we moved inference to \(variant)", against: basetenTargets)
            check(result == "we moved inference to Baseten",
                  "personal fuzzy match rescues \(variant.debugDescription) outside developer mode")
        }

        // Known, deliberate limit: the strict 0.85 floor means a short
        // name's near-miss spelling ("Soren" for "Søren", 0.800 computed)
        // is *not* fuzzy-rescued — only an exact previously-taught spelling
        // is, via the exact-phrase pass above. This is intentional, not an
        // oversight: real different given names commonly measure in this
        // same 0.75-0.80 band against each other (checked "Erik"/"Eric"
        // 0.750, "Karen"/"Karin" 0.800, "Jon"/"John" 0.750) — a floor loose
        // enough to catch "Soren" would just as readily rewrite someone's
        // *other*, correctly-heard "Loren" or "Karin" into the wrong
        // taught name, silently. Short personal names get real fuzzy
        // tolerance from the exact-phrase list growing as the user
        // corrects more variants over time, not from this floor.
        let sorenTargets = personalFuzzyTargets(from: [("so ren", "Søren")])
        check(DeveloperVocabulary.fuzzyCorrect(in: "I saw Soren yesterday", against: sorenTargets)
              == "I saw Soren yesterday",
              "personal fuzzy floor deliberately leaves a short name's near-miss uncaught")

        // Entries are read back clean, and History edits only teach real mishearings.
        for (raw, clean) in [("Murmur.", "Murmur"), (" Wispr Flow, ", "Wispr Flow"), ("U.S.", "U.S."),
                             ("whisper.cpp", "whisper.cpp"), ("UI/UX", "UI/UX"), ("Really?!", "Really")] {
            check(cleanedTerm(raw) == clean, "a term is kept as \"\(clean)\", not \"\(raw)\"")
        }
        check(extractCorrections(original: "Please check the revenue cut dashboard.",
                                 corrected: "Please check the RevenueCat dashboard.").first?.intended == "RevenueCat",
              "a real mishearing is still learned from a History edit")
        check(extractCorrections(original: "Apart from that and then through the website we launch.",
                                 corrected: "Apart from that from Chat website we launch.").isEmpty,
              "an unrelated rewording is not learned as a mishearing")
        check(extractCorrections(original: "We launch Mormore today.", corrected: "We launch Murmur. today.")
                .first?.intended == "Murmur", "a learned spelling never keeps a full stop")
        // A name spelled unlike it sounds, corrected in place — and the edits that only look like one.
        for (original, corrected, intended) in [
            ("Thanks Neve, here is the agenda.", "Thanks Niamh, here is the agenda.", "Niamh"),
            ("Ask Eefa about the invoice.", "Ask Aoife about the invoice.", "Aoife"),
            ("I met Keeva yesterday.", "I met Caoimhe yesterday.", "Caoimhe"),
        ] {
            check(extractCorrections(original: original, corrected: corrected).first?.intended == intended,
                  "a name spelled unlike it sounds is learned: \(intended)")
        }
        for (original, corrected, why) in [
            ("Thanks Neve, here is the agenda.", "Thanks Dmitri, here is the agenda.", "a different opening sound"),
            ("Thanks Neve, here is the agenda.", "Thanks Niamh, here is the plan.", "more than one word changed"),
            ("Thanks Neve, here is the agenda.", "Thanks niamh, here is the agenda.", "no capital"),
            ("Thanks never, here is the agenda.", "Thanks Niamh, here is the agenda.", "an ordinary word heard"),
            ("Thanks Neve, here is the agenda.", "Thanks Nobody, here is the agenda.", "an ordinary word written"),
        ] {
            check(extractCorrections(original: original, corrected: corrected).isEmpty,
                  "…but not learned from an edit with \(why)")
        }
        func matches(_ heard: String, _ text: String) -> Bool {
            text.range(of: flexiblePattern(for: heard), options: .regularExpression) != nil
        }
        check(matches("Whisperflow", "I tested Whisper Flow today") && matches("Whisperflow", "a whisper-flow test"),
              "a taught mishearing still matches when split into two words")
        check(matches("revenue cut", "check revenuecut now"), "…or joined into one")
        check(!matches("Whisperflow", "whisper flowchart") && !matches("IIS", "and i is here"),
              "but never inside a longer word, or across a gap in a short one")
        let everyday: (String) -> Bool = {
            ["for", "action", "correction", "the", "army", "is", "still", "are", "we", "base", "ten", "par", "key",
             "team"].contains($0)
        }
        check(isRewording(heard: "For action", intended: "Correction", isKnownWord: everyday)
              && isRewording(heard: "the army is still", intended: "are we", isKnownWord: everyday),
              "ordinary words swapped for ordinary words are a rewording, never learned")
        check(!isRewording(heard: "par key", intended: "Parakeet", isKnownWord: everyday)
              && !isRewording(heard: "base ten", intended: "Baseten", isKnownWord: everyday)
              && !isRewording(heard: "1030", intended: "10:30", isKnownWord: everyday)
              && !isRewording(heard: "Mormo", intended: "team", isKnownWord: everyday),
              "…while a misheard name, a number or an unknown heard word still is")
        let known: (String) -> Bool = { ["murmur", "gemini", "app"].contains($0) }
        check(enforceCasing(in: "PlanRify and revenuecat on IOS", terms: ["Planrify", "RevenueCat", "iOS"], isKnownWord: known)
              == "Planrify and RevenueCat on iOS", "names come out spelled the user's way")
        check(enforceCasing(in: "a murmur in the room, Gemini", terms: ["Murmur", "gemini", "dmg"], isKnownWord: known)
              == "a murmur in the room, Gemini", "everyday words and lowercase terms are left as they are")
        return passed
    }
}

/// Web addresses and emails in a dictation ("murmurmac.com", "www.example.co.uk", "jane@example.com"), swapped for
/// placeholders while word corrections run and put back after, so a correction can never change part of one.
enum ProtectedSpans {
    static let topLevelDomains = "com|org|net|io|co|uk|dev|app|ai|me|lv|de|eu|us|info|so|sh|xyz|tech|design|studio"
    private static let pattern = "(?i)(?:[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)+)"
        + "|(?:\\b(?:https?://)?(?:[A-Za-z0-9-]+\\.)+(?:" + topLevelDomains + ")\\b(?:/[^\\s]*)?)"

    static func mask(_ text: String) -> (String, (String) -> String) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return (text, { $0 }) }
        var spans: [String] = []
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            spans.insert(String(result[range]), at: 0)
            result.replaceSubrange(range, with: "\u{E000}\u{E001}")
        }
        guard !spans.isEmpty else { return (text, { $0 }) }
        return (result, { masked in
            var restored = masked
            for span in spans {
                guard let range = restored.range(of: "\u{E000}\u{E001}") else { break }
                restored.replaceSubrange(range, with: span)
            }
            return restored
        })
    }
}

