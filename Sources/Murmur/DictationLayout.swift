import Foundation
import FoundationModels

/// Lays a dictation out the way it was meant to be read — points counted out loud as a numbered list, a new subject as
/// a new paragraph, spoken bullets as real bullets — without changing a word of it.
///
/// Measured 2026-10-10: "We need three things. First, … Second, … And third, …" came out as one block; so did a
/// 120-word update on three subjects ("On a different topic, hiring." … "Finally, support."); "bullet point milk" gave
/// "- milk" with a full stop after the last item. Wispr Flow lays all three out by default (its Smart Formatting).
///
/// How it is done is the part that matters. A model asked to re-write text with breaks in it also changes the words —
/// the reason every rewrite in this app has a guard. So nothing here re-writes: what the speaker marked out loud
/// ("first… second…", "on a different topic", "bullet point") is read off by rule, and where a long dictation has no
/// such marks the model is asked only for the NUMBERS of the sentences that begin a new paragraph. The text is put
/// back together from the speaker's own sentences, and an answer that isn't a clean list of numbers is ignored. The
/// same division of labour as `TemplateEngine.arrangeInLatvian`.
///
/// English only and never in Raw style (the caller gates both, like every stage that reads words); not for a prompt
/// to a coding agent or an AI chat, which are pasted exactly as spoken — and where a line break in a terminal could
/// run a command. Text that already has line breaks (a template, "new line") is left as it is.
enum DictationLayout {
    /// Kill switch, no UI: `defaults write local.murmur smartLayout -bool false`.
    static var enabled: Bool { UserDefaults.standard.object(forKey: "smartLayout") as? Bool ?? true }

    static func applies(to destination: Destination?) -> Bool {
        guard enabled else { return false }
        switch destination {
        case .codingAgent?, .aiChat?: return false
        default: return true
        }
    }

    /// The part done by rule: spoken bullets in the destination's bullet, then — for text still in one block — a
    /// counted list, or paragraphs where the speaker announced a new subject.
    static func shape(_ text: String, bullet: String) -> String {
        var result = bulleted(text, bullet: bullet)
        guard !result.contains("\n") else { return result }
        result = numbered(result)
        if !result.contains("\n") { result = paragraphsAtCues(result) }
        return result
    }

    // MARK: - Spoken bullets

    /// A "- " line (the formatter's spoken "bullet point") in the bullet the destination uses, its first letter a
    /// capital, and no full stop after a one-phrase item: "• Milk", not "- milk." after the last one.
    static func bulleted(_ text: String, bullet: String) -> String {
        guard text.contains("\n- ") || text.hasPrefix("- ") else { return text }
        return text.components(separatedBy: "\n").map { line -> String in
            guard line.hasPrefix("- ") else { return line }
            var item = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            if item.hasSuffix("."), !item.hasSuffix(".."), !item.dropLast().contains(where: { ".!?".contains($0) }) {
                item.removeLast()
            }
            return bullet + " " + TemplateLayout.capitalized(item)
        }.joined(separator: "\n")
    }

    // MARK: - A list counted out loud

    /// What opens each point, in order. The speaker has to start at the first and go on to at least the second.
    private static let ordinals: [[String]] = [
        ["first of all", "firstly", "first", "number one", "point one", "one"],
        ["secondly", "second", "number two", "point two", "two"],
        ["thirdly", "third", "number three", "point three", "three"],
        ["fourthly", "fourth", "number four", "point four", "four"],
        ["fifthly", "fifth", "number five", "point five", "five"],
        ["sixth", "number six", "point six", "six"], ["seventh", "number seven", "seven"], ["eighth", "number eight", "eight"],
    ]
    private static let closers = ["finally", "lastly", "last of all", "and finally", "and lastly"]

    /// The point a sentence opens, if it opens one: (which, the sentence without its marker).
    private static func point(_ sentence: String, expecting index: Int) -> String? {
        var rest = sentence.trimmingCharacters(in: .whitespaces)
        var lower = rest.lowercased()
        for lead in ["and then ", "and ", "then "] where lower.hasPrefix(lead) {
            rest.removeFirst(lead.count)
            lower = rest.lowercased()
            break
        }
        // The last point may be announced as such, once there have been two.
        let markers = (index < ordinals.count ? ordinals[index] : []) + (index >= 2 ? closers : [])
        for marker in markers where lower.hasPrefix(marker) {
            let after = rest.dropFirst(marker.count)
            // A bare number word needs its comma or colon ("One, the pricing page"); "One thing I noticed" is prose.
            let bare = !marker.contains(" ") && ["one", "two", "three", "four", "five", "six", "seven", "eight"].contains(marker)
            guard let next = after.first else { return nil }
            if bare ? !",:".contains(next) : !(",: ".contains(next)) { continue }
            let body = after.drop { ",: ".contains($0) }
            guard body.split(whereSeparator: \.isWhitespace).count >= 2 else { return nil }
            return TemplateLayout.capitalized(String(body))
        }
        return nil
    }

