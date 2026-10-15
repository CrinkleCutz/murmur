import Foundation
import whisper

// Three ways past the ~400-character limit on what Whisper is told before it listens (`WhisperPrompt`), so a saved
// word is used whether or not it fits in that sentence (2026-10-15):
//  1. `TermUsage` — which words go into the prompt is chosen per dictation: words on screen, words the user actually
//     says (recent use counts most), words just learned. Nothing is ever removed for going unused; a word that misses
//     the prompt is still saved and still used by the other two.
//  2. `AudioRescore` — the name fix's proposals, including looser ones than its spelling rules allow, are checked
//     against the audio: Whisper scores the sentence with and without the change, and only a change the audio
//     supports is kept. Uses the whole list, no limit.
//  3. `VocabularyBoost` — while Whisper writes, once it has started one of the user's words, the rest of that word
//     gets a bonus (prefix-trie biasing, the decoding-time approach in the research). Whole list, no limit.

// MARK: - 1. Choosing the prompt

enum TermUsage {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var scores: [String: Double] = [:]
    nonisolated(unsafe) private static var computedFor: (terms: Set<String>, historyStamp: Date?)?
    nonisolated(unsafe) private static var computing = false
    private static let queue = DispatchQueue(label: "local.murmur.term-usage", qos: .utility)

    /// Use counts most when recent: a use 30 days ago counts half, 60 days a quarter.
    static let halfLifeDays = 30.0
    static let windowDays = 180.0

    /// How relevant each term is to this dictation, highest first wins a place in the prompt. Computed in the
    /// background from History; until it's ready (the first dictation after launch) every term scores alike.
    static func relevance(for terms: [String], screen: [String], recentlyLearned: [String]) -> (String) -> Double {
        refreshIfNeeded(terms)
        lock.lock()
        let usage = scores
        lock.unlock()
        let onScreen = Set(screen.map { $0.lowercased() })
        let fresh = Set(recentlyLearned.map { $0.lowercased() })
        return { term in
            let key = term.lowercased()
            return (onScreen.contains(key) ? 100 : 0) + (fresh.contains(key) ? 5 : 0) + (usage[key] ?? 0)
        }
    }

    private static func refreshIfNeeded(_ terms: [String]) {
        let keys = Set(terms.map { $0.lowercased() })
        let stamp = (try? HistoryStoreFile.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        lock.lock()
        let fresh = computedFor.map { $0.terms == keys && $0.historyStamp == stamp } ?? false
        guard !fresh, !computing else { lock.unlock(); return }
        computing = true
        lock.unlock()
        queue.async {
            let computed = usageScores(terms: Array(keys), entries: HistoryStoreFile.load(), now: Date())
            lock.lock()
            scores = computed
            computedFor = (keys, stamp)
            computing = false
            lock.unlock()
        }
    }

    /// Decayed counts: each dictation that contains the term adds 0.5^(age in days / half-life).
    static func usageScores(terms: [String], entries: [(text: String, date: Date)], now: Date) -> [String: Double] {
        var out: [String: Double] = [:]
        let terms = terms.filter { $0.count > 1 }
        for entry in entries {
            let age = now.timeIntervalSince(entry.date) / 86_400
            guard age >= 0, age <= windowDays else { continue }
            let weight = pow(0.5, age / halfLifeDays)
            let lower = entry.text.lowercased()
            for term in terms where contains(lower, word: term) { out[term, default: 0] += weight }
        }
        return out
    }

    /// `term` in `text` as a whole word (not inside a longer one).
    static func contains(_ text: String, word term: String) -> Bool {
        var from = text.startIndex
        while let range = text.range(of: term, range: from..<text.endIndex) {
            let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
            let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
            if !(before.map { $0.isLetter || $0.isNumber } ?? false), !(after.map { $0.isLetter || $0.isNumber } ?? false) {
                return true
            }
            from = text.index(after: range.lowerBound)
        }
        return false
    }

    static func runSelfTest() -> Bool {
        var passed = true
        func check(_ ok: Bool, _ label: String) {
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): term usage: \(label)")
        }
        let now = Date()
        let day: TimeInterval = 86_400
        let entries: [(text: String, date: Date)] = [
            ("Deploy it to Vercel today", now), ("vercel again", now.addingTimeInterval(-30 * day)),
            ("the fiberworks plan", now.addingTimeInterval(-200 * day)), ("Supabaseish words", now)]
        let s = usageScores(terms: ["vercel", "fiberworks", "supabase"], entries: entries, now: now)
        check(abs((s["vercel"] ?? 0) - 1.5) < 0.01, "a use today counts 1, a use 30 days ago counts half")
        check(s["fiberworks"] == nil && s["supabase"] == nil, "uses older than 180 days, and parts of longer words, don't count")
        return passed
    }
}

