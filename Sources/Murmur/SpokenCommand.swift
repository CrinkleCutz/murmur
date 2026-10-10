import AppKit
import Foundation

/// Editing selected text by voice: select text in any app, hold the dictation key and say what to do with it — "make
/// this shorter", "translate it into Spanish", "turn this into bullet points" — and the selection is rewritten in
/// place. Anything else said over a selection is dictated as usual (it replaces the selection, as typing would).
///
/// Built 2026-10-01. Wispr Flow (Command Mode, its own fn+ctrl shortcut, switched on under Experimental) and Typeless
/// (Ask anything, the normal key over a selection) both have it; Murmur only had Transforms — fixed rewrites on ⌥1…9.
/// Murmur does it the Typeless way, so there's nothing to set up or remember: the dictation key, over a selection.
/// What keeps that safe:
///  - a command needs text selected when the key goes down, read through Accessibility (`CursorContext`) — the
///    clipboard is never touched to find out, and an app that doesn't say what's selected simply gets dictation;
///  - what was said must read as an instruction about that text (`instruction(in:)`): an editing verb aimed at "this",
///    "it" or "the text", or one that can only be an edit ("translate into…", "summarize", "fix the grammar"), or a bare
///    "shorter" / "more formal" — "make sure the deck is ready" is dictation, "make it shorter" is a command;
///  - each kind of edit runs on what Murmur already does best for it (`Intent`): grammar fixes on Polish; an email as
///    the user's own words, polished, between Murmur's greeting and sign-off (the model, and the Email Draft template,
///    reworded notes into a different message); shortening and lists with their own worked examples; tone with "keep
///    every fact and opinion"; rough lower-case text polished first. A single generic instruction, measured on 16
///    edits, came back unchanged for "fix the grammar", "shorter" and "as a numbered list", and turned "mostly good"
///    into "excellent";
///  - the result is checked (`rejection`): it may not answer the text, leak Murmur's instructions, add a number, link,
///    name, date word or "[Name]" placeholder, or (except a shortening) lose a detail. When the check fails, the
///    selection is left exactly as it was.
/// English only for now: the instruction is read in English (the rewrite itself can be into any language).
enum SpokenCommand {
    /// What kind of edit was asked for — decides how it runs and how the result is checked.
    enum Intent: Equatable {
        /// Fix grammar, spelling, typos; proofread; polish: the Polish transform.
        case fix
        /// Shorten, summarize, cut: details may go, nothing may be added.
        case reduce
        /// Into another language: every number, link and name stays.
        case translate
        /// A bulleted or numbered list.
        case list(numbered: Bool)
        /// An email, to whoever was named: the Email Draft template.
        case email(to: String?)
        /// More formal, friendlier, simpler…: the wording changes, the meaning doesn't.
        case tone
        /// Anything else aimed at the text ("change it to past tense"): only what was asked changes.
        case other
    }

    struct Command: Equatable {
        /// What the user said, tidied — the instruction as the model gets it.
        let instruction: String
        let intent: Intent
    }

    /// Kill switch, no UI: `defaults write local.murmur spokenCommands -bool false`.
    static var enabled: Bool { UserDefaults.standard.object(forKey: "spokenCommands") as? Bool ?? true }

    /// Whether an app that doesn't report its selection may be asked for it with ⌘C. Not a code editor or a terminal:
    /// with nothing selected ⌘C copies the whole line in most editors, and an instruction would then rewrite a line
    /// the user never chose.
    static func copiesUnreadSelection(bundleID: String?) -> Bool {
        guard let id = bundleID?.lowercased() else { return true }
        return !CodeField.editorBundleIDs.contains(id) && !CodeField.terminalBundleIDs.contains(id)
    }

    /// Longest instruction considered — anything longer is dictation.
    static let maxWords = 24

    // MARK: - Hearing an instruction

    // An instruction may open with a run-up ("okay", "can you", "please just") and close with a softener ("for me").
    private static let ask = "^(?:(?:okay|ok|now|so|and|then|please|just|hey|murmur) )*"
        + "(?:(?:can|could|would|will) you |i (?:want|need) you to |i(?:'d| would) like you to |let's )?"
        + "(?:(?:please|just|now|go ahead and) )*"
    private static let softener = "(?: (?:for me|a bit|a little|a little bit|slightly|if you can|now|then))*"
    /// What the text can be called: "this", "it", "this text", "the whole paragraph", "my notes"… "Make this text more
    /// concise" was typed out as words (2026-10-09) because only "this" and "the text" were known.
    private static let nouns = "text|selection|paragraph|paragraphs|sentence|sentences|email|e-mail|message|messages|note|"
        + "notes|reply|draft|list|bullets|wording|part|bit|section|passage|content|writing|post|document|doc|page|article|"
        + "copy|piece|thing|stuff|line|lines|words"
    private static let reference =
        "(?:this|it|that|these|those|them|everything|all of (?:it|this|that|them)|all this|all that|"
        + "(?:this|that|the|my|these|those|all the|all of the|all of this)"
        + "(?: (?:whole|entire|selected|highlighted|above))? (?:" + nouns + "))"
    /// Comparatives only — not every word ending in -er ("make it after lunch" is dictation).
    private static let comparatives =
        "better|clearer|simpler|longer|friendlier|politer|warmer|crisper|punchier|stronger|softer|easier|smoother|"
        + "nicer|cleaner|bolder|sharper|lighter|plainer|kinder|calmer"
    /// How it should sound, for "more formal" / "less casual" / "make it professional".
    private static let tones =
        "formal|informal|casual|polite|friendly|professional|concise|direct|confident|persuasive|detailed|specific|"
        + "positive|neutral|enthusiastic|empathetic|natural|personal|serious|playful|technical|warm|respectful|"
        + "assertive|diplomatic"
    /// These only after "more" or "less": on their own they are ordinary dictation ("make it clear that…").
    private static let moreTones = tones + "|human|readable|clear|simple|engaging|exciting|fun|funny|kind|gentle|firm|urgent|"
        + "upbeat|relaxed|approachable|businesslike|academic|conversational|angry|harsh|blunt|wordy|stiff|robotic|aggressive|"
        + "apologetic|emotional|dramatic|salesy|pushy|rude|cold|negative|vague|complicated|boring|generic"
    private static let listWords = "(?:a |an |some )?(?:bulleted |numbered |bullet |bullet point |ordered |simple |short |quick )?"
        + "(?:list|bullet points|bullet point|bullets|checklist|notes|note form|key points|main points|points|steps|to-?do list)"
    private static let languages = "english|spanish|german|french|italian|portuguese|dutch|swedish|polish|russian|japanese|"
        + "chinese|mandarin|latvian|korean|arabic|turkish|ukrainian|greek|hindi|danish|norwegian|finnish|czech|lithuanian|"
        + "estonian"
    /// Words for a piece of the text, which make "remove…", "add…" or "replace…" an instruction about it.
    private static let pieces = "sentence|sentences|paragraph|paragraphs|line|lines|word|words|bullet|bullets|bullet points?|"
        + "heading|headings|title|emoji|emojis|comma|commas|full stops?|periods?|exclamation marks?|question marks?|greeting|"
        + "sign-?off|signature|typos?|duplicates?|repetition|filler|spaces|line breaks?|blank lines?|capitals|"
        + "capital letters|quotes|brackets|numbering|dashes|hyphens"

