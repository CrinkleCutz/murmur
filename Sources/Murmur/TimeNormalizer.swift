import Foundation

/// Writes every clock time the same way — "3pm", "3:30pm", "10am" — whatever the speech engine made of it.
///
/// Engines disagree: "3 p.m.", "3 PM", "3 pm" and "3:30 P.M." all come back for the same spoken time, and some write
/// the minutes like a number — "3.30pm", "330 pm", "1030 AM" — instead of like a time. All of them become "3pm" or
/// "3:30pm": lowercase, no space, no periods, and no ":00" on the hour.
///
/// A number is only ever read as a time when am/pm follows it directly, so "930 Main Street", "930 dollars" and
/// "3.30 dollars" are left alone, and only for a valid clock time (hour 1–12, minutes 00–59). English only — the
/// caller gates it on the dictation language, like every stage that reads words — and never in Raw style.
enum TimeNormalizer {
    // 1 = the number ("3", "3:30", "3.30", "330", "1030"), 2 = a/p, 3 = the dot inside "p.m.", 4 = a dot right after.
    private static let regex = try? NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}.:,$£€])(\d{1,2}[:.]\d{2}|\d{3,4}|\d{1,2})[ \u00A0\u202F]?([ap])(?:(\.)[ \u00A0\u202F]?)?m\b(\.)?"#,
        options: [.caseInsensitive])

    static func normalize(_ spoken: String) -> String {
        let text = colonForDottedTimes(digitsForSpelledTimes(wordsAfterHalfPast(spoken)))
        guard let regex, !text.isEmpty else { return text }
        let source = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return text }
        let result = NSMutableString(string: text)
        for match in matches.reversed() {
            guard let (hour, minute) = clock(source.substring(with: match.range(at: 1))),
                  (1...12).contains(hour), (0...59).contains(minute) else { continue }
            let meridiem = source.substring(with: match.range(at: 2)).lowercased()
            var out = "\(hour)" + (minute == 0 ? "" : String(format: ":%02d", minute)) + meridiem + "m"
            let dotted = match.range(at: 3).location != NSNotFound
            let trailingDot = match.range(at: 4).location != NSNotFound
            // A dot after "pm" is a real full stop. A dot after "p.m." is the abbreviation's own — kept only when it
            // also ends the sentence.
            if trailingDot, !dotted || endsSentence(after: source.substring(from: NSMaxRange(match.range))) { out += "." }
            result.replaceCharacters(in: match.range, with: out)
        }
        return result as String
    }

    // MARK: - Times an engine spelled out

    private static let hours = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve"]
    private static let units = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
    private static let teens = ["ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
    private static let tens = ["twenty", "thirty", "forty", "fifty"]

    // 1 = the word before (or nothing, at the start), 2 = the hour, 3 = the minutes if any; am/pm must follow.
    private static let spelled: NSRegularExpression? = {
        let unit = units.joined(separator: "|")
        let minutes = "oh[ -](?:\(unit))|\(teens.joined(separator: "|"))|(?:\(tens.joined(separator: "|")))(?:[ -](?:\(unit)))?"
        return try? NSRegularExpression(
            pattern: "(?:(?<![\\p{L}\\p{N}'’])([\\p{L}'’]+),? |^|(?<=\\n))(\(hours.joined(separator: "|")))(?:[ -](\(minutes)))?"
                + "(?=[ \u{00A0}\u{202F}]?[ap](?:\\.[ \u{00A0}\u{202F}]?)?m\\b)",
            options: [.caseInsensitive])
    }()

    /// What comes before a time: "at six PM", "for six PM", "nine a.m. to five p.m.". Without one of these, an hour
    /// alone before "PM" is as likely a count of product managers ("we need two PM leads").
    private static let timeLeadIns: Set<String> = [
        "at", "by", "for", "until", "till", "before", "after", "around", "about", "from", "to", "between", "and", "or",
        "actually", "is", "it's", "it’s", "past", "than", "like", "say"]
    /// "one PM" is a person far more often than the others, so it needs a word that only a time follows.
    private static let strictLeadIns: Set<String> = ["at", "by", "until", "till", "before", "after", "around"]

    /// Parakeet writes a spoken time as words about as often as digits — "six PM", "three thirty PM" — and the pattern
    /// above only reads digits, so the same sentence came out as "6pm" on one engine and "six PM" on another. The hour
    /// (and minutes) become digits here, only when am/pm follows directly, and the pattern above does the rest.
    private static func digitsForSpelledTimes(_ text: String) -> String {
        guard let spelled, !text.isEmpty else { return text }
        let source = text as NSString
        let result = NSMutableString(string: text)
        for match in spelled.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            let hourWord = source.substring(with: match.range(at: 2)).lowercased()
            guard let hour = hours.firstIndex(of: hourWord).map({ $0 + 1 }) else { continue }
            var minute: Int?
            if match.range(at: 3).location != NSNotFound {
                let words = source.substring(with: match.range(at: 3)).lowercased().split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init)
                if words.first == "oh", words.count == 2 { minute = units.firstIndex(of: words[1]).map { $0 + 1 } }
                else if let teen = teens.firstIndex(of: words[0]) { minute = teen + 10 }
                else if let ten = tens.firstIndex(of: words[0]) {
                    minute = (ten + 2) * 10 + (words.count == 2 ? (units.firstIndex(of: words[1]) ?? 0) + 1 : 0)
                }
                guard minute != nil else { continue }
            } else {
                // An hour on its own: only after a word a time follows.
                let before = match.range(at: 1).location == NSNotFound ? "" : source.substring(with: match.range(at: 1)).lowercased()
                guard (hourWord == "one" ? strictLeadIns : timeLeadIns).contains(before) else { continue }
            }
            let digits = "\(hour)" + (minute.map { String(format: ":%02d", $0) } ?? "")
            let hourStart = match.range(at: 2).location
            result.replaceCharacters(in: NSRange(location: hourStart, length: NSMaxRange(match.range) - hourStart), with: digits)
        }
        return result as String
    }

    // MARK: - "half past 3"

    private static let relative = try? NSRegularExpression(
        pattern: "\\b(half past|quarter past|quarter to|(?:five|ten|twenty|twenty-five) (?:past|to)) (1[0-2]|[1-9])\\b(?![:.]?\\d)(?![ \u{00A0}\u{202F}]?[ap]\\.?m\\b)",
        options: [.caseInsensitive])

    /// A recogniser writes "half past three" as "half past 3", which is neither words nor a time: the hour goes back
    /// to a word, the way the phrase is written.
    private static func wordsAfterHalfPast(_ text: String) -> String {
        guard let relative, text.range(of: " past ", options: .caseInsensitive) != nil
            || text.range(of: " to ", options: .caseInsensitive) != nil else { return text }
        let source = text as NSString
        let result = NSMutableString(string: text)
        for match in relative.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            guard let hour = Int(source.substring(with: match.range(at: 2))), (1...12).contains(hour) else { continue }
            result.replaceCharacters(in: match.range(at: 2), with: hours[hour - 1])
        }
        return result as String
    }

    // MARK: - Dotted times beside a day

    private static let days = "monday|tuesday|wednesday|thursday|friday|saturday|sunday|today|tonight|tomorrow|yesterday|morning|afternoon|evening"
    // "Friday at 10.30" (1 = the dot) or "at 10.30 on Friday" (2 = the dot).
    private static let dotted = try? NSRegularExpression(
        pattern: "\\b(?:\(days)) at (?:[01]?\\d|2[0-3])(\\.)[0-5]\\d(?![\\d%])"
            + "|\\bat (?:[01]?\\d|2[0-3])(\\.)[0-5]\\d(?= (?:on |this |next )?(?:\(days))\\b)",
        options: [.caseInsensitive])

    /// Whisper writes "ten thirty" as "10.30". Without am/pm that could as well be a price or a version, so it is read
    /// as a time only with a day right beside it — "Friday at 10.30", "at 10.30 tomorrow" — and written "10:30".
    private static func colonForDottedTimes(_ text: String) -> String {
        guard let dotted, text.contains(".") else { return text }
        let result = NSMutableString(string: text)
        for match in dotted.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).reversed() {
            for group in 1...2 where match.range(at: group).location != NSNotFound {
                result.replaceCharacters(in: match.range(at: group), with: ":")
            }
        }
        return result as String
    }

    /// Hour and minutes of "3", "3:30", "3.30", "330" or "1030".
    private static func clock(_ number: String) -> (Int, Int)? {
        if let separator = number.firstIndex(where: { $0 == ":" || $0 == "." }) {
            guard let hour = Int(number[..<separator]), let minute = Int(number[number.index(after: separator)...]) else { return nil }
            return (hour, minute)
        }
        guard let value = Int(number) else { return nil }
        return number.count >= 3 ? (value / 100, value % 100) : (value, 0)
    }

    /// Capitalised words that carry on after a time rather than start a new sentence ("3 p.m. Friday", "3 p.m. Eastern").
    private static let continuationWords: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december",
        "est", "edt", "cst", "cdt", "mst", "mdt", "pst", "pdt", "gmt", "utc", "cet", "cest", "bst", "ist", "jst",
        "eastern", "central", "mountain", "pacific", "greenwich", "standard", "daylight"]

    /// Whether the dot that follows "p.m." also ends the sentence, judged from what comes next: the end of the text or a
    /// line, a closing quote, or a capitalised word that isn't a day/month/zone. A lowercase word, a comma or other
    /// punctuation, a digit or a closing bracket means the dot was only the abbreviation's.
    private static func endsSentence(after rest: String) -> Bool {
        let trimmed = rest.drop(while: { $0 == " " || $0 == "\t" || $0 == "\u{00A0}" || $0 == "\u{202F}" })
        guard let next = trimmed.first else { return true }
        if next.isNewline { return true }
        if ",;:!?)]}".contains(next) || next.isNumber { return false }
        if "\"'\u{201D}\u{2019}".contains(next) { return true }
        guard next.isLetter else { return true }
        if next.isLowercase { return false }
        return !continuationWords.contains(String(trimmed.prefix(while: { $0.isLetter })).lowercased())
    }

    // MARK: - Self test

    static func runSelfTest() -> Bool {
        var passed = true
        func check(_ input: String, _ expected: String, _ label: String) {
            let got = normalize(input)
            let ok = got == expected
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): times: \(label)\(ok ? "" : " — got \(got.debugDescription)")")
        }
        // One style, whatever the engine wrote.
        check("Let's meet at 3 p.m. on Friday.", "Let's meet at 3pm on Friday.", "\"3 p.m.\" mid-sentence")
        check("The shift is 9 a.m. to 5 p.m. tomorrow.", "The shift is 9am to 5pm tomorrow.", "a range")
        check("See you at 5 p.m.", "See you at 5pm.", "a time ending the text keeps its full stop")
        check("We meet at 3 p.m. We'll bring lunch.", "We meet at 3pm. We'll bring lunch.", "a time ending a sentence keeps its full stop")
        check("Meet at 3 p.m. Friday.", "Meet at 3pm Friday.", "a weekday after the time is not a new sentence")
        check("At 3 p.m., we go.", "At 3pm, we go.", "the abbreviation's dot before a comma")
        check("Is it at 3 p.m.?", "Is it at 3pm?", "before a question mark")
        check("Lunch is at 12:30 PM.", "Lunch is at 12:30pm.", "\"12:30 PM\"")
        check("The call is at 3 PM today.", "The call is at 3pm today.", "\"3 PM\"")
        check("Starts at 3 P.M. sharp", "Starts at 3pm sharp", "\"3 P.M.\"")
        check("It starts at 3:30 pm.", "It starts at 3:30pm.", "\"3:30 pm\"")
        check("10:00 AM standup", "10am standup", "\":00\" on the hour is dropped")
        check("Let's meet at 3 p.m., 4 p.m. or 5 p.m.", "Let's meet at 3pm, 4pm or 5pm.", "a list of times")
        check("Let's meet at 3\u{202F}PM.", "Let's meet at 3pm.", "a narrow no-break space before PM")
        check("Let's meet at 3pm and 3:30pm.", "Let's meet at 3pm and 3:30pm.", "already in the house style")
        // Times written like numbers become times.
        check("It ends at 3.30pm.", "It ends at 3:30pm.", "\"3.30pm\"")
        check("Call me at 330 pm", "Call me at 3:30pm", "\"330 pm\"")
        check("Standup is at 1030 AM.", "Standup is at 10:30am.", "\"1030 AM\"")
        check("I'm free from 9.15 a.m. until 11.45 a.m.", "I'm free from 9:15am until 11:45am.", "dotted minutes")
        // Times an engine spelled out.
        check("Can you book the room for six PM?", "Can you book the room for 6pm?", "\"six PM\"")
        check("Can you book the room for five PM, actually six PM?", "Can you book the room for 5pm, actually 6pm?", "two spelled times")
        check("Let's meet at three thirty PM on Friday.", "Let's meet at 3:30pm on Friday.", "\"three thirty PM\"")
        check("The shift is nine a.m. to five p.m. tomorrow.", "The shift is 9am to 5pm tomorrow.", "a spelled range")
        check("Standup is at ten oh five am.", "Standup is at 10:05am.", "\"ten oh five am\"")
        check("Lunch at twelve forty-five p.m.", "Lunch at 12:45pm.", "\"twelve forty-five p.m.\"")
        check("Eleven thirty a.m. works for me.", "11:30am works for me.", "a spelled time opening the text")
        check("See you at one p.m.", "See you at 1pm.", "\"at one p.m.\"")
        for keep in [
            "I asked one PM about it.", "We need two PM leads.", "We are looking for one PM to join.", "The three PMs agreed.",
            "Twenty people came.", "I am sure the five of us can do it.",
        ] { check(keep, keep, "leaves alone: \(keep.prefix(40))") }
        check("Call me on Friday at half past 3.", "Call me on Friday at half past three.", "\"half past 3\"")
        check("It's quarter to 5 now, and I have 3 emails to send.", "It's quarter to five now, and I have 3 emails to send.", "only the hour of a spoken time")
        // A dotted time with a day beside it.
        check("Let's meet Friday at 10.30.", "Let's meet Friday at 10:30.", "\"Friday at 10.30\"")
        check("The call is at 9.15 tomorrow.", "The call is at 9:15 tomorrow.", "\"at 9.15 tomorrow\"")
        check("See you at 14.30 on Monday.", "See you at 14:30 on Monday.", "\"at 14.30 on Monday\"")
        for keep in ["We're at 2.10 now.", "It was priced at 10.30 last week.", "Growth is at 3.50%.", "Friday at 10.305 units."] {
            check(keep, keep, "leaves alone: \(keep.prefix(40))")
        }
        // Not times: no am/pm, not a clock time, or not a time word.
        for keep in [
            "The PM said no.", "We hired 2 PMs.", "We looked at 930 Main Street.", "That costs 930 dollars.",
            "The price is 3.30 dollars.", "Come at 15:30.", "Set it to 2030 pm.", "I have 3 amigos.",
            "The version is 2.10 and then 12.5 pm.", "It costs $3.30 pm.",
        ] { check(keep, keep, "leaves alone: \(keep.prefix(40))") }
        return passed
    }
}
