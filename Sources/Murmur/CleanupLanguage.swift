import Foundation
import FoundationModels

/// The languages besides English that the dictation clean-up runs in, and the rules it's held to in each.
///
/// Added 2026-10-01. The clean-up was English-only because, asked to "fix grammar" in Latvian (which Apple's model
/// doesn't support), it mangled word endings. Apple's on-device model does support Danish, Dutch, French, German,
/// Italian, Norwegian, Portuguese, Spanish, Swedish (and Japanese, Korean, Chinese, Turkish, Vietnamese). Measured on
/// 21 spoken-style sentences in German, French, Spanish, Italian, Dutch, Portuguese and Swedish (`build/eval-results/
/// multilingual/`): it kept the language every time, removed filler and stutters, and fixed "mit den Kunde" → "mit dem
/// Kunden" — but it also swapped or dropped meaning words in 4 of 21 ("Also ich glaube" → "Auch ich glaube", "revois"
/// → "reçoive", "mandarmi" → "mandare", a dropped "mir"). English has a full guard built on an English dictionary;
/// these languages get a stricter one (`LLMEditGuard`'s `.strict`): filler, stutters, punctuation, capitals, article
/// swaps, word endings and accents only — every other changed word goes back.
///
/// Only languages measured here are listed, and only those Apple's model reports it supports on this Mac. Languages
/// written without spaces (Japanese, Chinese) can't be checked word by word, so they're left out.
enum CleanupLanguage {
    struct Rules: Equatable {
        let code: String
        /// The language's name in English, for the model's instructions.
        let name: String
        /// Pure hesitation sounds — never real words — removed by the formatter and allowed out by the guard.
        let fillers: Set<String>
        /// Articles and their contractions: swapping one for another is a grammar fix (gender, case).
        let articles: Set<String>
        /// Words legitimately said twice in a row ("die, die …" — the ones who).
        let doubles: Set<String>
    }

    private static let all: [String: Rules] = [
        "de": Rules(code: "de", name: "German", fillers: ["äh", "ähm", "öh", "öhm", "ehm", "hm", "hmm"],
                    articles: ["der", "die", "das", "den", "dem", "des", "ein", "eine", "einen", "einem", "einer",
                               "eines"],
                    doubles: ["die", "das", "der", "den", "dem"]),
        "fr": Rules(code: "fr", name: "French", fillers: ["euh", "heu", "hum", "hmm"],
                    articles: ["le", "la", "les", "un", "une", "des", "du", "au", "aux"],
                    doubles: ["nous", "vous"]),
        "es": Rules(code: "es", name: "Spanish", fillers: ["eh", "em", "ehm", "mmm", "hmm"],
                    articles: ["el", "la", "los", "las", "un", "una", "unos", "unas", "al", "del"],
                    doubles: []),
        "it": Rules(code: "it", name: "Italian", fillers: ["ehm", "eh", "mmm", "hmm"],
                    articles: ["il", "lo", "la", "i", "gli", "le", "un", "uno", "una", "del", "della", "dei",
                               "degli", "delle", "al", "alla", "ai", "agli", "alle"],
                    doubles: []),
        "nl": Rules(code: "nl", name: "Dutch", fillers: ["eh", "ehm", "uh", "uhm", "euh", "hmm"],
                    articles: ["de", "het", "een"],
                    doubles: ["die", "dat"]),
        "pt": Rules(code: "pt", name: "Portuguese", fillers: ["hã", "ãh", "hum", "hmm"],
                    articles: ["o", "a", "os", "as", "um", "uma", "uns", "umas", "do", "da", "dos", "das", "no",
                               "na", "nos", "nas"],
                    doubles: []),
        "sv": Rules(code: "sv", name: "Swedish", fillers: ["öh", "öhm", "eh", "ehm", "hmm"],
                    articles: ["en", "ett", "den", "det", "de"],
                    doubles: []),
    ]

    /// The rules for a dictation language, or nil: English (it has its own, fuller pipeline), a language not measured
    /// here, or one Apple's model doesn't support on this Mac.
    static func rules(forLocale identifier: String,
                      modelSupports: (Locale) -> Bool = { SystemLanguageModel.default.supportsLocale($0) }) -> Rules? {
        let code = String(identifier.prefix { $0 != "-" && $0 != "_" }).lowercased()
        guard code != "en", let rules = all[code], modelSupports(Locale(identifier: identifier)) else { return nil }
        return rules
    }