    private enum Kind { case fix, reduce, translate, list, email, tone, other }

    /// Patterns, tried in order; the first that matches decides the kind of edit.
    private static let patterns: [(String, Kind)] = [
        (ask + "translate(?: " + reference + ")? (?:in)?to [\\p{L} ]+$", .translate),
        (ask + "(?:put|say|write|rewrite|give me) " + reference + " in (?:" + languages + ")" + softener + "$", .translate),
        (ask + "(?:fix|correct|check) (?:the |any |all the |my )?(?:grammar|spelling|typos|punctuation|capitali[sz]ation|"
            + "mistakes|errors)(?: (?:in|of|on) " + reference + ")?" + softener + "$", .fix),
        (ask + "(?:proofread|proof read|polish|tidy up|clean up|fix up|fix)(?: " + reference + ")?(?: up)?" + softener + "$", .fix),
        (ask + "(?:polish|tidy|clean|fix) " + reference + "(?: up)?" + softener + "$", .fix),
        // Shorter.
        (ask + "(?:summari[sz]e|sum up|shorten|condense|trim|cut down|cut|tighten up|recap|tl;?dr)(?: " + reference
            + ")?(?: up| down)?(?: (?:a bit|a little|for me|briefly|quickly|to .+|in .+|into .+))*$", .reduce),
        (ask + "sum " + reference + " up" + softener + "$", .reduce),
        (ask + "(?:give me|write|write me|make|create|do|i want|i need) (?:a |an |the )?(?:short |quick |brief |"
            + "one[- ]sentence |one[- ]line )?(?:summary|tl;?dr|recap|gist|overview)(?: (?:of|for) " + reference + ")?"
            + softener + "$", .reduce),
        (ask + "make " + reference + " (?:a lot |much |a bit |a little |way |slightly |even )?(?:shorter|more concise|briefer|"
            + "tighter|more succinct|more compact|less wordy|half as long)(?: .+)?$", .reduce),
        (ask + "(?:i want|i need|i'd like) " + reference + " (?:to be )?(?:a bit |a little |much )?(?:shorter|more concise|"
            + "briefer)$", .reduce),
        // A list.
        (ask + "(?:turn|make|put|format|rewrite|convert|write|change|structure|restructure|organi[sz]e|break|split|lay) "
            + reference + "(?: out| up| down)? (?:into |as |in |to |in the form of )?" + listWords + softener + "$", .list),
        (ask + "(?:bullet point|bullet-point|bullet|list) " + reference + "(?: out)?" + softener + "$", .list),
        (ask + "(?:change|turn|convert|replace|swap|make) (?:the |these |those |all the |all of the )?(?:dashes|hyphens|dash|"
            + "minus signs) (?:in|to|into|with|for)(?: real| actual| proper| normal)? (?:bullet points|bullet point|bullets|"
            + "dots)" + softener + "$", .list),
        (ask + "(?:use|add|i want|i need|give me|make them|make these|make it)(?: real| actual| proper| normal)? "
            + "(?:bullet points|bullets)(?: instead(?: of (?:the )?(?:dashes|hyphens))?| not dashes)?" + softener + "$", .list),
        (ask + "(?:turn|make|put|format|rewrite|convert|write|change) " + reference + " (?:into |as |to )(?:an )?e-?mail"
            + "(?: (?:to|for) .+)?$", .email),
        // A tone.
        (ask + "make " + reference + " (?:sound |read |look |feel |seem )?(?:a bit |a little |a lot |much |way |slightly |even )?"
            + "(?:(?:more |less )(?:" + moreTones + ")|" + tones + "|" + comparatives + ")(?: .+)?$", .tone),
        (ask + "make " + reference + " sound (?:like .+|more .+|less .+)$", .tone),
        (ask + "(?:rephrase|reword|simplify|soften|tighten|clarify|paraphrase)(?: " + reference + ")?(?: .+)?$", .tone),
        (ask + "(?:improve|humani[sz]e) " + reference + "(?: .+)?$", .tone),
        (ask + "(?:rewrite|write|say|put) " + reference + " (?:better|more clearly|more simply|in plain english|"
            + "in plain language|in simpler (?:words|terms)|in a .+ (?:tone|way|voice|style)|more .+ly)$", .tone),
        // Anything else aimed at the text.
        (ask + "(?:rewrite|change|convert|split|combine|merge|reorder|rearrange|restructure|reorgani[sz]e|"
            + "organi[sz]e|structure|expand|lengthen|extend|elaborate on|capitali[sz]e|lowercase|uppercase|number|format|"
            + "reformat|sort|group|break up|break down) " + reference + "(?: .+)?$", .other),
        // "Turn it into a table", "put this in bold" — not "put it in the shared folder" or "turn this around".
        (ask + "(?:turn|put|make|convert|change) " + reference + " (?:into|in to) .+$", .other),
        (ask + "put " + reference + " in (?:bold|italics?|quotes|brackets|capitals|caps|order|alphabetical order|"
            + "chronological order|a table|(?:past|present|future) tense|(?:first|second|third) person|"
            + "(?:my|your) own words)$", .other),
        (ask + "make " + reference + " (?:into .+|longer|(?:past|present|future) tense|(?:first|second|third) person|bold|"
            + "uppercase|lowercase|all caps|title case|sentence case|plural|singular)$", .other),
        (ask + "(?:remove|delete|take out|get rid of|add|insert|replace|swap|change|move|fix|capitali[sz]e) (?:.+ )?(?:"
            + pieces + ")(?: .+)?$", .other),
        // A bare "shorter", "more formal", "friendlier", "bullet points", "as a numbered list".
        ("^(?:shorter|briefer|more concise|half as long|summary|tl;?dr)$", .reduce),
        ("^(?:as |in |into |with )?" + listWords + "$", .list),
        ("^(?:" + comparatives + "|(?:more|less) (?:" + moreTones + ")|in plain english|in plain language)$", .tone),
    ]

