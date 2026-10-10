import Foundation

/// A deterministic check on the Style and Concise rewrite passes: they may reword, but they may not put words in the
/// speaker's mouth.
///
/// A tone rewrite is *supposed* to change the wording, so it can't be held to the input's words the way the plain cleanup
/// is (`LLMEditGuard`). It still went wrong in one recognisable way: the on-device model answered the dictation instead of
/// restyling it. Measured on 14 ordinary dictations, Casual turned "Can we push the launch by a week?" into "Sure, let's
/// push the launch by a week." — a question became a decision — and opened a third of its outputs with a "Hey!" nobody said;
/// Very casual added a "thanks!". A length check alone (the only guard this path had) can't see any of that: the output is
/// the right size, it just isn't what was said.
///
/// So the rewrite is refused when a sentence of it *opens* with a reply ("Sure,", "Okay,", "Of course", "Yes,"), a greeting
/// ("Hey", "Hi", "Dear"), thanks or a sign-off/offer ("Let me know if…", "Feel free to…", "Best regards") that the speaker
/// never said. If they said something of the same kind anywhere in the dictation, that kind is allowed: a rewrite may turn
/// "Thanks so much" into "Thank you so much", or "I can do that, sure" into "Sure, I can do that". The caller then keeps the
/// text it already had — exactly what "As spoken" would have delivered.
///
/// Templates are exempt: an Email Draft is *meant* to add a greeting and a sign-off, and to grow the text. English only,
/// like the stages around it (the caller gates on the dictation's language).
enum StyleRewriteGuard {
    /// Why a rewrite was refused. The raw values are what the app logs, so they never contain the user's words.
    enum Rejection: String, Equatable {
        case tooLong = "far longer than the dictation"
        case reply = "opens with a reply the speaker never said"
        case greeting = "opens with a greeting the speaker never said"
        case thanks = "adds thanks the speaker never said"
        case offer = "adds an offer or sign-off the speaker never said"
        case details = "changes a name, a number or a link"
        case question = "turns a question into a statement"
        case instructions = "repeats its own instructions"
        case example = "borrows wording from an example"
        case repeated = "says the same sentence twice"
        case drift = "strays too far from what was said"
        case symbols = "adds symbols the speaker never said"
        case spelling = "misspells a word"
        case negation = "adds or loses a \"not\""
        case apology = "loses an apology"
        case hedge = "adds or loses a \"maybe\""
    }

    /// The most a Style or Concise pass may grow the text. A real incident turned a 3-word dictation into a fabricated
    /// paragraph; nothing that restyles a sentence has a reason to multiply it.
    static func plausibleLimit(forCharacters count: Int) -> Int { max(count * 2, count + 40) }

    /// nil when the rewrite may be used; otherwise why not.
    static func rejection(original: String, rewritten: String, isTemplate: Bool) -> Rejection? {
        guard !isTemplate else { return nil }
        if rewritten.count > plausibleLimit(forCharacters: original.count) { return .tooLong }
        return openerRejection(original: original, rewritten: rewritten)
    }