    /// "We need three things. First, the page. Second, the link. And third, the policy." → the opening line, then
    /// "1. The page." "2. The link." "3. The policy." Unchanged when nothing was counted.
    static func numbered(_ text: String) -> String {
        let sentences = TemplateLayout.sentences(text)
        guard sentences.count >= 2 else { return text }
        // Where each point starts.
        var starts: [(sentence: Int, body: String)] = []
        for (offset, sentence) in sentences.enumerated() {
            if let body = point(sentence, expecting: starts.count) { starts.append((offset, body)) }
        }
        guard starts.count >= 2 else { return text }
        var items: [String] = []
        var closing: [String] = []
        for (index, start) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1].sentence : sentences.count
            var parts = [start.body] + sentences[(start.sentence + 1)..<end]
            // After the last point, what follows a one-sentence point is the speaker moving on, not more of it —
            // when every point before it was one sentence too.
            if index == starts.count - 1, parts.count > 1,
               zip(starts, starts.dropFirst()).allSatisfy({ $1.sentence - $0.sentence == 1 }) {
                closing = Array(parts.dropFirst())
                parts = [parts[0]]
            }
            items.append("\(index + 1). " + parts.joined(separator: " "))
        }
        var blocks: [String] = []
        let opening = sentences[..<starts[0].sentence].joined(separator: " ")
        blocks.append((opening.isEmpty ? "" : opening + "\n") + items.joined(separator: "\n"))
        if !closing.isEmpty { blocks.append(closing.joined(separator: " ")) }
        return blocks.joined(separator: "\n\n")
    }

    // MARK: - Paragraphs the speaker announced

    /// A sentence that opens with one of these says the subject is changing.
    private static let turns = [
        "on a different topic", "on a different note", "on another note", "on another topic", "on a separate note",
        "on a separate topic", "separately", "moving on", "next up", "another thing", "one more thing", "the other thing",
        "one other thing", "last thing", "the last thing", "finally", "lastly", "in other news", "switching gears",
        "changing the subject", "changing topic", "turning to", "now on to", "now onto", "on to the next", "second thing",
        "also, on", "as for", "when it comes to", "regarding", "ps", "p.s.", "by the way",
    ]

    /// A break before each sentence that announces a new subject — in a dictation long enough to have more than one
    /// (40 words), and only where both sides are left with a real paragraph (two sentences or a dozen words).
    static func paragraphsAtCues(_ text: String) -> String {
        guard text.split(whereSeparator: \.isWhitespace).count >= 40 else { return text }
        let sentences = TemplateLayout.sentences(text)
        guard sentences.count >= 4 else { return text }
        var starts = [0]
        for (offset, sentence) in sentences.enumerated().dropFirst() {
            let lower = sentence.lowercased()
            if turns.contains(where: { lower.hasPrefix($0 + " ") || lower.hasPrefix($0 + ",") || lower.hasPrefix($0 + ".") }) {
                starts.append(offset)
            }
        }
        return rebuilt(sentences, startingAt: starts) ?? text
    }

    /// The sentences as paragraphs; nil when the breaks would leave a paragraph too thin to be one.
    private static func rebuilt(_ sentences: [String], startingAt starts: [Int]) -> String? {
        guard starts.count >= 2 else { return nil }
        var paragraphs: [String] = []
        for (index, start) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1] : sentences.count
            let part = sentences[start..<end]
            guard part.count >= 2 || part.joined(separator: " ").split(whereSeparator: \.isWhitespace).count >= 12 else { return nil }
            paragraphs.append(part.joined(separator: " "))
        }
        return paragraphs.joined(separator: "\n\n")
    }

    // MARK: - Paragraphs the model finds

    /// How long a dictation has to be before it is worth asking: a short one is one paragraph.
    static let wordsWorthSplitting = 90

    /// A long dictation still in one block: Apple's on-device model names what each sentence is about, and a paragraph
    /// begins where a new subject holds for two sentences or more. The dictation is put back together from its own
    /// sentences — the model writes labels, never text. Returned unchanged when it is short, already laid out, the
    /// model isn't there, or its answer doesn't fit the sentences.
    ///
    /// Asked directly "which sentences begin a paragraph", the model answered with every sentence, or split a text
    /// about one thing in three (measured 2026-10-10). Asked for each sentence's subject, its labels lined up with
    /// the real topics ("pricing, film, pricing, hiring, hiring, hiring, emails, emails, support"), and reading the
    /// breaks off the runs gave the right paragraphs.
    ///
    /// OFF unless `defaults write local.murmur smartParagraphs -bool true`. Measured on twelve real long dictations
    /// from one user's history (2026-10-10): none gained a paragraph — spoken text runs to a few very long sentences,
    /// most dictations are about one thing, and where the model was asked it put every sentence under its first
    /// subject — while each one asked cost about a second. On three written-style test texts it got one right and
    /// left two alone. It never changed a word; it just isn't worth its second with this model.
    static var modelParagraphsEnabled: Bool { UserDefaults.standard.bool(forKey: "smartParagraphs") }

    static func paragraphed(_ text: String) async -> String {
        guard modelParagraphsEnabled || ProcessInfo.processInfo.environment["MURMUR_LAYOUT_DEBUG"] != nil,
              !text.contains("\n"), text.split(whereSeparator: \.isWhitespace).count >= wordsWorthSplitting,
              SystemLanguageModel.default.availability == .available else { return text }
        let sentences = TemplateLayout.sentences(text)
        guard sentences.count >= 6 else { return text }
        // First the few subjects the whole text covers, then — from that short list — the one each sentence belongs
        // to. Naming a subject per sentence from scratch gave a different word for nearly every sentence ("contract,
        // payment, clients, legal…"); choosing from a list it has just written keeps the labels the same.
        let session = LanguageModelSession(instructions: """
            You are given a dictated text as numbered sentences. First list the main subjects the text moves through, \
            in the order they come up: between one and four, each named in one or two words. A subject is broad: it \
            covers every sentence said about that matter, usually several in a row. Then, for each sentence in order, \
            give the number of the subject in your list that it belongs to. Give one number for every sentence.
            """)
        var options = GenerationOptions(sampling: .greedy)
        options.maximumResponseTokens = sentences.count * 4 + 80
        let numberedText = sentences.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        guard let plan = try? await session.respond(
            to: "<sentences>\n\(numberedText)\n</sentences>\n\nList the main subjects, then give the subject number of each of "
                + "the \(sentences.count) sentences.",
            generating: SubjectPlan.self, options: options).content else { return text }
        if ProcessInfo.processInfo.environment["MURMUR_LAYOUT_DEBUG"] != nil {
            FileHandle.standardError.write(Data("SUBJECTS: \(plan.subjects) \(plan.sentenceSubjects)\n".utf8))
        }
        let subjects = plan.sentenceSubjects.map(String.init)
        return rebuilt(sentences, startingAt: starts(fromSubjects: subjects, count: sentences.count)) ?? text
    }

    /// Where paragraphs begin, read off the sentences' subjects: at a new subject that lasts two sentences or more. A
    /// subject that comes up for one sentence is an aside inside the paragraph it interrupts. [0] — no breaks — when
    /// the labels don't match the sentences one for one, or would cut the text into more than a third as many
    /// paragraphs as it has sentences.
    static func starts(fromSubjects subjects: [String], count: Int) -> [Int] {
        guard subjects.count == count, count >= 4 else { return [0] }
        let keys = subjects.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
        func same(_ a: String, _ b: String) -> Bool { a == b || (a.count >= 4 && b.hasPrefix(a)) || (b.count >= 4 && a.hasPrefix(b)) }
        // Runs of the same subject.
        var runs: [(start: Int, length: Int)] = []
        for index in keys.indices {
            if let last = runs.last, same(keys[last.start], keys[index]) { runs[runs.count - 1].length += 1 } else { runs.append((index, 1)) }
        }
        var starts = [0]
        for run in runs.dropFirst() where run.length >= 2 { starts.append(run.start) }
        // A first paragraph of one sentence is that sentence leading into the next subject.
        if starts.count >= 2, starts[1] == 1 { starts.remove(at: 1) }
        guard starts.count - 1 <= count / 3 else { return [0] }
        return starts
    }

    // MARK: - Self-test

    static func runSelfTest() -> Bool {
        var passed = true
        func check(_ ok: Bool, _ label: String) {
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): layout: \(label)")
        }
        let counted = "We need three things for the launch. First, the pricing page has to be finished. Second, the "
            + "download link needs testing on a clean Mac. And third, the refund policy has to be written down."
        check(shape(counted, bullet: "•") == "We need three things for the launch.\n1. The pricing page has to be finished.\n"
              + "2. The download link needs testing on a clean Mac.\n3. The refund policy has to be written down.",
              "points counted out loud become a numbered list")
        check(numbered("One, book the room. Two, send the invites. Finally, order lunch. Let me know if that works.")
              == "1. Book the room.\n2. Send the invites.\n3. Order lunch.\n\nLet me know if that works.",
              "\"one… two… finally\", and what follows the last point is a paragraph of its own")
        check(numbered("First, we looked at pricing. It took most of the hour. Second, we looked at hiring.")
              == "1. We looked at pricing. It took most of the hour.\n2. We looked at hiring.",
              "a point may run to more than one sentence")
        for prose in ["One thing I noticed is that the page loads slowly. Two of the links are broken as well.",
                      "First we went to the park. Then we had lunch by the river.",
                      "The first step is done. The second step is harder than we thought.",
                      "First, thanks for coming on such short notice."] {
            check(numbered(prose) == prose, "left as prose: \(prose.prefix(44))…")
        }
        check(bulleted("Things to buy\n- milk\n- eggs\n- bread.", bullet: "•") == "Things to buy\n• Milk\n• Eggs\n• Bread"
              && bulleted("Notes\n- call the bank.", bullet: "-") == "Notes\n- Call the bank"
              && bulleted("No list here.", bullet: "•") == "No list here.",
              "spoken bullets get the destination's bullet, a capital and no stray full stop")
        let update = "Quick update on the launch. The pricing page is nearly done and I expect to finish it tomorrow. The film "
            + "on the home page still shows a feature we have hidden. On a different topic, hiring. We are still one engineer "
            + "short. Tom is going to reach out to two people this week. Finally, support. We had fourteen emails last week. "
            + "Nine of them were about the microphone prompt."
        let laidOut = paragraphsAtCues(update)
        check(laidOut.components(separatedBy: "\n\n").count == 3 && laidOut.contains("\n\nOn a different topic, hiring.")
              && laidOut.contains("\n\nFinally, support.") && laidOut.replacingOccurrences(of: "\n\n", with: " ") == update,
              "an announced change of subject starts a paragraph, and not a word changes")
        check(paragraphsAtCues("Finally, it works. Thanks for all the help with this.") == "Finally, it works. Thanks for all the help with this."
              && shape("Line one\nLine two", bullet: "•") == "Line one\nLine two",
              "a short dictation, or one already laid out, is left alone")
        check(starts(fromSubjects: ["pricing", "film", "pricing", "hiring", "hiring", "hiring", "emails", "emails", "support"], count: 9) == [0, 3, 6]
              && starts(fromSubjects: ["contract", "payment", "payment", "payment", "workshop", "workshop", "workshop", "workshop", "workshop"], count: 9) == [0, 4]
              && starts(fromSubjects: ["onboarding", "onboarding", "onboarding", "onboarding", "onboarding", "onboarding"], count: 6) == [0]
              && starts(fromSubjects: ["a", "b", "c", "d"], count: 6) == [0]
              && starts(fromSubjects: ["a", "b", "c", "d", "e", "f"], count: 6) == [0],
              "a paragraph begins where a new subject holds for two sentences; one-sentence asides and bad answers change nothing")
        check(applies(to: nil) && applies(to: .email) && !applies(to: .codingAgent) && !applies(to: .aiChat),
              "not for a prompt to a coding agent or an AI chat")
        return passed
    }
}

/// What each sentence is about, for telling where the subject changes.
@Generable
struct SubjectPlan {
    @Guide(description: "The main subjects the text moves through, in order: one to four, each in one or two words.")
    let subjects: [String]
    @Guide(description: "For each sentence in order, the number of the subject it belongs to (1 for the first subject).")
    let sentenceSubjects: [Int]
}