    /// The instruction in what was said, or nil when it's dictation. `text` is the formatted transcript.
    static func instruction(in text: String) -> Command? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty, words.count <= maxWords else { return nil }
        // Compared without capitals, the final full stop or a "please" at the end.
        var key = trimmed.lowercased().replacingOccurrences(of: "’", with: "'")
        while let last = key.last, ".!?,".contains(last) { key.removeLast() }
        key = key.replacingOccurrences(of: ",", with: "")
        if key.hasSuffix(" please") { key = String(key.dropLast(7)) }
        guard let kind = patterns.first(where: { key.range(of: $0.0, options: .regularExpression) != nil })?.1
        else { return nil }
        var said = trimmed
        while let last = said.last, ".!?".contains(last) { said.removeLast() }
        if let first = said.first { said = first.uppercased() + said.dropFirst() }
        let intent: Intent
        switch kind {
        case .fix: intent = .fix
        case .reduce: intent = .reduce
        case .translate: intent = .translate
        case .tone: intent = .tone
        case .other: intent = .other
        case .list: intent = .list(numbered: key.contains("numbered") || key.contains("ordered list") || key.contains("steps"))
        case .email:
            // "…as an email to Anna" → "Anna"
            let recipient = said.range(of: "(?i)e-?mail (to|for) ", options: .regularExpression)
                .map { String(said[$0.upperBound...]).trimmingCharacters(in: .whitespaces) }
            intent = .email(to: recipient?.isEmpty == false ? recipient : nil)
        }
        return Command(instruction: said, intent: intent)
    }

    // MARK: - Doing it

    /// The transform that runs the edit.
    static func plan(for command: Command, on selection: String) -> Transform {
        let keep = "Keep the meaning exactly: every fact, opinion, request, name, date, time and number stays as it is "
            + "(\"mostly good\" stays mostly good, \"today\" stays today). Keep the same language, and write with "
            + "normal capital letters and punctuation. Add no greeting, sign-off, emoji or placeholder such as [Name] "
            + "that the text doesn't have."
        func custom(_ instructions: String, _ examples: [(input: String, output: String)] = []) -> Transform {
            Transform(id: "spoken-command", name: "Your edit", keyLabel: "", keyCode: 0, description: "",
                      instructions: instructions, kind: .custom, examples: examples)
        }
        switch command.intent {
        case .fix:
            return Transform.all.first { $0.kind == .polish } ?? Transform.all[0]
        case .email(let recipient):
            // The message only: Murmur adds the greeting and the sign-off (`emailed`), as the Email Draft template does.
            let to = recipient.map { " to \($0)" } ?? ""
            return custom("""
                Rewrite the text as the message of an email\(to), in the user's own voice ("I", "we"), as clear, complete \
                sentences. Write only the message: no subject line, no greeting and no sign-off — Murmur adds those. \
                \(keep)
                """, [(
                    "Notes: photos from Saturday are ready, will send the link tonight, need to know which ones to print "
                        + "by Wednesday",
                    "The photos from Saturday are ready, and I'll send you the link tonight. Could you let me know which "
                        + "ones to print by Wednesday?")])
        case .reduce:
            return custom("""
                The user asked: "\(command.instruction)". Make the text clearly shorter. Keep what matters — every \
                request, decision, name, date, time and number — and cut repetition, filler and anything said twice. \
                Write it in the same language and the same voice ("I" stays "I"); add nothing new.
                """, [(
                    "Hi, so I just wanted to quickly follow up on the invoice from last month, because I think it might "
                        + "have been sent to the wrong address, and we still haven't received it on our side, so could you "
                        + "please resend it to accounts@acme.com when you get a chance?",
                    "Could you resend last month's invoice to accounts@acme.com? I think it went to the wrong address, "
                        + "and we haven't received it.")])
        case .translate:
            return custom("""
                \(command.instruction). Translate all of the text into natural, fluent writing in that language, keeping \
                its meaning, tone and line breaks. Keep every name, number, time, email address, link and file name \
                exactly as written.
                """)
        case .list(let numbered):
            let marker = numbered ? "a numbered list, \"1. \", \"2. \" and so on" : "a bulleted list, each line starting \"- \""
            return custom("""
                Rewrite the text as \(marker): one item for each separate point, in the order given. Keep each point's own \
                words, leaving out only joining words such as "and", "also" or "then". If the text starts with a heading \
                such as "Notes from today:", keep it as the line above the list. \(keep)
                """, [(
                    "For the trip we need to book the hotel, rent a car for three days, and also check that everyone's "
                        + "passport is still valid.",
                    numbered
                        ? "1. Book the hotel\n2. Rent a car for three days\n3. Check that everyone's passport is still valid"
                        : "- Book the hotel\n- Rent a car for three days\n- Check that everyone's passport is still valid")])
        case .tone:
            // The worked examples of the matching Style tone, when there is one. Without any, "more formal" came back in
            // capital letters throughout and was refused, and "friendlier" came back unchanged (measured 2026-10-09).
            let asked = command.instruction.lowercased()
            func asks(_ words: [String]) -> Bool { words.contains { asked.contains($0) } }
            let lessFormal = asks(["less formal", "less professional", "less serious", "less polite"])
            let examples: [(input: String, output: String)] =
                lessFormal || asks(["casual", "informal", "friendl", "relaxed", "warm", "natural", "personal", "nicer", "softer", "lighter"])
                    ? WritingStyle.casual.toneExamples
                    : asks(["formal", "professional", "polite", "respectful", "serious", "diplomatic"])
                        ? WritingStyle.formal.toneExamples : []
            return custom("""
                The user asked: "\(command.instruction)". Rewrite the text that way, changing only its tone and wording, \
                at about the same length. \(keep)
                """, examples)
        case .other:
            return custom("""
                The user asked: "\(command.instruction)". Change only what that asks for, and keep everything else as it \
                is. \(keep)
                """)
        }
    }

    // MARK: - The model that edits

    /// Gemma 4 does the edit when it is on this Mac (the Translate into download). Measured on a 1,450-character note
    /// (2026-10-09): asked to make it more concise or to summarize it, Apple's model handed it back at the same length
    /// after 6–7 s and was refused; Gemma cut it by a fifth, or to a summary, in 3–4 s, and kept the paragraphs.
    /// Apple's model stays the editor on a Mac without the download. Kill switch, no UI:
    /// `defaults write local.murmur spokenCommandsUseGemma -bool false`.
    static var usesGemma: Bool {
        (UserDefaults.standard.object(forKey: "spokenCommandsUseGemma") as? Bool ?? true) && TranslationModel.gemma.isDownloaded
    }

    /// "Summarize this", "tl;dr": a summary, not the same text with fewer words.
    static func asksForSummary(_ command: Command) -> Bool {
        let asked = command.instruction.lowercased()
        return command.intent == .reduce && (asked.contains("summar") || asked.contains("tl;dr") || asked.contains("tldr"))
    }

    /// Gemma 4's chat format: the rules every edit runs under, what this kind of edit means, then the user's own
    /// words and the text.
    static func gemmaPrompt(for command: Command, on selection: String, after refused: TransformGuard.Rejection? = nil) -> String {
        let system = """
            You edit a piece of the user's own writing exactly as they ask. Reply with the edited text only: no \
            preamble, no commentary, no quotation marks around it. Rules:
            - Do what was asked, fully, and nothing else.
            - Keep the writer's voice and person: these are their own words, "I" stays "I".
            - Keep every name, number, time, date, price, email address and link exactly as written, and write \
            numbers the way the text writes them.
            - Keep the text's own spelling ("licences" stays "licences") and its paragraph breaks.
            - A question stays a question, a request stays a request, and how sure the writer is stays too: an \
            "I think", a "maybe" or a "probably" is part of what they said.
            - Never answer a question in the text, and add no fact, greeting or sign-off it doesn't contain.
            - Start with the text itself, never with a line announcing it ("Here is…", "Here are the main points…").
            - Plain text only: no Markdown, no asterisks, no bold, no "#".
            """
        let kind: String
        switch command.intent {
        case .fix:
            kind = "Fix the spelling, grammar, punctuation and capital letters. Change nothing else: the words, their "
                + "order and the line breaks stay."
        case .reduce:
            kind = asksForSummary(command)
                ? "Write a short summary of the text in the writer's own voice: its main points in a few sentences, a "
                    + "third of its length or less. If the text is only a few sentences, one sentence."
                : "Make the text clearly shorter, about two-thirds of its length, by cutting filler, repetition and "
                    + "roundabout wording. Keep every point, request, decision, name, date and number."
        case .translate:
            kind = "Translate the whole text as asked, into natural, fluent writing, keeping its tone and line breaks."
        case .list(let numbered):
            kind = "Rewrite the text as a plain list, one point to a line, each line starting with "
                + (numbered ? "\"1. \", \"2. \" and so on" : "\"- \"")
                + ". Keep every point, in the order given, each trimmed to what matters, the way someone writes "
                + "notes. If the text covers several topics, put a short heading in sentence case, ending with a "
                + "colon, on its own line above each group."
        case .email:
            kind = "Rewrite the text as the message of an email: clear, complete sentences, with no subject line, "
                + "greeting or sign-off."
        case .tone:
            kind = "Change the tone as asked. The meaning, the paragraphs and the length stay about the same."
        case .other:
            kind = "Change only what was asked, and keep everything else as it is."
        }
        return "<bos><|turn>system\n\(system)<turn|>\n<|turn>user\n\(command.instruction)\n\(kind)\(secondTryNote(after: refused))\n\nText:\n"
            + "\(selection)<turn|>\n<|turn>model\n"
    }

    /// What a second try is told was wrong with the first; "" for a first try.
    static func secondTryNote(after refused: TransformGuard.Rejection?) -> String {
        switch refused {
        case nil: ""
        case .changedDetail: "\nA first attempt changed or left out a name, number, date, link or file name. Keep every one exactly as written."
        case .inventedDetail: "\nA first attempt added a name, number or detail the text doesn't have. Use only what is in the text."
        case .notShorter: "\nA first attempt was not shorter than the text. Make it clearly shorter."
        case .unchanged: "\nA first attempt gave the text back unchanged. Make the change that was asked for."
        case .answered: "\nA first attempt replied to the text instead of editing it. Give back the edited text only."
        case .changedMeaning, .lostQuestion: "\nA first attempt changed what the text says. Keep each question a question, and each \"not\" and greeting as it is."
        case .droppedContent: "\nA first attempt left out part of the text. Keep every point."
        case .wrongLength, .leakedInstructions: "\nA first attempt was not an edit of the text. Give back the edited text only."
        }
    }

    /// Something Gemma 4 drafts from a dictation (a prompt, an email): asked once, and once more — told what was wrong
    /// — when the first draft is refused or leaves out something that was said (`TransformGuard.missedClauses`). The
    /// better of the two, or nil when neither passes its check; the caller then turns to Apple's model.
    static func gemmaDraft<Draft>(
        _ attempt: (_ after: TransformGuard.Rejection?) async -> (draft: Draft, rejection: TransformGuard.Rejection?, missed: Int)?
    ) async -> Draft? {
        guard usesGemma, var best = await attempt(nil) else { return nil }
        if best.rejection != nil || best.missed > 0, let second = await attempt(best.rejection ?? .droppedContent) {
            dictationLog.notice(
                "Gemma 4 draft: first \(best.rejection?.rawValue ?? "left something out", privacy: .public); second \(second.rejection == nil ? "accepted" : "refused too", privacy: .public)")
            if second.rejection == nil, best.rejection != nil || second.missed < best.missed { best = second }
        }
        return best.rejection == nil ? best.draft : nil
    }

    // MARK: - What the patterns don't know

    /// What an instruction in words the patterns don't know is about, from the words in it — it is carried out as it
    /// was said either way; this picks the guidance and the check that go with it.
    static func intent(ofFreeInstruction said: String) -> Intent {
        let key = said.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { key.contains($0) } }
        if has(["translat"]) || key.range(of: " in (" + languages + ")\\b", options: .regularExpression) != nil { return .translate }
        if has(["summar", "shorter", "shorten", "concise", "brief", "gist", "tl;dr", "tldr", "condense", "recap", "trim", "sum ",
                "too long", "fluff", "wordy", "fewer words", "cut "]) {
            return .reduce
        }
        if has(["bullet", " list", "notes", "key points", "main points", "checklist", "steps"]) {
            return .list(numbered: has(["numbered", "ordered", "steps"]))
        }
        if has(["grammar", "spelling", "typo", "proofread", "punctuation"]) { return .fix }
        if has(["formal", "casual", "polite", "friendl", "professional", "tone", "sound", "confident", "warm", "angry"]) { return .tone }
        return .other
    }

    /// Text is selected and something short was said that the patterns don't know. Gemma 4 decides whether it is an
    /// instruction about the selection ("tighten this up", "give me the gist") or words to type in its place
    /// ("Sounds good, see you Thursday"). nil when it is dictation, or when there is no Gemma to ask.
    static func routed(_ text: String) async -> Command? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(whereSeparator: \.isWhitespace).count
        guard usesGemma, (1...16).contains(words) else { return nil }
        // Said to someone else, or about us: never an instruction to Murmur, whatever words are in it ("Let's cut the
        // budget by ten percent", "Send me a shorter version when you can" were read as edits without this).
        let opening = trimmed.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        let toSomeoneElse = ["we ", "we'", "let's ", "lets ", "i'll ", "i will ", "i think ", "i am ", "i'm ", "i was ", "i have ",
                             "i've ", "you ", "you'", "they ", "he ", "she ", "send ", "call ", "email ", "tell ", "ask ",
                             "remind ", "thanks", "thank you", "yes", "no ", "no,", "okay", "ok ", "sure", "sorry", "hi ", "hey ",
                             "hello", "dear "]
        guard !toSomeoneElse.contains(where: opening.hasPrefix) else { return nil }
        let system = """
            The user selected some text on their Mac, held the dictation key and said something. Decide which it is. \
            Answer with one word.
            EDIT: a command to you about the selected text itself: to change, rewrite, shorten, summarize, format, \
            translate, fix, add to or remove from it. Or a complaint about it that calls for one ("too long").
            TYPE: anything else. Words of their own to be typed in place of the selection: a reply, a remark, an \
            opinion ("I think…", "we need…", "let's…"), a request to another person, or a command about something that \
            is not the selected text (a meeting, a file, a person, a task, a place).
            If it is not clearly a command about the selected text, answer TYPE.
            Examples.
            "tighten this up" → EDIT
            "can you bullet this for me" → EDIT
            "give me the gist" → EDIT
            "write this better" → EDIT
            "too long" → EDIT
            "what's a nicer way to say this" → EDIT
            "convert to past tense" → EDIT
            "Sounds good, see you on Thursday." → TYPE
            "Make sure the deck is ready by Friday." → TYPE
            "No, let's keep the original plan." → TYPE
            "Remove your shoes at the door." → TYPE
            "This is the summary of the meeting." → TYPE
            "Can you send me the file?" → TYPE
            "I think the intro is too long for the homepage." → TYPE
            "Let's shorten the call to twenty minutes." → TYPE
            "We need a better list of suppliers." → TYPE
            "Move the review to Tuesday." → TYPE
            """
        let prompt = "<bos><|turn>system\n\(system)<turn|>\n<|turn>user\nThey said: \"\(trimmed)\"<turn|>\n<|turn>model\n"
        guard let answer = try? await Translator.shared.rewrite(prompt: prompt, source: trimmed),
              answer.uppercased().hasPrefix("EDIT") else { return nil }
        var said = trimmed
        while let last = said.last, ".!?".contains(last) { said.removeLast() }
        return Command(instruction: said, intent: intent(ofFreeInstruction: said))
    }

    /// Apple's model, for a Mac without Gemma: the whole selection in one call, or — a long one in several paragraphs
    /// — paragraph by paragraph. Given 1,450 characters at once it changed almost nothing; given a paragraph it does
    /// what was asked. A list or a summary needs the whole text, so those always go in one call.
    private static func appleEdit(_ command: Command, on selection: String, engine: RewriteEngine,
                                  destination: Destination?) async throws -> String {
        let plan = plan(for: command, on: selection)
        let lines = selection.components(separatedBy: "\n")
        let wordy = lines.filter { $0.split(whereSeparator: \.isWhitespace).count >= 12 }
        var wholeText = selection.count < 700 || wordy.count < 2 || asksForSummary(command)
        switch command.intent {
        case .list, .email, .translate: wholeText = true
        default: break
        }
        guard !wholeText else { return try await engine.transform(selection, with: plan, destination: destination) }
        var edited: [String] = []
        for line in lines {
            guard line.split(whereSeparator: \.isWhitespace).count >= 12,
                  let rewritten = try? await engine.transform(line, with: plan, destination: destination),
                  !rewritten.isEmpty, !rewritten.contains("\n") else {
                edited.append(line)
                continue
            }
            edited.append(rewritten)
        }
        return edited.joined(separator: "\n")
    }

    /// The model's edit and the check's verdict on it — shared by dictation and the command line (`--command`).
    static func attempt(_ command: Command, on selection: String, engine: RewriteEngine,
                        destination: Destination? = nil, bullet: String = "•") async throws
        -> (output: String, rejection: TransformGuard.Rejection?) {
        // An email: the text itself, polished, between Murmur's own greeting and sign-off. Asked to write an email
        // from notes, the model reworded them (the Email Draft template turned "decided to drop dark mode" into "Could
        // you drop dark mode?", a different message that its checks can't see), so the words stay the user's.
        if case .email(let recipient) = command.intent {
            var message = selection.trimmingCharacters(in: .whitespacesAndNewlines)
            if let polish = Transform.all.first(where: { $0.kind == .polish }),
               let polished = try? await engine.transform(message, with: polish, destination: destination),
               !polished.isEmpty, TransformGuard.rejection(original: message, output: polished, kind: .polish) == nil {
                message = finish(polished, original: message, intent: .fix)
            }
            return (emailed(message, to: recipient), nil)
        }
        // Already a list, and a list is what was asked for ("change the dashes to bullet points", "number these"):
        // only the markers change, so no model is asked — one rebuilt a three-line list with a heading of its own.
        if case .list(let numbered) = command.intent, let relisted = relisted(selection, numbered: numbered, bullet: bullet) {
            let same = relisted == selection.trimmingCharacters(in: .whitespacesAndNewlines)
            return (relisted, same ? .unchanged : nil)
        }
        var selection = selection
        /// The model's answer tidied and checked.
        func checked(_ raw: String) -> (output: String, rejection: TransformGuard.Rejection?) {
            let output = finish(raw, original: selection, intent: command.intent, bullet: bullet)
            guard !output.isEmpty else { return ("", nil) }
            func squashed(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            if squashed(output) == squashed(selection) { return (output, .unchanged) }
            let why = command.intent == .fix
                ? TransformGuard.rejection(original: selection, output: output, kind: .polish)
                : rejection(original: selection, output: output, intent: command.intent)
            return (output, why)
        }
        if usesGemma {
            let first = (try? await Translator.shared.rewrite(
                prompt: gemmaPrompt(for: command, on: selection), source: selection)) ?? ""
            dictationLog.notice("spoken command: Gemma 4 wrote \(first.count) characters")
            if !first.isEmpty {
                var result = checked(first)
                // Refused: asked once more, told what was wrong with the first answer. A refusal is the worst result
                // for the user — nothing happens — and most are one dropped number or a version that isn't shorter.
                if let why = result.rejection, !result.output.isEmpty,
                   let second = try? await Translator.shared.rewrite(
                       prompt: gemmaPrompt(for: command, on: selection, after: why), source: selection), !second.isEmpty {
                    let retried = checked(second)
                    dictationLog.notice(
                        "spoken command: first answer refused (\(why.rawValue, privacy: .public)); second \(retried.rejection == nil ? "accepted" : "refused too", privacy: .public)")
                    if retried.rejection == nil || result.rejection == .unchanged { result = retried }
                }
                if !result.output.isEmpty { return result }
            }
        }
        // Text typed or dictated without capitals or full stops is polished first: Apple's model edits lower-case
        // run-ons badly (asked to make one "more formal", it kept it lower-case and turned "launch" into
        // "commencement").
        if command.intent != .fix, needsPolish(selection),
           let polish = Transform.all.first(where: { $0.kind == .polish }),
           let polished = try? await engine.transform(selection, with: polish, destination: destination),
           !polished.isEmpty, TransformGuard.rejection(original: selection, output: polished, kind: .polish) == nil {
            selection = polished
        }
        let raw = try await appleEdit(command, on: selection, engine: engine, destination: destination)
        dictationLog.notice("spoken command: Apple's model wrote \(raw.count) characters")
        return checked(raw)
    }

    /// Lower-case at the start, or a long stretch with no full stop: written without care, worth polishing first.
    static func needsPolish(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first(where: \.isLetter) else { return false }
        if first.isLowercase { return true }
        let words = trimmed.split(whereSeparator: \.isWhitespace).count
        return words >= 12 && !trimmed.contains(where: { ".!?".contains($0) })
    }

    /// The checked message with Murmur's own greeting and sign-off around it.
    static func emailed(_ message: String, to recipient: String?, userName: String = NSFullUserName()) -> String {
        let firstName = userName.split(separator: " ").first.map(String.init) ?? ""
        let greeting = recipient.map { "Hi \($0.split(separator: " ").first.map(String.init) ?? $0)," } ?? "Hi,"
        return greeting + "\n\n" + message + "\n\nBest,\n" + firstName
    }

    /// Runs the edit on the selection: the rewritten text, or an error saying why the selection was left alone.
    static func perform(_ command: Command, on selection: String, engine: RewriteEngine,
                        destination: Destination? = nil, bullet: String = "•") async throws -> String {
        let name = "Your edit"
        let (output, why) = try await attempt(command, on: selection, engine: engine, destination: destination, bullet: bullet)
        guard !output.isEmpty else { throw TransformManager.TransformFailure.empty(name: name) }
        if let why { throw TransformManager.TransformFailure.refused(name: name, why) }
        return output
    }

    /// Tidies the model's output the same way every time: no trailing spaces on a line (Markdown line breaks), no emoji
    /// the text didn't have, and times in Murmur's style ("3:00 PM" → "3pm") unless it was translated.
    static func finish(_ output: String, original: String, intent: Intent, bullet: String = "•") -> String {
        var lines = output.components(separatedBy: "\n").map { line -> String in
            var line = line
            while line.last == " " || line.last == "\t" { line.removeLast() }
            return line
        }
        if !original.unicodeScalars.contains(where: isEmoji) {
            lines = lines.map { line in
                var kept = String.UnicodeScalarView()
                kept.append(contentsOf: line.unicodeScalars.filter { !isEmoji($0) && $0.value != 0xFE0F && $0.value != 0x200D })
                var result = String(kept)
                while result.last == " " { result.removeLast() }
                return result
            }
        }
        var text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if intent != .translate {
            text = TimeNormalizer.normalize(text)
            text = withCapitals(of: original, in: withoutShouting(text, original: original))
            text = LLMEditGuard.keepingDialect(of: original, in: text)
        }
        if case .list = intent { text = listLines(text, bullet: bullet) }
        return text
    }

    /// A selection that is a list already, with its markers changed to the bullet (or to numbers); nil when it isn't
    /// one. A line ending in a colon is a heading and stays; numbering starts again under each.
    static func relisted(_ selection: String, numbered: Bool, bullet: String) -> String? {
        let lines = selection.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        let marker = try? NSRegularExpression(pattern: "^([ \\t]*)(?:[-•*–—]|\\d{1,2}[.)])[ \\t]+(?=\\S)")
        func isItem(_ line: String) -> Bool {
            marker?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
        }
        let written = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let items = written.filter(isItem)
        let headings = written.filter { !isItem($0) && $0.trimmingCharacters(in: .whitespaces).hasSuffix(":") }
        guard items.count >= 2, items.count + headings.count == written.count, let marker else { return nil }
        var number = 0
        return lines.map { line -> String in
            guard isItem(line) else {
                if !line.trimmingCharacters(in: .whitespaces).isEmpty { number = 0 }
                return line
            }
            number += 1
            let range = NSRange(line.startIndex..., in: line)
            return marker.stringByReplacingMatches(
                in: line, range: range,
                withTemplate: "$1" + NSRegularExpression.escapedTemplate(for: numbered ? "\(number)." : bullet) + " ")
        }.joined(separator: "\n")
    }

    /// What a bullet looks like where the text is going. A real bullet ("•") nearly everywhere: asked for bullet
    /// points in Notes, a column of dashes isn't what anyone means. A dash where Markdown is the convention and "- "
    /// becomes a list by itself: Obsidian, Notion, Bear, a prompt to Claude or ChatGPT, a coding agent.
    static func bullet(forBundleID bundleID: String?) -> String {
        guard let id = bundleID?.lowercased() else { return "•" }
        return markdownApps.contains(id) || DestinationDetector.codingBundleIDs.contains(id)
            || DestinationDetector.chatBundleIDs.contains(id) ? "-" : "•"
    }
    private static let markdownApps: Set<String> = [
        "md.obsidian", "notion.id", "net.shinyfrog.bear", "com.electron.logseq", "abnerworks.typora", "pro.writer.mac",
        "com.linear", "com.anthropic.claudefordesktop", "com.github.githubclient", "com.lukilabs.lukiapp"]

    /// Words the model wrote in capital letters throughout that the user didn't — a tone edit of text typed without
    /// capitals came back as "THE DRAFT IS READY. COULD YOU…" (measured 2026-10-09). Each goes back to lower case, with
    /// a capital where a sentence starts and for "I"; `withCapitals` then restores the names.
    static func withoutShouting(_ output: String, original: String) -> String {
        let shouted = Set(original.split { !($0.isLetter || $0 == "'") }.filter { $0.count >= 2 && $0 == $0.uppercased() }.map(String.init))
        // Mostly capitals: then a one-letter word ("A") was shouted too.
        let letterCount = output.filter(\.isLetter).count
        let mostly = letterCount > 0 && output.filter(\.isUppercase).count * 10 > letterCount * 6
        var result = "", word = "", startsSentence = true
        func flush() {
            guard !word.isEmpty else { return }
            var written = word
            let letters = word.filter(\.isLetter)
            if letters.count >= (mostly ? 1 : 2), letters == letters.uppercased(), !shouted.contains(word) {
                written = word.lowercased()
                if startsSentence { written = written.prefix(1).uppercased() + written.dropFirst() }
                if written == "i" || written.hasPrefix("i'") || written.hasPrefix("i\u{2019}") {
                    written = "I" + written.dropFirst()
                }
            }
            result += written
            startsSentence = false
            word = ""
        }
        for character in output {
            if character.isLetter || character == "'" || character == "\u{2019}" {
                word.append(character)
            } else {
                flush()
                result.append(character)
                if ".!?\n".contains(character) { startsSentence = true }
            }
        }
        flush()
        return result
    }

    /// The capitals the text had, put back where an edit lost them: a name or a day the user wrote with one
    /// ("Thursday" came back "thursday" from a tone edit), and the first letter when the text began with one.
    static func withCapitals(of original: String, in output: String) -> String {
        func words(_ text: String) -> [Substring] { text.split { !($0.isLetter || $0 == "'" || $0 == "\u{2019}") } }
        // Written with a capital every time it appears, and at least once away from the start of a sentence.
        var capitalised: [String: String] = [:], lowercased: Set<String> = []
        var startsSentence = true
        for token in original.split(whereSeparator: \.isWhitespace) {
            for word in words(String(token)) {
                let key = word.lowercased()
                if word.first?.isUppercase == true {
                    if !startsSentence, word != word.uppercased() || word.count > 1 { capitalised[key] = String(word) }
                } else {
                    lowercased.insert(key)
                }
                startsSentence = false
            }
            if let last = token.last, ".!?".contains(last) { startsSentence = true }
        }
        var result = output
        for (key, word) in capitalised where !lowercased.contains(key) && key != "i" {
            result = result.replacingOccurrences(
                of: "(?<![\\p{L}'\u{2019}])\(NSRegularExpression.escapedPattern(for: key))(?![\\p{L}'\u{2019}])",
                with: NSRegularExpression.escapedTemplate(for: word), options: .regularExpression)
        }
        if original.first(where: \.isLetter)?.isUppercase == true, let first = result.first, first.isLowercase {
            result = first.uppercased() + result.dropFirst()
        }
        return result
    }

    /// A list the model wrote on one line ("Notes from today: - one - two", "1. one 2. two") put one item to a line,
    /// with "- " for bullets.
    static func listLines(_ text: String, bullet: String = "•") -> String {
        var result = text
        if !result.contains("\n") {
            result = result.replacingOccurrences(of: "\\s+[-•*]\\s+", with: "\n- ", options: .regularExpression)
            result = result.replacingOccurrences(of: "(?<=\\S)\\s+(\\d{1,2})\\.\\s+", with: "\n$1. ",
                                                 options: .regularExpression)
        }
        // Whatever the model used to mark a point — "-", "*", "•" — becomes the one bullet, indentation kept.
        return result.replacingOccurrences(
            of: "(?m)^([ \\t]*)[-•*–—][ \\t]+", with: "$1" + NSRegularExpression.escapedTemplate(for: bullet) + " ",
            options: .regularExpression)
    }

    /// The text without list markers ("- ", "1. ") at the starts of lines — they're layout, not numbers the user said.
    private static func withoutListMarkers(_ text: String) -> String {
        text.replacingOccurrences(of: "(?m)^\\s*(\\d{1,2}[.)]|[-•*])\\s+", with: "", options: .regularExpression)
    }

    private static func isEmoji(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isEmojiPresentation || (scalar.properties.isEmoji && scalar.value >= 0x1F000)
    }

    /// Words that pin a time down: a new one ("today" → "yesterday") changes what the text says.
    private static let dateWords: Set<String> = [
        "today", "tomorrow", "yesterday", "tonight", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday",
        "sunday", "january", "february", "march", "april", "june", "july", "august", "september", "october",
        "november", "december", "weekend", "morning", "afternoon", "evening"]

    /// Why an edit can't be used, or nil. Never contains the user's words.
    static func rejection(original: String, output: String, intent: Intent) -> TransformGuard.Rejection? {
        var output = output
        if case .list = intent { output = withoutListMarkers(output) }
        let inLength = original.count, outLength = output.count
        switch intent {
        // Shorter — and for more than a few sentences, shorter enough to see: a result within a few characters of a
        // long text looks like nothing happened.
        case .reduce: if outLength >= inLength || (inLength >= 400 && outLength * 100 > inLength * 92) { return .notShorter }
        case .translate: if outLength > inLength * 3 + 200 || outLength < inLength / 4 { return .wrongLength }
        default: if outLength > inLength * 4 + 400 { return .wrongLength }
        }
        if StyleRewriteGuard.openerRejection(original: original, rewritten: output) != nil { return .answered }
        // A new tone is still the same message: a question stays a question, a "not" stays, a greeting stays.
        if intent == .tone, StyleRewriteGuard.changesWhatWasMeant(original: original, rewritten: output) { return .changedMeaning }
        if TransformGuard.leaksInstructions(original: original, output: output) { return .leakedInstructions }
        // A shorter version may lose a detail, and "remove the second paragraph" is meant to.
        if intent != .reduce, intent != .other, !TransformGuard.keepsDetails(original: original, output: output) { return .changedDetail }
        if !TransformGuard.addsNoDetails(original: original, output: output) { return .inventedDetail }
        // "[Name]", "[Your Name]": a gap the user would have to fill in.
        if output.range(of: "\\[[A-Za-z ]+\\]", options: .regularExpression) != nil,
           original.range(of: "\\[[A-Za-z ]+\\]", options: .regularExpression) == nil { return .inventedDetail }
        // A translation writes everything in other words; anything else may not bring in a name or a date word.
        if intent != .translate {
            if !TransformGuard.addsNoNames(original: original, output: output) { return .inventedDetail }
            let said = Set(original.lowercased().split { !$0.isLetter }.map(String.init))
            let wrote = Set(output.lowercased().split { !$0.isLetter }.map(String.init))
            if !wrote.intersection(dateWords).isSubset(of: said) { return .changedDetail }
            // "May" the month, not "may" the verb (a formal rewrite's "this may be a bug" was refused as a new date).
            if !said.contains("may"), output.range(of: "(?<=[a-z,] )May\\b", options: .regularExpression) != nil {
                return .changedDetail
            }
        }
        return nil
    }

    // MARK: - Self-test

    static func runSelfTest() -> Bool {
        var passed = true
        func check(_ ok: Bool, _ label: String) {
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): spoken commands: \(label)")
        }
        let commands: [(String, Intent)] = [
            ("Make this text more concise.", .reduce), ("Can you summarize this paragraph for me?", .reduce),
            ("Give me a summary of this.", .reduce), ("Make this whole paragraph shorter.", .reduce),
            ("I want this to be shorter.", .reduce), ("Change the dashes to bullet points.", .list(numbered: false)),
            ("Use real bullet points.", .list(numbered: false)), ("Break this down into key points.", .list(numbered: false)),
            ("Turn these notes into a numbered list.", .list(numbered: true)), ("Put this in Spanish.", .translate),
            ("Make it sound less angry.", .tone), ("Okay, can you just make this more formal please?", .tone),
            ("Remove the last sentence.", .other), ("Add a heading to this.", .other), ("Clean this up a little.", .fix),
            ("Turn it into a table.", .other), ("Put this in bold.", .other),
            ("Make this shorter.", .reduce), ("Make it more formal.", .tone),
            ("Translate this into Spanish.", .translate), ("Translate to German please.", .translate),
            ("Turn this into bullet points.", .list(numbered: false)), ("Summarize this.", .reduce),
            ("Summarise it in one line.", .reduce), ("Fix the grammar.", .fix), ("Fix the typos in this.", .fix),
            ("Proofread this.", .fix), ("Make it sound friendlier.", .tone),
            ("Rewrite it as an email to Tom.", .email(to: "Tom")), ("Turn this into an email.", .email(to: nil)),
            ("Can you make this a bit shorter?", .reduce), ("Shorter.", .reduce), ("More casual.", .tone),
            ("As a numbered list.", .list(numbered: true)), ("Rephrase.", .tone), ("Change it to past tense.", .other),
            ("Make this a numbered list.", .list(numbered: true)), ("Simplify this.", .tone), ("Polish this.", .fix),
            ("Make it sound more confident.", .tone),
        ]
        for (said, intent) in commands {
            let heard = instruction(in: said)?.intent
            check(heard == intent, "\u{201c}\(said)\u{201d} is a command (\(heard.map { "\($0)" } ?? "dictation"))")
        }
        let dictation = [
            "Make sure this is sent by Friday.", "Drop me a line when you're done.", "Remove your shoes at the door.",
            "Make it clear that we need the report by Friday.", "Improve the onboarding flow before launch.",
            "Put it in the shared folder.", "Put this on my calendar.", "Turn this around by Friday.",
            "Make sure the deck is ready by Friday.", "Make it happen.", "I'll make it to the meeting at 3pm.",
            "Translate the brief for the Madrid team before the call, and send it to Anna and Tom so they have time.",
            "Can you fix the printer on the second floor?", "Shorter meetings would help everyone.",
            "This is great, thanks.", "Put the boxes in the hallway.", "Change of plans, we're meeting at 5pm.",
            "Turn left at the station.", "Summer is almost over.", "Make it after lunch.", "More coffee, please.",
            "Make it a priority for next week.", "Cut the onions first.",
        ]
        for said in dictation {
            check(instruction(in: said) == nil, "\u{201c}\(said)\u{201d} is dictation")
        }
        let long = Array(repeating: "word", count: 30).joined(separator: " ")
        check(instruction(in: "Make this shorter " + long) == nil, "a long dictation is never a command")

        let text = "Can we move the review to Thursday at 3pm? Anna has the deck at deck.key."
        check(rejection(original: text, output: "Move the review to Thursday at 3pm?", intent: .reduce) == nil,
              "a shortening may drop details")
        check(rejection(original: text, output: text + " " + text, intent: .reduce) == .notShorter,
              "a shortening must come out shorter")
        check(rejection(original: text, output: "Can we move the review to Friday at 4pm? Anna has deck.key.",
                        intent: .tone) == .changedDetail, "a rewrite may not change a time")
        check(rejection(original: text, output: "Can we move the review to Thursday at 3pm? Anna and Sarah have the "
                        + "deck at deck.key.", intent: .tone) == .inventedDetail, "or bring in a name")
        check(rejection(original: "Notes from today: demo moved", output: "Notes from yesterday: demo was moved",
                        intent: .other) == .changedDetail, "or a new date word")
        check(rejection(original: "the launch moved to Thursday", output: "The launch moved to Thursday. [Your Name]",
                        intent: .tone) != nil, "or a [Name] placeholder")
        check(rejection(original: text, output: "¿Podemos mover la revisión al jueves a las 3pm? Anna tiene la "
                        + "presentación en deck.key.", intent: .translate) == nil, "a translation keeps the details")
        check(finish("- One  \n- Two 😊", original: "one two", intent: .list(numbered: false)) == "• One\n• Two",
              "trailing spaces and added emoji are tidied away")
        check(finish("We'll be fine for 3:00 PM.", original: "fine for 3pm", intent: .tone) == "We'll be fine for 3pm.",
              "times in Murmur's style")
        check(finish("Notes: - one thing - two things", original: "Notes: one thing, two things",
                     intent: .list(numbered: false)) == "Notes:\n• one thing\n• two things",
              "a list written on one line gets a line per item")
        check(rejection(original: "Notes: drop dark mode, Tom owns the copy, demo Friday 10am",
                        output: "1. Drop dark mode\n2. Tom owns the copy\n3. Demo Friday 10am",
                        intent: .list(numbered: true)) == nil, "list numbers aren't invented numbers")
        check(needsPolish("hey so the launch moved") && !needsPolish("Thanks for the quick turnaround."),
              "lower-case text is polished first, written text isn't")
        check(emailed("The demo moved to Friday.", to: "Anna Berzina", userName: "Janis B")
              == "Hi Anna,\n\nThe demo moved to Friday.\n\nBest,\nJanis", "an email gets Murmur's greeting and sign-off")
        check(withCapitals(of: "I think we should move the review to Thursday with Anna.",
                           in: "we should move the review to thursday with anna.") == "We should move the review to Thursday with Anna.",
              "capitals a tone edit lost are put back")
        check(rejection(original: "I think that is a real bug.", output: "I believe this may be a genuine bug.", intent: .tone) == nil,
              "\"may\" the verb is not a new date")
        check(rejection(original: "We ship the update soon.", output: "We ship the update in May.", intent: .tone) != nil,
              "\"May\" the month still is")
        check(LLMEditGuard.keepingDialect(of: "The licences and the colour are fine.", in: "The licenses are fine. Color is too.")
              == "The licences are fine. Colour is too.", "an edit keeps the text's own spelling")
        check(instruction(in: "Turn this into notes.")?.intent == .list(numbered: false)
              && instruction(in: "Make this into bullet points.")?.intent == .list(numbered: false),
              "\"into notes\" asks for a list")
        let concise = Command(instruction: "Make this more concise.", intent: .reduce)
        check(gemmaPrompt(for: concise, on: "Some text.").hasSuffix("Text:\nSome text.<turn|>\n<|turn>model\n")
              && !asksForSummary(concise) && asksForSummary(Command(instruction: "Summarize this.", intent: .reduce)),
              "the stronger model is asked in its own chat format, and a summary is told apart from a trim")
        check(relisted("- Pricing page\n- Refund policy\n- Download test", numbered: false, bullet: "•")
              == "• Pricing page\n• Refund policy\n• Download test"
              && relisted("Launch:\n• one\n• two\n\nLater:\n• three", numbered: true, bullet: "•")
              == "Launch:\n1. one\n2. two\n\nLater:\n1. three"
              && relisted("We need to finish three things. Daniel owns two.", numbered: false, bullet: "•") == nil,
              "an existing list only has its markers changed; prose is left for the model")
        check(listLines("Topic:\n- one\n* two\n  - nested", bullet: "•") == "Topic:\n• one\n• two\n  • nested"
              && listLines("- one\n- two", bullet: "-") == "- one\n- two" && listLines("1. one\n2. two") == "1. one\n2. two",
              "a list gets real bullets, or dashes where Markdown is the convention; numbers stay")
        check(bullet(forBundleID: "com.apple.Notes") == "•" && bullet(forBundleID: "md.obsidian") == "-"
              && bullet(forBundleID: "com.openai.codex") == "-" && bullet(forBundleID: nil) == "•",
              "Notes gets bullets, Obsidian and a coding agent get dashes")
        check(rejection(original: String(repeating: "word ", count: 30), output: String(repeating: "word ", count: 29),
                        intent: .reduce) == nil
              && rejection(original: String(repeating: "word ", count: 120), output: String(repeating: "word ", count: 118),
                           intent: .reduce) == .notShorter, "a short text need only be shorter; a long one visibly so")
        check(intent(ofFreeInstruction: "Give me the gist") == .reduce && intent(ofFreeInstruction: "Can you bullet this for me")
              == .list(numbered: false) && intent(ofFreeInstruction: "Swap the first two points") == .other,
              "an instruction in unknown words still gets the right kind")
        check(withoutShouting("THE DRAFT IS READY. COULD YOU TAKE A LOOK AND TELL PRIYA WHAT I THINK? THANKS.", original: "hey so the draft is ready")
              == "The draft is ready. Could you take a look and tell priya what I think? Thanks.", "shouted output is put back in sentence case")
        check(withoutShouting("Send it to the NASA team ASAP.", original: "send it to the NASA team asap") == "Send it to the NASA team asap.",
              "capitals the user wrote stay")
        check(rejection(original: "Can you take a look and tell Priya what you think?", output: "Take a look and tell Priya what you think.",
                        intent: .tone) == .changedMeaning, "a tone edit may not turn a question into an order")
        check(withCapitals(of: "hey so the numbers are wrong", in: "hey, so the numbers are wrong.") == "hey, so the numbers are wrong.",
              "text written without capitals stays that way")
        check(withCapitals(of: "The plan is fine. The room is free.", in: "the plan is fine and the room is free.")
              == "The plan is fine and the room is free.", "a word that only opened sentences isn't capitalised inside one")
        check(!copiesUnreadSelection(bundleID: "com.microsoft.VSCode") && !copiesUnreadSelection(bundleID: "com.apple.Terminal")
              && copiesUnreadSelection(bundleID: "com.apple.Safari") && copiesUnreadSelection(bundleID: nil),
              "an unread selection is copied in a browser, never in a code editor or a terminal")
        return passed
    }
}
