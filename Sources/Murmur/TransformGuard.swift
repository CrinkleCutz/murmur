import Foundation

/// A deterministic check on a Transform's output (`RewriteEngine.transform`), so a rewrite the user asked for can't
/// quietly change what they wrote. The small on-device model's known ways of going wrong, each measured on real
/// dictations: answering the text instead of rewriting it, changing or dropping a name, number, link or file name,
/// leaving out part of the text, and turning a question into a statement. When one of them shows, the transform is
/// refused and the user's text stays exactly as it was — a Transform that can't be trusted is worse than none.
enum TransformGuard {
    /// Why a rewrite was refused — said to the user after "…left your text as it was:". Never contains their words.
    enum Rejection: String, Equatable {
        case answered = "it answered your text instead of rewriting it"
        case changedDetail = "it would have changed a name, number, link or file name"
        case inventedDetail = "it would have added a number, link or file name you didn't say"
        case droppedContent = "it would have left out part of your text"
        case lostQuestion = "it would have turned your question into a statement"
        case changedMeaning = "it would have changed what your text says"
        case unchanged = "there was nothing to change"
        case wrongLength = "the result wasn't a rewrite of your text"
        case leakedInstructions = "it returned Murmur's own instructions instead of your text"
        case notShorter = "the summary came out about as long as what you said"
    }

    static func rejection(original: String, output: String, kind: Transform.Kind) -> Rejection? {
        let inLength = original.count, outLength = output.count
        switch kind {
        case .polish: if outLength > max(inLength * 2, inLength + 60) || outLength < inLength * 2 / 5 { return .wrongLength }
        case .prompt: if outLength > inLength * 8 + 600 || outLength < inLength / 3 { return .wrongLength }
        case .custom: if outLength > inLength * 10 + 800 { return .wrongLength }
        }
        if StyleRewriteGuard.openerRejection(original: original, rewritten: output) != nil { return .answered }
        if leaksInstructions(original: original, output: output) { return .leakedInstructions }
        if !keepsDetails(original: original, output: output) { return .changedDetail }
        if kind != .custom, !addsNoDetails(original: original, output: output) { return .inventedDetail }
        if kind == .polish, original.contains("?"), !output.contains("?") { return .lostQuestion }
        let minimumCoverage: Double? = switch kind {
        case .polish: 0.8
        case .prompt: 0.6
        case .custom: nil   // a translation or a summary legitimately uses other words
        }
        if let minimumCoverage, coverage(of: original, in: output) < minimumCoverage { return .droppedContent }
        return nil
    }

    /// Words from Murmur's own prompt that turned up in the output ("Rewrite the text inside <text> following the given
    /// instructions." came back as a prompt's goal, measured 2026-09-30) — unless the user's text had them too.
    static func leaksInstructions(original: String, output: String) -> Bool {
        let lowerOriginal = original.lowercased(), lowerOutput = output.lowercased()
        return ["<text>", "</text>", "<instructions>", "<example", "<rewritten>", "inside <text>",
                "following the given instructions", "following your instructions", "the editing instructions"]
            .contains { lowerOutput.contains($0) && !lowerOriginal.contains($0) }
    }

    // MARK: - Details that must survive

    /// Every email, link, file name, code-style identifier and number in the original is still in the output.
    static func keepsDetails(original: String, output: String) -> Bool {
        let lowerOutput = output.lowercased()
        for detail in details(in: original) where !lowerOutput.contains(detail.lowercased()) { return false }
        let outputNumbers = Set(numbers(in: output))
        return numbers(in: original).allSatisfy(outputNumbers.contains)
    }

    /// And the other way round: no number, email, link, file name or identifier that the original doesn't have — the
    /// kind of detail a model makes up ("the call starts at 10am") and a reader can't tell from the real ones.
    /// Spacing and capitals don't count: "Mac OS" written as "macOS" is the same name, not a new one.
    static func addsNoDetails(original: String, output: String) -> Bool {
        let squashedOriginal = original.lowercased().filter { !$0.isWhitespace }
        for detail in details(in: output) where !squashedOriginal.contains(detail.lowercased().filter { !$0.isWhitespace }) {
            return false
        }
        // Numbers said as words count too: "three hours" written as "3 hours" isn't a new number.
        let originalNumbers = Set(numbers(in: original)).union(spokenNumbers(in: original))
        return numbers(in: output).allSatisfy(originalNumbers.contains)
    }