    /// For a tone rewrite (`RewriteEngine.restyle`), which is asked to change more than the old one did: everything
    /// `rejection` refuses, and a rewrite that loses or invents a name, number, link or identifier, stops asking what
    /// the speaker asked, or hands back its own instructions (`TransformGuard`'s checks, as for a Polish).
    static func toneRejection(original: String, rewritten: String, style: WritingStyle? = nil) -> Rejection? {
        if let refused = rejection(original: original, rewritten: rewritten, isTemplate: false) { return refused }
        if let style, borrowsFromExamples(original: original, rewritten: rewritten, style: style) { return .example }
        if repeatsItself(original: original, rewritten: rewritten) { return .repeated }
        if TransformGuard.leaksInstructions(original: original, output: rewritten) { return .instructions }
        guard TransformGuard.keepsDetails(original: original, output: rewritten),
              TransformGuard.addsNoDetails(original: original, output: rewritten),
              TransformGuard.addsNoNames(original: original, output: rewritten) else { return .details }
        if original.contains("?") != rewritten.contains("?") { return .question }
        let plain = CharacterSet.alphanumerics.union(.whitespacesAndNewlines)
            .union(CharacterSet(charactersIn: ".,!?;:'\u{2019}\"\u{201c}\u{201d}()-\u{2013}\u{2014}&/"))
        let spoken = Set(original.unicodeScalars)
        if !rewritten.unicodeScalars.allSatisfy({ plain.contains($0) || spoken.contains($0) }) { return .symbols }
        // Every word is one the speaker used, a dictionary word, or a shortening people text with — not "shud", "dem"
        // or "tomorow".
        let known = Set(toneWords(original))
        if toneWords(rewritten).contains(where: { word in
            word.count >= 3 && word.allSatisfy(\.isLetter) && !known.contains(word) && !shortenings.contains(word)
                && !bareNegations.contains(word) && !HarperChecker.isKnownEnglishWord(word)
        }) { return .spelling }
        // A greeting stays the greeting it was: "Hi Sam" is not "Yo Sam" or "Dear Sam".
        if let greeting = toneWords(original).first, greetings.contains(greeting), toneWords(rewritten).first != greeting {
            return .greeting
        }
        // What a change of tone must never change: whether it was a no, whether they said sorry, whether they were sure.
        let said = toneWords(original), wrote = toneWords(rewritten)
        if isNegated(said) != isNegated(wrote) { return .negation }
        if said.contains(where: apologies.contains), !wrote.contains(where: apologies.contains) { return .apology }
        if said.contains(where: hedges.contains), !wrote.contains(where: softeners.contains) { return .hedge }
        if wrote.contains(where: hedges.contains), !said.contains(where: softeners.contains) { return .hedge }
        // Most of the speaker's own words are still there, and most of what's there is theirs. Measured on 42 rewrites
        // (2026-10-09): every sound one kept at least 0.67 and 0.50; "It is imperative that this shipment is not
        // conducted prior to…" 0.25 and 0.14, "Please review the section in question." 1.00 and 0.25.
        guard TransformGuard.coverage(of: original, in: rewritten) >= minimumKept(for: style),
              TransformGuard.coverage(of: rewritten, in: original) >= minimumOwn else { return .drift }
        return nil
    }

    /// What no change of tone may change, whoever asked for it (a Style or a spoken "make it more confident"): a
    /// question is still a question, a "not" is still there, and the greeting is the one that was said.
    static func changesWhatWasMeant(original: String, rewritten: String) -> Bool {
        let said = toneWords(original), wrote = toneWords(rewritten)
        if original.contains("?") != rewritten.contains("?") || isNegated(said) != isNegated(wrote) { return true }
        // Dropping "hey, so" is a change of tone; "Yo" or "Dear" in its place is a greeting nobody said.
        if let greeting = said.first, greetings.contains(greeting), let opener = wrote.first, opener != greeting,
           greetings.contains(opener) || ["yo", "hiya", "howdy", "greetings"].contains(opener) { return true }
        return false
    }

    private static func toneWords(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .split { !($0.isLetter || $0.isNumber || $0 == "'") }.map(String.init)
    }
    private static func isNegated(_ words: [String]) -> Bool {
        words.contains { negations.contains($0) || $0.hasSuffix("n't") || bareNegations.contains($0) }
    }
    private static let negations: Set<String> = [
        "not", "no", "never", "cannot", "without", "unable", "nobody", "nothing", "none", "neither", "nor", "nowhere"]
    private static let greetings: Set<String> = ["hi", "hey", "hello", "dear", "morning", "good"]
    private static let shortenings: Set<String> = [
        "pls", "plz", "thx", "tmrw", "min", "mins", "sec", "secs", "gonna", "wanna", "gotta", "kinda", "sorta", "bout",
        "yea", "yeah", "yep", "nope", "prob", "probs", "tho", "cuz", "cos", "ill", "ive", "youre", "thats", "whats",
        "lemme", "gimme", "info", "msg", "btw", "asap", "fyi", "idk", "imo", "omw", "brb", "lol", "wed", "thu", "fri", "sat",
        "sun", "mon", "tue", "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec"]
    /// The same, texted without the apostrophe.
    private static let bareNegations: Set<String> = [
        "dont", "cant", "wont", "didnt", "doesnt", "isnt", "arent", "wasnt", "werent", "shouldnt", "couldnt", "wouldnt",
        "havent", "hasnt", "hadnt", "aint"]
    private static let apologies: Set<String> = [
        "sorry", "apologies", "apologise", "apologize", "apology", "regret", "regrettably", "unfortunately"]
    /// What marks the speaker as unsure…
    private static let hedges: Set<String> = [
        "think", "guess", "reckon", "probably", "maybe", "perhaps", "might", "kinda", "sorta", "kind", "sort", "almost",
        "nearly", "mostly", "roughly", "possibly"]
    /// …and what a rewrite may say instead.
    private static let softeners: Set<String> = hedges.union([
        "believe", "suppose", "suggest", "likely", "may", "could", "somewhat", "rather", "largely", "approximately",
        "seems", "appears", "fairly", "quite", "prob", "probs", "mayb"])

