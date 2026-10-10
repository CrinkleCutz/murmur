import Foundation

/// The kind of place a dictation is going — what "Auto (match app)" matches the writing to, and what Prompt Engineer
/// writes its prompt for (`DestinationDetector` decides).
enum Destination: Equatable {
    case email
    case messaging
    /// Claude Code, Codex, a terminal or an editor: a prompt for an agent that works on the user's project.
    case codingAgent
    /// Claude's chat, ChatGPT, Gemini, Perplexity: a question or request to a chat assistant.
    case aiChat
}

/// "Auto (match app)": shapes a finished dictation for the app it is going into, without changing a single word.
///
/// The same idea Flit sells as "Auto matches the destination" — casual in messengers, a greeting and sign-off on their
/// own lines in email — with the same discipline: it only ever moves line breaks and drops a final full stop. Nothing is
/// rewritten, no hedge is deleted, and a greeting, sign-off or subject that wasn't spoken is never invented. Because
/// every rule is deterministic and touches no words, the word-preservation guard's guarantees still hold, and it costs
/// nothing to run.
///
/// English only (the caller gates it, like every stage that reads words) and never in Raw style. Runs last, after the
/// grammar pass, so nothing later undoes it.
enum DestinationShaper {
    // MARK: - Which apps

    private static let emailApps: Set<String> = [
        "com.apple.mail", "com.microsoft.outlook", "com.mimestream.mimestream", "com.readdle.smartemail-macos",
        "it.bloop.airmail2", "com.airmailapp.airmail2", "com.freron.mailmate", "org.mozilla.thunderbird"]

    private static let messagingApps: Set<String> = [
        "com.apple.mobilesms", "com.tinyspeck.slackmacgap", "net.whatsapp.whatsapp", "ru.keepcoder.telegram",
        "org.whispersystems.signal-desktop", "com.hnc.discord"]

    /// What kind of place an app is, by bundle ID; nil for everything else (which then stays exactly as spoken).
    static func destination(forBundleID bundleID: String?) -> Destination? {
        guard let id = bundleID?.lowercased() else { return nil }
        if emailApps.contains(id) { return .email }
        if messagingApps.contains(id) { return .messaging }
        return nil
    }

    static func shape(_ text: String, for destination: Destination) -> String {
        switch destination {
        case .email: return shapeEmail(text)
        case .messaging: return shapeMessage(text)
        case .codingAgent, .aiChat: return text   // exactly as spoken
        }
    }

    // MARK: - Email: a spoken greeting and sign-off get their own lines