    /// No person, place or date the original doesn't have: a capitalised word in the middle of a sentence (not its
    /// first word) must appear in the original, capitals aside — "Attendees: Sarah, Tom" from a dictation that named
    /// nobody is refused, "Tom will write the copy by Thursday" from one that said it passes.
    /// `loose` (Latvian): a name counts as said when its first four letters were — "Annai" for "Anna".
    static func addsNoNames(original: String, output: String, loose: Bool = false) -> Bool {
        let known = Set(original.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init))
        let stems = Set(known.filter { $0.count >= 4 }.map { String($0.prefix(4)) })
        for rawLine in output.split(whereSeparator: \.isNewline) {
            // Dashes and slashes join words without a space ("Saturday—it"), and so does the dot in a file name: the
            // "ReportExporter" of "ReportExporter.swift" was said, "ReportExporterswift" never was.
            let line = rawLine.replacingOccurrences(of: #"[—–/()\[\]]"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"(?<=[\p{L}\d])[._@:+-](?=[\p{L}\d])"#, with: " ", options: .regularExpression)
            // Sentence starts: the line's first word and the first word after . ! ? : — a list item or a heading
            // starts with a capital anyway.
            var sentenceStart = true
            for token in line.split(separator: " ") {
                // "I'm", "Sophie's": the word before the apostrophe.
                let word = token.prefix { $0 != "'" && $0 != "’" }.filter { $0.isLetter || $0.isNumber }
                defer { sentenceStart = token.last.map { ".!?:".contains($0) } ?? false }
                guard let first = word.first, first.isUppercase, !sentenceStart, word != "I",
                      word.count > 1 else { continue }
                let lower = word.lowercased()
                if !known.contains(lower), !(loose && lower.count >= 4 && stems.contains(String(lower.prefix(4)))) {
                    return false
                }
            }
        }
        return true
    }

    /// Emails, links and domains, file names ("ExportViewModel.swift"), identifiers with a capital inside
    /// ("RevenueCat", "iOS") or an underscore ("retry_count").
    static func details(in text: String) -> [String] {
        let pattern = #"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+"#
            + #"|(?:https?://)?(?:[A-Za-z0-9-]+\.)+(?:"# + ProtectedSpans.topLevelDomains + #")\b(?:/\S*)?"#
            + #"|\b[\w-]{2,}\.(?:swift|js|ts|tsx|jsx|py|rb|go|rs|java|kt|json|md|html|css|yml|yaml|txt|sh|c|h|m|cpp)\b"#
            + #"|\b[a-z]+[A-Z][A-Za-z0-9]*\b|\b[A-Z][a-z0-9]+[A-Z][A-Za-z0-9]*\b|\b[A-Za-z]+_[A-Za-z0-9_]+\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:")) }
    }