    /// The share of the dictation's content words a tone rewrite must keep, and the share of its own that must be the
    /// dictation's (`TransformGuard.coverage`, each way).
    /// Formal swaps casual words for professional ones, so it may replace more of them; a casual tone loosens the
    /// speaker's own words and has no reason to bring new ones ("failed" → "crashed", "send" → "shoot").
    static func minimumKept(for style: WritingStyle?) -> Double {
        switch style {
        case .casual: 0.8
        case .veryCasual: 0.7
        default: 0.5
        }
    }
    static let minimumOwn = 0.4

    /// A sentence that opens with the first four words of one of the tone's own examples, when the dictation has no
    /// such run: the model wrote the example, not the speaker ("The numbers are incorrect. I will…" for a dictation
    /// about a draft). Four, so that what an example teaches — "Thank you for…", "Could you…" — stays usable.
    static func borrowsFromExamples(original: String, rewritten: String, style: WritingStyle) -> Bool {
        func words(_ text: [Character]) -> [String] { LLMEditGuard.tokenize(text).map(\.norm).filter { !$0.isEmpty } }
        let spoken = " " + words(Array(original)).joined(separator: " ") + " "
        let openings = Set(style.toneExamples.flatMap { sentences(of: $0.output) }
            .map { words($0).prefix(4).joined(separator: " ") }.filter { $0.split(separator: " ").count == 4 })
        let said = Set(words(Array(original)).map { String($0.prefix(5)) })
        return sentences(of: rewritten).contains { sentence in
            let opener = Array(words(sentence).prefix(4))
            guard openings.contains(opener.joined(separator: " ")), !spoken.contains(" " + opener.joined(separator: " ") + " ")
            else { return false }
            // The words an example is there to teach ("Could you…", "Thank you…", "I am sorry…") aren't borrowed.
            return opener.contains { $0.count >= 4 && !toneOpeners.contains($0) && !said.contains(String($0.prefix(5))) }
        }
    }
    private static let toneOpeners: Set<String> = ["could", "would", "please", "thank", "thanks", "believe", "sorry", "that", "rather"]

    /// The same sentence twice, when it was said once — the model starting over ("send the deck before lunch. send the
    /// deck before lunch", measured 2026-10-09).
    static func repeatsItself(original: String, rewritten: String) -> Bool {
        func keys(_ text: String) -> [String] {
            sentences(of: text).map { LLMEditGuard.tokenize($0).map(\.norm).filter { !$0.isEmpty }.joined(separator: " ") }
                .filter { $0.contains(" ") }
        }
        let written = keys(rewritten)
        return Set(written).count < written.count && Set(keys(original)).count == keys(original).count
    }

    /// Only the reply / greeting / thanks / sign-off check, without the length limit — for rewrites that may grow the
    /// text (a Transform building a prompt).
    static func openerRejection(original: String, rewritten: String) -> Rejection? {
        let spoken = LLMEditGuard.tokenize(Array(original)).map(\.norm)
        for family in families where !family.isSpoken(in: spoken) {
            for sentence in sentences(of: rewritten) where family.opens(sentence) { return family.rejection }
        }
        return nil
    }

    // MARK: - What counts

    private struct Family {
        let rejection: Rejection
        /// Phrases (lowercased words) that mark the family when a sentence starts with them.
        let phrases: [[String]]
        /// Phrases that only count with punctuation straight after them — "No, …" is a reply, "No later than Friday" is not.
        let punctuated: [[String]]

        /// The speaker said something of this kind, so a rewrite of it isn't an invention.
        func isSpoken(in words: [String]) -> Bool {
            (phrases + punctuated).contains { StyleRewriteGuard.contains($0, in: words) }
        }

