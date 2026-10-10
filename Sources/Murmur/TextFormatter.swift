import Foundation

/// Rule-based cleanup of raw transcripts: filler removal, spoken layout
/// commands, full-restart commands ("scratch that"), spacing/
/// capitalization fixes, and personal-dictionary substitutions. Mirrors
/// Wispr Flow's "AI edits" with local rules.
struct TextFormatter {

    /// Filler words removed when they appear as standalone tokens.
    static let fillers: Set<String> = [
        "um", "umm", "uh", "uhh", "uhm", "er", "erm", "ehm", "mhm", "hmm",
    ]

    var dictionary: [String: String]
    /// Spoken punctuation, spelled-out addresses and "bullet point" are English words — off for other languages.
    var speaksEnglish: Bool
    /// The dictation language's own hesitation sounds ("äh", "euh") — see `CleanupLanguage`.
    var extraFillers: Set<String>

    init(dictionary: [String: String] = TextFormatter.loadDictionary(), speaksEnglish: Bool = true,
         extraFillers: Set<String> = []) {
        self.dictionary = dictionary
        self.speaksEnglish = speaksEnglish
        self.extraFillers = extraFillers
    }

    static var dictionaryURL: URL {
        AppPaths.supportDirectory.appendingPathComponent("dictionary.json")
    }

    static func loadDictionary() -> [String: String] {
        guard let data = try? Data(contentsOf: dictionaryURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return dict
    }

    func format(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "" }

        text = applyRestartCommands(to: text)
        text = removeFillers(from: text)
        text = applySpokenCommands(to: text)
        if speaksEnglish {
            text = applySpokenAddresses(to: text)
            text = applySpokenPunctuation(to: text)
        }
        text = applyDictionary(to: text)
        text = tidyWhitespaceAndPunctuation(in: text)
        text = capitalizeSentences(in: text)
        text = ensureTerminalPunctuation(in: text)
        return text
    }

    // MARK: - Passes

    /// A full verbal restart — "scratch that," "forget that" — where the
    /// user abandons everything said so far in this dictation and starts
    /// over. Keeps only the text after the *last* such phrase; if nothing
    /// follows it (the dictation ends right on the trigger), leaves the
    /// text untouched rather than returning empty — the user still said
    /// something real, and silently erasing all of it is a worse failure
    /// than leaving an unresolved "scratch that" in the output for them to
    /// delete themselves.
    ///
    /// This is the free, zero-latency slice of what Wispr Flow calls
    /// "Backtrack" — deliberately narrow: each phrase must be its own
    /// clause, followed by a comma/sentence-ending punctuation or the end
    /// of the dictation, so "I need to scratch that itch" or "don't forget
    /// that meeting" (the phrase followed directly by a noun, no clause
    /// boundary) are left alone. What this can't do — an in-place swap
    /// like "5pm, actually 6" → "6pm," or judging whether an unpunctuated
    /// "actually" is a filler or a real correction — needs actual language
    /// understanding, which is what `RewriteEngine`'s rewrite pass is for,
    /// not a regex.
    private static let restartPhrases = [
        "scratch that", "forget that", "disregard that", "ignore that",
        "never mind that",
    ]

    private func applyRestartCommands(to text: String) -> String {
        let escaped = Self.restartPhrases
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        let pattern = "(?i)\\b(?:\(escaped))\\b\\s*(?:[,.!?]|$)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }

        let nsText = text as NSString
        let matches = regex.matches(
            in: text, range: NSRange(location: 0, length: nsText.length))
        guard let last = matches.last else { return text }

        // "Scratch that" wipes everything before it — right for "First idea. Scratch that. Second idea.", wrong for "We
        // can do the meeting on the Friday 5PM, scratch that, do that on Tuesday", where the new day takes the old
        // one's place and the rest of the sentence stays (also how Flit treats it). When the correction can be made in
        // place without gluing clauses together, do that; otherwise the start-over command wipes exactly as before.
        // Resolved here, on the filler-free text, so it doesn't depend on any later stage (non-English dictation and
        // Raw style skip the resolver).
        if matches.count == 1, let resolved = SelfCorrectionResolver.resolveSoleRestart(removeFillers(from: text)) { return resolved }

        let remainder = nsText
            .substring(from: last.range.location + last.range.length)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return remainder.isEmpty ? text : remainder
    }