    /// "Hi Sophie," / "Hello everyone," / "Dear Dr. Smith," / "Hey," — a greeting word, up to three name words, a comma.
    private static let greetingPattern = try? NSRegularExpression(
        pattern: #"^(?:Hi|Hello|Hey|Dear|Good morning|Good afternoon|Good evening)(?:[ \t]+\p{L}[\p{L}'’.\-]*){0,3}(?:,|(?<=\p{L})[.!](?=[ \t]+\p{Lu}))[ \t]*(?=\S)"#)

    /// A sentence end, then a sign-off phrase, then at most a name — and nothing else after it. "Thanks for the update."
    /// is not a sign-off: something other than a name follows the word.
    private static let signOffPattern = try? NSRegularExpression(
        pattern: #"(?<=[.!?])\s+(Thanks so much|Thank you so much|Thanks a lot|Many thanks|Thank you|Thanks|Best regards|Kind regards|Warm regards|Best wishes|Regards|Cheers|Sincerely|Talk soon|Speak soon|Take care|Best),?(?:[ \t]+(\p{Lu}[\p{L}'’\-]*(?:[ \t]+\p{Lu}[\p{L}'’\-]*){0,2}))?[ \t]*([.!])?\s*$"#)

    private static func shapeEmail(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return text }

        // The sign-off first, so splitting the greeting can't move it.
        if let regex = signOffPattern {
            let source = result as NSString
            if let match = regex.firstMatch(in: result, range: NSRange(location: 0, length: source.length)) {
                let body = source.substring(to: match.range.location)
                let signOff = source.substring(with: match.range(at: 1))
                let name = match.range(at: 2).location == NSNotFound ? nil : source.substring(with: match.range(at: 2))
                let punctuation = match.range(at: 3).location == NSNotFound ? "" : source.substring(with: match.range(at: 3))
                result = body + "\n\n" + (name.map { "\(signOff),\n\($0)" } ?? signOff + punctuation)
            }
        }

        if let regex = greetingPattern {
            let source = result as NSString
            if let match = regex.firstMatch(in: result, range: NSRange(location: 0, length: source.length)) {
                var greeting = source.substring(with: match.range).trimmingCharacters(in: .whitespaces)
                // A recogniser may close the greeting with a full stop ("Hi Tom. Thanks for…"): it is still one.
                if let last = greeting.last, ".!".contains(last) { greeting = greeting.dropLast() + "," }
                let rest = source.substring(from: NSMaxRange(match.range))
                result = greeting + "\n\n" + rest.prefix(1).uppercased() + rest.dropFirst()
            }
        }
        return result
    }

    // MARK: - Messaging: a short single sentence needs no full stop

    /// Things that end in a period without ending a sentence.
    private static let abbreviations: Set<String> = [
        "mr.", "mrs.", "ms.", "dr.", "prof.", "sr.", "jr.", "st.", "vs.", "etc.", "e.g.", "i.e.", "no.", "approx.", "inc.", "ltd.", "co."]

    private static func endsSentence(_ token: String) -> Bool {
        guard let last = token.last, ".!?".contains(last) else { return false }
        let lower = token.lowercased()
        if abbreviations.contains(lower) { return false }
        if lower.range(of: #"^(\p{L}\.){2,}$"#, options: .regularExpression) != nil { return false }   // "p.m.", "u.s."
        if lower.range(of: #"^\p{L}\.$"#, options: .regularExpression) != nil { return false }          // an initial: "J."
        return true
    }

    private static func shapeMessage(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\n"), trimmed.hasSuffix("."), !trimmed.hasSuffix("..") else { return text }
        let tokens = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.count <= 20 else { return text }
        // Exactly one sentence, and its full stop is the last character.
        var ends = 0
        for (index, token) in tokens.enumerated() where endsSentence(token) {
            ends += 1
            if index != tokens.count - 1 { return text }
        }
        guard ends == 1 else { return text }
        return String(trimmed.dropLast())
    }

    // MARK: - Self test

    static func runSelfTest() -> Bool {
        var passed = true
        func check(_ input: String, _ destination: Destination, _ expected: String, _ label: String) {
            let got = shape(input, for: destination)
            let ok = got == expected
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): match app: \(label)\(ok ? "" : " — got \(got.debugDescription)")")
        }
        // Email — a spoken greeting and sign-off on their own lines.
        check("Hi Sophie, I just wanted to follow up on the invoice. Could you let me know when it will be paid? Thanks, Alex", .email,
              "Hi Sophie,\n\nI just wanted to follow up on the invoice. Could you let me know when it will be paid?\n\nThanks,\nAlex",
              "greeting and sign-off with a name")
        check("Hello everyone, the meeting moved to Friday. Best regards, Dana Lee", .email,
              "Hello everyone,\n\nThe meeting moved to Friday.\n\nBest regards,\nDana Lee", "a two-word name")
        check("Hey, can you send the deck?", .email, "Hey,\n\nCan you send the deck?", "a bare greeting")
        check("Hi Tom. Thanks for sending the contract. Best regards, Jānis.", .email,
              "Hi Tom,\n\nThanks for sending the contract.\n\nBest regards,\nJānis", "a greeting closed with a full stop; a name with an accent")
        check("Hello. This is a test of the new build.", .email, "Hello,\n\nThis is a test of the new build.", "a bare greeting with a full stop")
        check("Hi there is a problem with the invoice.", .email, "Hi there is a problem with the invoice.", "\"Hi there is…\" is not a greeting")
        check("Dear Dr. Smith, thank you for your time.", .email, "Dear Dr. Smith,\n\nThank you for your time.", "a title in the greeting")
        check("Please send the report by Friday. Thank you.", .email, "Please send the report by Friday.\n\nThank you.", "a sign-off without a name")
        // Email — nothing is invented, and nothing is touched unless it was spoken as a greeting or sign-off.
        check("Could you send the final deck before lunch?", .email, "Could you send the final deck before lunch?", "no greeting, no sign-off: unchanged")
        check("Hi there I think we should meet on Friday.", .email, "Hi there I think we should meet on Friday.", "a greeting word without a comma is not a greeting")
        check("I wanted to say thanks for the update.", .email, "I wanted to say thanks for the update.", "thanks inside a sentence")
        check("Please confirm. Thanks for sending it over.", .email, "Please confirm. Thanks for sending it over.", "a sentence that starts with thanks is not a sign-off")
        check("Hi Sophie,\n\nI wanted to ask.\n\nThanks,\nAlex", .email, "Hi Sophie,\n\nI wanted to ask.\n\nThanks,\nAlex", "already shaped: left alone")
        let once = shape("Hi Sophie, please call me. Thanks, Alex", for: .email)
        check(once, .email, once, "shaping twice changes nothing")
        // Messaging — a short single sentence loses its full stop, and only that.
        check("Sounds good, I'll be there at 5.", .messaging, "Sounds good, I'll be there at 5", "a short single sentence")
        check("Thanks.", .messaging, "Thanks", "one word")
        check("Talk to Dr. Smith tomorrow.", .messaging, "Talk to Dr. Smith tomorrow", "an abbreviation is not a sentence end")
        check("Sounds good. See you at 5.", .messaging, "Sounds good. See you at 5.", "two sentences keep their stops")
        check("Are you coming tonight?", .messaging, "Are you coming tonight?", "a question keeps its mark")
        check("On my way!", .messaging, "On my way!", "an exclamation keeps its mark")
        check("See you at 5 p.m.", .messaging, "See you at 5 p.m.", "the stop of an abbreviation stays")
        check("Hmm...", .messaging, "Hmm...", "an ellipsis stays")
        check("First line.\nSecond line.", .messaging, "First line.\nSecond line.", "a message with a line break is left alone")
        check("I was thinking that we could maybe get together sometime next week to go over the whole plan again together before the review.", .messaging,
              "I was thinking that we could maybe get together sometime next week to go over the whole plan again together before the review.",
              "a long message is left alone")
        check("", .messaging, "", "empty stays empty")
        // Which apps.
        func app(_ id: String?, _ expected: Destination?, _ label: String) {
            let got = destination(forBundleID: id)
            let ok = got == expected
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): match app: \(label)")
        }
        app("com.apple.mail", .email, "Mail is email")
        app("COM.APPLE.MOBILESMS", .messaging, "Messages is messaging, whatever the case")
        app("com.tinyspeck.slackmacgap", .messaging, "Slack is messaging")
        app("com.openai.codex", nil, "Codex is left exactly as spoken")
        app("com.anthropic.claudefordesktop", nil, "Claude is left exactly as spoken")
        app("com.googlecode.iterm2", nil, "a terminal is left exactly as spoken")
        app(nil, nil, "no app, no shaping")
        return passed
    }
}