        func opens(_ sentence: [Character]) -> Bool {
            let tokens = LLMEditGuard.tokenize(sentence)
            func starts(with phrase: [String]) -> Int? {
                guard tokens.count >= phrase.count, zip(tokens, phrase).allSatisfy({ $0.norm == $1 }) else { return nil }
                return tokens[phrase.count - 1].end
            }
            if phrases.contains(where: { starts(with: $0) != nil }) { return true }
            return punctuated.contains { phrase in
                guard let end = starts(with: phrase) else { return false }
                return end >= sentence.count || StyleRewriteGuard.punctuation.contains(sentence[end])
            }
        }
    }

    private static let punctuation: Set<Character> = [",", ".", "!", "?", ";", ":", "\u{2013}", "\u{2014}"]

    private static let families: [Family] = [
        Family(rejection: .reply, phrases: [
            ["sure"], ["certainly"], ["absolutely"], ["definitely"], ["of", "course"], ["okay"], ["ok"], ["alright"],
            ["all", "right"], ["got", "it"], ["understood"], ["noted"], ["yeah"], ["yep"], ["no", "problem"],
            ["no", "worries"], ["you're", "welcome"], ["i'd", "be", "happy"], ["i", "would", "be", "happy"]],
               punctuated: [
            ["yes"], ["no"], ["nope"], ["great"], ["awesome"], ["perfect"], ["sounds", "good"], ["sounds", "great"]]),
        Family(rejection: .greeting, phrases: [
            ["hey"], ["hi"], ["hello"], ["hiya"], ["heya"], ["yo"], ["dear"], ["greetings"], ["good", "morning"],
            ["good", "afternoon"], ["good", "evening"]],
               punctuated: []),
        Family(rejection: .thanks, phrases: [["thanks"], ["thank"], ["cheers"], ["much", "appreciated"], ["appreciate", "it"]],
               punctuated: []),
        Family(rejection: .offer, phrases: [
            ["let", "me", "know"], ["hope", "this", "helps"], ["hope", "that", "helps"], ["i", "hope", "this", "helps"],
            ["i", "hope", "that", "helps"], ["feel", "free"], ["happy", "to", "help"], ["glad", "to", "help"],
            ["talk", "soon"], ["speak", "soon"], ["have", "a", "great"], ["have", "a", "good"], ["take", "care"],
            ["best", "regards"], ["kind", "regards"], ["warm", "regards"], ["best", "wishes"]],
               punctuated: []),
    ]

    /// `phrase` appears among `words` as consecutive words.
    private static func contains(_ phrase: [String], in words: [String]) -> Bool {
        guard !phrase.isEmpty, words.count >= phrase.count else { return false }
        for start in 0...(words.count - phrase.count) where Array(words[start..<start + phrase.count]) == phrase {
            return true
        }
        return false
    }

