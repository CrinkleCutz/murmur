import Foundation

/// What whisper.cpp is told before it listens, and which of its segments to keep afterwards.
///
/// Whisper reads its prompt as the text that came *before* the recording and carries on in the same style. The old
/// prompt was "Vocabulary: " followed by up to 150 terms — Murmur's ~116 developer terms first, then the user's own —
/// and it went wrong three ways, all measured on the same synthesized dictations (2026-09-28):
///  - whisper.cpp keeps only the last ~224 tokens of a prompt, so a 150-term list was cut from the front at random;
///  - a long list of comma-separated fragments made it write the same way: "and, open the, website" at every pause;
///  - everyday words the Dictionary had picked up ("app", "they", "from Chat") pulled the words themselves in.
/// Same audio, same model: that prompt 1.5% word errors, 10 of 13 dictionary words, 2 commas at pauses; this one
/// 1.1%, 12 of 13, none. No prompt at all was worst (3.0%, 7 of 13) — and invented a "Thank you." (below).
enum WhisperPrompt {
    /// For a shell (`CodeField.Kind.shell`): commands the way they're typed, so whisper.cpp writes what's said as one —
    /// measured 2026-10-01 on large-v3-turbo: "git rebase dash i head tilde three" came out "git rebase-i, head
    /// tilde-3" with the usual prompt and `git rebase -i HEAD~3` with this one; "npm run test dash dash watch" →
    /// `npm run test --watch`; "git checkout dash b feature slash…" → `git checkout -b feature/…`.
    static let shell = "git rebase -i HEAD~3, npm run test --watch, cd ~/projects, ls *.swift, git checkout -b feature/login"

    /// Whisper sometimes hands its prompt back on near-silent audio. Two or more of the example commands in the result
    /// is that, not what was said — it's thrown away rather than pasted into a terminal.
    static func echoesShell(_ text: String) -> Bool {
        let said = text.lowercased()
        return shell.lowercased().components(separatedBy: ", ").filter { said.contains($0) }.count >= 2
    }

    /// Short enough that whisper.cpp never has to cut it.
    static let characterBudget = 400

    /// "I'm dictating about Murmur, Wispr Flow, Planrify and Vercel." — or nil when there's nothing worth saying.
    /// `terms` in the order the caller has them; `personal` (lowercased) are the user's own, which go first.
    /// Every word the user taught is included, everyday or not — their choice (2026-09-29): what they taught should
    /// reach the engine. Only Murmur's own built-in list is held to names and unusual words.
    static func text(for terms: [String], personal: Set<String>,
                     isKnownWord: (String) -> Bool = HarperChecker.isKnownEnglishWord) -> String? {
        var seen = Set<String>()
        var candidates: [(term: String, isPersonal: Bool)] = []
        for raw in terms {
            let term = LearnedStore.cleanedTerm(raw)
            let key = term.lowercased()
            let isPersonal = personal.contains(key)
            guard !term.isEmpty, !seen.contains(key),
                  isPersonal || isWorthMentioning(term, isKnownWord: isKnownWord) else { continue }
            seen.insert(key)
            candidates.append((term, isPersonal))
        }
        let ordered = candidates.filter(\.isPersonal) + candidates.filter { !$0.isPersonal }
        var chosen: [String] = []
        var length = 0
        for candidate in ordered {
            let added = candidate.term.count + 2
            if length + added > characterBudget { break }
            chosen.append(candidate.term)
            length += added
        }
        guard let last = chosen.last else { return nil }
        let list = chosen.count == 1 ? last : chosen.dropLast().joined(separator: ", ") + " and " + last
        return "I'm dictating about \(list)."
    }

    /// For Murmur's built-in terms: a name or an unusual word — something the model might not spell right on its own.
    /// An everyday word or phrase only pulls it towards that word where it doesn't belong, and a bare number or time
    /// ("10:30") says nothing.
    static func isWorthMentioning(_ term: String, isKnownWord: (String) -> Bool) -> Bool {
        guard term.contains(where: \.isLetter) else { return false }
        if term.first?.isUppercase == true { return true }
        if term.contains(where: { $0.isNumber || "/.+#_".contains($0) }) { return true }
        return term.split(separator: " ").contains { word in
            let letters = word.filter(\.isLetter).lowercased()
            return !letters.isEmpty && !isKnownWord(letters)
        }
    }

    // MARK: - Segments to keep

    /// Whisper works in 30-second windows. When a dictation runs a little past 30 seconds, the last window is almost
    /// all silence, and the model fills it with the sign-off it learned from video subtitles: "Thank you." Every one of
    /// the user's stray "Thank you."s so far was on a dictation of 30 seconds or more. In the transcript that segment
    /// sits over silent audio (measured: loudness 0.0001), where a "thank you" actually said is as loud as the rest
    /// (0.136) — so a known sign-off over a silent span is dropped, and one that was said stays.
    static func keptSegments(_ segments: [(text: String, rms: Float)],
                             quietBelow threshold: Float = TrailingSilenceTrimmer.audibleRMS) -> [Int] {
        segments.indices.filter { index in
            let segment = segments[index]
            return !(segment.rms < threshold && HallucinationFilter.isLikelyHallucination(segment.text))
        }
    }

    // MARK: - Self test

    static func runSelfTest() -> Bool {
        var passed = true
        func check(_ ok: Bool, _ label: String) {
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): whisper prompt: \(label)")
        }
        let common: Set<String> = ["app", "they", "latest", "updates", "from", "chat", "are", "we", "white", "murmur"]
        let known: (String) -> Bool = { common.contains($0) }

        let text = self.text(for: ["Claude", "npm", "Murmur.", "app", "from Chat", "latest updates", "Wispr Flow",
                                   "10:30", "iOS", "whisper.cpp", "they", "Wispr flow"],
                             personal: ["murmur", "wispr flow", "ios", "whisper.cpp", "app", "from chat"], isKnownWord: known)
        check(text == "I'm dictating about Murmur, app, from Chat, Wispr Flow, iOS, whisper.cpp, Claude and npm.",
              "every word the user taught, first; built-in terms only when a name or unusual word; one plain sentence (got \(text ?? "nil"))")
        check(self.text(for: ["app", "they", "10:30"], personal: [], isKnownWord: known) == nil,
              "everyday words that aren't the user's: no prompt")
        check(self.text(for: ["10:30", "latest updates"], personal: ["10:30", "latest updates"], isKnownWord: known)
              == "I'm dictating about 10:30 and latest updates.", "the user's own everyday words and times are kept")
        let many = (1...200).map { "Term\($0)" }
        let long = self.text(for: many, personal: [], isKnownWord: known) ?? ""
        check(long.count <= characterBudget + 40, "never longer than whisper.cpp keeps (\(long.count) characters)")

        let silentThanks = keptSegments([("I want to go through the whole website.", 0.15), ("Thank you.", 0.0001)])
        check(silentThanks == [0], "a \"Thank you.\" over silence is dropped")
        let saidThanks = keptSegments([("I want to go through the whole website.", 0.15), ("Thank you.", 0.136)])
        check(saidThanks == [0, 1], "a \"Thank you.\" actually said stays")
        check(keptSegments([("And that was the plan.", 0.0001)]) == [0], "quiet real words are never dropped")
        return passed
    }
}