    private func removeFillers(from text: String) -> String {
        var result = text
        // A language's own filler between commas ("am Donnerstag, ähm, auf Freitag") takes both commas with it.
        for filler in extraFillers {
            result = result.replacingOccurrences(
                of: "(?i),\\s+\(filler),\\s+", with: " ", options: .regularExpression)
        }
        for filler in Self.fillers.union(extraFillers) {
            // Filler optionally followed by a comma, as its own word.
            let pattern = "(?i)(^|\\s)\(filler)[,.]?(?=\\s|$)"
            result = result.replacingOccurrences(
                of: pattern, with: "$1", options: .regularExpression)
        }
        return result
    }

    private func applySpokenCommands(to text: String) -> String {
        var result = text
        let commands: [(pattern: String, replacement: String)] = [
            ("(?i)[,.]?\\s*\\bnew paragraph[,.]?\\s*", "\n\n"),
            ("(?i)[,.]?\\s*\\bnew ?line[,.]?\\s*", "\n"),
        ]
        for command in commands {
            result = result.replacingOccurrences(
                of: command.pattern, with: command.replacement,
                options: .regularExpression)
        }
        return result
    }

    /// Punctuation said out loud — "how are you question mark", "Hi John comma" — as the mark itself, whatever
    /// punctuation the recognizer already put around the word. Only when it's the command, not the noun: never after
    /// "a", "the", "this"… or a word that makes a span of time ("add a comma", "a trial period"), never before "of".
    /// "bullet point" starts a "- " line.
    private static let spokenPunctuation: [(words: String, mark: String)] = [
        ("question mark", "?"), ("exclamation mark", "!"), ("exclamation point", "!"), ("full stop", "."),
        ("period", "."), ("comma", ","), ("semicolon", ";"), ("colon", ":"), ("bullet point", "\n- "),
        // As one word, the way whisper.cpp writes it ("Bulletpoint milk, Bulletpoint eggs").
        ("bulletpoint", "\n- "), ("bullet-point", "\n- "),
    ]
    private static let nounMakers = [
        "a", "an", "the", "this", "that", "these", "those", "each", "every", "no", "any", "one", "per", "my", "your",
        "our", "their", "his", "her", "its", "trial", "grace", "waiting", "cooling", "billing", "notice", "school",
        "free", "test", "holding", "same", "whole", "long", "short", "given", "certain", "reporting", "payment", "time",
        "refund", "rest", "lunch", "second", "first", "third", "last", "next", "extra", "missing", "oxford",
    ]

    private func applySpokenPunctuation(to text: String) -> String {
        var result = text
        let notAfter = "(?<!\\b(?:" + Self.nounMakers.joined(separator: "|") + ")\\s)"
        func replace(_ pattern: String, _ template: String) {
            result = result.replacingOccurrences(of: "(?i)" + pattern, with: template, options: .regularExpression)
        }
        // Paired first: quote … unquote / end quote / close quote, and open … close parenthesis or bracket — the pair is
        // what makes it a command ("get a quote from them" has no "unquote").
        replace("\\s*" + notAfter + "\\b(?:open\\s+)?quote\\b[,:]?\\s+(.+?),?\\s+\\b(?:unquote|end\\s+quote|close\\s+quote)\\b",
                " \"$1\"")
        replace(",?\\s*\\bopen\\s+(?:parenthesis|parentheses|paren|bracket)\\b,?\\s+(.+?),?\\s+"
                + "\\bclose\\s+(?:parenthesis|parentheses|paren|bracket)\\b", " ($1)")
        // "state hyphen of hyphen the hyphen art" → "state-of-the-art"; "add a hyphen" stays. "the" or "a" joins only
        // when it already continues a chain ("of-the hyphen art"), so it's repeated until the chain is whole.
        replace("\\bhyphen,?\\s+hyphen\\b", "hyphen")
        for _ in 0..<6 {
            let before = result
            replace("\\b((?<=-)[A-Za-z0-9]+|(?!(?:a|an|the|this|that|no)\\b)[A-Za-z0-9]+),?\\s+hyphen,?\\s+(?=[A-Za-z0-9])", "$1-")
            if result == before { break }
        }
        // "dot dot dot" → "…", "hashtag launch" → "#launch", "ampersand" → "&", "50 percent" → "50%".
        replace("[,]?\\s*\\bdot,?\\s+dot,?\\s+dot\\b[,.]?", "…")
        replace(notAfter + "\\bhashtag\\s+([A-Za-z0-9_]+)", "#$1")
        replace("\\s*" + notAfter + "\\bampersand\\b\\s*", " & ")
        replace("(\\d)\\s*percent\\b", "$1%")
        for (words, mark) in Self.spokenPunctuation {
            let spoken = words.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
                .joined(separator: "\\s+")
            let trailing = mark == "\n- " ? "[,.;:]?\\s*" : "[,.;:!?]?"
            let pattern = "(?i)[,.;:!?]?\\s*" + notAfter + "\\b" + spoken + "\\b" + trailing + "(?!\\s+of\\b)"
            result = result.replacingOccurrences(
                of: pattern, with: NSRegularExpression.escapedTemplate(for: mark), options: .regularExpression)
        }
        return result
    }