/// History's file, read without the store (which lives on the main actor).
enum HistoryStoreFile {
    static var url: URL { AppPaths.supportDirectory.appendingPathComponent("history.json") }
    private struct Entry: Decodable { let text: String; let date: Date }
    static func load() -> [(text: String, date: Date)] {
        guard let data = try? Data(contentsOf: url), let entries = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        return entries.map { ($0.text, $0.date) }
    }
}

// MARK: - Shared: Whisper's tokens

enum WhisperTokens {
    static func tokenize(_ ctx: OpaquePointer, _ text: String) -> [whisper_token] {
        var buffer = [whisper_token](repeating: 0, count: 1024)
        let count = text.withCString { whisper_tokenize(ctx, $0, &buffer, Int32(buffer.count)) }
        return count > 0 ? Array(buffer.prefix(Int(count))) : []
    }
}

// MARK: - 2. Checking a name fix against the audio

enum AudioRescore {
    /// OFF: measured 2026-10-15 on the 150 test recordings (like-for-like proposals, audio must prefer the change):
    /// 3.34% → 3.38% errors, names 186 → 185 — it turned down a right fix (Supabase) and let a wrong one through
    /// (VoiceInk → VoiceOS). Whisper's own score of a sentence doesn't tell a name from a near-sound well enough.
    /// `MURMUR_NAMEFIX_AUDIO=1` or `defaults write local.murmur nameFixAudio -bool true` to try it.
    static var isEnabled: Bool {
        if let env = ProcessInfo.processInfo.environment["MURMUR_NAMEFIX_AUDIO"] { return env == "1" }
        return UserDefaults.standard.object(forKey: "nameFixAudio") as? Bool ?? false
    }
    /// How much more likely (in log-probability) the audio must find the changed sentence for the change to be kept.
    /// At least as likely, by default: Whisper's own decode already picked the original, so a change it now prefers is
    /// real evidence. (A tolerance the other way let shorter sentences win just for being shorter, 2026-10-15.)
    static var margin: Double {
        ProcessInfo.processInfo.environment["MURMUR_NAMEFIX_MARGIN"].flatMap(Double.init) ?? 0
    }

    /// The log-probability Whisper gives `text` for the audio it last encoded (the decode that just ran on `ctx`),
    /// with the same prompt that decode had. nil when it can't be computed.
    static func logProbability(ctx: OpaquePointer, language: String, prompt: String?, text: String) -> Double? {
        var sequence: [whisper_token] = []
        if let prompt, !prompt.isEmpty {
            sequence.append(whisper_token_prev(ctx))
            sequence += WhisperTokens.tokenize(ctx, prompt).suffix(Int(whisper_n_text_ctx(ctx) / 2) - 1)
        }
        sequence += [whisper_token_sot(ctx), whisper_token_lang(ctx, whisper_lang_id(language)),
                     whisper_token_transcribe(ctx), whisper_token_not(ctx)]
        let textStart = sequence.count
        let textTokens = WhisperTokens.tokenize(ctx, " " + text)
        guard !textTokens.isEmpty else { return nil }
        sequence += textTokens
        sequence.append(whisper_token_eot(ctx))
        guard sequence.count < Int(whisper_n_text_ctx(ctx)),
              whisper_decode(ctx, sequence, Int32(sequence.count), 0, 4) == 0,
              let logits = whisper_get_logits(ctx) else { return nil }
        let vocab = Int(whisper_n_vocab(ctx))
        var total = 0.0
        for position in (textStart - 1)..<(sequence.count - 1) {
            let row = logits.advanced(by: position * vocab)
            var maxLogit = -Float.infinity
            for i in 0..<vocab where row[i] > maxLogit { maxLogit = row[i] }
            var sum = 0.0
            for i in 0..<vocab { sum += exp(Double(row[i] - maxLogit)) }
            let next = Int(sequence[position + 1])
            total += Double(row[next] - maxLogit) - log(sum)
        }
        return total
    }

