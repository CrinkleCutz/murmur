import Foundation

/// A deterministic check on the on-device cleanup pass: keeps the edits that
/// pass is *for* and reverts the ones it isn't, edit by edit.
///
/// The cleanup model is asked to remove filler, resolve self-corrections, fix
/// grammar and punctuate — and a small on-device model does those things, but
/// it also does others nobody asked for. Measured on real transcripts it
/// swapped synonyms ("important" → "crucial"), Americanized "colour" and
/// "organisation", expanded "env" to "environment", dropped "I think" and
/// "had", and — worst — *answered* short fragments and questions instead of
/// editing them: "The future of work." came back as a three-sentence essay,
/// and "What the future means." as "Future means something different for
/// everyone…". Prompt wording alone never closed this (four rounds are
/// documented in `RewriteEngine.edit`; the fifth reproduced with and without
/// the Voice Profile), and the old backstop — reject output more than
/// `max(3×, +80 chars)` longer than the input — let a 98-character answer
/// through for a 22-character dictation.
///
/// So the model's output is treated as a *proposal*. The words it changed are
/// found with a word-level diff against the text that went in, and every
/// changed stretch is classified:
///
///  - kept: punctuation and casing (invisible to the diff), spoken filler and
///    stutters, a grammar fix (their/there, its/it's, could of → could have, verb
///    inflection, a/an, pronoun case), re-spacing or hyphenation of the same
///    letters, and the repair of a word that isn't a word at all;
///  - reverted in place: a substituted word, an invented word, a dropped word,
///    a dialect flip — the original wording goes back in, and the good edits
///    around it stay.
///
/// If too much is reverted the model has clearly stopped editing and started
/// writing, and the whole output is discarded in favour of the input.
///
/// Self-corrections ("5pm, actually 6pm") are resolved first, deterministically, by
/// `SelfCorrectionResolver`. For the ones its rules don't cover, the model may still
/// merge the correction in place — and this guard lets exactly that through: the
/// replaced half of a correction next to a strong cue ("no wait", "I mean", "sorry",
/// "make that", "scratch that"…) may be dropped — besides filler, the only words the
/// model is allowed to delete. A bare "actually" is not a cue.
///
/// Only meaningful for the plain cleanup pass ("As spoken"): a Style or a
/// Template is *supposed* to change the wording, so those don't go through
/// here. The rules above are English (they consult an English dictionary).
/// The other languages the clean-up runs in (`CleanupLanguage`) get a stricter
/// set with no dictionary at all: filler, stutters, punctuation and capitals,
/// an article swapped for another, a word ending or an accent fixed — every
/// other changed, added or dropped word goes back.
enum LLMEditGuard {

    struct Verdict {
        /// What to use: the model's output with unsafe edits reverted, or
        /// the untouched input when the whole pass was discarded.
        let text: String
        /// Changed stretches that were put back the way the speaker said them.
        let revertedEdits: Int
        /// The model rewrote so much that none of its output was trusted.
        let discarded: Bool
        /// One line per reverted edit. For the CLI only — these contain the
        /// user's words, so the app itself only ever logs the counts.
        let notes: [String]
    }

    /// Beyond this many reverted edits, or this share of the input's words
    /// reverted, the output is thrown away entirely.
    private static let maxRevertedEdits = 4
    private static let maxRevertedFraction = 0.25

    // MARK: - Public entry points

    /// `known` answers "is this an ordinary word?" (lowercased input) — the
    /// app passes Harper's dictionary. `vocabulary` is the user's own terms
    /// and developer vocabulary, lowercased single words, which count as
    /// known too.
    static func apply(
        original: String, edited: String,
        vocabulary: Set<String> = [],
        language: CleanupLanguage.Rules? = nil,
        known: @escaping (String) -> Bool = HarperChecker.isKnownEnglishWord
    ) -> Verdict {
        Checker(known: known, vocabulary: vocabulary, strict: language).apply(original: original, edited: edited)
    }

    /// Single lowercased words out of Murmur's term list (developer terms,
    /// personal dictionary, learned corrections), split the same way the
    /// guard tokenizes so "Next.js" contributes "next" and "js".
    static func vocabularyWords(from terms: [String]) -> Set<String> {
        var words = Set<String>()
        for term in terms {
            for token in tokenize(Array(term)) { words.insert(token.norm) }
        }
        return words
    }

    /// Dictations this long or longer always go to the model.
    ///
    /// Measured over 760 samples of the real cleanup call: it answered or
    /// elaborated on 5.1% of inputs of 1–3 words and 7.3% of 4–5 words
    /// ("The future of work." → an essay, "So basically." → "I'm not sure
    /// what you're asking, but I'll try to help"), then 0.7% at 6–7 words and
    /// 0 of 99 at 8 or more. Every change it made to a *clean* 5-word-or-
    /// shorter input was one of those leaks or a wording swap
    /// ("deploy" → "deployment", a dropped "I think") — never an improvement.
    /// The grammar fixes it does make well ("results was" → "results were",
    /// "John and I" → "John and me") are all in sentences of 6+ words.
    static let alwaysRunsAtWords = 6

