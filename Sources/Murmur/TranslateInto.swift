import Foundation
import NaturalLanguage

/// "Translate into" — you speak one language and Murmur pastes it in another, all on this Mac.
///
/// The words are recognised and cleaned up in the language you speak, translated as the last step before the paste
/// (after Harper, before a snippet's saved text goes back in), then checked: a name, number, date, link or snippet
/// that didn't come through, or text in the wrong language, pastes your own words instead — and the notch says why.
///
/// Which translator was measured on 2026-10-02 (`build/eval-results/translation`, 16 systems, 13 languages both ways
/// with English): Gemma 4 E4B when it's downloaded — the most natural, into and out of English; else the translator
/// built into macOS — nothing to download, reliable meaning, but no Latvian; EuroLLM 9B wherever Latvian is involved,
/// the one model that writes good Latvian. Terminals and code editors are never translated (`CodeField`).
enum TranslateInto {
    /// The languages offered — the 13 the measurement covered, nothing unmeasured.
    static let languages = ["en", "de", "fr", "es", "it", "pt", "nl", "sv", "pl", "ru", "ja", "zh", "lv"]

    /// "German" — in the app's own language, the way the Language menu names them.
    static func name(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code)?.capitalized(with: Locale.current) ?? code
    }

    /// The language part of a dictation locale ("lv-LV" → "lv", "zh-Hans-CN" → "zh").
    static func code(forLocale identifier: String) -> String {
        String(identifier.prefix(while: { $0 != "-" && $0 != "_" })).lowercased()
    }

    /// Two letters for the bar's chip ("LV", "EN").
    static func chip(_ code: String) -> String { code.uppercased() }

    // MARK: Settings

    private static let key = "translateInto"

    /// Settings ▸ Dictation ▸ Translate into: a language code, or nil when it's off (the default).
    static var target: String? {
        get { UserDefaults.standard.string(forKey: key).flatMap { languages.contains($0) ? $0 : nil } }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// An app's own choice in App Profiles wins — "" there means off in that app — else Settings.
    static func target(forBundleID bundleID: String?) -> String? {
        if let own = AppProfileStore.profile(forBundleID: bundleID)?.translateInto {
            return own.isEmpty ? nil : own
        }
        return target
    }

    /// What this dictation is translated from and into, or nil: off, already that language, or a code field (exact
    /// words there, always).
    static func pair(spokenLocale: String, bundleID: String?, codeField: CodeField.Kind?) -> (from: String, to: String)? {
        guard let to = target(forBundleID: bundleID), codeField == nil || codeField == .prompt else { return nil }
        let from = code(forLocale: spokenLocale)
        guard from != to, languages.contains(from) else { return nil }
        return (from, to)
    }

    // MARK: Which translator

    enum Engine: String, Sendable {
        case gemma, euroLLM, apple

        var displayName: String {
            switch self {
            case .gemma: "Gemma 4"
            case .euroLLM: "EuroLLM"
            case .apple: "macOS’s translator"
            }
        }
    }

    /// Latvian is the one offered language macOS can't translate and Gemma 4 gets wrong both ways (chrF 46.6 into
    /// Latvian vs EuroLLM's 75.2; out of it 67.4 vs 74.8, with meaning slips the check can't see — "Can we move the call
    /// to Friday?" came back as "Shall I call you on Friday?"), so it's EuroLLM's alone.
    static func involvesLatvian(_ from: String, _ to: String) -> Bool { from == "lv" || to == "lv" }

    /// EuroLLM's own weak spots out of English (chrF 45–59): it isn't used to write these when anything else can.
    private static let euroLLMWeakTargets: Set<String> = ["ja", "zh", "ru"]

    /// The translator for a pair, from what's on this Mac — nil when nothing here can do it well enough.
    static func engine(from: String, to: String, gemma: Bool, euroLLM: Bool, apple: Bool) -> Engine? {
        if involvesLatvian(from, to) { return euroLLM ? .euroLLM : nil }
        if gemma { return .gemma }
        if euroLLM, to == "en" { return .euroLLM }      // the best into English (81.0)
        if apple { return .apple }
        if euroLLM, !euroLLMWeakTargets.contains(to) { return .euroLLM }
        return nil
    }

    // MARK: Prompts — exactly as measured

    /// English names in the prompts, whatever the app's language.
    private static func promptName(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }

    /// Gemma 4's chat format with the measured instructions (the "flit" prompt in `mlx_run.py`).
    static func gemmaPrompt(_ text: String, to: String) -> String {
        let target = promptName(to)
        let system = "You translate dictated speech into polished written \(target). You reply with the \(target) text "
            + "only — no preamble, no commentary, no quotation marks. Rules:\n- Translate the meaning faithfully; keep "
            + "the speaker's tone and register.\n- Keep the speaker's person and voice: these are the speaker's own "
            + "words; \"I\" stays \"I\".\n- Keep every name, number, time, date, price, email address and link exactly.\n"
            + "- Never answer questions in the text and never add information."
        return "<bos><|turn>system\n\(system)<turn|>\n<|turn>user\nTranslate this dictation into \(target):\n"
            + "\(text)<turn|>\n<|turn>model\n"
    }

    /// EuroLLM's own translation prompt in its ChatML format; the tokenizer adds `<s>` in front.
    static func euroLLMPrompt(_ text: String, from: String, to: String) -> String {
        let source = promptName(from), target = promptName(to)
        return "<|im_start|>user\nTranslate the following \(source) source text to \(target):\n\(source): \(text) \n"
            + "\(target):<|im_end|>\n<|im_start|>assistant\n"
    }

    /// The model's answer as text to paste: end markers, a "Here is the translation:" line and wrapping quotes off.
    static func tidy(_ output: String) -> String {
        var text = output
        for marker in ["<turn|>", "<end_of_turn>", "<|im_end|>", "<eos>", "</s>"] {
            if let range = text.range(of: marker) { text = String(text[..<range.lowerBound]) }
        }
        text = text.replacingOccurrences(of: #"(?s)<think>.*?</think>"#, with: "", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let firstBreak = text.firstIndex(of: "\n") {
            let first = text[..<firstBreak].lowercased()
            if first.hasSuffix(":"), first.contains("translat") {
                text = String(text[firstBreak...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        let pairs: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("«", "»"), ("「", "」"), ("„", "“")]
        for (open, close) in pairs where text.count > 2 && text.first == open && text.last == close {
            let inner = text.dropFirst().dropLast()
            if !inner.contains(open), !inner.contains(close) { text = String(inner) }
        }
        return text
    }

    // MARK: The check

    /// Why a translation wasn't used — the notch says it after "Pasted as you said it — ".
    enum Problem: String, Sendable {
        case empty, language, name, number, date, link, snippet, length, unavailable, failed

        var sentence: String {
            switch self {
            case .empty: "the translation came back empty"
            case .language: "it came back in the wrong language"
            case .name: "a name didn’t match"
            case .number: "a number didn’t match"
            case .date: "a date didn’t match"
            case .link: "a link or email didn’t match"
            case .snippet: "a snippet didn’t come through"
            case .length: "the translation left words out"
            case .unavailable: "no translator for this language yet"
            case .failed: "the translator didn’t answer"
            }
        }
    }

    /// Anything wrong with `output` as a translation of `source`, or nil when it's safe to paste. Only checks that
    /// can't be fooled by a good translation: what's checked is what must come through unchanged (names, numbers,
    /// links, snippets, the weekday or month), and that it reads as the language asked for.
    static func problem(source: String, output: String, from: String, to: String, markers: [String] = []) -> Problem? {
        let output = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return .empty }
        if markers.contains(where: { !output.contains($0) }) { return .snippet }
        if links(in: source).contains(where: { !output.contains($0) }) { return .link }
        if !numbersKept(source: source, output: output, to: to) { return .number }
        if !datesKept(source: source, output: output, from: from, to: to) { return .date }
        if !namesKept(source: source, output: output, from: from, to: to) { return .name }
        if !lengthPlausible(source: source, output: output, from: from, to: to) { return .length }
        if !readsAs(to, output) { return .language }
        return nil
    }

    // Links and email addresses, exactly.
    static func links(in text: String) -> [String] {
        matches(of: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}|https?://\S+|www\.\S+"#, in: text)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)")) }
    }

    /// Every number said must be in the translation, however it's written there: "€1,240" may become "1.240 €",
    /// "3:30pm" may become "15:30" (a time up to 24 may move by 12 hours), "1240" may become "1,240", and a small one
    /// may be written out ("2 kids" → "zwei Kinder").
    static func numbersKept(source: String, output: String, to: String) -> Bool {
        let withoutLinks = links(in: source).reduce(source) { $0.replacingOccurrences(of: $1, with: " ") }
        let said = matches(of: #"\d+(?:[.,:' \x{00A0}\x{202F}]\d+)*"#, in: withoutLinks)
        guard !said.isEmpty else { return true }
        let written = matches(of: #"\d+(?:[.,:' \x{00A0}\x{202F}]\d+)*"#, in: output)
        let writtenGroups = Set(written.flatMap(digitGroups))
        let writtenWhole = Set(written.map { $0.filter(\.isNumber) }.map(unpadded))
        for number in said {
            let whole = unpadded(number.filter(\.isNumber))
            if writtenWhole.contains(whole) { continue }
            if let value = Int(whole), value <= 20, spelledOut(value, in: to, appearsIn: output) { continue }
            let groups = digitGroups(number)
            let allThere = groups.allSatisfy { group in
                if writtenGroups.contains(group) { return true }
                guard let value = Int(group), value <= 24 else { return false }
                return writtenGroups.contains(String(value + 12)) || (value > 12 && writtenGroups.contains(String(value - 12)))
                    || (value == 12 && writtenGroups.contains("0")) || (value == 0 && writtenGroups.contains("12"))
            }
            if !allThere { return false }
        }
        return true
    }

    private static func spelledOut(_ value: Int, in language: String, appearsIn text: String) -> Bool {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: language)
        formatter.numberStyle = .spellOut
        guard let word = formatter.string(from: NSNumber(value: value)).map(fold), !word.isEmpty else { return false }
        if isCJK(language) { return text.contains(word) }
        // "divi" is also "divas"/"divos" in Latvian, "zwei" is "zweiten" — a stem, as with weekdays.
        let stem = word.count > 4 ? String(word.dropLast(1)) : word
        return text.split(whereSeparator: { !$0.isLetter }).contains { fold(String($0)).hasPrefix(stem) }
    }

    private static func digitGroups(_ number: String) -> [String] {
        number.split(whereSeparator: { !$0.isNumber }).map { unpadded(String($0)) }
    }

    private static func unpadded(_ digits: String) -> String {
        let trimmed = digits.drop(while: { $0 == "0" })
        return trimmed.isEmpty ? "0" : String(trimmed)
    }

    /// A weekday or month that was said must be the same one in the translation — the slip the measurement caught
    /// ("Thursday" came back as "Wednesday"). Names come from each language's own calendar, so "ceturtdienu" is a
    /// Thursday and so is "Donnerstag"; in Japanese and Chinese "3月" is March.
    static func datesKept(source: String, output: String, from: String, to: String) -> Bool {
        for kind in [CalendarWord.weekday, .month] {
            let said = calendarIndices(kind, in: source, language: from)
            guard !said.isEmpty else { continue }
            let written = calendarIndices(kind, in: output, language: to)
            if !said.isSubset(of: written) { return false }
        }
        return true
    }

    enum CalendarWord { case weekday, month }

    static func calendarIndices(_ kind: CalendarWord, in text: String, language: String) -> Set<Int> {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language)
        let symbols: [[String]]
        switch kind {
        case .weekday:
            symbols = [formatter.weekdaySymbols, formatter.standaloneWeekdaySymbols]
                + (isCJK(language) ? [formatter.shortWeekdaySymbols, formatter.shortStandaloneWeekdaySymbols] : [])
        case .month:
            symbols = [formatter.monthSymbols, formatter.standaloneMonthSymbols]
        }
        var found = Set<Int>()
        if isCJK(language) {
            for list in symbols { for (index, symbol) in list.enumerated() where text.contains(symbol) { found.insert(index) } }
            if kind == .month {
                for month in 1...12 where text.range(of: "(?<![0-9])\(month)月", options: .regularExpression) != nil {
                    found.insert(month - 1)
                }
            }
            if kind == .weekday {
                let chinese = ["日", "一", "二", "三", "四", "五", "六"]
                for (index, day) in chinese.enumerated()
                where text.contains("周" + day) || text.contains("星期" + day) || text.contains("礼拜" + day) {
                    found.insert(index)
                }
            }
            return found
        }
        let words = text.split(whereSeparator: { !$0.isLetter }).map(String.init)
        for list in symbols {
            for (index, symbol) in list.enumerated() {
                let folded = fold(symbol)
                switch language {
                case "en":
                    // Always capitalised ("March", not the verb "march"); "May" is skipped — it's also a verb.
                    if folded == "may" { continue }
                    if words.contains(where: { $0 == symbol || $0 == symbol + "s" }) { found.insert(index) }
                case "lv", "pl", "ru":
                    // Declined ("ceturtdienu", "piątku", "пятницу"): the name less its last letter or two.
                    let stem = String(folded.prefix(max(4, folded.count - (folded.count > 6 ? 2 : 1))))
                    if words.contains(where: { fold($0).hasPrefix(stem) }) { found.insert(index) }
                case "de", "nl", "sv":
                    // Joined onto other words ("Montagmorgen", "måndagsmorgon").
                    if words.contains(where: { fold($0).hasPrefix(folded) }) { found.insert(index) }
                default:
                    // As written ("mars" is March, "mardi" is Tuesday).
                    if words.contains(where: { let word = fold($0); return word == folded || word == folded + "s" }) {
                        found.insert(index)
                    }
                }
            }
        }
        return found
    }

    /// People's and companies' names come through — allowing for Latvian or Polish endings ("Annai" → "Anna", "Toms" →
    /// "Tom"). Place names aren't checked (Munich is München), nor names written in another script, which are
    /// transliterated.
    static func namesKept(source: String, output: String, from: String, to: String) -> Bool {
        let names = self.names(in: source, language: from)
        guard !names.isEmpty else { return true }
        let written = output.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { fold(String($0)) }
        for name in names {
            let folded = fold(name)
            let isProduct = name.contains(where: \.isNumber) || name.dropFirst().contains(where: \.isUppercase)
            // A product-like name (iPhone, UploadClient, v2) stays as written in every script; a person's may be
            // transliterated into Japanese, Chinese or Russian, so it isn't checked there.
            if !isProduct, !isLatin(to) { continue }
            let kept = written.contains { word in
                if word == folded { return true }
                if isProduct { return false }
                let shorter = min(word.count, folded.count)
                guard shorter >= 3 else { return false }
                let common = zip(word, folded).prefix(while: { $0 == $1 }).count
                return common >= max(3, shorter - 1)
            }
            if !kept { return false }
        }
        return true
    }

    /// The names worth checking in what was said: people and organisations where NaturalLanguage can tag them (never
    /// German's capitalised nouns), else words capitalised mid-sentence; never an all-caps abbreviation (VAT becomes
    /// MwSt), a weekday or month, or anything in another script than Latin.
    static func names(in text: String, language: String) -> [String] {
        guard isLatin(language) else { return [] }
        var names: [String] = []
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        let nlLanguage = NLLanguage(rawValue: language)
        let tagged = NLTagger.availableTagSchemes(for: .word, language: nlLanguage).contains(.nameType)
        if tagged {
            tagger.setLanguage(nlLanguage, range: text.startIndex..<text.endIndex)
            tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                                 options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
                if tag == .personalName || tag == .organizationName {
                    names.append(contentsOf: text[range].split(separator: " ").map(String.init))
                }
                return true
            }
        } else if language != "de" {
            var sentenceStart = true
            for token in text.split(separator: " ", omittingEmptySubsequences: true) {
                let word = String(token).trimmingCharacters(in: .punctuationCharacters.union(.symbols))
                defer { sentenceStart = token.last.map { ".!?:".contains($0) } ?? false }
                guard let first = word.first, first.isUppercase, !sentenceStart, word.count > 1 else { continue }
                names.append(word)
            }
        }
        // Product-like words are names in any language: iPhone, UploadClient, v2.
        for token in text.split(whereSeparator: { $0.isWhitespace }) {
            let word = String(token).trimmingCharacters(in: .punctuationCharacters)
            if word.count > 1, word.first?.isLetter == true,
               word.contains(where: \.isNumber) || (word.first?.isLowercase == true && word.contains(where: \.isUppercase))
                || (word.first?.isUppercase == true && word.dropFirst().contains(where: \.isUppercase)
                    && word.contains(where: \.isLowercase)) {
                names.append(word)
            }
        }
        let calendar = Set(calendarWords(language))
        return names.filter { name in
            !(name.count > 1 && name.allSatisfy { $0.isUppercase || $0.isNumber }) && !calendar.contains(fold(name))
                && !links(in: text).contains(where: { $0.contains(name) }) && name != "I"
        }
    }

    private static func calendarWords(_ language: String) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language)
        return (formatter.weekdaySymbols + formatter.monthSymbols).map(fold)
    }

    /// Japanese or Chinese text is about a third as many characters as the same thing in English, so the length check
    /// allows for it; otherwise a translation under a third or over three times as long left something out or added.
    static func lengthPlausible(source: String, output: String, from: String, to: String) -> Bool {
        guard source.count >= 24 else { return true }
        var ratio = Double(output.count) / Double(source.count)
        if isCJK(to), !isCJK(from) { ratio *= 3 }
        if isCJK(from), !isCJK(to) { ratio /= 3 }
        return ratio > 0.33 && ratio < 3
    }

    /// Reads as `language` — or is too short to tell, or in a language NaturalLanguage can't recognise.
    static func readsAs(_ language: String, _ text: String) -> Bool {
        guard text.split(whereSeparator: \.isWhitespace).count >= 4 || (isCJK(language) && text.count >= 8)
        else { return true }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let (best, confidence) = recognizer.languageHypotheses(withMaximum: 1).first, confidence > 0.8
        else { return true }
        let expected: Set<String> = language == "zh" ? ["zh-Hans", "zh-Hant"] : [language]
        if expected.contains(best.rawValue) { return true }
        // A language NaturalLanguage doesn't know at all (it has no Latvian model) can't be told apart — let it pass
        // unless the text is plainly the language it was translated *from*, i.e. it came back untranslated.
        let known = NLLanguageRecognizer()
        known.languageConstraints = [NLLanguage(rawValue: language)]
        known.processString(text)
        if known.dominantLanguage == nil { return true }
        return false
    }

    static func isLatin(_ language: String) -> Bool { !["ru", "ja", "zh"].contains(language) }
    static func isCJK(_ language: String) -> Bool { language == "ja" || language == "zh" }

    /// Lower-cased without accents, for comparing names and calendar words ("Jānis" = "janis").
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en"))
    }

    private static func matches(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    // MARK: The example in Settings

    /// "You say" in each language — translated live by the real translator when the setting is on.
    static let examples: [String: String] = [
        "en": "Can we move the call to Friday at 10am?",
        "de": "Können wir den Anruf auf Freitag um 10 Uhr verschieben?",
        "fr": "On peut décaler l’appel à vendredi 10 h ?",
        "es": "¿Podemos pasar la llamada al viernes a las 10?",
        "it": "Possiamo spostare la chiamata a venerdì alle 10?",
        "pt": "Podemos mudar a chamada para sexta às 10h?",
        "nl": "Kunnen we het gesprek naar vrijdag om 10 uur verzetten?",
        "sv": "Kan vi flytta samtalet till fredag klockan 10?",
        "pl": "Czy możemy przenieść rozmowę na piątek na 10?",
        "ru": "Можем перенести звонок на пятницу на 10 утра?",
        "ja": "通話を金曜日の10時に変更できますか？",
        "zh": "我们可以把电话改到周五上午10点吗？",
        "lv": "Vai varam pārcelt zvanu uz piektdienu plkst. 10?",
    ]

    // MARK: Self-test

    static func runSelfTest() -> Bool {
        var passed = true
        func check(_ ok: Bool, _ label: String) {
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): translate into: \(label)")
        }

        // Which translator.
        check(engine(from: "en", to: "de", gemma: true, euroLLM: true, apple: true) == .gemma, "Gemma 4 first")
        check(engine(from: "en", to: "de", gemma: false, euroLLM: false, apple: true) == .apple,
              "macOS's translator with nothing downloaded")
        check(engine(from: "de", to: "en", gemma: false, euroLLM: true, apple: true) == .euroLLM,
              "EuroLLM into English (the best there) over macOS")
        check(engine(from: "en", to: "ja", gemma: false, euroLLM: true, apple: false) == nil,
              "EuroLLM never writes Japanese")
        check(engine(from: "lv", to: "en", gemma: true, euroLLM: true, apple: true) == .euroLLM, "EuroLLM for Latvian")
        check(engine(from: "lv", to: "en", gemma: true, euroLLM: false, apple: true) == nil,
              "out of Latvian only EuroLLM too")
        check(engine(from: "en", to: "lv", gemma: true, euroLLM: false, apple: true) == nil,
              "into Latvian only EuroLLM")
        check(code(forLocale: "zh-Hans-CN") == "zh" && code(forLocale: "lv-LV") == "lv", "locale to language")

        // Prompts, byte for byte as measured.
        check(gemmaPrompt("Labdien", to: "en").hasPrefix("<bos><|turn>system\nYou translate dictated speech into polished written English.")
              && gemmaPrompt("Labdien", to: "en").hasSuffix("Translate this dictation into English:\nLabdien<turn|>\n<|turn>model\n"),
              "Gemma 4 prompt")
        check(euroLLMPrompt("Labdien", from: "lv", to: "en")
              == "<|im_start|>user\nTranslate the following Latvian source text to English:\nLatvian: Labdien \nEnglish:<|im_end|>\n<|im_start|>assistant\n",
              "EuroLLM prompt")
        check(tidy("Here is the translation:\nSee you at 10.<turn|>") == "See you at 10.", "a preamble line goes")
        check(tidy("“See you at 10.”") == "See you at 10.", "wrapping quotes go")

        // The check, on real answers from the measurement.
        let lv0 = "Vai mēs varam pārcelt dizaina apskatu uz ceturtdienu plkst. 15.30? Annai vēl vajag vienu dienu, lai "
            + "pabeigtu slaidus."
        check(problem(source: lv0, output: "Is it possible to move the design presentation to Thursday at 3:30 PM? Anna "
                      + "still needs one more day to finish the slides.", from: "lv", to: "en") == nil,
              "Latvian → English with the time in 12 hours passes")
        check(problem(source: lv0, output: "Can we move the design review to Wednesday at 3:30 PM? Anna still needs a "
                      + "day to finish the slides.", from: "lv", to: "en") == .date,
              "Thursday turned Wednesday is caught")
        let en1 = "I'll send the invoice to billing@acme.com tonight, and the total is €1,240 including VAT."
        check(problem(source: en1, output: "Ich sende die Rechnung heute Abend an billing@acme.com, und der Gesamtbetrag "
                      + "beträgt 1.240 €, inklusive Mehrwertsteuer.", from: "en", to: "de") == nil,
              "€1,240 as 1.240 € and VAT as Mehrwertsteuer pass")
        check(problem(source: en1, output: "Ich sende die Rechnung heute Abend an billing@acme.de, und der Gesamtbetrag "
                      + "beträgt 1.240 €, inklusive Mehrwertsteuer.", from: "en", to: "de") == .link,
              "a changed email is caught")
        check(problem(source: en1, output: "Ich sende die Rechnung heute Abend an billing@acme.com, und der Gesamtbetrag "
                      + "beträgt 1.420 €, inklusive Mehrwertsteuer.", from: "en", to: "de") == .number,
              "1,240 turned 1.420 is caught")
        check(problem(source: en1, output: "請求書は今晩billing@acme.comに送ります。合計はVAT込みで1,240ユーロです。",
                      from: "en", to: "ja") == nil, "into Japanese passes")
        let lv2 = "Jaunā versija avarē, ja iestatījumu lapu atver divreiz, tāpēc, lūdzu, neizlaidiet to, kamēr Toms to "
            + "nav salabojis."
        check(problem(source: lv2, output: "The new version crashes if you open the settings page twice, so please don't "
                      + "release it until Tom has fixed it.", from: "lv", to: "en") == nil,
              "Toms → Tom (a Latvian ending) passes")
        check(problem(source: lv2, output: "The new version crashes if you open the settings page twice, so please don't "
                      + "release it until Peter has fixed it.", from: "lv", to: "en") == .name,
              "a changed name is caught")
        let en4 = "Remind me to call the dentist on Monday morning and to book train tickets for the 14th of March."
        check(problem(source: en4, output: "月曜日の午前中に歯医者に電話することと、3月14日の切符を予約することを思い出させてください。",
                      from: "en", to: "ja") == nil, "Monday and March into Japanese pass")
        check(problem(source: en4, output: "Erinnere mich daran, am Montagmorgen beim Zahnarzt anzurufen und die "
                      + "Zugtickets für den 14. Mai zu buchen.", from: "en", to: "de") == .date,
              "March turned May is caught")
        check(problem(source: "Danke für deine Hilfe gestern, der Kunde war von der Präsentation begeistert.",
                      output: "Thanks for your help yesterday, the client loved the presentation.",
                      from: "de", to: "en") == nil, "German's capitalised nouns aren't names")
        check(problem(source: "Thanks for your help yesterday, the client loved the presentation and wants to sign.",
                      output: "Thanks for your help yesterday, the client loved the presentation and wants to sign.",
                      from: "en", to: "de") == .language, "an untranslated answer is caught")
        check(problem(source: "Send SNIPPET1 to Anna today please.", output: "Schick heute bitte an Anna.",
                      from: "en", to: "de", markers: ["SNIPPET1"]) == .snippet, "a lost snippet is caught")
        check(problem(source: "I may come by at 5pm.", output: "Ich komme vielleicht um 17 Uhr vorbei.",
                      from: "en", to: "de") == nil, "\"may\" isn't the month")
        return passed
    }
}