    /// Every language with rules — for the self-test and the command line.
    static var codes: [String] { all.keys.sorted() }

    // MARK: - Self-test

    static func runSelfTest() -> Bool {
        var passed = true
        func check(_ ok: Bool, _ label: String) {
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): clean-up languages: \(label)")
        }
        let yes: (Locale) -> Bool = { _ in true }
        check(rules(forLocale: "de-DE", modelSupports: yes)?.name == "German", "German has rules")
        check(rules(forLocale: "en-GB", modelSupports: yes) == nil, "English keeps its own pipeline")
        check(rules(forLocale: "lv-LV", modelSupports: yes) == nil, "Latvian isn't one (the model doesn't support it)")
        check(rules(forLocale: "fr-FR", modelSupports: { _ in false }) == nil, "nothing when the model can't do it")
        check(all.values.allSatisfy { $0.fillers.isDisjoint(with: $0.articles) }, "no filler is also an article")

        // The stricter guard, on the model's real answers from the measurement.
        func guarded(_ code: String, _ original: String, _ edited: String) -> String {
            LLMEditGuard.apply(original: original, edited: edited, language: all[code], known: { _ in false }).text
        }
        check(guarded("de", "Kannst du kannst du mir bitte die Folien bis morgen schicken, damit ich sie mit den Kunde "
                      + "durchgehen kann?",
                      "Kannst du bitte die Folien bis morgen schicken, damit ich sie mit dem Kunden durchgehen kann?")
              == "Kannst du mir bitte die Folien bis morgen schicken, damit ich sie mit dem Kunden durchgehen kann?",
              "German: the stutter goes, the article and ending are fixed, the dropped \"mir\" comes back")
        check(guarded("de", "Also ich glaube wir sollten das Budget nochmal prüfen bevor wir die Bestellung abschicken",
                      "Auch ich glaube, wir sollten das Budget prüfen, bevor wir die Bestellung abschicken")
              == "Also ich glaube, wir sollten das Budget nochmal prüfen, bevor wir die Bestellung abschicken",
              "German: \"Also\" → \"Auch\" and the dropped \"nochmal\" go back, the commas stay")
        check(guarded("fr", "Est-ce que tu peux tu peux m'envoyer les diapositives avant demain, pour que je les revois "
                      + "avec le client?",
                      "Est-ce que tu peux m'envoyer les diapositives avant demain, pour que je les reçoive avec le client?")
              == "Est-ce que tu peux m'envoyer les diapositives avant demain, pour que je les revois avec le client?",
              "French: \"revois\" → \"reçoive\" (a different verb) goes back")
        check(guarded("it", "Puoi puoi mandarmi le slide entro domani così le rivedo con il cliente?",
                      "Puoi mandare le slide entro domani così le rivedo con il cliente?")
              == "Puoi mandarmi le slide entro domani così le rivedo con il cliente?",
              "Italian: the stutter goes, the lost \"mi\" (mandarmi) comes back")
        check(guarded("es", "Eh, solo quería decir que la reunión del jueves, em, se pasa al viernes.",
                      "Solo quería decir que la reunión del jueves se pasa al viernes.")
              == "Solo quería decir que la reunión del jueves se pasa al viernes.", "Spanish: filler sounds go")
        check(guarded("es", "Creo que esta bien", "Creo que está bien") == "Creo que está bien", "an accent fix stays")
        check(guarded("de", "Ich sehe die die kommen", "Ich sehe die kommen") == "Ich sehe die die kommen",
              "German: \"die die\" (the ones who) is not a stutter")
        check(guarded("de", "Wir sollten das prüfen", "Wir sollten das nochmal prüfen") == "Wir sollten das prüfen",
              "an added word goes back")
        check(!LLMEditGuard.hasCleanupWork("Das passt.", language: all["de"])
              && LLMEditGuard.hasCleanupWork("Äh das passt.", language: all["de"]),
              "a short clean sentence skips the model; a filler doesn't")
        check(TextFormatter(dictionary: [:], speaksEnglish: false, extraFillers: all["de"]!.fillers)
                .format("Äh, das Meeting am Donnerstag, ähm, auf Freitag.") == "Das Meeting am Donnerstag auf Freitag.",
              "the formatter takes a language's filler sounds out, commas and all")
        return passed
    }
}