    /// Whether the pass is worth running at all. A short dictation with
    /// nothing for the model to do — no filler, no repeated word, no
    /// unrecognised word — can only get worse, and
    /// short fragments are exactly what the model likes to "continue".
    /// Skipping saves the ~1s round-trip too. Longer dictations always run:
    /// the model earns its keep there (grammar, garbled words), and the
    /// guard is what protects the words.
    static func hasCleanupWork(
        _ text: String, vocabulary: Set<String> = [],
        language: CleanupLanguage.Rules? = nil,
        known: @escaping (String) -> Bool = HarperChecker.isKnownEnglishWord
    ) -> Bool {
        let checker = Checker(known: known, vocabulary: vocabulary, strict: language)
        let words = tokenize(Array(text)).map(\.norm)
        guard !words.isEmpty else { return false }
        if let language {
            // No dictionary to spot a garbled word: a short one is worth it only for filler or a stutter.
            if words.count >= alwaysRunsAtWords { return true }
            return words.indices.contains { index in
                language.fillers.contains(words[index])
                    || (index > 0 && words[index - 1] == words[index] && !language.doubles.contains(words[index]))
            }
        }
        if words.count >= alwaysRunsAtWords || containsCorrectionCue(words) { return true }
        for (index, word) in words.enumerated() {
            if fillers.contains(word) { return true }
            if index > 0, words[index - 1] == word, !legitimateDoubles.contains(word) { return true }
            if index > 0, fillerPhrases.contains(where: { $0[0] == words[index - 1] && $0[1] == word }) {
                return true
            }
            // A word the dictionary has never seen is a candidate garble the
            // model may repair ("bezerr" → "be there"). Numbers aren't words.
            if !word.contains(where: \.isNumber), !checker.isKnown(word) { return true }
        }
        return false
    }

    // MARK: - Tables

    private static let fillers: Set<String> = [
        "um", "uh", "uhm", "umm", "er", "erm", "ah", "eh", "hmm", "hm", "mm", "mmm", "like"]
    private static let fillerPhrases: [[String]] = [["you", "know"], ["i", "mean"]]
    /// Words that are legitimately said twice in a row ("I had had enough").
    private static let legitimateDoubles: Set<String> = ["had", "that"]
    /// The phrases that mark a spoken self-correction — the usual editing terms, plus "no actually". A bare "actually",
    /// "rather" or "wait" is deliberately NOT here: they are ordinary words, and
    /// letting the model drop words beside them wrongly cut "Friday, actually Monday too" and "3 kids, actually 2 boys
    /// and 1 girl". "no weight" is how recognizers routinely mishear "no wait".
    private static let correctionCues: [[String]] = [
        ["scratch", "that"], ["strike", "that"], ["forget", "that"], ["delete", "that"], ["no", "wait"], ["wait", "no"],
        ["no", "weight"], ["no", "actually"], ["actually", "no"], ["i", "mean"], ["i", "meant"], ["make", "that"],
        ["or", "rather"], ["correction"], ["sorry"]]

    /// Start and end (exclusive) of every correction cue in the words.
    private static func correctionCueRanges(in words: [String]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        for i in words.indices {
            for cue in correctionCues where i + cue.count <= words.count && Array(words[i..<i + cue.count]) == cue {
                ranges.append(i..<i + cue.count)
            }
        }
        return ranges
    }

    static func containsCorrectionCue(_ words: [String]) -> Bool { !correctionCueRanges(in: words).isEmpty }

    /// The most words a self-correction may drop on either side of its cue: the retracted phrase before it, the
    /// restated frame ("do that", "I'll send it on the") after it.
    private static let maxRetractedWords = 8

    private static let insertableWords: Set<String> = ["the", "a", "an", "and", "to", "of"]
    private static let maxInsertedWords = 2
    private static let functionWords: Set<String> = [
        "the", "a", "an", "to", "of", "and", "in", "on", "at", "for", "is", "are", "was", "were",
        "it", "that", "you", "we", "i", "he", "she", "they"]
    /// The dictionary lists fragments like "se" and "de" as words; of the
    /// one- and two-letter strings, only these are real English.
    private static let shortWords: Set<String> = [
        "a", "i", "am", "an", "as", "at", "be", "by", "do", "go", "he", "hi", "if", "in", "is", "it",
        "me", "my", "no", "of", "oh", "ok", "on", "or", "so", "to", "up", "us", "we"]