    /// An address spelled out loud: "jane at example dot com" → "jane@example.com", "murmurmac dot com" →
    /// "murmurmac.com". A word that ordinarily comes before "at" isn't a mailbox ("look at google dot com" →
    /// "look at google.com"), and "the dot com bubble" stays.
    private static let topLevelDomains = [
        "com", "org", "net", "io", "co", "uk", "dev", "app", "ai", "me", "lv", "de", "eu", "us", "info", "so", "sh",
        "xyz", "tech", "design", "studio",
    ]
    private static let notMailboxes: Set<String> = [
        "look", "looking", "looked", "check", "checking", "checked", "visit", "visiting", "see", "go", "going", "went",
        "find", "found", "available", "based", "live", "lives", "living", "work", "works", "working", "sign", "signed",
        "log", "logged", "stay", "staying", "arrive", "arrived", "meet", "meeting", "hosted", "deployed", "published",
        "launched", "it", "that", "this", "them", "me", "us", "you", "him", "her", "we", "i", "is", "are", "was", "were",
        "be", "here", "there", "now", "up", "out", "in", "on", "just", "also", "only", "even", "still",
    ]

    private func applySpokenAddresses(to text: String) -> String {
        let tld = Self.topLevelDomains.joined(separator: "|")
        let label = "[A-Za-z0-9][A-Za-z0-9-]*"
        let name = "(" + label + "(?:(?:\\s+dot\\s+|\\.)" + label + ")*)"
        func address(_ spoken: String) -> String {
            spoken.replacingOccurrences(of: "\\s+dot\\s+", with: ".", options: [.regularExpression, .caseInsensitive])
                .lowercased()
        }
        var result = text
        // Email the recognizer half-wrote — "email jane at example.com" — only right after a word that says it's an
        // address (email, mail, address, contact, reach, write to, send to), so "we're at booking.com" stays.
        if let regex = try? NSRegularExpression(pattern: "(?i)\\b(?:e-?mail|mail|address|contact|reach|write\\s+to|send\\s+(?:it\\s+|this\\s+)?to)"
            + "\\b[^.?!]{0,30}?(?<![\\w'’.@-])([A-Za-z0-9][A-Za-z0-9._-]*)\\s+at\\s+((?:[A-Za-z0-9-]+\\.)+(?:" + tld + "))\\b") {
            for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
                guard let box = Range(match.range(at: 1), in: result), let domain = Range(match.range(at: 2), in: result),
                      !Self.notMailboxes.contains(result[box].lowercased()) else { continue }
                let address = result[box].lowercased() + "@" + result[domain].lowercased()
                result.replaceSubrange(box.lowerBound..<domain.upperBound, with: address)
            }
        }
        // Email: mailbox "at" domain "dot" top-level domain.
        if let regex = try? NSRegularExpression(
            pattern: "(?i)\\b" + name + "\\s+at\\s+" + name + "\\s+dot\\s+(" + tld + ")\\b") {
            for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
                guard let whole = Range(match.range, in: result), let box = Range(match.range(at: 1), in: result),
                      let domain = Range(match.range(at: 2), in: result), let top = Range(match.range(at: 3), in: result)
                else { continue }
                let mailbox = String(result[box])
                guard !Self.notMailboxes.contains(mailbox.lowercased()) else { continue }
                result.replaceSubrange(whole, with: address(mailbox) + "@" + address(String(result[domain]))
                                       + "." + result[top].lowercased())
            }
        }
        // A bare domain: name "dot" top-level domain — not "the dot com bubble".
        if let regex = try? NSRegularExpression(pattern: "(?i)\\b" + name + "\\s+dot\\s+(" + tld + ")\\b") {
            for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
                guard let whole = Range(match.range, in: result), let site = Range(match.range(at: 1), in: result),
                      let top = Range(match.range(at: 2), in: result) else { continue }
                let first = result[site].split(separator: " ").first.map { $0.lowercased() } ?? ""
                guard !["the", "a", "an", "this", "that"].contains(first) else { continue }
                result.replaceSubrange(whole, with: address(String(result[site])) + "." + result[top].lowercased())
            }
        }
        return result
    }

    private func applyDictionary(to text: String) -> String {
        var result = text
        for (spoken, replacement) in dictionary {
            let escaped = NSRegularExpression.escapedPattern(for: spoken)
            result = result.replacingOccurrences(
                of: "(?i)\\b\(escaped)\\b", with: replacement,
                options: .regularExpression)
        }
        return result
    }

    private func tidyWhitespaceAndPunctuation(in text: String) -> String {
        var result = text
        // Collapse runs of spaces/tabs (not newlines).
        result = result.replacingOccurrences(
            of: "[ \\t]+", with: " ", options: .regularExpression)
        // No space before closing punctuation.
        result = result.replacingOccurrences(
            of: " +([,.;:!?])", with: "$1", options: .regularExpression)
        // Collapse duplicate punctuation like ",." or ".." left by edits —
        // but not ".," specifically: an abbreviation's period ("p.m.,")
        // immediately followed by a real, separate comma starting the next
        // clause is not a duplicate to clean up, and the old broader
        // pattern (any of ,.;:!? followed by either , or .) silently
        // deleted that comma. Found because it broke self-correction
        // detection downstream: "5pm, no, actually 6pm" needs that comma
        // to read as one corrected utterance rather than two sentences —
        // collapsing it to "5pm. No, actually 6pm" made the correction
        // pass in RewritePlan treat "No, actually..." as an unrelated new
        // sentence and leave both halves in the output.
        result = result.replacingOccurrences(
            of: ",\\.", with: ".", options: .regularExpression)
        result = result.replacingOccurrences(
            of: "\\.{2,}", with: ".", options: .regularExpression)
        // Trim each line.
        result = result
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
        // At most one blank line in a row.
        result = result.replacingOccurrences(
            of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func capitalizeSentences(in text: String) -> String {
        guard !text.isEmpty else { return text }
        var characters = Array(text)
        var capitalizeNext = true
        for index in characters.indices {
            let character = characters[index]
            if capitalizeNext, character.isLetter {
                characters[index] = Character(character.uppercased())
                capitalizeNext = false
            } else if ".!?\n".contains(character) {
                // "3 p.m. on Friday" must not become "3 p.M. On Friday": a period inside a word or closing an
                // abbreviation doesn't end the sentence.
                capitalizeNext = !(character == "." && Self.isAbbreviationPeriod(at: index, in: characters))
            } else if !character.isWhitespace, !"\"'([{".contains(character) {
                capitalizeNext = false
            }
        }
        return String(characters)
    }

    /// Abbreviations that carry on into the sentence: what follows "etc." or "vs." is rarely a new sentence.
    private static let continuingAbbreviations: Set<String> = ["etc.", "vs."]

    /// Whether the period at `index` belongs to a word rather than ending a sentence: it is glued to the next letter or
    /// digit ("p.m", "example.com", "3.5"), or it closes a dotted abbreviation ("p.m.", "e.g.", "i.e.", "U.S.") or one
    /// of the few that carry on into the sentence ("etc."). Titles ("Dr.", "Mr.") are left out on purpose: a name
    /// follows them, and capitalising it is right.
    private static func isAbbreviationPeriod(at index: Int, in characters: [Character]) -> Bool {
        if index + 1 < characters.count, characters[index + 1].isLetter || characters[index + 1].isNumber { return true }
        var start = index
        while start > 0, !characters[start - 1].isWhitespace { start -= 1 }
        let token = String(characters[start...index])
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'([{\u{201C}\u{2018}"))
            .lowercased()
        if continuingAbbreviations.contains(token) { return true }
        return token.range(of: #"^(\p{L}{1,2}\.){2,}$"#, options: .regularExpression) != nil
    }

    private func ensureTerminalPunctuation(in text: String) -> String {
        guard let last = text.last else { return text }
        if last.isLetter || last.isNumber {
            return text + "."
        }
        // A quote the recognizer closed on a comma at the very end ("He said, "Hello there,"") ends on a full stop.
        if text.hasSuffix(",\"") || text.hasSuffix(",)") {
            return String(text.dropLast(2)) + "." + String(last)
        }
        // A dictation that ends on a spoken quote or bracket ("…quote hello there unquote") still ends its sentence —
        // unless what's inside already did ("are you there?").
        if "\")".contains(last), let inside = text.dropLast().last, inside.isLetter || inside.isNumber {
            return text + "."
        }
        return text
    }

    // MARK: - Self test

    static func runSelfTest() -> Bool {
        let formatter = TextFormatter(dictionary: ["jira": "Jira", "claude code": "Claude Code"])
        let cases: [(input: String, expected: String)] = [
            ("um hello world", "Hello world."),
            ("this is, uh, a test", "This is, a test."),
            ("first line new line second line", "First line\nSecond line."),
            ("intro new paragraph details here", "Intro\n\nDetails here."),
            ("file a ticket in jira today", "File a ticket in Jira today."),
            ("i use claude code daily", "I use Claude Code daily."),
            ("hello world. this is fine", "Hello world. This is fine."),
            // A period that belongs to a word or an abbreviation doesn't start a sentence…
            ("let's meet at 3 p.m. on Friday", "Let's meet at 3 p.m. on Friday."),
            ("the shift is 9 a.m. to 5 p.m. tomorrow", "The shift is 9 a.m. to 5 p.m. tomorrow."),
            ("see you at 5 p.m.", "See you at 5 p.m."),
            ("use a tool, e.g. a hammer, for that", "Use a tool, e.g. a hammer, for that."),
            ("that is, i.e. the same thing", "That is, i.e. the same thing."),
            ("the U.S. team lands at 9 a.m. on Monday", "The U.S. team lands at 9 a.m. on Monday."),
            ("it costs five dollars etc. and more", "It costs five dollars etc. and more."),
            ("visit example.com today", "Visit example.com today."),
            ("version 3.5 is out", "Version 3.5 is out."),
            // …while every real sentence end keeps capitalising the next word, a name after a title included.
            ("we meet at 3 p.m. We'll bring lunch", "We meet at 3 p.m. We'll bring lunch."),
            ("it ends here. does it? yes. really", "It ends here. Does it? Yes. Really."),
            ("say hi. we go. plan b. then c", "Say hi. We go. Plan b. Then c."),
            ("ask dr. smith about it", "Ask dr. Smith about it."),
            ("  spaced   out   words ", "Spaced out words."),
            ("already punctuated!", "Already punctuated!"),
            ("", ""),
            ("Let's meet at 5pm, no, actually let's do 6pm.",
             "Let's meet at 5pm, no, actually let's do 6pm."),
            ("Wait,. let me think", "Wait. Let me think."),
            ("Sorry.. let me think", "Sorry. Let me think."),
            // The designed start-over behaviour is untouched when the repair is a clause of its own or a whole sentence was
            // retracted: the new thing carries its own predicate, so keeping "Let's meet" would glue two clauses together.
            ("Let's meet Tuesday. Scratch that, Wednesday works better.", "Wednesday works better."),
            ("Send the invoice on Friday, scratch that, Monday works for the team.", "Monday works for the team."),
            ("The meeting is Friday. Forget that. Let's do Monday instead.", "Let's do Monday instead."),
            // A bare replacement in the same sentence goes where the old one was, and the rest of the sentence stays.
            ("Buy milk, scratch that, eggs.", "Buy eggs."),
            ("We need 20 licenses, scratch that, 25.", "We need 25 licenses."),
            ("Let's do the demo on Monday, scratch that, Tuesday afternoon, and invite the whole team.",
             "Let's do the demo on Tuesday afternoon, and invite the whole team."),
            ("Testing testing, forget that. Let's start over with the real message.",
             "Let's start over with the real message."),
            ("First idea. Scratch that. Second idea. Scratch that. Third idea.",
             "Third idea."),
            ("First idea. Scratch that. Second idea, scratch that, third.", "Third."),
            ("I need to scratch that itch before we start.",
             "I need to scratch that itch before we start."),
            ("Don't forget that meeting tomorrow.",
             "Don't forget that meeting tomorrow."),
            ("This is a test, actually scratch that",
             "This is a test, actually scratch that."),
            // A restart that restates the sentence around a new day is a correction, not an erasure.
            ("We can do the meeting on the Friday 5PM, scratch that, do that on Tuesday.",
             "We can do the meeting on the Tuesday 5PM."),
            ("Um, we can do the meeting on the Friday 5PM, uh, scratch that, do that on Tuesday.",
             "We can do the meeting on the Tuesday 5PM."),
            ("Let's meet Friday at 3pm, scratch that, do it on Monday.", "Let's meet Monday at 3pm."),
            // Punctuation said out loud, whatever the recognizer put around it.
            ("hi john comma how are you question mark", "Hi john, how are you?"),
            ("Hi John, comma, how are you? Question mark.", "Hi John, how are you?"),
            ("send it tomorrow period thanks", "Send it tomorrow. Thanks."),
            ("that's amazing exclamation mark", "That's amazing!"),
            ("the list colon apples", "The list: apples."),
            // …but never the noun.
            ("add a comma after the name", "Add a comma after the name."),
            ("the trial period ends on Friday", "The trial period ends on Friday."),
            ("a period of two weeks", "A period of two weeks."),
            ("the period is over", "The period is over."),
            ("groceries bullet point milk bullet point eggs", "Groceries\n- milk\n- eggs."),
            // Addresses spelled out.
            ("email jane at example dot com today", "Email jane@example.com today."),
            ("write to support at murmurmac dot com", "Write to support@murmurmac.com."),
            ("visit murmurmac dot com today", "Visit murmurmac.com today."),
            ("look at google dot com", "Look at google.com."),
            ("the dot com bubble burst", "The dot com bubble burst."),
            ("meet me at the office", "Meet me at the office."),
            ("email jane at example.com", "Email jane@example.com."),
            ("my email is Jane at Example.com thanks", "My email is jane@example.com thanks."),
            ("we're at booking.com now", "We're at booking.com now."),
            ("look at example.com", "Look at example.com."),
            // Quotes, brackets, hyphens, "dot dot dot", hashtags, ampersand, percent.
            ("he said quote hello there unquote", "He said \"hello there\"."),
            ("He said, quote, hello there, unquote.", "He said, \"hello there\"."),
            ("get a quote from them", "Get a quote from them."),
            ("add the note open parenthesis optional close parenthesis", "Add the note (optional)."),
            ("Add the note, open parenthesis, optional, close parenthesis.", "Add the note (optional)."),
            ("He said, \"Hello there,\"", "He said, \"Hello there.\""),
            ("it is state hyphen of hyphen the hyphen art", "It is state-of-the-art."),
            ("add a hyphen here", "Add a hyphen here."),
            ("Well, dot, dot, dot, maybe.", "Well… maybe."),
            ("tag them with hashtag launch day", "Tag them with #launch day."),
            ("post a hashtag today", "Post a hashtag today."),
            ("salt ampersand pepper", "Salt & pepper."),
            ("growth was 50 percent this year", "Growth was 50% this year."),
        ]
        var passed = true
        for testCase in cases {
            let got = formatter.format(testCase.input)
            let ok = got == testCase.expected
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): \"\(testCase.input)\" -> \"\(got)\"" +
                  (ok ? "" : " (expected \"\(testCase.expected)\")"))
        }
        return passed
    }
}
