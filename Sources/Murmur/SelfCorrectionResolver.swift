import Foundation

/// Resolves spoken self-corrections — "5pm, actually 6pm" → "6pm" — with a
/// deterministic pass over the speaker's own words.
///
/// Linguists split a repair into three parts: the *reparandum* (what the
/// speaker takes back), the *interregnum* (the "actually", "no wait", "I
/// mean") and the *repair* (the replacement), which is usually a rough copy of
/// the structure it replaces ("ship on Friday, actually ship on Monday").
/// This pass finds that shape and keeps only the repair.
///
/// Why not leave it to the on-device model? It was tried, and measured on the
/// exact case that matters: fed "Let's meet at 5pm, actually 6pm works better
/// for everyone." the model answered "6pm, actually 6pm" — it substituted the
/// value and left the correction words behind — and the word-preservation
/// guard correctly refused that malformed edit, so the correction was never
/// resolved. Benchmarks of LLM disfluency removal report the same family of
/// failures (models over-delete fluent words; free rewriting is the risk).
/// A rule can't hallucinate: it only ever deletes, or moves one of the
/// speaker's own values into the slot it replaces.
///
/// It acts on *structural evidence*, never on a cue word alone — Wispr Flow
/// documents the same principle ("removes only clear self-corrections; 'I
/// actually enjoyed the movie' is preserved"):
///  - a value pair of the same kind on either side of the cue (times, days,
///    dates, numbers, money, percentages; names only with a strong cue);
///  - a parallel phrase — the repair repeats the words before the retracted
///    one and swaps the rest ("use Postgres, actually use Redis");
///  - a strong cue between two single words ("blue, no wait, green").
/// Anything ambiguous — an additive "…Monday too", a list, an elaboration —
/// is left exactly as dictated. English only, like every other stage that
/// reads words; the caller skips Raw style.
enum SelfCorrectionResolver {
    struct Result {
        let text: String
        /// How many corrections were resolved (0 = the text is untouched).
        let corrections: Int
    }

    private static let maxCorrections = 6

    static func resolve(_ text: String) -> Result {
        var tokens = tokenize(text)
        var count = 0
        while count < maxCorrections, let next = applyFirstCorrection(to: tokens) {
            tokens = next
            count += 1
        }
        return count == 0 ? Result(text: text, corrections: 0) : Result(text: render(tokens), corrections: count)
    }

    // MARK: - Tokens

    private struct Tok {
        var sep: String     // whitespace before it, as dictated
        var lead: String    // opening quotes / brackets
        var body: String    // the word itself
        var trail: String   // closing punctuation (and any stand-alone dash after it)
        var core: String { body.lowercased() }
        /// "p.m." → "pm"
        var flat: String { core.replacingOccurrences(of: ".", with: "") }
    }

    private static let leadingPunctuation: Set<Character> = ["\"", "'", "\u{201C}", "\u{2018}", "(", "[", "{"]
    private static let trailingPunctuation: Set<Character> = [
        ".", ",", ";", ":", "!", "?", "\u{2026}", "\"", "\u{201D}", "\u{2019}", "'", ")", "]", "}", "\u{2014}", "\u{2013}", "-"]

    private static func tokenize(_ text: String) -> [Tok] {
        var tokens: [Tok] = []
        var pendingLead = ""
        var sep = ""
        var run = ""
        func flush() {
            guard !run.isEmpty else { return }
            var chars = Array(run)
            var lead = "", trail = ""
            while let first = chars.first, leadingPunctuation.contains(first) { lead.append(first); chars.removeFirst() }
            while let last = chars.last, trailingPunctuation.contains(last) { trail = String(last) + trail; chars.removeLast() }
            if chars.isEmpty {
                // Stand-alone punctuation ("—", "..."): fold into the neighbour.
                if var previous = tokens.popLast() { previous.trail += sep + run; tokens.append(previous) }
                else { pendingLead += run + sep }
            } else {
                tokens.append(Tok(sep: sep, lead: pendingLead + lead, body: String(chars), trail: trail))
                pendingLead = ""
            }
            run = ""
            sep = ""
        }
        var whitespace = ""
        for c in text {
            if c.isWhitespace {
                if !run.isEmpty { flush() }
                whitespace.append(c)
            } else {
                if run.isEmpty { sep = whitespace; whitespace = "" }
                run.append(c)
            }
        }
        flush()
        if var first = tokens.first, tokens.count > 0, first.sep.isEmpty, !text.isEmpty {
            // keep any leading whitespace the text began with
            let leading = String(text.prefix { $0.isWhitespace })
            first.sep = leading
            tokens[0] = first
        }
        return tokens
    }

    private static func render(_ tokens: [Tok]) -> String {
        tokens.map { $0.sep + $0.lead + $0.body + $0.trail }.joined()
    }

    /// Whether the token closes a sentence. The period in "p.m." belongs to
    /// the abbreviation, not the sentence.
    private static func endsSentence(_ t: Tok) -> Bool {
        var trail = t.trail
        if t.flat == "am" || t.flat == "pm", let dot = trail.firstIndex(of: ".") { trail.remove(at: dot) }
        return trail.contains { ".?!".contains($0) }
    }

    // MARK: - Cues

    private struct Cue {
        let end: Int            // index of the first token after the cue and its frame
        let strength: Int       // 3 strong, 2 medium, 1 weak
        let allowsWordSwap: Bool
        /// A bare "sorry" is as often an apology ("I was late. Sorry, I was stuck in traffic.") as a retraction.
        let apologyOnly: Bool
        /// "forget that", "never mind that"… — `TextFormatter`'s start-over commands. Only the restated-clause rule may
        /// act on these; the ordinary rules never could, so they still can't.
        var restartOnly = false
    }

    private static let restartOnlyPhrases: [[String]] = [
        ["forget", "that"], ["never", "mind", "that"], ["disregard", "that"], ["ignore", "that"]]