    private static let confusionSets: [Set<String>] = [
        ["their", "there", "they're"], ["its", "it's"], ["your", "you're"], ["then", "than"],
        ["to", "too", "two"], ["whose", "who's"], ["affect", "effect"], ["accept", "except"],
        ["lose", "loose"], ["were", "where", "we're"], ["weather", "whether"], ["here", "hear"],
        ["know", "no"], ["new", "knew"], ["write", "right"], ["sight", "site", "cite"],
        ["bare", "bear"], ["principal", "principle"], ["stationary", "stationery"],
        ["advice", "advise"], ["compliment", "complement"], ["quiet", "quite"], ["of", "have"],
        ["by", "buy"], ["our", "hour"],
    ]
    private static let irregularLemmas: [Set<String>] = [
        ["is", "are", "was", "were", "am", "be", "been", "being"], ["do", "does", "did", "done", "doing"],
        ["have", "has", "had", "having"], ["go", "goes", "went", "gone", "going"],
        ["see", "saw", "seen", "sees", "seeing"], ["write", "wrote", "written", "writes", "writing"],
        ["take", "took", "taken", "takes", "taking"], ["give", "gave", "given", "gives", "giving"],
        ["come", "came", "comes", "coming"], ["run", "ran", "runs", "running"],
        ["eat", "ate", "eaten", "eats", "eating"], ["begin", "began", "begun", "begins", "beginning"],
        ["say", "said", "says", "saying"], ["make", "made", "makes", "making"],
        ["know", "knew", "known", "knows", "knowing"], ["get", "got", "gets", "gotten", "getting"],
        ["buy", "bought", "buys", "buying"], ["think", "thought", "thinks", "thinking"],
        ["don't", "doesn't", "didn't"], ["isn't", "aren't", "wasn't", "weren't"],
        ["haven't", "hasn't", "hadn't"],
    ]
    private static let pronounPairs: [Set<String>] = [
        ["i", "me"], ["he", "him"], ["she", "her"], ["we", "us"], ["they", "them"], ["who", "whom"]]
    private static let modals: Set<String> = ["could", "would", "should", "might", "must"]

    // British ↔ American spelling. The recognizers already Americanize on
    // their own; the cleanup model must not add a second flip, in either
    // direction, so these pairs are never a legitimate edit.
    private static let dialectWords: [String: String] = [
        "grey": "gray", "plough": "plow", "tyre": "tire", "aluminium": "aluminum",
        "programme": "program", "cheque": "check", "mum": "mom", "jewellery": "jewelry",
        "pyjamas": "pajamas", "sceptical": "skeptical", "storey": "story", "kerb": "curb",
        "licence": "license", "licences": "licenses", "defence": "defense", "defences": "defenses",
        "offence": "offense", "offences": "offenses"]
    private static let notBritishSpelling: Set<String> = [
        "hour", "four", "your", "our", "tour", "pour", "sour", "flour", "scour", "dour", "devour",
        "detour", "contour", "course", "source", "resource", "journey"]
    private static let americanRules: [(NSRegularExpression, String)] = {
        let rules: [(String, String)] = [
            ("^(.+)our(s|ed|ing|ful|less|able|ite|ites)?$", "$1or$2"),
            ("^(.+)is(ation|ations|e|es|ed|ing|er|ers)$", "$1iz$2"),
            ("^(.+)yse(s|d)?$", "$1yze$2"),
            ("^(.+)(t|b)re(s)?$", "$1$2er$3"),
            ("^(.+)elled$", "$1eled"),
            ("^(.+)elling$", "$1eling"),
            ("^(.+)ence$", "$1ense"),
            ("^(.+)ogue(s)?$", "$1og$2"),
        ]
        return rules.compactMap { pattern, template in
            (try? NSRegularExpression(pattern: pattern)).map { ($0, template) }
        }
    }()

    // MARK: - Tokenizing

    struct Token {
        let text: String
        let norm: String
        /// Character offsets into the string it came from.
        let start: Int
        let end: Int
    }