    /// The text split into sentences at ". ", "! ", "? " and line breaks — each keeps its own end mark.
    private static func sentences(of text: String) -> [[Character]] {
        let chars = Array(text)
        var result: [[Character]] = []
        var current: [Character] = []
        for (index, c) in chars.enumerated() {
            if c == "\n" {
                if !current.isEmpty { result.append(current); current = [] }
                continue
            }
            current.append(c)
            if ".!?".contains(c), index + 1 == chars.count || chars[index + 1].isWhitespace {
                result.append(current)
                current = []
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    // MARK: - Self test

    static func runSelfTest() -> Bool {
        var passed = true
        func check(_ ok: Bool, _ label: String) {
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): style guard: \(label)")
        }
        func refused(_ original: String, _ rewritten: String, _ expected: Rejection, _ label: String) {
            let got = rejection(original: original, rewritten: rewritten, isTemplate: false)
            let note = got == expected ? "" : " (got \(got?.rawValue ?? "accepted"))"
            check(got == expected, "refuses \(label)\(note)")
        }
        func allowed(_ original: String, _ rewritten: String, _ label: String) {
            let got = rejection(original: original, rewritten: rewritten, isTemplate: false)
            let note = got.map { " (refused: \($0.rawValue))" } ?? ""
            check(got == nil, "allows \(label)\(note)")
        }

        // The measured leaks.
        refused("Can we push the launch by a week?", "Sure, let's push the launch by a week.", .reply,
                "a question answered with \"Sure,\"")
        refused("Can you send the final deck when you get a chance before lunch and maybe mention that the numbers are updated?",
                "Sure, let me know when you can send the final deck before lunch and just mention that the numbers are updated.",
                .reply, "a request turned into a reply")
        refused("Could you review the pull request when you have time?",
                "Hey! Could you take a look at the pull request when you get a chance?", .greeting, "an invented greeting")
        refused("Could you review the pull request when you have time?",
                "hey, can you check out that pull request when you get a chance? thanks!", .greeting, "a greeting and thanks")
        refused("Could you review the pull request when you have time?",
                "Could you take a look at the pull request when you get a chance? Thanks!", .thanks, "thanks added at the end")
        refused("The report is attached.", "The report is attached. Let me know if you need anything else.", .offer,
                "an offer added at the end")
        refused("Please send it by Friday.", "Please send it by Friday. Best regards", .offer, "a sign-off added")

        // Other reply shapes.
        refused("Can we push the launch by a week?", "Yes, we can push the launch by a week.", .reply, "\"Yes,\"")
        refused("Is the printer working?", "No, it isn't.", .reply, "\"No,\"")
        refused("Can you take this?", "Of course! I can take this.", .reply, "\"Of course\"")
        refused("Can you take this?", "Okay, I can take this.", .reply, "\"Okay\"")
        refused("Can you take this?", "Absolutely, I'll take this.", .reply, "\"Absolutely\"")
        refused("Can you take this?", "I'd be happy to take this.", .reply, "\"I'd be happy to\"")
        refused("Send the deck.", "SURE, send the deck.", .reply, "a reply in capitals")
        refused("Send the deck.", "\u{201C}Sure, send the deck.\u{201D}", .reply, "a reply inside quotation marks")
        refused("We should ship it. Then tell the customers.", "We should ship it. Great, then tell the customers.", .reply,
                "a reply that opens a later sentence")
        refused("Send the deck.", "Hello, send the deck.", .greeting, "\"Hello\"")
        refused("Send the deck.", "Send the deck.\nCheers", .thanks, "\"Cheers\" on its own line")

        // Length — the check this path always had.
        let short = "In this section."
        refused(short, String(repeating: "This section covers the details. ", count: 6), .tooLong, "a 3-word dictation grown into a paragraph")
        allowed("Can you send it?", "Could you please send it over?", "a longer sentence within the limit")

        // What the pass is for: rewording, and the speaker's own words in a different shape.
        allowed("Thanks so much for fixing that issue.", "Thanks for fixing that!", "thanks the speaker did say")
        allowed("Thanks so much for fixing that issue.", "Thank you so much for resolving that issue.", "\"thanks\" restyled as \"thank you\"")
        allowed("I can't make it tonight, sorry.", "Sorry, I can't make it tonight.", "an apology moved to the front")
        allowed("Sounds good, see you then.", "Sounds good! See you soon.", "\"Sounds good\" the speaker said")
        allowed("I can do that, sure.", "Sure, I can do that.", "\"sure\" moved to the front")
        allowed("Hey Sophie, can you send it?", "Hi Sophie, can you send it?", "a spoken greeting swapped for another")
        allowed("Let me know if it works.", "Let me know if that works.", "an offer the speaker made")
        allowed("Please send the report by Friday at the latest.", "No later than Friday, please send the report.",
                "\"No later than\" isn't a reply")
        allowed("There is no problem with it.", "It's no problem at all.", "\"no problem\" inside a sentence")
        allowed("The numbers are updated, I'm sure of it.", "I'm sure the numbers are updated.", "\"sure\" inside a sentence")
        allowed("Please call the dentist tomorrow morning.", "Just call the dentist tomorrow morning.", "an ordinary rewording")
        allowed("Can you send the final deck before lunch?", "Could you send over the final deck before lunch?", "a reworded request")
        allowed("Do you know if the printer works?", "Does the printer work?", "a question kept as a question")
        allowed("Hi.", "Hi.", "unchanged text")

        // Templates are meant to add a greeting and a sign-off, and to grow the text.
        check(rejection(original: "Send the deck.", rewritten: "Hi team,\n\nPlease send the deck.\n\nBest regards,\nAlex", isTemplate: true) == nil,
              "leaves templates alone")
        // A tone rewrite (`toneRejection`): the wording may change, what was said may not.
        for (original, rewritten, expected, label): (String, String, Rejection?, String) in [
            ("So I think we should send them the updated file when you get a chance.",
             "I believe we should send them the updated file when you have a moment.", nil, "a formal rewording"),
            ("Can we push the launch by a week?", "We will push the launch by a week.", .question, "a question made a statement"),
            ("The call is at three with Anna.", "The call is at 4 with Anna.", .details, "a changed number"),
            ("Tell them the report is late.", "Tell Sarah the report is late.", .details, "an invented name"),
            ("Send the deck to sam@example.com today.", "Please send the deck today.", .details, "a dropped address"),
            ("Can we push the launch by a week?", "Sure, let's push the launch by a week.", .reply, "an answer"),
            ("Tell Anna I'll be fifteen minutes late.", "Please tell Maya the room is booked.", .details, "an example's name"),
        ] {
            let got = toneRejection(original: original, rewritten: rewritten)
            check(got == expected, "tone: \(expected == nil ? "allows" : "refuses") \(label)"
                  + (got == expected ? "" : " (got \(got?.rawValue ?? "accepted"))"))
        }
        check(toneRejection(original: "Hi Sam, I'll send the draft tomorrow.", rewritten: "The numbers are wrong. I will send the draft tomorrow.",
                            style: .formal) == .example, "tone: refuses a sentence opened with an example's words")
        check(toneRejection(original: "Thanks for the update on the launch.", rewritten: "Thank you for the update on the launch.",
                            style: .formal) == nil, "tone: …but not the wording an example teaches")
        check(toneRejection(original: "We should not ship this before the review is done.",
                            rewritten: "It is imperative that this shipment is not conducted prior to the completion of the review process.")
              == .drift, "tone: refuses a rewrite that left the speaker's words behind")
        check(toneRejection(original: "Let's look at the next part in this section.", rewritten: "let's look at the next part in this section ¯\\_(ツ)_/¯")
              == .symbols, "tone: refuses an added emoticon")
        check(toneRejection(original: "The build failed twice and I had to restart the server.",
                            rewritten: "The build crashed twice and I had to reboot the server.", style: .casual) == .drift,
              "tone: refuses a casual rewrite that swaps the speaker's words")
        check(toneRejection(original: "So I think we should send them the updated file when you get a chance.",
                            rewritten: "Think we should send them the updated file when you get a chance.", style: .casual) == nil,
              "tone: allows a dropped lead-in")
        check(toneRejection(original: "So I think we should send them the file.", rewritten: "so i think we shud send dem the file")
              == .spelling, "tone: refuses made-up spellings")
        check(toneRejection(original: "Please don't forward this to anyone outside the team.", rewritten: "pls dont forward this to anyone outside the team")
              == nil, "tone: allows the shortenings people text with")
        check(toneRejection(original: "Hi Sam, I'll send the draft tomorrow.", rewritten: "Yo Sam, I'll send the draft tomorrow.")
              == .greeting, "tone: refuses a changed greeting")
        check(toneRejection(original: "I'm sorry but I won't be able to make it on Friday.",
                            rewritten: "I am sorry, but I will not be able to make it on Friday.", style: .formal) == nil,
              "tone: allows an opener an example shares when the words are the speaker's")
        check(toneRejection(original: "We should not ship this before the review.", rewritten: "We should ship this before the review.")
              == .negation, "tone: refuses a lost \"not\"")
        check(toneRejection(original: "I'm sorry but I won't be able to make it on Friday.", rewritten: "I'm bummed but I won't be able to make it on Friday.")
              == .apology, "tone: refuses a lost apology")
        check(toneRejection(original: "The migration is kind of done but we still need to test it.",
                            rewritten: "The migration is done, but we still need to test it.") == .hedge, "tone: refuses a lost hedge")
        check(toneRejection(original: "The first one is too busy.", rewritten: "The first one is kinda too busy.") == .hedge,
              "tone: refuses an added hedge")
        check(toneRejection(original: "I think we should move the review to Thursday.", rewritten: "I believe we should move the review to Thursday.")
              == nil, "tone: allows a hedge said another way")
        check(toneRejection(original: "Tell Anna I'll be fifteen minutes late.", rewritten: "Please inform Anna that I will be fifteen minutes late.")
              == nil, "tone: allows a formal request")
        check(toneRejection(original: "Send the deck before lunch.", rewritten: "send the deck before lunch. send the deck before lunch",
                            style: .veryCasual) == .repeated, "tone: refuses a sentence said twice")
        return passed
    }
}