    private static let cuePhrases: [(words: [String], strength: Int, wordSwap: Bool)] = [
        (["no", "wait"], 3, true), (["wait", "no"], 3, true), (["no", "sorry"], 3, true), (["no", "actually"], 2, false),
        (["actually", "no"], 2, false), (["or", "rather"], 3, true), (["i", "mean"], 3, true), (["i", "meant"], 3, true),
        (["make", "that"], 3, false), (["scratch", "that"], 3, true), (["strike", "that"], 3, true), (["delete", "that"], 3, true),
        (["no", "weight"], 3, true), (["correction"], 3, false), (["sorry"], 3, true), (["oops"], 3, true),
        (["actually"], 1, false), (["rather"], 1, false), (["wait"], 1, false),
    ]
    /// Words that introduce the repair after a cue ("actually *make it* 4pm").
    private static let framePhrases: [[String]] = [
        ["let's", "make", "it"], ["it", "should", "be"], ["make", "it"], ["let's", "say"], ["it's"], ["it", "is"], ["should", "be"], ["say"]]

    private static func matches(_ phrase: [String], in toks: [Tok], at i: Int) -> Bool {
        guard i + phrase.count <= toks.count else { return false }
        for (offset, word) in phrase.enumerated() where toks[i + offset].core != word { return false }
        return true
    }

    /// A cue starting at `p`, greedily extended over further cue words and
    /// an introducing frame; nil if no cue starts there.
    private static func parseCue(_ toks: [Tok], at p: Int) -> Cue? {
        var i = p
        var strength = 0
        var wordSwap = true
        var apologyOnly = true
        var restartOnly = false
        var sawCue = false
        while i < toks.count {
            if let restart = restartOnlyPhrases.first(where: { matches($0, in: toks, at: i) }) {
                strength = 3
                wordSwap = false
                apologyOnly = false
                restartOnly = true
                i += restart.count
                sawCue = true
            } else if let phrase = cuePhrases.first(where: { matches($0.words, in: toks, at: i) }) {
                strength = max(strength, phrase.strength)
                wordSwap = wordSwap && phrase.wordSwap
                if phrase.words != ["sorry"] { apologyOnly = false }
                i += phrase.words.count
                sawCue = true
            } else if sawCue, let frame = framePhrases.first(where: { matches($0, in: toks, at: i) }) {
                i += frame.count
            } else {
                break
            }
        }
        return sawCue ? Cue(end: i, strength: strength, allowsWordSwap: wordSwap, apologyOnly: apologyOnly, restartOnly: restartOnly) : nil
    }

    // MARK: - Values

    private enum Kind { case time, number, money, percent, day, date, name }
    private struct Value { let start: Int; let end: Int; let kind: Kind }