    private static func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber }
    private static func isApostrophe(_ c: Character) -> Bool { c == "'" || c == "\u{2019}" }

    /// Words, including contractions ("don't") and hyphenated compounds
    /// ("double-check") as single tokens. Punctuation, spacing and case play
    /// no part in the comparison.
    static func tokenize(_ chars: [Character]) -> [Token] {
        var tokens: [Token] = []
        let n = chars.count
        var i = 0
        while i < n {
            guard isWordCharacter(chars[i]) else { i += 1; continue }
            var j = i
            func consumeRun() { while j < n, isWordCharacter(chars[j]) { j += 1 } }
            consumeRun()
            while j + 1 < n, isWordCharacter(chars[j + 1]), isApostrophe(chars[j]) || chars[j] == "-" {
                j += 1
                consumeRun()
            }
            let text = String(chars[i..<j])
            tokens.append(Token(text: text, norm: normalize(text), start: i, end: j))
            i = j
        }
        return tokens
    }

    static func normalize(_ word: String) -> String {
        word.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
    }

    /// Both spelled with the same letters once hyphens, apostrophes and
    /// spaces are ignored.
    private static func squash(_ word: String) -> String {
        String(normalize(word).filter { $0 != "-" && $0 != "'" && $0 != " " })
    }

    private static func stem(_ word: String) -> String {
        for suffix in ["ing", "ed", "es", "s", "d"] where word.hasSuffix(suffix) {
            if word.count - suffix.count >= 3 { return String(word.dropLast(suffix.count)) }
        }
        return word
    }

    private static func american(_ word: String) -> String {
        if notBritishSpelling.contains(word) { return word }
        let range = NSRange(word.startIndex..., in: word)
        for (regex, template) in americanRules where regex.firstMatch(in: word, range: range) != nil {
            let candidate = regex.stringByReplacingMatches(in: word, range: range, withTemplate: template)
            if candidate != word { return candidate }
        }
        return dialectWords[word] ?? word
    }

    /// Spellings a rewrite moved to the other side of the Atlantic, put back the way the text had them: a note that
    /// says "licences" and "colour" doesn't come back with "licenses" and "color", nor the other way round.
    static func keepingDialect(of original: String, in output: String) -> String {
        func words(_ text: String) -> [String] { text.split { !$0.isLetter }.map { $0.lowercased() } }
        let had = Set(words(original))
        var theirs: [String: String] = [:]
        for word in had { let flipped = american(word); if flipped != word, !had.contains(flipped) { theirs[flipped] = word } }
        for word in Set(words(output)) where !had.contains(word) {
            let flipped = american(word)
            if flipped != word, had.contains(flipped) { theirs[word] = flipped }
        }
        var result = output
        for (written, wanted) in theirs {
            let pattern = "(?<!\\p{L})\(NSRegularExpression.escapedPattern(for: written))(?!\\p{L})"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let source = result as NSString
            for match in regex.matches(in: result, range: NSRange(location: 0, length: source.length)).reversed() {
                let found = source.substring(with: match.range)
                let capital = found.first?.isUppercase == true
                result = (result as NSString).replacingCharacters(
                    in: match.range, with: capital ? wanted.prefix(1).uppercased() + wanted.dropFirst() : wanted)
            }
        }
        return result
    }

    private static func isDialectPair(_ a: String, _ b: String) -> Bool {
        let a = a.lowercased(), b = b.lowercased()
        return a != b && (american(a) == b || american(b) == a)
    }

    /// 1 − (edit distance ÷ longer length): how alike two spellings are.
    private static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        let n = x.count, m = y.count
        if max(n, m) == 0 { return 1.0 }
        var previous = Array(0...m)
        for i in stride(from: 1, through: n, by: 1) {
            var current = [Int](repeating: 0, count: m + 1)
            current[0] = i
            for j in stride(from: 1, through: m, by: 1) {
                current[j] = min(previous[j] + 1, current[j - 1] + 1,
                                 previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return 1 - Double(previous[m]) / Double(max(n, m))
    }

    // MARK: - Word-level diff

    private struct Hunk {
        let isEqual: Bool
        let aLow: Int, aHigh: Int, bLow: Int, bHigh: Int
    }

    /// Longest-common-subsequence diff over normalized words, with a fixed
    /// tie-break so the result is reproducible run to run (and identical to
    /// the prototype this was validated with). nil if the inputs are too
    /// long to diff cheaply — the caller then trusts nothing.
    private static func diff(_ a: [String], _ b: [String]) -> [Hunk]? {
        let n = a.count, m = b.count
        guard (n + 1) * (m + 1) <= 25_000_000 else { return nil }
        let width = m + 1
        var table = [Int32](repeating: 0, count: (n + 1) * width)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i * width + j] = a[i] == b[j]
                    ? table[(i + 1) * width + j + 1] + 1
                    : max(table[(i + 1) * width + j], table[i * width + j + 1])
            }
        }
        var hunks: [Hunk] = []
        func append(equal: Bool, _ aLow: Int, _ aHigh: Int, _ bLow: Int, _ bHigh: Int) {
            if let last = hunks.last, last.isEqual == equal {
                hunks[hunks.count - 1] = Hunk(
                    isEqual: equal, aLow: last.aLow, aHigh: max(last.aHigh, aHigh),
                    bLow: last.bLow, bHigh: max(last.bHigh, bHigh))
            } else {
                hunks.append(Hunk(isEqual: equal, aLow: aLow, aHigh: aHigh, bLow: bLow, bHigh: bHigh))
            }
        }
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, a[i] == b[j] {
                append(equal: true, i, i + 1, j, j + 1); i += 1; j += 1
            } else if j < m, i == n || table[i * width + j + 1] >= table[(i + 1) * width + j] {
                append(equal: false, i, i, j, j + 1); j += 1
            } else {
                append(equal: false, i, i + 1, j, j); i += 1
            }
        }
        return hunks
    }

    // MARK: - The checker

    private struct Checker {
        let known: (String) -> Bool
        let vocabulary: Set<String>
        /// Another language's rules: the stricter check, no dictionary.
        var strict: CleanupLanguage.Rules?

        /// Another language: the same word, its accents fixed, an article swapped, or an ending changed (one word a
        /// prefix of the other, at least four letters shared, at most two letters different) — "Kunde" → "Kunden",
        /// "den" → "dem", "esta" → "está". Not "revois" → "reçoive", not "mandarmi" → "mandare".
        func isStrictSubstitution(old: String, new: String, rules: CleanupLanguage.Rules) -> Bool {
            let o = LLMEditGuard.normalize(old), n = LLMEditGuard.normalize(new)
            if o == n || LLMEditGuard.squash(o) == LLMEditGuard.squash(n) { return true }
            if o.folding(options: .diacriticInsensitive, locale: nil) == n.folding(options: .diacriticInsensitive, locale: nil) {
                return true
            }
            if rules.articles.contains(o), rules.articles.contains(n) { return true }
            if (o + n).contains(where: \.isNumber) { return false }
            let (short, long) = o.count <= n.count ? (o, n) : (n, o)
            return short.count >= 4 && long.hasPrefix(short) && long.count - short.count <= 2
        }

        func isKnown(_ word: String) -> Bool {
            let w = LLMEditGuard.normalize(word)
            if vocabulary.contains(w) { return true }
            if w.count <= 2 { return LLMEditGuard.shortWords.contains(w) }
            if w.contains("-") {
                return w.split(separator: "-").allSatisfy { isKnown(String($0)) }
            }
            return known(w)
        }

        /// Is replacing one word with another a legitimate edit?
        func isSafeSubstitution(old: String, new: String, previous: String, oldRaw: String) -> Bool {
            if let strict { return isStrictSubstitution(old: old, new: new, rules: strict) }
            let o = LLMEditGuard.normalize(old), n = LLMEditGuard.normalize(new)
            if o == n { return true }
            if LLMEditGuard.isDialectPair(o, n) { return false }
            if LLMEditGuard.squash(o) == LLMEditGuard.squash(n) { return true }
            if LLMEditGuard.confusionSets.contains(where: { $0.contains(o) && $0.contains(n) }) {
                if o == "of", n == "have" { return LLMEditGuard.modals.contains(previous) }
                if o == "have", n == "of" { return false }
                return true
            }
            if LLMEditGuard.irregularLemmas.contains(where: { $0.contains(o) && $0.contains(n) }) { return true }
            let stemmed = LLMEditGuard.stem(o)
            if stemmed == LLMEditGuard.stem(n), stemmed.count >= 3 { return true }
            if (o == "a" && n == "an") || (o == "an" && n == "a") { return true }
            if LLMEditGuard.pronounPairs.contains(where: { $0.contains(o) && $0.contains(n) }) { return true }
            // Repair of a word that isn't a word (never one the speaker
            // really said): a real, similar word, or a small function word
            // in its slot ("bezerr" → "be there").
            if !isKnown(o), !(o + n).contains(where: \.isNumber) {
                if LLMEditGuard.functionWords.contains(n), o.count <= 6 { return true }
                let needed = (oldRaw.first?.isLowercase ?? true) ? 0.5 : 0.75
                if isKnown(n), LLMEditGuard.similarity(o, n) >= needed { return true }
            }
            return false
        }

        /// Several words replaced by a different number of words: only
        /// re-spacing or hyphenation of the same letters ("set up" ↔
        /// "setup", "double check" → "double-check"), or a tiny spelling
        /// repair into real words.
        func isAllowedReplacement(old: [String], new: [String]) -> Bool {
            let so = LLMEditGuard.squash(old.joined()), se = LLMEditGuard.squash(new.joined())
            // Another language: only re-spacing or hyphenation of the very same letters.
            if strict != nil { return so == se }
            let oldParts = old.flatMap { LLMEditGuard.normalize($0).split(separator: "-").map(String.init) }
            let newParts = new.flatMap { LLMEditGuard.normalize($0).split(separator: "-").map(String.init) }
            for a in oldParts { for b in newParts where LLMEditGuard.isDialectPair(a, b) { return false } }
            if LLMEditGuard.isDialectPair(so, se) { return false }
            if so != se {
                // A spelling repair has to start from something that isn't a
                // word ("sheetplease" → "sheet please"); real words turning
                // into other real words is rewording ("don't" → "do not").
                return old.contains { !isKnown($0) }
                    && new.allSatisfy { isKnown($0) }
                    && !(so + se).contains(where: \.isNumber)
                    && LLMEditGuard.similarity(so, se) >= 0.6
            }
            // "double check" → "doublecheck" is not a word.
            if new.count == 1, !new[0].contains("-"), !isKnown(new[0]) { return false }
            return true
        }

        func isAllowedDeletion(_ span: [String], in words: [String], low: Int, high: Int) -> Bool {
            if let strict {
                // Another language: its own filler sounds, or a stutter — nothing else may go.
                if span.allSatisfy({ strict.fillers.contains($0) }) { return true }
                let k = span.count
                let following = Array(words[high..<min(words.count, high + k)])
                let preceding = Array(words[max(0, low - k)..<low])
                return (span == following || span == preceding) && !(k == 1 && strict.doubles.contains(span[0]))
            }
            if span.allSatisfy({ LLMEditGuard.fillers.contains($0) }) { return true }
            if span.count == 2, LLMEditGuard.fillerPhrases.contains(span) { return true }
            let k = span.count
            let following = Array(words[high..<min(words.count, high + k)])
            let preceding = Array(words[max(0, low - k)..<low])
            if span == following || span == preceding,
               !(k == 1 && LLMEditGuard.legitimateDoubles.contains(span[0])) {
                return true   // a stutter or repeated phrase
            }
            // The replaced half of a self-correction — the one deletion besides filler that is allowed. It is the
            // stretch that comes BEFORE a strong correction cue, so it must hold real words ahead of the cue and run
            // through it; a stretch that merely starts with "sorry for the delay" or "I mean it" is not one. The repair
            // itself must survive (something is left after the dropped stretch), and both halves stay phrase-sized, so
            // a benign "I mean" in a long sentence can't license deleting half of it. `SelfCorrectionResolver` has
            // already resolved every clear case before the model runs; this lets the model's own in-place merge through
            // for the rest ("…on the Friday 5pm, no, actually do that Tuesday 5pm." → "…on the Tuesday 5pm.").
            return LLMEditGuard.correctionCueRanges(in: words).contains { cue in
                low < cue.lowerBound && cue.upperBound <= high && high < words.count
                    && cue.lowerBound - low <= LLMEditGuard.maxRetractedWords
                    && high - cue.upperBound <= LLMEditGuard.maxRetractedWords
            }
        }

        private enum RevertKind: Int { case resub = 0, uninsert = 1, undelete = 2 }
        private struct Revert {
            let kind: RevertKind
            let aLow: Int, aHigh: Int, bLow: Int, bHigh: Int
        }

        func apply(original: String, edited: String) -> Verdict {
            let originalChars = Array(original), editedChars = Array(edited)
            let a = LLMEditGuard.tokenize(originalChars), b = LLMEditGuard.tokenize(editedChars)
            let aWords = a.map(\.norm), bWords = b.map(\.norm)
            guard let hunks = LLMEditGuard.diff(aWords, bWords) else {
                return Verdict(text: original, revertedEdits: 0, discarded: true,
                               notes: ["too long to verify"])
            }

            var reverts: [Revert] = []
            var notes: [String] = []
            var rejectedWords = 0
            var rejectedEdits = 0
            func reject(_ revert: Revert, words: Int, _ note: String) {
                reverts.append(revert)
                rejectedEdits += 1
                rejectedWords += words
                notes.append(note)
            }

            for hunk in hunks where !hunk.isEqual {
                let o = Array(aWords[hunk.aLow..<hunk.aHigh]), e = Array(bWords[hunk.bLow..<hunk.bHigh])
                if e.isEmpty {
                    if !isAllowedDeletion(o, in: aWords, low: hunk.aLow, high: hunk.aHigh) {
                        // Another language: a stutter at the front of a longer drop ("kannst du [kannst du mir]") may
                        // still go; only the rest comes back.
                        var lead = 0
                        if strict != nil {
                            for k in stride(from: o.count - 1, through: 1, by: -1)
                            where isAllowedDeletion(Array(o[0..<k]), in: aWords, low: hunk.aLow, high: hunk.aLow + k) {
                                lead = k
                                break
                            }
                        }
                        let back = Array(o[lead...])
                        reject(Revert(kind: .undelete, aLow: hunk.aLow + lead, aHigh: hunk.aHigh,
                                      bLow: hunk.bLow, bHigh: hunk.bHigh),
                               words: back.count, "dropped \"\(back.joined(separator: " "))\"")
                    }
                } else if o.isEmpty {
                    // Another language: at most one article may be added.
                    let allowed = strict.map { rules in e.count == 1 && rules.articles.contains(e[0]) }
                        ?? (e.allSatisfy { LLMEditGuard.insertableWords.contains($0) }
                            && e.count <= LLMEditGuard.maxInsertedWords)
                    if !allowed {
                        reject(Revert(kind: .uninsert, aLow: hunk.aLow, aHigh: hunk.aHigh,
                                      bLow: hunk.bLow, bHigh: hunk.bHigh),
                               words: e.count, "added \"\(e.joined(separator: " "))\"")
                    }
                } else if o.count == e.count {
                    for t in 0..<o.count {
                        let index = hunk.aLow + t
                        let previous = index > 0 ? aWords[index - 1] : ""
                        if !isSafeSubstitution(old: o[t], new: e[t], previous: previous, oldRaw: a[index].text) {
                            reject(Revert(kind: .resub, aLow: index, aHigh: index + 1,
                                          bLow: hunk.bLow + t, bHigh: hunk.bLow + t + 1),
                                   words: 1, "\"\(o[t])\" → \"\(e[t])\"")
                        }
                    }
                } else {
                    // Another language: a stutter in front of a changed word ("puoi [puoi mandarmi]" → "mandare") —
                    // the stutter may go, and each remaining word is judged on its own.
                    if strict != nil, o.count > e.count,
                       let lead = (1..<o.count).reversed().first(where: { k in
                           o.count - k == e.count
                               && isAllowedDeletion(Array(o[0..<k]), in: aWords, low: hunk.aLow, high: hunk.aLow + k)
                       }) {
                        for t in 0..<e.count {
                            let index = hunk.aLow + lead + t
                            let previous = index > 0 ? aWords[index - 1] : ""
                            if !isSafeSubstitution(old: o[lead + t], new: e[t], previous: previous, oldRaw: a[index].text) {
                                reject(Revert(kind: .resub, aLow: index, aHigh: index + 1,
                                              bLow: hunk.bLow + t, bHigh: hunk.bLow + t + 1),
                                       words: 1, "\"\(o[lead + t])\" → \"\(e[t])\"")
                            }
                        }
                        continue
                    }
                    let oldRaw = a[hunk.aLow..<hunk.aHigh].map(\.text)
                    let newRaw = b[hunk.bLow..<hunk.bHigh].map(\.text)
                    if !isAllowedReplacement(old: oldRaw, new: newRaw) {
                        reject(Revert(kind: .resub, aLow: hunk.aLow, aHigh: hunk.aHigh,
                                      bLow: hunk.bLow, bHigh: hunk.bHigh),
                               words: max(o.count, e.count),
                               "\"\(o.joined(separator: " "))\" → \"\(e.joined(separator: " "))\"")
                    }
                }
            }

            if reverts.isEmpty { return Verdict(text: edited, revertedEdits: 0, discarded: false, notes: []) }
            if rejectedEdits > LLMEditGuard.maxRevertedEdits
                || Double(rejectedWords) / Double(max(1, aWords.count)) > LLMEditGuard.maxRevertedFraction {
                return Verdict(text: original, revertedEdits: rejectedEdits, discarded: true, notes: notes)
            }

            // Undo from the end of the text backwards so earlier offsets stay
            // valid while later ones are rewritten.
            var out = editedChars
            let ordered = reverts.enumerated().sorted { l, r in
                if l.element.bLow != r.element.bLow { return l.element.bLow > r.element.bLow }
                if l.element.kind != r.element.kind { return l.element.kind.rawValue < r.element.kind.rawValue }
                return l.offset < r.offset
            }.map(\.element)
            for revert in ordered {
                switch revert.kind {
                case .resub:
                    let start = b[revert.bLow].start, end = b[revert.bHigh - 1].end
                    out.replaceSubrange(start..<end,
                                        with: originalChars[a[revert.aLow].start..<a[revert.aHigh - 1].end])
                case .uninsert:
                    var start = b[revert.bLow].start, end = b[revert.bHigh - 1].end
                    if start > 0, out[start - 1] == " " { start -= 1 }
                    else if end < out.count, out[end] == " " { end += 1 }
                    out.removeSubrange(start..<end)
                case .undelete:
                    let text = Array(originalChars[a[revert.aLow].start..<a[revert.aHigh - 1].end])
                    if revert.bLow < b.count {
                        let position = b[revert.bLow].start
                        out.insert(contentsOf: text + [" "], at: position)
                        // The model may have capitalised the word that
                        // followed the dropped ones; give it its own case back.
                        if revert.aHigh < a.count {
                            let next = a[revert.aHigh]
                            if next.norm == b[revert.bLow].norm {
                                let from = position + text.count + 1
                                out.replaceSubrange(from..<min(out.count, from + (next.end - next.start)),
                                                    with: originalChars[next.start..<next.end])
                            }
                        }
                    } else {
                        let position = revert.bLow > 0 ? b[revert.bLow - 1].end : out.count
                        out.insert(contentsOf: [" "] + text, at: position)
                    }
                }
            }
            return Verdict(text: tidy(out), revertedEdits: rejectedEdits, discarded: false, notes: notes)
        }

        /// Collapses the double spaces and the space before punctuation that
        /// removing or restoring words can leave behind.
        private func tidy(_ chars: [Character]) -> String {
            var collapsed: [Character] = []
            for c in chars {
                if c == " ", collapsed.last == " " { continue }
                collapsed.append(c)
            }
            var result: [Character] = []
            for c in collapsed {
                if ",.;:!?".contains(c) { while result.last == " " { result.removeLast() } }
                result.append(c)
            }
            return String(result)
        }
    }

    // MARK: - Self-test

    /// Exercises the real dictionary: the model's typical over-reach must be
    /// undone and its legitimate edits must survive — including the exact
    /// dictation that came back as an invented sentence in the field.
    static func runSelfTest() -> Bool {
        var passed = true
        func check(_ ok: Bool, _ label: String) {
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): \(label)")
        }
        func run(_ original: String, _ edited: String, vocabulary: Set<String> = []) -> Verdict {
            apply(original: original, edited: edited, vocabulary: vocabulary)
        }
        func kept(_ original: String, _ edited: String, _ label: String, vocabulary: Set<String> = []) {
            let verdict = run(original, edited, vocabulary: vocabulary)
            check(verdict.text == edited && !verdict.discarded, "keeps \(label)")
        }
        func undone(_ original: String, _ edited: String, _ label: String, vocabulary: Set<String> = []) {
            let verdict = run(original, edited, vocabulary: vocabulary)
            check(verdict.text == original, "undoes \(label)")
        }

        // What the model does that nobody asked for.
        undone("What the future means.",
               "Future means something different for everyone, but it's always about growth and new possibilities.",
               "the answer that replaced a 4-word dictation (the field incident)")
        undone("The future of work.",
               "The future of work is evolving rapidly, driven by technological advancements. Companies are embracing remote work.",
               "an essay grown from a fragment")
        undone("How does this work?", "This works by sending your voice to the model, which then transcribes it.",
               "an answer to a question")
        undone("Write a poem about the sea.", "The sea is vast and blue, with waves that whisper secrets too.",
               "a poem written instead of dictated")
        undone("The colour and the organisation of the page look better.",
               "The color and the organization of the page look better.", "an Americanised spelling")
        undone("Send me the env file.", "Send me the environment file.", "an expanded abbreviation")
        undone("This is important.", "This is crucial.", "a synonym swap")
        undone("I think we should wait.", "We should wait.", "a dropped \"I think\"")
        undone("We need more time to review the design.", "We need time to review the design.",
               "a dropped content word")
        undone("I don't approve this design.", "I do not approve this design.", "an expanded contraction")
        kept("I'll send the report on the 5th, sorry, I'll send it on the 7th.", "I'll send the report on the 7th.",
             "the replaced half of a self-correction (cue: sorry)")
        kept("We can do the meeting on the Friday 5pm, no, actually do that Tuesday 5pm.", "We can do the meeting on the Tuesday 5pm.",
             "the replaced half of a self-correction (cue: no actually)")
        kept("Send it to Bob, no wait, Alice.", "Send it to Alice.", "an open-class correction the model merged")
        undone("Send it to Bob, no wait, Alice.", "Send it to.", "a correction whose repair was dropped too")
        undone("The design is fine and I think the pricing page reads well, I mean, the whole thing works.", "The whole thing works.",
               "half a sentence dropped beside a benign \"I mean\"")
        kept("We can schedule the review meeting for the Friday at 3pm, no wait, we can schedule it for Monday at 3pm.",
             "We can schedule the review meeting for Monday at 3pm.", "a restated clause merged in place")
        undone("Sorry for the delay, I was in a meeting.", "I was in a meeting.", "a dropped apology (starts with the cue)")
        undone("I mean it, this is really important.", "This is really important.", "a dropped \"I mean it\"")
        undone("I have 3 kids, actually 2 boys and 1 girl.", "I have 2 boys and 1 girl.", "a deletion beside a bare \"actually\"")
        undone("Let's not wait.", "Let's not.", "a dropped \"wait\" that wasn't a correction")
        undone("I actually enjoyed the movie.", "I enjoyed the movie.", "a stripped \"actually\"")

        // What the pass is for.
        kept("what the future means", "What the future means.", "punctuation and capitalisation")
        kept("So I think, like, we should wait.", "So I think, we should wait.", "a spoken filler")
        kept("I went to the the store yesterday.", "I went to the store yesterday.", "a stutter")
        kept("I had had enough of that.", "I had had enough of that.", "a legitimate double word")
        undone("Let's meet Friday, actually Monday too.", "Let's meet Monday too.",
               "a deletion next to \"actually\" (self-corrections belong to the resolver)")
        kept("I could of finished it.", "I could have finished it.", "could of → could have")
        kept("I went there yesterday and their was a problem.",
             "I went there yesterday and there was a problem.", "their → there")
        kept("This is faster then before.", "This is faster than before.", "then → than")
        kept("He don't know the answer.", "He doesn't know the answer.", "a verb-agreement fix")
        kept("Please double check the setup.", "Please double-check the setup.", "hyphenation")
        kept("Please open the Jithub repo.", "Please open the GitHub repo.", "a repaired garble",
             vocabulary: ["github"])
        kept("How does this work?", "How does this work?", "an unchanged question")

        // Good edits survive next to bad ones instead of being lost with them.
        let mixed = run("So I think, like, the colour is important.", "So I think, the color is important.")
        check(mixed.text == "So I think, the colour is important." && mixed.revertedEdits == 1 && !mixed.discarded,
              "keeps the filler removal while restoring \"colour\"")

        // A model that stops editing and starts writing is discarded whole.
        let rewritten = run("We should ship on Friday and tell the customers.",
                            "It would be advisable to release the product this week and notify every client promptly.")
        check(rewritten.discarded && rewritten.text == "We should ship on Friday and tell the customers.",
              "discards an output that rewrote the whole sentence")

        // No text at all from the model means nothing to trust.
        check(run("Hello there.", "").text == "Hello there.", "treats empty output as no edit")

        // Cleanup-work routing.
        check(!hasCleanupWork("What the future means."), "skips the model for a clean fragment")
        check(!hasCleanupWork("Where to watch Practical Magic?"), "skips the model for a clean question")
        check(hasCleanupWork("The results was better than expected."),
              "runs the model for a six-word dictation, where its grammar fixes are")
        check(hasCleanupWork("So, you know, what the future means."), "runs the model when there is filler")
        check(!hasCleanupWork("Meet at five, actually six."), "doesn't call the model just for a bare \"actually\"")
        check(hasCleanupWork("Tell Sam, no wait, Priya."), "does call the model for a strong correction cue")
        check(hasCleanupWork("I went to the the store."), "runs the model when a word is repeated")
        check(hasCleanupWork("Please open the Jithub repo."), "runs the model when a word isn't a word")
        check(!hasCleanupWork("Please open the Jithub repo.", vocabulary: ["jithub"]),
              "counts the user's own terms as words")

        return passed
    }
}