    /// The name fix's proposals for this decode — its usual ones and looser ones — each kept only if the audio supports
    /// it. Returns the corrected text and what changed, or nil when nothing did.
    static func fix(ctx: OpaquePointer, language: String, prompt: String?, text: String, words: [UnsureWordFix.Word],
                    terms: [String]) -> (text: String, changes: [(heard: String, name: String)])? {
        let strict = UnsureWordFix.replacements(in: words, terms: terms, screenNames: ScreenContext.current,
                                                ownWords: LearnedStore.personalTermKeys(),
                                                isKnownWord: HarperChecker.isKnownEnglishWord) ?? []
        let loose = UnsureWordFix.replacements(in: words, terms: terms, screenNames: ScreenContext.current,
                                               ownWords: LearnedStore.personalTermKeys(),
                                               isKnownWord: HarperChecker.isKnownEnglishWord, loose: true) ?? []
        // Like for like only: as many words out as in, and none of them already one of the names — a sentence with a
        // word dropped always scores as more likely, whatever the audio says.
        let names = Set(terms.map { UnsureWordFix.letters($0) })
        var proposals: [(words: [String], with: String)] = []
        for proposal in strict + loose where !proposals.contains(where: { $0.words == proposal.words }) {
            guard proposal.words.count == proposal.with.split(separator: " ").count,
                  !proposal.words.contains(where: { names.contains(UnsureWordFix.letters($0)) }) else { continue }
            proposals.append(proposal)
        }
        guard !proposals.isEmpty, let base = logProbability(ctx: ctx, language: language, prompt: prompt, text: text)
        else { return nil }
        var accepted: [(words: [String], with: String)] = []
        for proposal in proposals {
            guard let candidate = UnsureWordFix.apply([proposal], to: text),
                  let score = logProbability(ctx: ctx, language: language, prompt: prompt, text: candidate.text)
            else { continue }
            if ProcessInfo.processInfo.environment["MURMUR_NAMEFIX_WORDS"] != nil {
                FileHandle.standardError.write(Data(String(
                    format: "AUDIO %@ -> %@: %.2f\n", proposal.words.joined(separator: " "), proposal.with, score - base).utf8))
            }
            if score - base >= margin { accepted.append(proposal) }
        }
        return UnsureWordFix.apply(accepted, to: text)
    }
}

// MARK: - 3. Boosting the user's words while Whisper writes

final class VocabularyBoost {
    /// OFF: measured 2026-10-15 — finishing a started word (the safe half) changed nothing, Whisper finishes it anyway;
    /// a bonus for starting one cost names (186 → 178 at start 1 / continue 3, → 164 at 2 / 4) by running words
    /// together ("HUD pill" → "HUDPIL"). `MURMUR_BOOST=1` or `defaults write local.murmur vocabularyBoost -bool true`.
    static var isEnabled: Bool {
        if let env = ProcessInfo.processInfo.environment["MURMUR_BOOST"] { return env == "1" }
        return UserDefaults.standard.object(forKey: "vocabularyBoost") as? Bool ?? false
    }

    private var sequences: [[whisper_token]] = []
    private let continueBonus: Float
    private let startBonus: Float
    private let endOfText: whisper_token

    init(ctx: OpaquePointer, terms: [String]) {
        let env = ProcessInfo.processInfo.environment
        continueBonus = env["MURMUR_BOOST_CONT"].flatMap(Float.init) ?? 2.0
        startBonus = env["MURMUR_BOOST_START"].flatMap(Float.init) ?? 0
        endOfText = whisper_token_eot(ctx)
        var seen = Set<[whisper_token]>()
        for term in terms where term.count > 2 {
            for variant in [" " + term, term] {
                let tokens = WhisperTokens.tokenize(ctx, variant)
                if tokens.count >= 2, seen.insert(tokens).inserted { sequences.append(tokens) }
            }
        }
    }

    var isEmpty: Bool { sequences.isEmpty }

    /// Adds the bonuses to `logits` given the tokens written so far.
    func apply(tokens: UnsafePointer<whisper_token_data>?, count: Int32, logits: UnsafeMutablePointer<Float>) {
        var recent: [whisper_token] = []
        if let tokens, count > 0 {
            for i in max(0, Int(count) - 8)..<Int(count) where tokens[i].id < endOfText { recent.append(tokens[i].id) }
        }
        var bonus: [whisper_token: Float] = [:]
        for sequence in sequences {
            if startBonus > 0 { bonus[sequence[0]] = max(bonus[sequence[0]] ?? 0, startBonus) }
            guard !recent.isEmpty else { continue }
            for length in stride(from: min(sequence.count - 1, recent.count), through: 1, by: -1)
            where recent.suffix(length).elementsEqual(sequence.prefix(length)) {
                bonus[sequence[length]] = max(bonus[sequence[length]] ?? 0, continueBonus)
                break
            }
        }
        for (token, value) in bonus { logits[Int(token)] += value }
    }
}

/// The C callback whisper.cpp calls before each token is chosen; `user_data` is a `VocabularyBoost`.
let vocabularyBoostCallback: whisper_logits_filter_callback = { _, _, tokens, count, logits, userData in
    guard let logits, let userData else { return }
    Unmanaged<VocabularyBoost>.fromOpaque(userData).takeUnretainedValue().apply(tokens: tokens, count: count, logits: logits)
}