    private static let smallNumbers: Set<String> = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve", "thirteen",
        "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty", "forty", "fifty", "sixty",
        "seventy", "eighty", "ninety", "hundred", "thousand", "million"]
    private static let dayWords: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "today", "tomorrow", "tonight", "yesterday", "weekend"]
    private static let monthWords: Set<String> = [
        "january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
    private static let currencyWords: Set<String> = ["dollars", "dollar", "pounds", "pound", "euros", "euro", "bucks", "quid", "usd", "gbp", "eur"]
    private static let dayModifiers: Set<String> = ["next", "this", "last", "coming"]

    private static func matchesRegex(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: .regularExpression) != nil
    }
    private static func isDigits(_ s: String) -> Bool { matchesRegex(s, #"^\d[\d,]*(\.\d+)?$"#) }
    /// "seven", or a hyphenated compound like "twenty-five".
    private static func isNumberWord(_ core: String) -> Bool {
        if smallNumbers.contains(core) { return true }
        let parts = core.split(separator: "-").map(String.init)
        return parts.count > 1 && parts.allSatisfy { smallNumbers.contains($0) }
    }
    private static func isNumeric(_ t: Tok) -> Bool { isDigits(t.core) || isNumberWord(t.core) }
    private static func isOrdinal(_ s: String) -> Bool { matchesRegex(s, #"^\d{1,2}(st|nd|rd|th)$"#) }

    private static func parseValue(_ toks: [Tok], at i: Int, allowName: Bool) -> Value? {
        guard i < toks.count else { return nil }
        let t = toks[i]
        let core = t.core, flat = t.flat
        func following(_ offset: Int) -> Tok? { i + offset < toks.count ? toks[i + offset] : nil }
        // money, percent
        if matchesRegex(core, #"^[$£€]\d[\d,]*(\.\d+)?[km]?$"#) { return Value(start: i, end: i + 1, kind: .money) }
        if matchesRegex(core, #"^\d+(\.\d+)?%$"#) { return Value(start: i, end: i + 1, kind: .percent) }
        // times
        if matchesRegex(flat, #"^\d{1,2}(:\d{2})?(am|pm)$"#) || matchesRegex(core, #"^\d{1,2}:\d{2}$"#) {
            if let next = following(1), next.flat == "am" || next.flat == "pm" { return Value(start: i, end: i + 2, kind: .time) }
            return Value(start: i, end: i + 1, kind: .time)
        }
        if core == "noon" || core == "midnight" { return Value(start: i, end: i + 1, kind: .time) }
        if (core == "half" || core == "quarter"), let a = following(1), ["past", "to", "after"].contains(a.core),
           let b = following(2), isNumeric(b) { return Value(start: i, end: i + 3, kind: .time) }
        // day / date (with an optional "next" / "this" / "last")
        if dayModifiers.contains(core), let d = following(1), dayWords.contains(d.core) { return Value(start: i, end: i + 2, kind: .day) }
        if dayWords.contains(core) { return Value(start: i, end: i + 1, kind: .day) }
        if monthWords.contains(core) {
            if let d = following(1), isOrdinal(d.core) || matchesRegex(d.core, #"^\d{1,2}$"#) { return Value(start: i, end: i + 2, kind: .date) }
            return Value(start: i, end: i + 1, kind: .date)
        }
        if core == "the", let o = following(1), isOrdinal(o.core) { return Value(start: i, end: i + 2, kind: .date) }
        if isOrdinal(core) { return Value(start: i, end: i + 1, kind: .date) }
        // numbers (with a following unit that makes it a time or an amount)
        if isNumeric(t) {
            var end = i + 1
            if isNumberWord(core) { while end < toks.count, end - i < 4, isNumberWord(toks[end].core) { end += 1 } }
            if let next = toks.indices.contains(end) ? toks[end] : nil {
                if next.flat == "am" || next.flat == "pm" || next.core == "o'clock" { return Value(start: i, end: end + 1, kind: .time) }
                if next.core == "percent" { return Value(start: i, end: end + 1, kind: .percent) }
                if currencyWords.contains(next.core) { return Value(start: i, end: end + 1, kind: .money) }
            }
            return Value(start: i, end: end, kind: .number)
        }
        // names: only with a strong cue, and never a sentence's first word
        if allowName, let first = body(of: t).first, first.isUppercase, body(of: t).allSatisfy({ $0.isLetter || $0 == "'" || $0 == "-" }),
           body(of: t).count >= 2, core != "i", !dayWords.contains(core), !monthWords.contains(core),
           i > 0, !endsSentence(toks[i - 1]) {
            var end = i + 1
            if let n = following(1), !t.trail.contains(where: { ",.;:!?".contains($0) }),
               let f = n.body.first, f.isUppercase, n.body.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "-" }) { end = i + 2 }
            return Value(start: i, end: end, kind: .name)
        }
        return nil
    }
    private static func body(of t: Tok) -> String { t.body }

    /// The longest value that ends exactly at token `q`.
    private static func backwardValue(_ toks: [Tok], endingAt q: Int, allowName: Bool) -> Value? {
        for s in max(0, q - 3)...q {
            if let v = parseValue(toks, at: s, allowName: allowName), v.end == q + 1 { return v }
        }
        return nil
    }

    private static func compatible(_ a: Kind, _ b: Kind) -> Bool {
        if a == b { return true }
        let numeric: Set<Kind> = [.time, .number, .money, .percent]
        if numeric.contains(a), numeric.contains(b) { return a == .number || b == .number }
        return (a == .day && b == .date) || (a == .date && b == .day)
    }

    // MARK: - The three rules

    private static func applyFirstCorrection(to toks: [Tok]) -> [Tok]? {
        for p in 1..<max(1, toks.count) {
            guard let cue = parseCue(toks, at: p), cue.end < toks.count else { continue }
            if let fix = resolveCue(toks, at: p, cue: cue) { return fix.tokens }
        }
        return nil
    }

    private enum Rule { case value, parallel, wordSwap, leadIn, restatedPhrase, restatedClause }

    /// Tries every rule for the cue at `p`, in the order they were added, and says which one resolved it.
    private static func resolveCue(_ toks: [Tok], at p: Int, cue: Cue) -> (tokens: [Tok], rule: Rule)? {
        if !cue.restartOnly {
            if let out = resolveValue(toks, cueStart: p, cue: cue) { return (out, .value) }
            if let out = resolveParallel(toks, cueStart: p, cue: cue) { return (out, .parallel) }
            if let out = resolveWordSwap(toks, cueStart: p, cue: cue) { return (out, .wordSwap) }
            // Added later, and only reached when every rule above declined — so a correction that was
            // already resolved can never come out differently.
            if let out = resolveWithLeadIn(toks, cueStart: p, cue: cue) { return (out, .leadIn) }
            if let out = resolveRestatedPhrase(toks, cueStart: p, cue: cue) { return (out, .restatedPhrase) }
        }
        if let out = resolveRestatedClause(toks, cueStart: p, cue: cue) { return (out, .restatedClause) }
        return nil
    }

    /// Deletes tokens `a..<b`, keeping the whitespace that preceded the first
    /// of them and re-capitalising a kept word that now starts a sentence.
    private static func delete(_ toks: [Tok], _ a: Int, _ b: Int) -> [Tok] {
        var out = Array(toks[..<a]) + Array(toks[b...])
        if a < out.count {
            out[a].sep = toks[a].sep
            let startsSentence = a == 0 || endsSentence(out[a - 1])
            if startsSentence, let f = out[a].body.first, f.isLowercase {
                out[a].body = String(f).uppercased() + out[a].body.dropFirst()
            }
        }
        return out
    }

    private static let additiveWords: Set<String> = ["too", "also", "or", "plus", "as"]

    private static func isAdditive(_ toks: [Tok], after end: Int, kind: Kind?) -> Bool {
        guard end < toks.count else { return false }
        let next = toks[end].core
        if additiveWords.contains(next) { return true }
        if next == "and", end + 1 < toks.count, let kind,
           let v = parseValue(toks, at: end + 1, allowName: kind == .name), compatible(v.kind, kind) { return true }
        return false
    }

    /// Rule 1 — a value of the same kind on each side of the cue.
    private static func resolveValue(_ toks: [Tok], cueStart p: Int, cue: Cue, repairStart: Int? = nil) -> [Tok]? {
        let r = repairStart ?? cue.end
        guard let v2 = parseValue(toks, at: r, allowName: cue.strength >= 2) else { return nil }
        var v1: Value?
        for q in stride(from: p - 1, through: max(0, p - 5), by: -1) {
            if q < p - 1, endsSentence(toks[q]) { break }
            if let candidate = backwardValue(toks, endingAt: q, allowName: cue.strength >= 2), compatible(candidate.kind, v2.kind) {
                v1 = candidate
                break
            }
        }
        guard let v1 else { return nil }
        let between = Array(toks[v1.end..<p])
        // A sentence break before the cue is fine only when the retracted value is the last thing said.
        if !between.isEmpty, endsSentence(toks[p - 1]) { return nil }
        if between.dropLast().contains(where: endsSentence) { return nil }
        let old = toks[v1.start..<v1.end].map(\.core).joined(separator: " ")
        let new = toks[v2.start..<v2.end].map(\.core).joined(separator: " ")
        if old == new || isAdditive(toks, after: v2.end, kind: v2.kind) { return nil }
        if between.isEmpty {
            // The retracted value ended its sentence — "…the copy tomorrow? Actually, Thursday, I moved the pricing
            // up." — so the sentence still ends there, with the new value: "…the copy Thursday? I moved the pricing
            // up." (the question mark used to be deleted along with "tomorrow", measured 2026-10-10).
            // Only for a question or exclamation mark, and only when the new value is set off by a comma: a full stop
            // before "Actually" is as often the recogniser's own ("…on Tuesday. Actually, Thursday morning, and invite
            // the team" is one sentence).
            var out = toks
            let ended = toks[v1.end - 1].trail.filter { "?!".contains($0) }
            let last = v2.end - 1
            if !ended.isEmpty {
                if v2.end < toks.count, toks[last].trail.contains(","), !toks[last].trail.contains(where: { ".?!;".contains($0) }) {
                    out[last].trail = toks[last].trail.replacingOccurrences(of: ",", with: "") + ended
                    if let first = out[v2.end].body.first, first.isLowercase {
                        out[v2.end].body = String(first).uppercased() + out[v2.end].body.dropFirst()
                    }
                } else if ended.contains("?"), !toks[last].trail.contains("?") {
                    // "Is it Monday? Actually, Tuesday." was asked, and is still a question.
                    out[last].trail = toks[last].trail.replacingOccurrences(of: ".", with: "?")
                }
            }
            return delete(out, v1.start, r)
        }
        let after = Array(toks[v2.end...])
        // The repair repeats what came between ("three tickets, actually four tickets"): drop the retracted stretch.
        if after.count >= between.count, zip(between, after).allSatisfy({ $0.core == $1.core }) {
            return delete(toks, v1.start, v2.start)
        }
        // The repair ends the clause ("20 licenses, actually 25."): put its value in the retracted slot.
        let last = toks[v2.end - 1]
        if v2.end == toks.count || last.trail.contains(where: { ".?!;".contains($0) }) {
            var pre = Array(toks[..<v1.start])
            var moved = Array(toks[v2.start..<v2.end])
            var kept = between
            moved[0].sep = toks[v1.start].sep
            kept[kept.count - 1].trail = moved[moved.count - 1].trail
            moved[moved.count - 1].trail = ""
            for i in kept.indices { kept[i].sep = " " }
            pre.append(contentsOf: moved)
            pre.append(contentsOf: kept)
            pre.append(contentsOf: after)
            return pre
        }
        return nil
    }

    /// Words that can introduce the replacement after a cue ("no, actually *let's do* 6pm").
    private static let leadInFrames: [[String]] = [
        ["let's", "go", "with"], ["let's", "do"], ["let's", "have"], ["let's", "try"], ["go", "with"], ["do"], ["have"]]

    /// Rule 1b — Rule 1 with a lead-in verb before the new value. Needs a medium or strong cue: a bare "actually, do
    /// 6pm work for you?" is a question, not a correction.
    private static func resolveWithLeadIn(_ toks: [Tok], cueStart p: Int, cue: Cue) -> [Tok]? {
        guard cue.strength >= 2, !cue.apologyOnly else { return nil }
        for frame in leadInFrames where matches(frame, in: toks, at: cue.end) {
            let r = cue.end + frame.count
            guard r < toks.count, !endsWithQuestion(toks, from: r) else { continue }
            if let out = resolveValue(toks, cueStart: p, cue: cue, repairStart: r) { return out }
        }
        return nil
    }

    private static func endsWithQuestion(_ toks: [Tok], from index: Int) -> Bool {
        guard let end = (index..<toks.count).first(where: { endsSentence(toks[$0]) }) else { return false }
        return toks[end].trail.contains("?")
    }

    private static let prepositions: Set<String> = ["on", "at", "for", "by", "in", "to", "around", "until"]
    private static let lightVerbs: Set<String> = ["do", "make", "put", "set", "schedule", "move", "have", "go", "meet"]
    private static let determiners: Set<String> = ["the", "a", "this", "that"]

    /// Rule 4 — "We can do the meeting in the Friday 5pm. No, actually do on Tuesday.": the retracted stretch is a
    /// prepositional phrase around a day or time, and the repair restates the verb and brings its own preposition and
    /// value. Nothing is invented: everything from the old preposition up to the new one is dropped, so the sentence
    /// reads "We can do the meeting on Tuesday." This is the one genuine self-correction in 500 real dictations that
    /// the other rules left standing.
    private static func resolveRestatedPhrase(_ toks: [Tok], cueStart p: Int, cue: Cue) -> [Tok]? {
        guard cue.strength >= 2, !cue.apologyOnly else { return nil }
        var v = cue.end
        if v < toks.count, lightVerbs.contains(toks[v].core) { v += 1 }
        else if v + 1 < toks.count, toks[v].core == "let's", lightVerbs.contains(toks[v + 1].core) { v += 2 }
        guard v + 1 < toks.count, prepositions.contains(toks[v].core),
              let v2 = parseValue(toks, at: v + 1, allowName: false), [.day, .date, .time].contains(v2.kind),
              !endsWithQuestion(toks, from: v2.end) else { return nil }
        // Values of the date/time family ending right before the cue (a sentence end there is fine: the cue may
        // start a new sentence), and at least one that the new value can replace.
        let family: [Kind] = [.day, .date, .time]
        var start = p, c = p - 1
        var replaceable = false
        while c >= 0, let value = backwardValue(toks, endingAt: c, allowName: false), family.contains(value.kind) {
            if compatible(value.kind, v2.kind) { replaceable = true }
            start = value.start
            c = value.start - 1
            if c >= 0, endsSentence(toks[c]) { break }
        }
        guard start < p, replaceable else { return nil }
        var a = start - 1
        if a >= 0, determiners.contains(toks[a].core) { a -= 1 }
        guard a >= 0, prepositions.contains(toks[a].core), !endsSentence(toks[a]) else { return nil }
        return delete(toks, a, v)
    }

    private static let restateWords: Set<String> = lightVerbs
        .union(["that", "it", "this", "let's", "lets"]).union(prepositions).union(determiners)

    /// Words that join a day and a time inside one stretch: "Friday *at* 3pm", "3pm *on* Friday", "the 5th *around* noon".
    private static let dayTimeConnectors: Set<String> = ["at", "around", "on"]

    /// The run of new days/dates/times starting at `start` (up to three), each optionally joined to the next by a
    /// connector ("Monday at 4pm"). `gaps[i]` is the connector that sat right before `values[i]`, `end` the index just
    /// past the run.
    private static func scanRepair(_ toks: [Tok], from start: Int) -> (values: [Value], gaps: [[Tok]], end: Int) {
        let family: [Kind] = [.day, .date, .time]
        var values: [Value] = [], gaps: [[Tok]] = []
        var pending: [Tok] = []
        var j = start
        while j < toks.count, values.count < 3, let value = parseValue(toks, at: j, allowName: false), family.contains(value.kind) {
            values.append(value)
            gaps.append(pending)
            pending = []
            j = value.end
            if endsSentence(toks[value.end - 1]) { break }
            if values.count < 3, j + 1 < toks.count, dayTimeConnectors.contains(toks[j].core), toks[j].trail.isEmpty,
               let next = parseValue(toks, at: j + 1, allowName: false), family.contains(next.kind) {
                pending = [toks[j]]
                j += 1
            }
        }
        return (values, gaps, j)
    }

    /// Rule 5 — the repair restates the sentence and gives a new day and/or time:
    ///
    ///     We can do the meeting on the Friday 5pm, no, actually do that Tuesday 5pm.  → …on the Tuesday 5pm.
    ///     We can do the meeting on the Friday 5PM, scratch that, do that on Tuesday.   → …on the Tuesday 5PM.
    ///     Let's meet Friday at 3pm, no wait, do it on Monday.                          → Let's meet Monday at 3pm.
    ///
    /// The new values replace the matching kind of retracted value *in place* (day for day, time for time); a retracted
    /// value the repair says nothing about stays ("5PM" when only the day changed), and so does the connector that joined
    /// them ("at"). Everything the speaker said around them is kept, and only their own words are used. Needs a medium or
    /// strong cue AND a restated verb ("do that (on)"): with nothing restated ("Let's meet Tuesday. Scratch that,
    /// Wednesday works better.") it is left alone, and the formatter's start-over command does what it always did.
    private static func resolveRestatedClause(_ toks: [Tok], cueStart p: Int, cue: Cue) -> [Tok]? {
        guard cue.strength >= 2, !cue.apologyOnly else { return nil }
        // The restated frame: "do that", "do that on" — closed-class words only, and it must contain a verb.
        var idx = cue.end
        while idx < toks.count, idx - cue.end < 5, restateWords.contains(toks[idx].core),
              parseValue(toks, at: idx, allowName: false) == nil { idx += 1 }
        guard idx > cue.end, toks[cue.end..<idx].contains(where: { lightVerbs.contains($0.core) || $0.core == "let's" || $0.core == "lets" })
        else { return nil }
        let family: [Kind] = [.day, .date, .time]
        // The new values.
        let scan = scanRepair(toks, from: idx)
        let repair = scan.values, j = scan.end
        guard let lastRepair = repair.last, !endsWithQuestion(toks, from: idx),
              !isAdditive(toks, after: j, kind: lastRepair.kind) else { return nil }
        // The retracted values, right before the cue (a sentence end there is fine: the cue may start a new sentence).
        // A connector between two of them ("Friday at 3pm") belongs to the stretch being taken back, and is kept.
        var retracted: [Value] = []
        var retractedGaps: [[Tok]] = []       // retractedGaps[i] sat between retracted[i - 1] and retracted[i]
        var c = p - 1
        while c >= 0, retracted.count < 3, let value = backwardValue(toks, endingAt: c, allowName: false), family.contains(value.kind) {
            retracted.insert(value, at: 0)
            retractedGaps.insert([], at: 0)
            c = value.start - 1
            if c >= 0, endsSentence(toks[c]) { break }
            if c >= 1, retracted.count < 3, dayTimeConnectors.contains(toks[c].core), toks[c].trail.isEmpty,
               let earlier = backwardValue(toks, endingAt: c - 1, allowName: false), family.contains(earlier.kind) {
                retractedGaps[0] = [toks[c]]
                c -= 1
            }
        }
        guard let firstRetracted = retracted.first else { return nil }
        // Pair each new value with a retracted value of the same kind (a day may stand in for a date only as a last resort).
        func words(_ value: Value) -> String { toks[value.start..<value.end].map(\.core).joined(separator: " ") }
        var replacement: [Int: Value] = [:]
        var matched: [Int] = [], unmatched: [Int] = []
        for (k, value) in repair.enumerated() {
            let free = retracted.indices.filter { replacement[$0] == nil }
            if let i = free.first(where: { retracted[$0].kind == value.kind }) ?? free.first(where: { compatible(retracted[$0].kind, value.kind) }) {
                replacement[i] = value
                matched.append(k)
            } else {
                unmatched.append(k)
            }
        }
        guard replacement.contains(where: { words(retracted[$0.key]) != words($0.value) }) else { return nil }
        // A value the speaker hadn't given before is appended after the rest, so it has to come last in what they said
        // now ("do it on Monday at 4pm" after "Friday"); "Monday at 4pm" after only "3pm" would come out as "4pm Monday".
        if let lastMatched = matched.max(), unmatched.contains(where: { $0 < lastMatched }) { return nil }
        // "Friday the 5th" is one fact: replacing only one of the two would leave the other contradicting it.
        let kinds = Set(retracted.map(\.kind))
        if kinds.contains(.day), kinds.contains(.date), replacement.count < retracted.count { return nil }
        var merged: [Tok] = []
        for (i, value) in retracted.enumerated() {
            if i > 0 { merged.append(contentsOf: retractedGaps[i]) }
            let source = replacement[i] ?? value
            merged.append(contentsOf: toks[source.start..<source.end])
        }
        for k in unmatched {
            merged.append(contentsOf: scan.gaps[k])
            merged.append(contentsOf: toks[repair[k].start..<repair[k].end])
        }
        for k in merged.indices {
            merged[k].sep = k == 0 ? toks[firstRetracted.start].sep : " "
            merged[k].trail = k == merged.count - 1 ? toks[lastRepair.end - 1].trail
                : (merged[k].trail.contains(where: { ",.;!?".contains($0) }) ? "" : merged[k].trail)
        }
        if firstRetracted.start == 0 || endsSentence(toks[firstRetracted.start - 1]), let f = merged[0].body.first, f.isLowercase {
            merged[0].body = String(f).uppercased() + merged[0].body.dropFirst()
        }
        return Array(toks[..<firstRetracted.start]) + merged + Array(toks[j...])
    }

    // MARK: - "Scratch that"

    /// `TextFormatter`'s start-over command ("scratch that", "forget that"…) wipes everything said before it, which is
    /// right for "First idea. Scratch that. Second idea." and wrong for "We can do the meeting on the Friday 5PM,
    /// scratch that, do that on Tuesday" — there the new day takes the old one's place and the rest of the sentence
    /// stays ("…on the Tuesday 5PM"), which is also how Flit handles it. When the text holds exactly one such phrase,
    /// this resolves it in place — but only when nothing can go wrong — and returns nil otherwise so the start-over
    /// command does what it always did:
    ///  - the repair restates the clause's own verb and brings a new day/time ("do that on Tuesday"), or the retracted
    ///    stretch and the cue share one sentence ("Buy milk, scratch that, eggs"); and
    ///  - whatever the speaker says after the new value is a separate clause, not an attachment — with "Let's meet
    ///    Tuesday. Scratch that, Wednesday works better." the new value carries its own predicate, so keeping "Let's
    ///    meet" would glue two clauses together.
    /// With several start-over phrases the old wipe (everything before the last one) is what the speaker meant.
    static func resolveSoleRestart(_ text: String) -> String? {
        let toks = tokenize(text)
        let phrases = toks.indices.filter { isRestartPhrase(toks, at: $0) }
        guard phrases.count == 1, let p = phrases.first, p > 0,
              let cue = parseCue(toks, at: p), cue.end < toks.count,
              let fix = resolveCue(toks, at: p, cue: cue),
              let end = repairEnd(toks, cue: cue, rule: fix.rule), tailIsClean(toks, after: end)
        else { return nil }
        switch fix.rule {
        case .restatedPhrase, .restatedClause: break
        case .parallel: return nil
        // A whole sentence was retracted ("First idea. Scratch that. …"): that is a restart, not a swap.
        case .value, .wordSwap, .leadIn: if endsSentence(toks[p - 1]) { return nil }
        }
        return render(fix.tokens)
    }

    private static func isRestartPhrase(_ toks: [Tok], at i: Int) -> Bool {
        matches(["scratch", "that"], in: toks, at: i) || restartOnlyPhrases.contains(where: { matches($0, in: toks, at: i) })
    }

    /// Index just past the repair's last value or word: where whatever the speaker said afterwards begins.
    private static func repairEnd(_ toks: [Tok], cue: Cue, rule: Rule) -> Int? {
        switch rule {
        case .parallel: return nil
        case .wordSwap: return cue.end + 1
        case .value: return parseValue(toks, at: cue.end, allowName: cue.strength >= 2)?.end
        case .leadIn:
            guard let frame = leadInFrames.first(where: { matches($0, in: toks, at: cue.end) }) else { return nil }
            return parseValue(toks, at: cue.end + frame.count, allowName: cue.strength >= 2)?.end
        case .restatedPhrase, .restatedClause:
            var i = cue.end
            while i < toks.count, i - cue.end < 5, restateWords.contains(toks[i].core), parseValue(toks, at: i, allowName: false) == nil { i += 1 }
            let scan = scanRepair(toks, from: i)
            return scan.values.isEmpty ? nil : scan.end
        }
    }

    /// Words that may follow a new value directly without starting a predicate of their own.
    private static let attachableAfterValue: Set<String> = [
        "and", "or", "but", "so", "then", "because", "since", "while", "morning", "afternoon", "evening", "night"]

    /// Nothing is glued to the new value: it ends its clause, or a conjunction / part of the day follows.
    private static func tailIsClean(_ toks: [Tok], after end: Int) -> Bool {
        guard end < toks.count else { return true }
        if toks[end - 1].trail.contains(where: { ",;.?!:\u{2014}\u{2013}\u{2026}".contains($0) }) { return true }
        return attachableAfterValue.contains(toks[end].core)
    }

    private static let subjectOpeners: Set<String> = ["i", "we", "you", "he", "she", "they", "it", "there", "this", "that"]
    private static let stopWords: Set<String> = [
        "a", "an", "the", "it", "its", "that", "this", "these", "those", "them", "they", "he", "she", "we", "you", "i", "me", "my", "and",
        "or", "but", "so", "to", "of", "in", "on", "at", "for", "with", "is", "are", "was", "were", "be", "been", "do", "does", "did",
        "don't", "doesn't", "didn't", "not", "no", "what", "which", "who", "how", "there", "here", "then", "than", "if", "as", "by", "from"]

    /// Rule 2 — the repair is a parallel phrase: same first word, most words
    /// the same, the rest swapped for other content words.
    private static func resolveParallel(_ toks: [Tok], cueStart p: Int, cue: Cue) -> [Tok]? {
        let r = cue.end
        for k in stride(from: min(6, p), through: 2, by: -1) {
            let a = p - k
            guard r + k <= toks.count else { continue }
            if (a..<(p - 1)).contains(where: { endsSentence(toks[$0]) }) { continue }
            guard toks[a].core == toks[r].core else { continue }
            var same = 0
            var sharedContent = 0
            var swapsAreContent = true
            for i in 0..<k {
                if toks[a + i].core == toks[r + i].core {
                    same += 1
                    if !stopWords.contains(toks[a + i].core) { sharedContent += 1 }
                } else if stopWords.contains(toks[a + i].core) || stopWords.contains(toks[r + i].core) { swapsAreContent = false }
            }
            guard same < k, swapsAreContent, same >= (k + 1) / 2 else { continue }
            // "I was late. Sorry, I was stuck in traffic." repeats only "I was" — an explanation, not a repair.
            if sharedContent == 0, subjectOpeners.contains(toks[a].core), cue.apologyOnly || cue.strength < 3 { continue }
            if isAdditive(toks, after: r + k, kind: nil) { continue }
            return delete(toks, a, r)
        }
        return nil
    }

    /// Rule 3 — a strong cue, set off by punctuation, between two single words.
    private static func resolveWordSwap(_ toks: [Tok], cueStart p: Int, cue: Cue) -> [Tok]? {
        guard cue.strength >= 3, cue.allowsWordSwap else { return nil }
        let r = cue.end
        let before = toks[p - 1], after = toks[r]
        let setOff = before.trail.contains(where: { ",\u{2014}\u{2013}\u{2026}-".contains($0) })
            || toks[r - 1].trail.contains(where: { ",\u{2014}\u{2013}\u{2026}-".contains($0) })
        guard setOff, !endsSentence(before) else { return nil }
        let ends = after.trail.contains(where: { ".,;?!".contains($0) }) || r == toks.count - 1
        func isPlainWord(_ t: Tok) -> Bool {
            t.body.count >= 3 && t.body.allSatisfy { $0.isLetter || $0 == "'" || $0 == "-" } && !stopWords.contains(t.core)
        }
        guard ends, isPlainWord(before), isPlainWord(after), before.core != after.core else { return nil }
        if isAdditive(toks, after: r + 1, kind: nil) { return nil }
        return delete(toks, p - 1, r)
    }

    // MARK: - Self-test

    static func runSelfTest() -> Bool {
        var passed = true
        func check(_ input: String, _ expected: String, _ label: String) {
            let got = resolve(input).text
            let ok = got == expected
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): \(label)\(ok ? "" : " — got \(got.debugDescription)")")
        }
        check("Can you check the launch copy tomorrow? Actually, Thursday, I moved the pricing bit up.",
              "Can you check the launch copy Thursday? I moved the pricing bit up.", "a correction after a question mark keeps the question")
        check("Is it on Monday? Actually, Tuesday.", "Is it on Tuesday?", "…also when the correction ends the dictation")
        check("Let's meet at 5pm, actually 6pm works better for everyone.",
              "Let's meet at 6pm works better for everyone.", "resolves the field case: 5pm, actually 6pm")
        check("Let's do coffee at 2 actually 3.", "Let's do coffee at 3.", "resolves bare numbers with no commas")
        check("Let's meet at 5 pm, no actually 6 pm.", "Let's meet at 6 pm.", "resolves spaced am/pm")
        check("Let's meet at 5:00 p.m., actually 6:00 p.m. on Friday.", "Let's meet at 6:00 p.m. on Friday.", "keeps the abbreviation's periods")
        check("Let's ship on Friday, actually Monday.", "Let's ship on Monday.", "resolves days")
        check("Send the invoice by March 5th, sorry, March 6th.", "Send the invoice by March 6th.", "resolves dates")
        check("Call John at 3pm, actually make it 4pm, and tell him Tuesday, actually Wednesday works.",
              "Call John at 4pm, and tell him Wednesday works.", "resolves two corrections in one sentence")
        check("We need 20 licenses, actually 25.", "We need 25 licenses.", "moves the new value into the retracted slot")
        check("I need three tickets, actually four tickets for the trip.", "I need four tickets for the trip.", "drops the repeated unit")
        check("The meeting is at 5pm in the big room, actually 6pm.", "The meeting is at 6pm in the big room.", "keeps words between value and cue")
        check("Send it to John, no wait, Mary.", "Send it to Mary.", "resolves names with a strong cue")
        check("Let's ship on Friday, actually let's ship on Monday instead.", "Let's ship on Monday instead.", "resolves a parallel phrase")
        check("Use Postgres, actually use Redis for the cache.", "Use Redis for the cache.", "resolves a one-word swap in a parallel phrase")
        check("The button should be blue, no wait, green.", "The button should be green.", "resolves a strong-cue word swap")
        check("We can do the meeting in the Friday 5pm. No, actually do on Tuesday.", "We can do the meeting on Tuesday.",
              "resolves the real dictation that used to slip through")
        check("We can do the meeting on the Friday 5pm, no, actually do that Tuesday 5pm.", "We can do the meeting on the Tuesday 5pm.",
              "restated clause: new day AND time replace the old ones")
        check("We can do the meeting on the Friday 5PM, scratch that, do that on Tuesday.", "We can do the meeting on the Tuesday 5PM.",
              "restated clause after \"scratch that\": only the day changes, 5PM stays")
        check("We can do the meeting on the Friday 5PM, scratch that do that on Tuesday", "We can do the meeting on the Tuesday 5PM",
              "restated clause with no punctuation")
        // The trigger phrases across the value kinds: weekday, amount, time, month, quantity, percent, date.
        check("let's book the workshop on wednesday no wait thursday morning and invite the whole team",
              "let's book the workshop on thursday morning and invite the whole team", "weekday swap in place")
        check("the fee is $250, no wait, $350, and please pay it by friday", "the fee is $350, and please pay it by friday",
              "amount swap keeps the rest")
        check("Let's hold the workshop on Wednesday. No wait. Thursday morning, and invite the whole team.",
              "Let's hold the workshop on Thursday morning, and invite the whole team.", "the recognizer split it into sentences")
        check("The fee is $250. No wait. $350.", "The fee is $350.", "amount across sentences")
        check("the fee is $250 scratch that $350", "the fee is $350", "scratch that + amount")
        check("call at 8:15 I meant 9:15", "call at 9:15", "I meant + time")
        check("we leave in june sorry july", "we leave in july", "month + sorry")
        check("we need 4 make that 9 seats", "we need 9 seats", "make that + quantity")
        check("it grew 12% no weight 15%", "it grew 15%", "\"no weight\", the usual mishearing of \"no wait\"")
        check("due the 3rd correction the 4th", "due the 4th", "correction + date")
        check("the flight is at 6:00 AM or rather 7:00 AM", "the flight is at 7:00 AM", "or rather + time")
        // A day and its time in one stretch ("Friday at 3pm"): only the day changes, the connector and the time stay.
        check("Let's meet Friday at 3pm, no wait, do it on Monday.", "Let's meet Monday at 3pm.", "restated clause: day changes, \"at 3pm\" stays")
        check("Let's meet Friday at 3pm, no wait, do it Monday.", "Let's meet Monday at 3pm.", "restated clause with no preposition")
        check("The call is Tuesday at 10am, no wait, do it on Wednesday.", "The call is Wednesday at 10am.", "same, another day and time")
        check("We can do the meeting on Friday at 3pm, no wait, do that on Monday at 4pm.", "We can do the meeting on Monday at 4pm.",
              "day AND time both replaced")
        check("Let's meet Friday at 3pm, no wait, do it at 4pm.", "Let's meet Friday at 4pm.", "only the time changes")
        check("Let's meet on the 5th at 3pm, no wait, do it on the 6th.", "Let's meet on the 6th at 3pm.", "date and time")
        check("Let's meet at 3pm on Friday, no wait, do it Monday at 4pm.", "Let's meet at 4pm on Monday.", "time before day, values matched by kind")
        check("Let's meet Friday, no wait, do it on Monday at 4pm.", "Let's meet Monday at 4pm.", "new detail (a time) follows the day")
        check("Buy milk, scratch that, eggs.", "Buy eggs.", "scratch that swaps in place")
        check("Let's meet at 5pm. No, actually let's do 6pm.", "Let's meet at 6pm.", "resolves a lead-in verb before the new value")
        check("Schedule it for Friday, no, actually do Tuesday.", "Schedule it for Tuesday.", "resolves 'actually do Tuesday'")
        check("Send it to John. No wait, send it to Mary.", "Send it to Mary.", "resolves a phrase the recognizer split with a period")
        check("I need to deploy to the prod. Sorry, I mean the staging environment.",
              "I need to deploy to the staging environment.", "resolves 'sorry, I mean' after a period")
        check("We need twenty-five seats, actually thirty.", "We need thirty seats.", "reads hyphenated number words")
        check("Meet at 5 o'clock, actually 6 o'clock.", "Meet at 6 o'clock.", "reads o'clock times")
        check("Use version 1.2, actually 1.3 for the build.", "Use version 1.3 for the build.", "reads decimal numbers")
        check("let's meet at five thirty no wait six thirty tomorrow", "let's meet at six thirty tomorrow", "resolves unpunctuated speech text")
        // Things that must be left alone.
        for keep in [
            "I actually enjoyed the movie more than I expected.", "I mean it, this is really important.", "Sorry for the delay, I was in a meeting.",
            "There is no wait time at the restaurant.", "The meeting is at 5pm and the dinner is at 7pm.", "Let's meet Friday, actually Monday too.",
            "I have 3 kids, actually 2 boys and 1 girl.", "Please don't scratch that surface.", "Tell Sarah, actually, that is fine.",
            "We use Postgres, actually we use it a lot.", "It's actually 6pm now, not 5pm.", "You can call me at 5pm or 6pm.",
            "We can do the meeting on the Friday 5pm. Actually, do you want Tuesday 5pm?", "We meet Friday 5pm. Sorry, do that.",
            "Book it for Friday 5pm. No, actually do that Monday too.",
            // Restated clauses that must be left alone: a question, an additive tail, a weak cue, an awkward order, a
            // weekday plus a date where only one is replaced.
            "Let's meet Friday at 3pm, no wait, do you want Monday?", "Let's meet Friday at 3pm, no wait, do it on Monday and Tuesday.",
            "Let's meet Friday at 3pm, actually do it on Monday.", "Let's meet at 3pm, no wait, do it Monday at 4pm.",
            "Let's meet Friday the 5th, no wait, do it on the 6th.",
            // Shapes that only look like corrections: an additive tail, a new detail, a comparison, a list, a noun.
            "the options are wednesday no wait we also have thursday", "call wednesday no wait at 8:15", "thursday rather than wednesday",
            "wednesday and thursday both work", "the parcel has no weight", "we shipped 1075 PM builds",
            "The call is at 5pm. Actually, do 6pm work for you?", "No, actually do you know what time it closes?",
            "We meet in the morning. No, actually do on Tuesday.", "I was late. Sorry, I was stuck in traffic.", "He is late. Actually, he is on his way.", "We shipped it. Sorry, we shipped the wrong build.",
        ] { check(keep, keep, "leaves alone: \(keep.prefix(40))") }
        // The start-over entry point: in place only when nothing can be glued to the wrong half; nil = the wipe stays.
        func restart(_ input: String, _ expected: String?, _ label: String) {
            let got = resolveSoleRestart(input)
            let ok = got == expected
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): \(label)\(ok ? "" : " — got \((got ?? "nil").debugDescription)")")
        }
        restart("Buy milk, scratch that, eggs.", "Buy eggs.", "restart: one word swaps in place")
        restart("We need 20 licenses, scratch that, 25.", "We need 25 licenses.", "restart: a bare number swaps in place")
        restart("We can do the meeting on the Friday 5PM, scratch that, do that on Tuesday.", "We can do the meeting on the Tuesday 5PM.",
                "restart: a restated clause swaps the day and keeps the time")
        restart("Let's do the demo on Monday, scratch that, Tuesday afternoon, and invite the whole team.",
                "Let's do the demo on Tuesday afternoon, and invite the whole team.", "restart: a part of the day may follow the value")
        restart("Let's meet Tuesday. Scratch that, Wednesday works better.", nil, "restart: a repair with its own predicate is a new clause")
        restart("Send the invoice on Friday, scratch that, Monday works for the team.", nil, "restart: same, inside one sentence")
        restart("The meeting is Friday. Forget that. Let's do Monday instead.", nil, "restart: \"instead\" is glued to the new value")
        restart("First idea. Scratch that. Second idea.", nil, "restart: a whole retracted sentence is wiped")
        restart("Ship on Friday, scratch that, ship on Monday.", nil, "restart: parallel phrases keep the old behaviour")
        restart("I need to scratch that itch before we start.", nil, "restart: a phrase that is not a command")
        restart("First idea. Scratch that. Second idea, scratch that, third.", nil, "restart: several phrases keep the old wipe")
        restart("Let's meet Friday at 3pm, scratch that, do it on Monday.", "Let's meet Monday at 3pm.", "restart: a day inside \"Friday at 3pm\" swaps in place")
        restart("Let's meet Friday at 3pm, scratch that, do it on Monday at 4pm.", "Let's meet Monday at 4pm.", "restart: day and time both new")
        return passed
    }
}