    /// Numbers said as words ("three", "twenty", "a thousand"), as digits.
    static func spokenNumbers(in text: String) -> Set<String> {
        let units = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven",
                     "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
        let tens = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80,
                    "ninety": 90]
        let ordinals = ["first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "tenth": 10, "twelfth": 12,
                        "twentieth": 20, "thirtieth": 30]
        let words = text.lowercased().split { !$0.isLetter }.map(String.init)
        var found = Set<String>()
        for (index, word) in words.enumerated() {
            if let value = units.firstIndex(of: word) { found.insert(String(value)) }
            if let value = ordinals[word] { found.insert(String(value)) }
            if let value = tens[word] {
                found.insert(String(value))
                if index + 1 < words.count, let unit = units.firstIndex(of: words[index + 1]), unit < 10 {
                    found.insert(String(value + unit))
                }
            }
            if word == "hundred" { found.insert("100") }
            if word == "thousand" { found.insert("1000") }
            // Latvian: the first letters of each number word, so every ending counts ("trīs", "divās", "piecdesmit").
            for (stem, value) in latvianNumbers where word.hasPrefix(stem) { found.insert(String(value)) }
        }
        return found
    }

    private static let latvianNumbers: [(String, Int)] = [
        ("nulle", 0), ("vien", 1), ("div", 2), ("trīs", 3), ("trij", 3), ("četr", 4), ("piec", 5), ("seš", 6),
        ("septiņ", 7), ("astoņ", 8), ("deviņ", 9), ("desmit", 10), ("vienpadsmit", 11), ("divpadsmit", 12),
        ("divdesmit", 20), ("trīsdesmit", 30), ("četrdesmit", 40), ("piecdesmit", 50), ("simt", 100), ("tūkstot", 1000),
        ("pirm", 1), ("otr", 2), ("treš", 3), ("ceturt", 4), ("piekt", 5), ("sest", 6)]

    /// The numbers written with digits, thousands separators ignored ("1,240" → "1240").
    static func numbers(in text: String) -> [String] {
        let joined = text.replacingOccurrences(of: #"(?<=\d),(?=\d{3}\b)"#, with: "", options: .regularExpression)
        guard let regex = try? NSRegularExpression(pattern: #"\d+"#) else { return [] }
        return regex.matches(in: joined, range: NSRange(joined.startIndex..., in: joined))
            .compactMap { Range($0.range, in: joined).map { String(joined[$0]) } }
    }

    // MARK: - Content kept

    private static let minor: Set<String> = [
        "about", "also", "and", "because", "been", "being", "but", "can", "could", "does", "doesn", "don", "from", "have",
        "here", "into", "it's", "just", "like", "maybe", "more", "much", "only", "really", "should", "some", "that",
        "their", "them", "then", "there", "these", "they", "thing", "things", "think", "this", "those", "very", "want",
        "was", "were", "what", "when", "where", "which", "while", "will", "with", "would", "your", "yeah", "okay", "so",
        "actually", "basically", "kind", "sort", "even", "still", "again", "need", "needs", "make", "made", "going",
        "myself", "yourself", "ourselves", "there's", "that's", "what's", "here's", "it'll", "i've", "we're", "they're",
        "you're", "doesn't", "don't", "can't", "won't", "isn't", "aren't", "didn't", "wasn't", "couldn't", "wouldn't",
    ]

    /// The share of the original's content words (four letters or more, not minor words) that the output still has —
    /// matched loosely, so "overwhelm" and "overwhelmed", "fixed" and "fix" count as the same word.
    static func coverage(of original: String, in output: String) -> Double {
        func words(_ text: String) -> [String] {
            text.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "'") }.map(String.init)
        }
        let content = words(original).filter { $0.count >= 4 && !minor.contains($0) }
        guard !content.isEmpty else { return 1 }
        let stems = Set(words(output).map { String($0.prefix(5)) })
        return Double(content.filter { stems.contains(String($0.prefix(5))) }.count) / Double(content.count)
    }

    /// How many things that were said left no trace in the output: a clause of the original (up to a comma, a full
    /// stop, "and" or "but") none of whose content words the output has. `coverage` can't see these — "and don't add
    /// any new dependencies" is two words in twenty — yet a dropped clause is a dropped requirement (measured
    /// 2026-10-10: Apple's model left out that one, "no pandas please", and "we were charged 240 pounds twice"). A
    /// clause counts with two content words, or one after a "no", "not" or "don't"; "there's a couple of things"
    /// doesn't.
    static func missedClauses(of original: String, in output: String) -> Int {
        func words(_ text: String) -> [String] {
            text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
                .split { !($0.isLetter || $0.isNumber || $0 == "'") }.map(String.init)
        }
        let stems = Set(words(output).map { String($0.prefix(5)) })
        let negations: Set<String> = ["no", "not", "never", "without", "dont", "don't", "doesnt", "doesn't", "cant", "can't",
                                      "wont", "won't"]
        // A comma inside a number (1,800) or a full stop inside a name (2.3, Report.swift) ends nothing.
        let clauses = original.replacingOccurrences(of: #"(?<!\d),(?!\d)|[.;:!?]+(?=\s|$)|\n|\s(?:and|but)\s"#, with: "\u{1}",
                                                    options: [.regularExpression, .caseInsensitive]).split(separator: "\u{1}")
        return clauses.filter { clause in
            let all = words(String(clause))
            let content = all.filter { $0.count >= 4 && !minor.contains($0) && !negations.contains($0) }
            guard content.count >= 2 || (content.count == 1 && all.contains(where: negations.contains)) else { return false }
            return !content.contains { stems.contains(String($0.prefix(5))) }
        }.count
    }

    static func runSelfTest() -> Bool {
        var passed = true
        func check(_ ok: Bool, _ label: String) {
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): transform guard: \(label)")
        }
        let pricing = "i want a section that shows the three pricing plans and it should work on mobile and dont add any new dependencies"
        check(missedClauses(of: pricing, in: "Create a section that shows the three pricing plans.\n\nWhat I need:\n- It works on mobile.") == 1
              && missedClauses(of: pricing, in: "Create a section that shows the three pricing plans.\n\nConstraints:\n- It must work on "
                               + "mobile.\n- Don't add any new dependencies.") == 0
              && missedClauses(of: "there's a couple of things, the total is 1,800 pounds, no pandas",
                               in: "The total is 1,800 pounds.") == 1,
              "a requirement that left no trace is counted; filler isn't")
        let polishIn = "so the export button it doesnt work on the settings page, can you check ExportViewModel.swift"
        check(rejection(original: polishIn, output: "The export button doesn't work on the settings page. Can you check "
                        + "ExportViewModel.swift?", kind: .polish) == nil, "a real polish passes")
        check(rejection(original: "What time does the call start on Thursday?",
                        output: "The call starts at 10am on Thursday.", kind: .polish) != nil,
              "an answered question is refused")
        check(rejection(original: "Send the invoice to jane@example.com by 3pm, the total is 1,240 pounds.",
                        output: "Send the invoice to jane@example.org by 3pm; the total is 1,240 pounds.", kind: .polish)
              == .changedDetail, "a changed email is refused")
        check(rejection(original: "Send the invoice by 3pm, the total is 1,240 pounds.",
                        output: "Send the invoice by 3pm; the total is 1,420 pounds.", kind: .polish) == .changedDetail,
              "a changed number is refused")
        check(rejection(original: "Send the invoice by 3pm, the total is 1,240 pounds.",
                        output: "Send the invoice by 3 p.m.; the total is 1240 pounds.", kind: .polish) == nil,
              "…while the same number written differently passes")
        check(rejection(original: "The navigation bar opens on hover but the Dock slides up and covers the icons so I "
                            + "can't click them, and Wispr Flow handles this well, so research how they do it.",
                        output: "Research how Wispr Flow handles its navigation bar.", kind: .prompt) != nil,
              "a prompt that leaves out most of what was said is refused")
        check(rejection(original: "can you make the search fast",
                        output: "Sure! Here's how to make the search fast: add an index.", kind: .prompt) == .answered,
              "a prompt that answers the request is refused")
        check(rejection(original: "What time does the client call start on Thursday?",
                        output: "What time does the client call start on Thursday at 10am?", kind: .polish)
              == .inventedDetail, "a made-up time is refused")
        check(addsNoNames(original: "we drove up on saturday and it took three hours", output: "We drove up on Saturday—it took 3 hours.")
              && addsNoNames(original: "can someone fix the boiler this week", output: "Broken boiler\nIt stopped, I'm home")
              && addsNoDetails(original: "it took about three hours", output: "It took about 3 hours."),
              "\"I'm\" is not a name, and a number said as a word isn't a new one")
        check(addsNoNames(original: "i think it's the pagination in ReportExporter.swift",
                          output: "I think the issue is the pagination in ReportExporter.swift.")
              && !addsNoNames(original: "make the page faster", output: "Make the page faster with React.Lazy."),
              "a file name that was said is not a new name; one that wasn't is")
        check(rejection(original: "my Mac OS bar slides up over the icons", output: "My macOS bar slides up over the icons.",
                        kind: .polish) == nil, "a name only respelled (Mac OS → macOS) is not an invented one")
        check(rejection(original: "the header looks too small on the settings page and needs to be bigger",
                        output: "Rewrite the text inside <text> following the given instructions.\n\nContext:\nThe header "
                            + "looks too small on the settings page and needs to be bigger.", kind: .prompt)
              == .leakedInstructions, "a prompt that returns Murmur's own instructions is refused")
        check(rejection(original: "Translate this into German please: good morning team",
                        output: "Guten Morgen, Team", kind: .custom) == nil,
              "a custom transform may use other words (a translation)")
        return passed
    }
}
