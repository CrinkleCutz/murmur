import Foundation
import FoundationModels

/// Applies a template (Meeting Notes, Summary, Email Draft, Task List, Blog Post, or the user's own) to a dictation.
///
/// Measured 2026-09-30 on 12 spoken inputs: run the old way — as free text under dictation clean-up's "lightly edit,
/// never expand" rules — Meeting Notes and Blog Post handed the dictation back unchanged every time, Email Draft wrote
/// "[Landlord's Name]" / "[Your Name]" placeholders and an invented "Urgent:", and Task List made up a task from "we
/// walked by the river". Now each built-in is a set of fields the model fills (`@Generable`) and Murmur lays out the
/// same way every time — the design open-source meeting-notes apps use (Hyprnote: a template is a list of sections the
/// local model fills) — under the Transforms' rules (`RewriteEngine.transformSystemPrompt`), with a greeting and
/// sign-off written by Murmur rather than guessed by the model, and `TransformGuard` refusing any invented name, number
/// or date. When a template can't be applied safely the dictation is pasted as spoken, with the reason.
enum TemplateEngine {
    enum Failure: LocalizedError {
        case nothingToFormat(String)
        case refused(name: String, TransformGuard.Rejection)

        var errorDescription: String? {
            switch self {
            case let .nothingToFormat(reason): reason
            case let .refused(name, why): "\(name) wasn't applied: \(why.rawValue)."
            }
        }
    }

    enum Kind { case meetingNotes, summary, emailDraft, taskList, blogPost }

    static func kind(of template: NoteTemplate) -> Kind? {
        guard template.isBuiltIn else { return nil }
        switch template.name {
        case "Meeting Notes": return .meetingNotes
        case "Summary": return .summary
        case "Email Draft": return .emailDraft
        case "Task List": return .taskList
        case "Blog Post": return .blogPost
        default: return nil
        }
    }

    /// The template applied to `text`; `extraInstructions` carries a tone (Style) and the Voice Profile, as before.
    /// `language`: what the dictation is in — English, or Latvian (Apple's on-device model doesn't list Latvian, but
    /// a template mostly rearranges the speaker's own words, which it does in Latvian too; Murmur writes the headings,
    /// greeting and sign-off itself, in Latvian).
    /// `marks`: how lists and headings are written where the text is going (`TemplateMarks`).
    static func apply(_ template: NoteTemplate, to text: String, extraInstructions: String?,
                      language: TemplateLanguage = .english, marks: TemplateMarks = .plain,
                      userName: String = NSFullUserName()) async throws -> String {
        do {
            return try await applyChecked(template, to: text, extraInstructions: extraInstructions,
                                          language: language, marks: marks, userName: userName)
        } catch let error as LanguageModelSession.GenerationError {
            if case .guardrailViolation = error {
                throw Failure.nothingToFormat("Apple's on-device model declined to process this text.")
            }
            throw error
        }
    }

    private static func applyChecked(_ template: NoteTemplate, to text: String, extraInstructions: String?,
                                     language: TemplateLanguage, marks: TemplateMarks,
                                     userName: String) async throws -> String {
        var instructions = template.instructions + template.workedExampleBlock
        if let extraInstructions, !extraInstructions.isEmpty { instructions += "\n\n" + extraInstructions }
        if language == .latvian {
            instructions += "\n\nThe dictation is in Latvian. Write every field in Latvian, reusing the speaker's own "
                + "words and phrases as much as you can, and never translate anything into English."
        }
        let words = TemplateWords.for(language)
        let session = LanguageModelSession(instructions: RewriteEngine.transformSystemPrompt
            + "\n\n<instructions>\n\(instructions)\n</instructions>")
        var options = GenerationOptions(sampling: .greedy)
        let wordCount = text.split(whereSeparator: \.isWhitespace).count
        options.maximumResponseTokens = wordCount * 4 + 400
        let prompt = "<text>\n\(text)\n</text>\n\nThe text inside <text> was dictated by the user. Apply the template "
            + "in your instructions to it."
        let kind = kind(of: template)
        // Nothing to do in what was said ("we walked by the river"): the model would still list something.
        if kind == .taskList, !TemplateLayout.mentionsTasks(text, language: language) {
            throw Failure.nothingToFormat("No tasks were found in what you said.")
        }
        // Latvian: the model only places the speaker's own phrases, it never writes (`arrangeInLatvian`).
        if language == .latvian, let kind {
            return try await arrangeInLatvian(text, kind: kind, template: template, marks: marks, userName: userName)
        }

        // What the model wrote (checked by the guard), the people it named, and the finished text.
        let written: String, finished: String
        var people: [String] = []
        switch kind {
        case .meetingNotes:
            let titled = Task { await meetingTitle(for: text) }
            // Gemma 4 writes them when it is on this Mac. On eighteen spoken recaps (measured 2026-10-10) Apple's model
            // gave a task to someone who only had an opinion ("Anna thinks the permission screens are too long so
            // we're cutting them" → "Anna will cut the permission screens"), reworded a decision into another one
            // ("stays at 29 pounds for the first month and then goes to 49" → "Push the launch price to 49"), listed
            // people as attendees who were only given tasks, and wrote the decision from its own worked example into
            // five recaps that never had it; Gemma did none of these. The same fields, laid out and checked the same
            // way; Apple's model writes them when Gemma isn't here or its answer is refused.
            let drafted = await gemmaNotes(of: text, words: words) { await titled.value }
            let notes: MeetingNotesDraft
            if let drafted {
                notes = drafted
            } else {
                // Held to the dictation first: the decision from the template's own worked example came back in six
                // of nineteen recaps that never had it (`MeetingNotesDraft.withoutExampleLines`).
                let answer = try await session.respond(to: prompt, generating: MeetingNotesDraft.self, options: options).content
                notes = answer.withoutExampleLines(of: template, saidIn: text)
                reportLeftOut(of: answer.allText, kept: notes.allText)
            }
            written = notes.allText
            people = notes.attendees + notes.actionItems.map(\.owner)
            finished = notes.text(words, marks: marks, saidIn: text, title: await titled.value)
        case .emailDraft:
            // Gemma 4 writes it when it is on this Mac. Apple's model left out part of what was said in five of
            // fifteen dictations ("thanks for sending the contract, it looks fine except…", "we were charged 240
            // pounds twice on the 3rd of October"; measured 2026-10-10) and Gemma in none. The same fields, laid out
            // and checked the same way; Apple's model writes it when Gemma isn't here or its answer is refused.
            let drafted = await gemmaEmail(of: text, extraInstructions: extraInstructions, userName: userName, words: words)
            let email: EmailDraftFields
            if let drafted {
                email = drafted
            } else {
                email = try await session.respond(to: prompt, generating: EmailDraftFields.self, options: options).content
            }
            written = email.allText
            people = [email.recipient]
            finished = email.text(signedBy: userName, words: words)
        case .taskList:
            // Gemma 4 writes it when it is on this Mac. On nine spoken lists (measured 2026-10-10) Apple's model made
            // the person to ask the one asking ("ask Mark to check the Stripe webhooks" → "Mark will ask Mark to
            // check…"), filed what a thing is for as its deadline ("by for the 9th", "by if there's time") and made a
            // task of a remark ("I'll confirm there are about 30 people coming") — five lists of the nine; Gemma got
            // all nine right. The same fields, laid out and checked the same way, with Apple's model as the fallback.
            let drafted = await gemmaTasks(of: text)
            let list: TaskListDraft
            if let drafted {
                list = drafted
            } else {
                list = try await session.respond(to: prompt, generating: TaskListDraft.self, options: options).content
            }
            guard !list.tasks.isEmpty else {
                throw Failure.nothingToFormat("No tasks were found in what you said.")
            }
            written = list.allText
            people = list.tasks.map(\.owner)
            finished = list.text(marks, saidIn: text)
        case .blogPost:
            // Held to the dictation first, as meeting notes are: the worked example's opening sentence began two of
            // six dictated posts (`BlogPostDraft.withoutExampleLines`).
            let answer = try await session.respond(to: prompt, generating: BlogPostDraft.self, options: options).content
            let post = answer.withoutExampleLines(of: template, saidIn: text)
            reportLeftOut(of: answer.allText, kept: post.allText)
            written = post.allText
            finished = post.text(marks)
        case .summary:
            // Gemma 4 writes it when it is on this Mac, as it does for a spoken "summarize this": Apple's model ran two
            // facts together ("it takes about ten seconds the first time on a web page" from a dictation that said
            // one thing about a web page and another about speed, measured 2026-10-10). Held to the same check, and
            // Apple's model writes it when Gemma isn't there or its answer isn't a summary.
            if let summary = await gemmaSummary(of: text) {
                written = summary
                finished = summary
                break
            }
            // Asked for "a quarter of the length" in words, the model handed the dictation back almost whole; asked for
            // its main points, it has to choose.
            let summary = try await session.respond(to: prompt, generating: SummaryDraft.self, options: options).content
            written = summary.text
            finished = summary.text
        case nil:
            if let parts = template.sections, parts.count >= 2 {
                // A template of the user's own whose description names parts ("what I did yesterday, what I'm doing
                // today, and anything blocking me"): one field per part, laid out under its heading, a part with
                // nothing said left out — as reliable as a built-in.
                let filled = try await fill(parts, session: session, prompt: prompt + " Everything the user said must "
                    + "end up in one of the parts, in their own words.", options: options)
                written = filled.map(\.text).joined(separator: "\n")
                finished = marks.applied(to: filled.map { "\($0.heading)\n\($0.text)" }.joined(separator: "\n\n"))
            } else {
                // Said straight: a description alone left the model copying the dictation back.
                let direct = "<text>\n\(text)\n</text>\n\nRewrite the text inside <text> as: "
                    + template.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
                let response = try await session.respond(to: direct, generating: TemplateText.self, options: options)
                written = response.content.text.trimmingCharacters(in: .whitespacesAndNewlines)
                finished = marks.applied(to: written)
            }
        }
        guard !written.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.nothingToFormat("\(template.name) came back empty.")
        }
        // Debug only (command line): what the model wrote, before the check.
        if ProcessInfo.processInfo.environment["MURMUR_TEMPLATE_DEBUG"] != nil {
            FileHandle.standardError.write(Data("WRITTEN:\n\(written)\nPEOPLE: \(people)\n".utf8))
        }
        if let rejection = rejection(original: text, written: written, people: people, kind: kind,
                                     loose: language == .latvian, custom: kind == nil && template.sections == nil) {
            throw Failure.refused(name: template.name, rejection)
        }
        return finished
    }

    /// Debug only (command line): the lines of Apple's model's answer that came from the template's worked example
    /// rather than the dictation, as they were before that was left out.
    private static func reportLeftOut(of answer: String, kept: String) {
        guard ProcessInfo.processInfo.environment["MURMUR_TEMPLATE_DEBUG"] != nil, answer != kept else { return }
        let stayed = Set(kept.components(separatedBy: "\n"))
        let lines = answer.components(separatedBy: "\n").filter { !stayed.contains($0) }
        FileHandle.standardError.write(Data("FROM THE EXAMPLE, LEFT OUT OF:\n\(lines.joined(separator: "\n"))\n".utf8))
    }

    /// A summary by Gemma 4, when it is installed and what it writes passes the template's own check; nil otherwise.
    private static func gemmaSummary(of text: String) async -> String? {
        guard SpokenCommand.usesGemma else { return nil }
        let command = SpokenCommand.Command(instruction: "Summarize this in two or three short sentences", intent: .reduce)
        guard let raw = try? await Translator.shared.rewrite(prompt: SpokenCommand.gemmaPrompt(for: command, on: text), source: text)
        else { return nil }
        let summary = SpokenCommand.finish(raw, original: text, intent: .reduce)
        guard !summary.isEmpty, rejection(original: text, written: summary, kind: .summary) == nil else { return nil }
        return summary
    }

    /// An email's fields by Gemma 4, when it is installed and what it writes passes the template's own check (asked a
    /// second time, told why, when it doesn't, or when something that was said is missing); nil otherwise.
    private static func gemmaEmail(of text: String, extraInstructions: String?, userName: String,
                                   words: TemplateWords) async -> EmailDraftFields? {
        await SpokenCommand.gemmaDraft { refused in
            guard let raw = try? await Translator.shared.rewrite(
                      prompt: EmailDraftFields.gemmaPrompt(for: text, extraInstructions: extraInstructions, after: refused),
                      source: text, room: 96),
                  let email = EmailDraftFields(gemmaAnswer: LLMEditGuard.keepingDialect(of: text, in: raw), saidIn: text)
            else { return nil }
            let why = rejection(original: text, written: email.allText, people: [email.recipient], kind: .emailDraft)
            if ProcessInfo.processInfo.environment["MURMUR_TEMPLATE_DEBUG"] != nil {
                FileHandle.standardError.write(Data("GEMMA WROTE:\n\(raw)\nCHECK: \(why?.rawValue ?? "passed")\n".utf8))
            }
            // Against the finished email: the greeting is where "Dear Mr Jensen" went.
            return (email, why, TransformGuard.missedClauses(of: text, in: email.text(signedBy: userName, words: words)))
        }
    }

    /// Meeting notes by Gemma 4, when it is installed and what it writes passes the template's own check and gives no
    /// task to someone the recap didn't give it to (asked a second time, told why, when it doesn't, or when something
    /// that was said is missing); nil otherwise. `title`: the line above the notes, which says part of the recap too.
    private static func gemmaNotes(of text: String, words: TemplateWords, title: () async -> String) async -> MeetingNotesDraft? {
        await SpokenCommand.gemmaDraft { refused in
            guard let raw = try? await Translator.shared.rewrite(
                      prompt: MeetingNotesDraft.gemmaPrompt(for: text, after: refused), source: text, room: 96),
                  let notes = MeetingNotesDraft(gemmaAnswer: LLMEditGuard.keepingDialect(of: text, in: raw), saidIn: text)
            else { return nil }
            let people = notes.attendees + notes.actionItems.map(\.owner)
            let why = rejection(original: text, written: notes.allText, people: people, kind: .meetingNotes)
                ?? (notes.actionItems.contains { TemplateLayout.givenToSomeoneElse($0, in: text, people: people) } ? .changedMeaning : nil)
            if ProcessInfo.processInfo.environment["MURMUR_TEMPLATE_DEBUG"] != nil {
                FileHandle.standardError.write(Data("GEMMA WROTE:\n\(raw)\nCHECK: \(why?.rawValue ?? "passed")\n".utf8))
            }
            return (notes, why, leftOut(of: text, in: notes.text(words, saidIn: text, title: await title())))
        }
    }

    /// A task list by Gemma 4, on the same terms as its meeting notes; nil otherwise.
    private static func gemmaTasks(of text: String) async -> TaskListDraft? {
        await SpokenCommand.gemmaDraft { refused in
            guard let raw = try? await Translator.shared.rewrite(
                      prompt: TaskListDraft.gemmaPrompt(for: text, after: refused), source: text, room: 96),
                  let list = TaskListDraft(gemmaAnswer: LLMEditGuard.keepingDialect(of: text, in: raw))
            else { return nil }
            let people = list.tasks.map(\.owner)
            let why = rejection(original: text, written: list.allText, people: people, kind: .taskList)
                ?? (list.tasks.contains { TemplateLayout.givenToSomeoneElse($0, in: text, people: people) } ? .changedMeaning : nil)
            if ProcessInfo.processInfo.environment["MURMUR_TEMPLATE_DEBUG"] != nil {
                FileHandle.standardError.write(Data("GEMMA WROTE:\n\(raw)\nCHECK: \(why?.rawValue ?? "passed")\n".utf8))
            }
            return (list, why, leftOut(of: text, in: list.text(.plain, saidIn: text), tasksOnly: true))
        }
    }

    /// How much of a dictation a draft of it left out: things said that left no trace (`TransformGuard.missedClauses`)
    /// and numbers that aren't there any more — "pay invoice 4471 for 240 pounds" noted without the 240.
    /// `tasksOnly`: a task list leaves out what isn't a task ("the meeting went fine"), so only what there is to do
    /// counts.
    static func leftOut(of text: String, in finished: String, tasksOnly: Bool = false) -> Int {
        let kept = Set(TransformGuard.numbers(in: finished))
        let numbers = TransformGuard.numbers(in: text).filter { !kept.contains($0) }.count
        guard tasksOnly else { return numbers + TransformGuard.missedClauses(of: text, in: finished) }
        let said = text.replacingOccurrences(of: #"(?<!\d),(?!\d)|[.;!?]+(?=\s|$)|\n"#, with: "\u{1}", options: .regularExpression)
            .split(separator: "\u{1}").map(String.init)
        return numbers + said.filter { TemplateLayout.mentionsTasks($0) && TransformGuard.missedClauses(of: $0, in: finished) > 0 }.count
    }

    /// What a meeting was about, in the speaker's own words, for the line above the notes — "Launch prep" from "we
    /// went over launch prep". Said outright at the start of most recaps, so it is read off first (`spokenTopic`);
    /// only when it isn't does the model name it, and `TemplateLayout.title` then keeps a title only if every word
    /// of it was said. "" when there is none: the notes simply start with their first heading.
    static func meetingTitle(for text: String) async -> String {
        if let topic = TemplateLayout.spokenTopic(text) { return topic }
        // No example titles here: given "Launch prep" as one, the model answered "Launch prep" for a recap about a
        // kitchen (measured 2026-10-10; the words-were-said check dropped it, so the notes had no title at all).
        let session = LanguageModelSession(instructions: """
            You name a meeting from the user's own spoken recap of it. The title is two to four words taken from the \
            recap itself that name the subject the whole recap is about. Use only words the recap uses, and no verb. \
            When the recap has no single subject, leave the title empty.
            """)
        var options = GenerationOptions(sampling: .greedy)
        options.maximumResponseTokens = 24
        let prompt = "<text>\n\(text)\n</text>\n\nGive the meeting described in <text> its title."
        let title = (try? await session.respond(to: prompt, generating: MeetingTitleDraft.self, options: options).content.title) ?? ""
        if ProcessInfo.processInfo.environment["MURMUR_TEMPLATE_DEBUG"] != nil {
            FileHandle.standardError.write(Data("TITLE (model): \(title)\n".utf8))
        }
        return title
    }

    /// The same checks as a Transform's, fitted to templates: nothing Murmur's own prompt says, no answer, no
    /// invented number, link or file; no invented person or date where a template lists people (Meeting Notes, Email,
    /// Task List, Summary — a blog title may use new words); a summary shorter than what was said.
    /// `loose`: Latvian names change their ending ("Sofija", "Sofijai"), so a name counts as said when its first four
    /// letters were. `custom`: a free-form template of the user's own (a LinkedIn post, a translation) may bring in
    /// new capitalised words, so only numbers, links and files are held to what was said.
    static func rejection(original: String, written: String, people: [String] = [], kind: Kind?,
                          loose: Bool = false, custom: Bool = false) -> TransformGuard.Rejection? {
        if TransformGuard.leaksInstructions(original: original, output: written) { return .leakedInstructions }
        // Attendees, owners and the recipient: each one a name the user actually said.
        let said = original.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
        func wasSaid(_ word: String) -> Bool {
            loose && word.count >= 4 ? said.contains { $0.hasPrefix(word.prefix(4)) } : said.contains(word)
        }
        for person in people {
            let words = person.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
                .filter { !["the", "a", "an", "my", "our", "and"].contains($0) }
            if !words.allSatisfy(wasSaid) { return .inventedDetail }
        }
        if StyleRewriteGuard.openerRejection(original: original, rewritten: written) != nil { return .answered }
        // A free-form template of the user's own may legitimately change numbers and names (a translation turns
        // "3pm" into "15 Uhr"): it's held only to the checks above.
        if custom { return nil }
        if !TransformGuard.addsNoDetails(original: original, output: written) { return .inventedDetail }
        if kind != .blogPost,
           !TransformGuard.addsNoNames(original: original, output: written, loose: loose) { return .inventedDetail }
        // A summary that isn't clearly shorter than what was said isn't one (at most two thirds of it, or 40 words).
        if kind == .summary, written.split(whereSeparator: \.isWhitespace).count
            > max(40, original.split(whereSeparator: \.isWhitespace).count * 2 / 3) { return .notShorter }
        return nil
    }

    // MARK: - Latvian: the speaker's own words, arranged

    /// Measured 2026-10-01 on six Latvian dictations: asked to WRITE Latvian, Apple's on-device model (which doesn't
    /// list Latvian) produced broken forms ("Annus", "apskaitīšana", "Iziet videju"), dropped the start of an email,
    /// and once answered in English with wrong facts ("yesterday", "forty-five euros" for 240). So for Latvian the
    /// dictation is split into its own phrases (`TemplateLayout.clauses`), the model only says which phrase goes where
    /// (by number), and every line is the speaker's own words — correct Latvian, nothing invented. Headings, greeting
    /// and sign-off are Murmur's (`TemplateWords.latvian`).
    private static func arrangeInLatvian(_ text: String, kind: Kind, template: NoteTemplate, marks: TemplateMarks,
                                         userName: String) async throws -> String {
        let words = TemplateWords.latvian
        let clauses = TemplateLayout.clauses(text)
        guard !clauses.isEmpty else { throw Failure.nothingToFormat("\(template.name) found nothing to arrange.") }
        let firstName = userName.split(separator: " ").first.map(String.init) ?? ""
        func line(_ index: Int) -> String? {
            clauses.indices.contains(index - 1) ? TemplateLayout.listItem(clauses[index - 1]) : nil
        }

        switch kind {
        case .emailDraft:
            // A leading recipient ("Sofijai, …") is dropped from the body; the rest is the message, as said.
            var body = clauses
            if let first = body.first, first.split(separator: " ").count == 1 { body.removeFirst() }
            let message = TemplateLayout.paragraphs(body)
            guard !message.isEmpty else { throw Failure.nothingToFormat("Email Draft found no message.") }
            return words.greeting(nil) + "\n\n" + message + "\n\n" + words.signOff
                + (firstName.isEmpty ? "" : "\n" + firstName)
        case .blogPost:
            // The opening phrase becomes the title, the rest the post, in the author's own sentences.
            guard clauses.count >= 2 else { throw Failure.nothingToFormat("Blog Post needs more than one thought.") }
            return "# " + TemplateLayout.capitalized(clauses[0]) + "\n\n" + TemplateLayout.paragraphs(Array(clauses.dropFirst()))
        default:
            break
        }

        let numbered = clauses.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let arrangeInstructions = """
            You receive numbered phrases from something the user dictated in Latvian. You never write text: you only \
            put phrase numbers into the fields where they belong, each number at most once, and leave out phrases that \
            are filler or don't fit.
            """
        let session = LanguageModelSession(instructions: arrangeInstructions)
        var options = GenerationOptions(sampling: .greedy)
        options.maximumResponseTokens = 200
        let prompt = "<phrases>\n\(numbered)\n</phrases>"
        func items(_ indices: [Int]) -> [String] {
            var seen = Set<Int>()
            return indices.filter { seen.insert($0).inserted }.compactMap(line)
        }
        /// The model's placement as field → phrase numbers. Asked for fields first; when Apple's safety filter blocks
        /// a harmless dictation (measured: a Latvian trip summary), asked again under the guardrails Apple provides for
        /// transforming the user's own text — which only apply to plain-text answers, so the numbers come back as
        /// "field: 1, 3" lines.
        func placement<Plan: Generable>(_ type: Plan.Type, fields: [String],
                                        from plan: (Plan) -> [[Int]]) async throws -> [[Int]] {
            do {
                let placed = plan(try await session.respond(to: prompt, generating: type, options: options).content)
                if ProcessInfo.processInfo.environment["MURMUR_TEMPLATE_DEBUG"] != nil {
                    FileHandle.standardError.write(Data("PLACED: \(placed)\nPHRASES:\n\(numbered)\n".utf8))
                }
                return placed
            } catch let error as LanguageModelSession.GenerationError {
                if ProcessInfo.processInfo.environment["MURMUR_TEMPLATE_DEBUG"] != nil {
                    FileHandle.standardError.write(Data("GUIDED FAILED: \(error)\n".utf8))
                }
                guard case .guardrailViolation = error else { throw error }
                let permissive = LanguageModelSession(
                    model: SystemLanguageModel(guardrails: .permissiveContentTransformations),
                    instructions: arrangeInstructions)
                let form = fields.map { "\($0): numbers" }.joined(separator: "\n")
                let answer = try await permissive.respond(
                    to: prompt + "\n\nAnswer in exactly this form, with phrase numbers only:\n" + form, options: options).content
                if ProcessInfo.processInfo.environment["MURMUR_TEMPLATE_DEBUG"] != nil {
                    FileHandle.standardError.write(Data("PERMISSIVE ANSWER:\n\(answer)\n".utf8))
                }
                func numbers(_ text: Substring) -> [Int] { text.split { !$0.isNumber }.compactMap { Int($0) } }
                // One field: every number in the answer ("1. 2. 4." came back without its label).
                if fields.count == 1 { return [numbers(Substring(answer))] }
                return fields.map { field in
                    answer.split(whereSeparator: \.isNewline)
                        .first { $0.lowercased().hasPrefix(field.lowercased()) }
                        .map { numbers($0.drop { $0 != ":" }) } ?? []
                }
            }
        }
        switch kind {
        case .meetingNotes:
            let placed = try await placement(LatvianMeetingPlan.self,
                                             fields: ["Main points", "Decisions", "Actions", "Open questions"]) {
                [$0.keyPoints, $0.decisions, $0.actionItems, $0.openQuestions]
            }
            // Each phrase in one place. Latvian says outright what is undecided ("nezinām", "izlemsim"), decided
            // ("nolēmām") or to be done ("jāizdara", "izdarīšu") — those words decide first; the model places the rest;
            // anything left over is a main point, so nothing that was said is lost.
            var placement = [Int: Int]()   // phrase number → field (0 points, 1 decisions, 2 actions, 3 questions)
            for (field, indices) in placed.enumerated().reversed() {
                for index in indices where clauses.indices.contains(index - 1) && placement[index] == nil {
                    placement[index] = field
                }
            }
            for (offset, clause) in clauses.enumerated() {
                if let field = TemplateLayout.latvianMeetingField(of: clause) { placement[offset + 1] = field }
                if placement[offset + 1] == nil { placement[offset + 1] = 0 }
            }
            var sections: [String] = []
            for (field, title) in [words.keyPoints, words.decisions, words.actionItems, words.openQuestions].enumerated() {
                let lines = (1...clauses.count).filter { placement[$0] == field }.compactMap(line)
                if !lines.isEmpty { sections.append(title + "\n" + lines.map { marks.bullet + " " + $0 }.joined(separator: "\n")) }
            }
            guard !sections.isEmpty else { throw Failure.nothingToFormat("Meeting Notes found nothing to arrange.") }
            return sections.joined(separator: "\n\n")
        case .taskList:
            let tasks = items(try await placement(LatvianTaskPlan.self, fields: ["Tasks"]) { [$0.tasks] }[0])
            guard !tasks.isEmpty else { throw Failure.nothingToFormat("No tasks were found in what you said.") }
            return tasks.map { marks.checkbox + " " + $0 }.joined(separator: "\n")
        case .summary:
            let chosen = try await placement(LatvianSummaryPlan.self, fields: ["Main points"]) { [$0.mainPoints] }[0]
            let points = Array(items(chosen).prefix(3))
            guard !points.isEmpty, points.count < clauses.count else {
                throw Failure.refused(name: template.name, .notShorter)
            }
            return points.map(TemplateLayout.sentence).joined(separator: " ")
        case .emailDraft, .blogPost:
            return text
        }
    }

    // MARK: - The user's own templates

    /// One field per part, built at run time from the user's own headings (`DynamicGenerationSchema`); a part they
    /// said nothing about comes back empty and is left out.
    private static func fill(_ parts: [TemplateSectionSpec], session: LanguageModelSession, prompt: String,
                             options: GenerationOptions) async throws -> [(heading: String, text: String)] {
        let properties = parts.enumerated().map { index, part in
            DynamicGenerationSchema.Property(
                name: "part\(index + 1)",
                description: "\(part.heading): \(part.content). Everything the user said about this, all of it, in "
                    + "their own words; empty when they said nothing about it.",
                schema: DynamicGenerationSchema(type: String.self))
        }
        let schema = try GenerationSchema(root: DynamicGenerationSchema(name: "Result", properties: properties),
                                          dependencies: [])
        let content = try await session.respond(to: prompt, schema: schema, options: options).content
        return parts.enumerated().compactMap { index, part in
            let text = ((try? content.value(String.self, forProperty: "part\(index + 1)")) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : (part.heading, TemplateLayout.sentence(text))
        }
    }

    /// The parts a description asks for, worked out once when the template is saved or tried — "A short update in
    /// three parts: what I did yesterday, what I'm doing today, and anything blocking me" gives Yesterday, Today,
    /// Blockers. Empty for anything that isn't laid out in parts (a message, an email, a list, a translation), which
    /// then runs from the description as written.
    static func planSections(for description: String) async -> [TemplateSectionSpec] {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        // Parts are named in a list: a colon, or at least two commas / "and"s.
        let separators = trimmed.filter { $0 == "," }.count + (trimmed.lowercased().contains(" and ") ? 1 : 0)
        guard trimmed.contains(":") || separators >= 2,
              SystemLanguageModel.default.availability == .available else { return [] }
        let session = LanguageModelSession(instructions: """
            You read a description of how someone wants their dictation laid out, and list the parts it names, in \
            order, each with a short heading. Only list parts the description actually names; when it doesn't ask for \
            the result in parts, return none.
            """)
        var options = GenerationOptions(sampling: .greedy)
        options.maximumResponseTokens = 300
        guard let plan = try? await session.respond(
            to: "<description>\n\(trimmed)\n</description>", generating: SectionPlan.self, options: options).content
        else { return [] }
        let parts = plan.parts.map {
            TemplateSectionSpec(heading: TemplateLayout.capitalized($0.heading.trimmingCharacters(in: .whitespacesAndNewlines)),
                                content: $0.content.trimmingCharacters(in: .whitespacesAndNewlines))
        }.filter { !$0.heading.isEmpty }
        return (2...8).contains(parts.count) ? parts : []
    }
}

@Generable
struct LatvianMeetingPlan {
    @Guide(description: "Numbers of the phrases that are main points of what was discussed.")
    let keyPoints: [Int]
    @Guide(description: "Numbers of the phrases that say what was decided. Empty when nothing was decided.")
    let decisions: [Int]
    @Guide(description: "Numbers of the phrases that say someone will do something.")
    let actionItems: [Int]
    @Guide(description: "Numbers of the phrases that are still open or undecided.")
    let openQuestions: [Int]
}

@Generable
struct LatvianTaskPlan {
    @Guide(description: "Numbers of the phrases that are something to do. Empty when none are.")
    let tasks: [Int]
}

@Generable
struct LatvianSummaryPlan {
    @Guide(description: "Numbers of the two or three phrases that carry the most important points, in order.")
    let mainPoints: [Int]
}

/// What one part of the user's own template holds.
struct TemplateSectionSpec: Codable, Equatable {
    var heading: String
    var content: String
}

@Generable
struct SectionPlan {
    @Guide(description: "The parts the result should have, in order, only when the description asks for it in parts or under headings — for example 'what I did yesterday, what I'm doing today, and anything blocking me' has three parts. Empty for a message, an email, a list, a post or a translation.")
    let parts: [SectionPlanPart]
}

@Generable
struct SectionPlanPart {
    @Guide(description: "A heading of one or two words naming the part, in the description's own language, for example Yesterday, Today or Blockers.")
    let heading: String
    @Guide(description: "What goes in this part, in the description's words.")
    let content: String
}

/// The language a template is applied in. English, and Latvian: Apple's on-device model doesn't officially list
/// Latvian (2026-10-01: da de en es fr it ja ko nb nl pt sv tr vi zh), but templates mostly rearrange the speaker's own
/// words, which it does well enough in Latvian; the words Murmur adds itself come from `TemplateWords`.
enum TemplateLanguage: String {
    case english = "en", latvian = "lv"

    /// The dictation's language, when templates support it.
    static func from(localeIdentifier: String) -> TemplateLanguage? {
        TemplateLanguage(rawValue: String(localeIdentifier.prefix { $0 != "-" && $0 != "_" }).lowercased())
    }
}

/// The words Murmur writes itself around what the model filled in.
struct TemplateWords {
    var attendees, keyPoints, decisions, actionItems, openQuestions, subject: String
    /// The heading over a single decision.
    var decision: String
    /// Action items written out as sentences ("Maya will email the testers tomorrow") — English; Latvian keeps the
    /// speaker's own phrase.
    var sentences = false
    /// The greeting for a recipient name (nil = none said), and for a group ("team").
    var greeting: (_ name: String?) -> String
    var signOff: String

    static let english = TemplateWords(
        attendees: "Attendees", keyPoints: "Key points", decisions: "Decisions", actionItems: "Action items",
        openQuestions: "Open questions", subject: "Subject", decision: "Decision", sentences: true,
        greeting: { name in
            guard let name else { return "Hello," }
            // "Mr Jensen", "Dr Patel": written to the way they were spoken of.
            if name.contains(" ") { return "Dear \(name)," }
            return ["team", "everyone", "all", "everybody"].contains(name.lowercased()) ? "Hi \(name.lowercased())," : "Hi \(name),"
        },
        signOff: "Best,")

    /// Latvian addresses a person in the vocative, which a spoken name rarely is — so the greeting is the neutral
    /// "Labdien!" (or "Sveiki visiem!" for a group) rather than a name in the wrong case.
    static let latvian = TemplateWords(
        attendees: "Dalībnieki", keyPoints: "Galvenais", decisions: "Lēmumi", actionItems: "Darāmais",
        openQuestions: "Atklātie jautājumi", subject: "Temats", decision: "Lēmums",
        greeting: { name in
            guard let name else { return "Labdien!" }
            return ["komanda", "komandai", "visiem", "kolēģiem", "team"].contains(name.lowercased()) ? "Sveiki visiem!" : "Labdien!"
        },
        signOff: "Ar cieņu,")

    static func `for`(_ language: TemplateLanguage) -> TemplateWords {
        language == .latvian ? .latvian : .english
    }
}

// MARK: - The fields each built-in template fills

@Generable
private struct TemplateText {
    let text: String
}

@Generable
struct SummaryDraft {
    @Guide(description: "The two or three most important points, each one sentence of at most fifteen words in the speaker's voice (I, we). Keep what each point means exactly, including words like 'as of', 'because', 'about' and 'maybe', and keep numbers, names and dates as said.")
    let mainPoints: [String]

    /// One paragraph, from at most four points.
    var text: String {
        TemplateLayout.clean(mainPoints).prefix(4).map(TemplateLayout.sentence).joined(separator: " ")
    }
}

/// How a template marks its lists and headings where the text is going. Real bullets and plain headings nearly
/// everywhere: in Notes or Mail a column of "- " and a "# Title" are Markdown nobody asked for. Markdown where it is
/// the convention and turns into formatting by itself (Obsidian, Notion, a prompt to Claude) — the same line
/// `SpokenCommand.bullet(forBundleID:)` draws for a list made by voice.
struct TemplateMarks: Equatable {
    var bullet: String
    var checkbox: String
    var markdown: Bool

    static let plain = TemplateMarks(bullet: "•", checkbox: "☐", markdown: false)
    static let markdown = TemplateMarks(bullet: "-", checkbox: "- [ ]", markdown: true)
    static func `for`(bundleID: String?) -> TemplateMarks {
        SpokenCommand.bullet(forBundleID: bundleID) == "-" ? .markdown : .plain
    }

    /// Text a model laid out itself (a template of the user's own), with its Markdown marks made plain.
    func applied(to text: String) -> String {
        guard !markdown else { return text }
        var result = text.replacingOccurrences(of: "(?m)^([ \\t]*)[-*] \\[ ?\\][ \\t]+", with: "$1☐ ", options: .regularExpression)
        result = result.replacingOccurrences(of: "(?m)^([ \\t]*)[-*][ \\t]+", with: "$1• ", options: .regularExpression)
        return result.replacingOccurrences(of: "(?m)^#{1,6}[ \\t]+", with: "", options: .regularExpression)
    }
}

@Generable
struct MeetingNotesDraft {
    @Guide(description: "People named as taking part. Empty when nobody is named.")
    let attendees: [String]
    @Guide(description: "The topics and points discussed, one per item, as short clear sentences.")
    let keyPoints: [String]
    @Guide(description: "Only what was actually decided, one per item. Empty when nothing was decided.")
    let decisions: [String]
    @Guide(description: "Each task someone will do, one per item. Empty when none was mentioned.")
    let actionItems: [ActionItemDraft]
    @Guide(description: "Questions left open or things still to decide. Empty when there are none.")
    let openQuestions: [String]
    // No title field here on purpose. With one — first or last — the model filled the other fields differently: asked
    // first it took the opening point for itself and a decision landed under the key points; asked last it folded
    // "ready by Wednesday" into an action (measured 2026-10-10 on the website's example). The title is found
    // separately (`TemplateEngine.meetingTitle`).

    var allText: String {
        (attendees + keyPoints + decisions + actionItems.map(\.line) + openQuestions).joined(separator: "\n")
    }

    var text: String { text(.english) }

    /// A title when what was said gives one, then each part under its heading; a part with nothing in it is left
    /// out. The shape meeting notes are usually given, and the one the website shows: what it was about, the points,
    /// what was decided, and who does what by when.
    /// `saidIn`: the dictation, which a title has to come from.
    func text(_ words: TemplateWords, marks: TemplateMarks = .plain, saidIn original: String? = nil,
              title: String = "") -> String {
        var sections: [String] = []
        let heading = TemplateLayout.title(title, saidIn: original)
        if !heading.isEmpty { sections.append(heading) }
        // "I" isn't an attendee worth a line of its own, and nobody is one unless the dictation says who was there:
        // "Maya will email the testers" gives Maya a task, not a seat.
        let people = TemplateLayout.clean(attendees).filter { !TemplateLayout.isSpeaker($0) }
        if !people.isEmpty, original.map(TemplateLayout.saysWhoAttended) ?? true {
            sections.append("\(words.attendees): " + people.joined(separator: ", "))
        }
        // "We decided to keep the old cabinets" filed as a point is a decision all the same: the speaker said so.
        var points: [String] = [], moved: [String] = []
        for point in TemplateLayout.clean(keyPoints) {
            if words.sentences, let decision = TemplateLayout.statedDecision(point) { moved.append(decision) } else { points.append(point) }
        }
        // The speaker's own statement of a decision stands in for the model's version of the same one.
        let kept = decisions.filter { decision in !moved.contains { TransformGuard.coverage(of: $0, in: decision) >= 0.6 } }
        let decided = TemplateLayout.clean(kept + moved)
        let actions = actionItems.map { words.sentences ? $0.sentence(saidIn: original) : $0.line }
        // A point that is also listed as a decision or an action is said once, where it counts.
        let elsewhere = Set((decided + actionItems.map(\.task)).map(TemplateLayout.key))
        points = points.filter { !elsewhere.contains(TemplateLayout.key($0)) }
        for (title, items) in [(words.keyPoints, points),
                               (decided.count == 1 ? words.decision : words.decisions, decided),
                               (words.actionItems, TemplateLayout.clean(actions)),
                               (words.openQuestions, TemplateLayout.clean(openQuestions))] where !items.isEmpty {
            sections.append(title + "\n" + items.map { marks.bullet + " " + $0 }.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }
}

// MARK: - Meeting Notes by Apple's model: nothing from its worked example

extension MeetingNotesDraft {
    /// Apple's model's answer without what it took from the template's worked example rather than from the
    /// dictation. Measured 2026-10-10 on nineteen spoken recaps: six came back with the decision "Push the launch
    /// date instead of cutting scope" — the example's own (`NoteTemplate.builtIns`) — in notes about a kitchen, a
    /// one-to-one and a job interview, and `TemplateEngine.rejection` passes it, every word in it being ordinary.
    /// So the answer is read against the dictation: a line that is one of the example's goes unless the recap said
    /// the same (`TemplateLayout.isExampleLine`), and a decision already goes when half of its words are the
    /// example's and fewer than half were said — with the Formal tone on, the same decision came back as "The
    /// launch date will be postponed instead of reducing the scope". A decision merely reworded ("The hiring team
    /// is unchanged") is none of the example's and stays. The rest is the model's answer as it was. Taking the
    /// example away, or only its decision, stopped the leak too but changed sixteen or more of the nineteen notes
    /// (one refused, lines said twice, tasks filed as open questions, "Nothing else" as an action), so it stays.
    func withoutExampleLines(of template: NoteTemplate, saidIn text: String) -> MeetingNotesDraft {
        func own(_ line: String) -> Bool { !TemplateLayout.isExampleLine(line, of: template, saidIn: text) }
        return MeetingNotesDraft(
            attendees: attendees, keyPoints: keyPoints.filter(own),
            decisions: decisions.filter { own($0) && !TemplateLayout.isExampleLine($0, of: template, saidIn: text, share: 0.5) },
            actionItems: actionItems.filter { own($0.task) }, openQuestions: openQuestions.filter(own))
    }
}

@Generable
struct MeetingTitleDraft {
    @Guide(description: "Two to four words from the text naming what the meeting was about. Empty when the text doesn't say.")
    let title: String
}

@Generable
struct ActionItemDraft {
    @Guide(description: "What needs to be done, as a short instruction.")
    let task: String
    @Guide(description: "Who will do it, only when named. Empty otherwise.")
    let owner: String
    @Guide(description: "When it is due, only when said. Empty otherwise.")
    let due: String

    /// "Tom: write the copy (by Thursday)".
    var line: String {
        let task = task.trimmingCharacters(in: .whitespacesAndNewlines)
        let owner = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        let due = due.trimmingCharacters(in: .whitespacesAndNewlines)
        var line = owner.isEmpty ? task : "\(owner): \(task.prefix(1).lowercased() + task.dropFirst())"
        if !due.isEmpty, !task.lowercased().contains(due.lowercased()) { line += " (\(due))" }
        return line
    }

    /// "Maya will email the beta testers tomorrow", "I'll update the page", "Renew the domain before the 12th": who,
    /// what and by when as one sentence — how an action is written down so that it still reads right next week (a
    /// named owner, the thing to do, the deadline). Put together by Murmur from the three fields, so nothing in it
    /// is the model's own wording.
    var sentence: String { sentence(saidIn: nil) }

    /// `saidIn`: the dictation, for the word that tied the deadline to the task ("on Friday", not "by Friday").
    func sentence(saidIn original: String?) -> String {
        var task = task.trimmingCharacters(in: .whitespacesAndNewlines)
        let owner = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        let due = due.trimmingCharacters(in: .whitespacesAndNewlines)
        let who = owner.lowercased()
        // The task without a run-up of its own ("to update…", "will update…", "Maya will…", "I'll…").
        var leads = ["i'll ", "i will ", "i'm going to ", "i am going to ", "i need to ", "i have to ", "we'll ", "we will ",
                     "we need to ", "to ", "will ", "needs to ", "need to ", "should ", "has to ", "have to ", "is going to ",
                     "going to "]
        if !who.isEmpty { leads = ["\(who) will ", "\(who) to ", "\(who) needs to ", "\(who) should ", "\(who) is going to "] + leads }
        for lead in leads where task.lowercased().replacingOccurrences(of: "\u{2019}", with: "'").hasPrefix(lead) {
            task.removeFirst(lead.count)
            break
        }
        // Lower case after "will", unless the first word is a name or an abbreviation ("API docs", "Anna's deck").
        let second = task.dropFirst().first
        let body = second.map { $0.isLowercase || $0 == " " } == true && !Self.keepsCapital(task)
            ? task.prefix(1).lowercased() + task.dropFirst() : task
        var line: String
        if ["", "someone", "somebody", "anyone", "anybody", "nobody", "unknown", "none", "n/a", "tbd", "unassigned"].contains(who) {
            line = TemplateLayout.capitalized(task)
        } else if ["i", "me", "myself"].contains(who) {
            line = "I'll " + body
        } else if ["we", "us", "the team", "team", "everyone"].contains(who) {
            line = "We'll " + body
        } else {
            line = "\(TemplateLayout.capitalized(owner)) will " + body
        }
        if !due.isEmpty, !line.lowercased().contains(due.lowercased()) {
            if Self.readsAsWhen(due) {
                line += " " + TemplateLayout.lowercasedLead(due)
            } else {
                // The speaker's own word before the date, when they used one; "by" otherwise.
                let pattern = "\\b(by|on|before|after|until|till|at|in|this|next)\\s+" + NSRegularExpression.escapedPattern(for: due)
                let spoken = original.flatMap { text in
                    text.range(of: pattern, options: [.regularExpression, .caseInsensitive]).map { String(text[$0]) }
                }?.split(separator: " ").first.map { $0.lowercased() }
                line += " \(spoken ?? "by") " + due
            }
        }
        return line
    }

    /// "I" and a capitalised second word ("Email Anna" is a verb; "Anna's deck" isn't, but that isn't a task).
    private static func keepsCapital(_ task: String) -> Bool {
        let first = task.split(separator: " ").first.map(String.init) ?? ""
        return first == "I" || first.hasPrefix("I'") || first.hasPrefix("I\u{2019}")
    }

    /// A deadline that already says how it relates to the task ("by Thursday", "tomorrow", "next week", "before the
    /// 12th") rather than a bare date ("Thursday", "the 12th"), which gets a "by".
    private static func readsAsWhen(_ due: String) -> Bool {
        let first = due.lowercased().split(separator: " ").first.map(String.init) ?? ""
        return ["by", "on", "before", "after", "until", "till", "in", "at", "this", "next", "tomorrow", "today", "tonight",
                "end", "eod", "asap", "later", "within", "every", "each", "now", "soon", "first", "early", "late", "when",
                "once", "as"].contains(first)
    }
}

@Generable
struct EmailDraftFields {
    @Guide(description: "A short subject line made only from what the email is about.")
    let subject: String
    @Guide(description: "The first name or group the email is written to, only when the text says it (for example Sophie or team). Empty otherwise.")
    let recipient: String
    @Guide(description: "The body of the email as paragraphs, rewritten as a message to the recipient in the user's voice: 'can she ask legal to change it' becomes 'Could you ask legal to change it?'. No greeting or sign-off.")
    let paragraphs: [String]

    var allText: String { ([subject] + paragraphs).joined(separator: "\n") }

    /// The greeting and sign-off are Murmur's, never the model's: no "[Your Name]", no guessed recipient.
    func text(signedBy userName: String, words: TemplateWords = .english) -> String {
        let name = recipient.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let isGroup = ["team", "everyone", "all", "everybody", "komanda", "komandai", "visiem", "kolēģiem"]
            .contains(name.lowercased())
        // A first name ("Sophie"), or a title and a surname ("Mr Jensen").
        let parts = name.split(separator: " ")
        let titled = parts.count == 2 && parts[1].first?.isUppercase == true
            && ["mr", "mrs", "ms", "miss", "mx", "dr", "prof", "professor", "sir"]
                .contains(parts[0].lowercased().trimmingCharacters(in: .punctuationCharacters))
        let isName = name.first?.isUppercase == true && (parts.count == 1 || titled)
        let greeting = words.greeting(isGroup || isName ? name : nil)
        let firstName = userName.split(separator: " ").first.map(String.init) ?? ""
        let body = TemplateLayout.clean(paragraphs).map(TemplateLayout.sentence).joined(separator: "\n\n")
        let subject = TemplateLayout.capitalized(subject.trimmingCharacters(in: .whitespacesAndNewlines))
        return (subject.isEmpty ? "" : "\(words.subject): \(subject)\n\n") + greeting + "\n\n" + body
            + "\n\n\(words.signOff)" + (firstName.isEmpty ? "" : "\n" + firstName)
    }
}

// MARK: - Email Draft by Gemma 4

extension EmailDraftFields {
    /// Gemma 4's answer read back into the fields: "Subject: …", "To: …", then the message, a paragraph to a blank
    /// line. A greeting or a sign-off the model wrote anyway is dropped — those are Murmur's (`text(signedBy:)`).
    init?(gemmaAnswer answer: String, saidIn original: String = "") {
        var subject = "", recipient = ""
        var paragraphs: [String] = [], current: [String] = []
        func endParagraph() {
            if !current.isEmpty { paragraphs.append(current.joined(separator: " ")) }
            current = []
        }
        for raw in answer.components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
            let lower = line.lowercased()
            // The two labelled lines come before the message; the examples' "Email:" may come back too.
            if paragraphs.isEmpty, current.isEmpty {
                if lower.hasPrefix("subject:") { subject = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces); continue }
                if lower.hasPrefix("to:") { recipient = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces); continue }
                if lower == "email:" { continue }
            }
            if line.isEmpty { endParagraph() } else { current.append(line) }
        }
        endParagraph()
        if ["none", "none.", "n/a", "nobody", "-"].contains(recipient.lowercased()) { recipient = "" }
        // A subject in Title Case ("Contract Review", what a formal tone brings out) goes back to sentence case: a
        // word keeps its capital only when the dictation wrote it with one.
        let capitals = Set(original.split { !$0.isLetter }.map(String.init))
        subject = subject.split(separator: " ").enumerated().map { index, word in
            let letters = word.trimmingCharacters(in: .punctuationCharacters)
            guard index > 0, letters.count > 1, letters.allSatisfy(\.isLetter), letters.first?.isUppercase == true,
                  letters.dropFirst() == letters.dropFirst().lowercased(), !capitals.contains(letters) else { return String(word) }
            return word.lowercased()
        }.joined(separator: " ")
        if recipient.lowercased().hasPrefix("the ") { recipient.removeFirst(4) }
        // "Hello, I'd like to cancel…", "Hi Tom,": said as the greeting, so not said again under Murmur's.
        if let first = paragraphs.first {
            let rest = first.replacingOccurrences(
                of: #"^(?i:hi|hello|hey|dear|good (?:morning|afternoon|evening))(?: (?:there|all|everyone|team|[A-Z][\w.'’-]*)){0,3}[,!.]\s*"#,
                with: "", options: .regularExpression)
            if rest.isEmpty { paragraphs.removeFirst() } else { paragraphs[0] = rest }
        }
        // "Best regards," and a name or "[Your Name]" under it, at the end; "Best to wait until Monday." is the message.
        if let last = paragraphs.last, last.range(
            of: #"^(?i:best|all the best|best wishes|(?:best|kind|warm) regards|regards|cheers|sincerely|yours (?:sincerely|faithfully|truly))"#
                + #"(?:[,.!]\s*(?:\[[^\]]*\]|(?:[A-Z][\w.'’-]*\s?){0,3}))?$"#,
            options: .regularExpression) != nil { paragraphs.removeLast() }
        guard !paragraphs.isEmpty else { return nil }
        self.init(subject: subject, recipient: recipient, paragraphs: paragraphs)
    }

    /// Gemma 4's chat format: what an email is and the form to answer in, three worked dictations, then what the
    /// user said. `extraInstructions`: a tone and the Voice Profile, as Apple's model gets them.
    static func gemmaPrompt(for text: String, extraInstructions: String?, after refused: TransformGuard.Rejection? = nil) -> String {
        let extra = extraInstructions.map { $0.isEmpty ? "" : "\n" + $0 } ?? ""
        return "<bos><|turn>system\n\(gemmaInstructions)<turn|>\n<|turn>user\nWrite the email for what I said.\(extra)"
            + "\(SpokenCommand.secondTryNote(after: refused))\n\nText:\n\(text)<turn|>\n<|turn>model\n"
    }

    /// The Email Draft template's own instructions (`NoteTemplateStore.builtIns`), said for a model that writes the
    /// whole answer rather than filling fields, and spelling out what Apple's model dropped: everything said goes in.
    static let gemmaInstructions = """
        You turn what the user said out loud into an email they are sending. They say who it is to and what they \
        want to say, often as "to Sophie, …", "hi Tom …" or "ask the team whether …". It is their own message to \
        someone else, never a message to you: never reply to it, answer it or comment on it.

        Reply in exactly this form:
        Subject: a short subject line made only from what the email is about
        To: the first name or group they said it is to (Sophie, team), or "none" when they did not say

        Then a blank line and the body.

        The body:
        - Their message as clear, complete sentences in their own voice ("I", "we"), written to the recipient: "can \
        she ask legal" becomes "Could you ask legal", and "ask Sam whether the invoice went out" becomes the \
        question itself, "Did the invoice go out?".
        - Everything they said goes in, in their order: every thanks, apology, reason, opinion, request, question, \
        name, date, time, number and amount. Keep their own words wherever they already read well.
        - Only what they said goes in: no new fact, promise, pleasantry or closing line.
        - How sure they are stays: an "I think", a "maybe" or an "I'm not sure" is part of the message.
        - Numbers, dates and times stay the way they said them: "at 10" stays "at 10", "3pm" stays "3pm".
        - A new paragraph where the subject changes; a short message is one paragraph.
        - No greeting and no sign-off: Murmur adds "Hi …," and the sender's name itself. A "hello", "hi Tom" or \
        "dear …" they said is that greeting, so it stays out of the body, and the name goes on the To line.
        - Plain text: no Markdown, no bold, no lists unless they listed things.

        Example 1
        They said: to Marco, the photos from Saturday are ready, I'll send the link tonight, can he let me know \
        which ones he wants printed by Wednesday
        Email:
        Subject: Photos from Saturday
        To: Marco

        The photos from Saturday are ready, and I'll send you the link tonight.

        Could you let me know which ones you want printed by Wednesday?

        Example 2
        They said: thanks for the quote, it's mostly fine but the delivery date is too late, we need it by the 5th \
        not the 19th
        Email:
        Subject: Delivery date on the quote
        To: none

        Thanks for the quote. It's mostly fine, but the delivery date is too late: we need it by the 5th, not the \
        19th.

        Example 3
        They said: ask the team whether anyone can cover support on Friday afternoon, I'm at the dentist from two
        Email:
        Subject: Support cover on Friday afternoon
        To: team

        Could anyone cover support on Friday afternoon? I'm at the dentist from two.
        """
}

@Generable
struct TaskListDraft {
    @Guide(description: "Every task, to-do or action the user mentions, one per item. Empty when nothing is a task.")
    let tasks: [ActionItemDraft]

    var allText: String { tasks.map(\.line).joined(separator: "\n") }
    var text: String { text(.plain) }
    /// One box to a task: an empty box where the text is plain, a Markdown checkbox where Markdown is read.
    func text(_ marks: TemplateMarks, saidIn original: String? = nil) -> String {
        TemplateLayout.clean(tasks.map { $0.sentence(saidIn: original) }).map { marks.checkbox + " " + $0 }
            .joined(separator: "\n")
    }
}

// MARK: - Meeting Notes and Task List by Gemma 4

extension MeetingNotesDraft {
    /// Gemma 4's answer read back into the fields: a labelled line for each thing said — "Attendees: Anna, Tom",
    /// "Point: …", "Decision: …", "Action: who | the task", "Question: …" — or the same labels as headings over "- "
    /// lines. A model's word isn't enough for two of them, so the dictation is asked as well: someone is an attendee
    /// only where it says they were there (`TemplateLayout.saysAttended`), and a decision only where it says so
    /// (`saidAsDecided`) — otherwise it is a point, which loses nothing.
    init?(gemmaAnswer answer: String, saidIn original: String) {
        var attendees: [String] = [], points: [String] = [], decisions: [String] = [], questions: [String] = []
        var actions: [ActionItemDraft] = []
        var part = ""
        for raw in answer.components(separatedBy: "\n") {
            var line = raw.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
            for mark in ["- ", "• ", "* "] where line.hasPrefix(mark) { line.removeFirst(mark.count) }
            if let colon = line.firstIndex(of: ":"),
               let label = ["attendees", "point", "decision", "action", "question"].first(where: {
                   [$0, $0 + "s"].contains(line[..<colon].lowercased())
               }) {
                part = label
                line = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            guard !line.isEmpty, !TemplateLayout.isNone(line) else { continue }
            switch part {
            case "attendees":
                attendees += line.components(separatedBy: ",").flatMap { $0.components(separatedBy: " and ") }
                    .map { $0.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters)) }
                    .filter { !$0.isEmpty && !TemplateLayout.isNone($0) && !TemplateLayout.isSpeaker($0)
                        && TemplateLayout.saysAttended($0, in: original) }
            case "point": points.append(line)
            case "decision":
                if TemplateLayout.saidAsDecided(line, in: original) { decisions.append(line) } else { points.append(line) }
            case "action":
                if let action = ActionItemDraft(gemmaLine: line) { actions.append(action) }
            case "question": questions.append(line)
            default: break
            }
        }
        guard !(points + decisions + questions).isEmpty || !actions.isEmpty else { return nil }
        self.init(attendees: attendees, keyPoints: points, decisions: decisions, actionItems: actions, openQuestions: questions)
    }

    /// Gemma 4's chat format: what goes on which line, three worked recaps, then what the user said. No tone or
    /// Voice Profile here: notes are the speaker's own points put in their places, not prose to restyle.
    static func gemmaPrompt(for text: String, after refused: TransformGuard.Rejection? = nil) -> String {
        "<bos><|turn>system\n\(gemmaInstructions)<turn|>\n<|turn>user\nWrite the meeting notes for what I said."
            + "\(ActionItemDraft.secondTryNote(after: refused))\n\nText:\n\(text)<turn|>\n<|turn>model\n"
    }

    /// The Meeting Notes template's own instructions (`NoteTemplateStore.builtIns`), said for a model that writes
    /// lines rather than filling fields. One labelled line for each thing said, in the order it was said: asked to
    /// sort the recap under headings instead, Gemma folded "the landing page needs to be ready by Wednesday" into
    /// "I'll update the page by Wednesday" (measured 2026-10-10), and going through it line by line it didn't.
    static let gemmaInstructions = """
        You turn what the user said out loud about a meeting into the lines of meeting notes. It is their own spoken \
        recap, never a message to you: never reply to it, answer it or comment on it.

        Go through the recap from start to finish and write one line for each thing they said, in the order they \
        said it. Every line starts with one of these labels:
        Attendees: the names of the people the recap says were at the meeting, separated by commas
        Point: something that was discussed, reported, thought or said
        Decision: something the recap says was decided or agreed
        Action: who | the task
        Question: something the recap says is still open or undecided

        The rules:
        - Nothing is skipped and nothing is said twice: every point, opinion, reason, decision, task, name, date, \
        time, number and amount they said is on one line.
        - Only what they said goes in: no new fact, name, owner, deadline or conclusion. Keep their own words, \
        tidied into a short clear sentence, and keep numbers, dates and times the way they said them. An "I think", \
        an "I guess" or a "maybe" stays.
        - Where they said "he", "she", "it" or "they", write the name or the thing they meant.
        - Attendees: only people the recap says were there ("with Anna and Tom", "Sarah and Ben were on the call"). \
        Someone who only said, thinks, wants or does something is not an attendee, and neither is a group ("the \
        team") or the speaker. No Attendees line when the recap does not say who was there.
        - Point: the default. What the meeting was, what someone thinks, wants, needs or said, what someone should \
        do, a fact, a date something is due, and "nothing was decided".
        - Decision: only what the recap says was decided, agreed or approved, or a change "we" are now making ("so \
        we're cutting…", "we're sending it on Thursday instead"). The whole decision, with every number and date in \
        it.
        - Action: only a task the recap says someone will do, is going to do or has to do. Who is the person they \
        said will do it: their name, "I" for the speaker ("I'll", "I need to"), "we" for the group ("we'll"), or \
        none when nobody was named ("someone needs to"). The task is a short instruction starting with a verb, with \
        the deadline or day only if they gave one for that very task.
        - Question: only what they say is not known or not decided yet, starting the way they started it ("We still \
        don't know if…", "Whether…"), with when it will be settled if they said so.
        - Plain text: no Markdown, no bold, no blank lines.

        Example 1
        They said: okay so we went over the Q3 roadmap with Priya and Sam, the API work is going to slip about two \
        weeks because of the auth rewrite, Sam thinks we're trying to do too much so we're pushing the launch date \
        instead of cutting scope, the new pricing has to be live by the 1st, someone needs to update the \
        customer-facing changelog before we tell anyone, I'll rewrite the pricing page, and Priya will talk to sales \
        on Monday
        Notes:
        Attendees: Priya, Sam
        Point: Went over the Q3 roadmap
        Point: The API work is going to slip about two weeks because of the auth rewrite
        Point: Sam thinks we're trying to do too much
        Decision: Push the launch date instead of cutting scope
        Point: The new pricing has to be live by the 1st
        Action: none | Update the customer-facing changelog before we tell anyone
        Action: I | Rewrite the pricing page
        Action: Priya | Talk to sales on Monday

        Example 2
        They said: catch-up with Nina about the office move. The new place is ready from the 1st of May and the rent \
        is 2,400 a month. She thinks the kitchen is too small and she wants me to look at other floors. We agreed to \
        keep Fridays remote. I'll order the desks this week, she'll sort out the internet and send me the floor plan \
        by Friday. We still don't know how many parking spaces we get, the landlord will tell us next week.
        Notes:
        Attendees: Nina
        Point: Catch-up about the office move
        Point: The new place is ready from the 1st of May and the rent is 2,400 a month
        Point: Nina thinks the kitchen is too small
        Point: Nina wants me to look at other floors
        Decision: Keep Fridays remote
        Action: I | Order the desks this week
        Action: Nina | Sort out the internet and send me the floor plan by Friday
        Question: We still don't know how many parking spaces we get; the landlord will tell us next week

        Example 3
        They said: we looked at the survey results, Jo said the response rate was only 12 percent, Ravi thinks we \
        should ask fewer questions, people should get a reminder after a week, Lena needs the raw data from the \
        agency by Tuesday or the report is late, nothing was decided, I guess we wait for the agency, we'll look at \
        it again next Thursday
        Notes:
        Point: Looked at the survey results
        Point: Jo said the response rate was only 12 percent
        Point: Ravi thinks we should ask fewer questions
        Point: People should get a reminder after a week
        Point: Lena needs the raw data from the agency by Tuesday or the report is late
        Point: Nothing was decided
        Point: I guess we wait for the agency
        Action: we | Look at the survey results again next Thursday
        """
}

extension ActionItemDraft {
    /// One of Gemma 4's task lines, "who | the task": who is a name, "I", "we" or "none". A deadline stays in the
    /// task, in the place and the words it was said ("for Saturday the 14th", "if there's time") — asked for it in
    /// a field of its own, Gemma took a date said about something else.
    init?(gemmaLine line: String) {
        let parts = line.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        let task = parts.count > 1 ? parts[1] : parts[0]
        guard !task.isEmpty, !TemplateLayout.isNone(task) else { return nil }
        self.init(task: task, owner: parts.count > 1 && !TemplateLayout.isNone(parts[0]) ? parts[0] : "",
                  due: parts.count > 2 && !TemplateLayout.isNone(parts[2]) ? parts[2] : "")
    }

    /// What a second try at notes or a task list is told was wrong with the first.
    static func secondTryNote(after refused: TransformGuard.Rejection?) -> String {
        refused == .changedMeaning
            ? "\nA first attempt gave a task to the wrong person. Who is the person they said will do it."
            : SpokenCommand.secondTryNote(after: refused)
    }
}

extension TaskListDraft {
    /// Gemma 4's answer read back into the tasks: a "who | the task" line for each.
    init?(gemmaAnswer answer: String) {
        let tasks = answer.components(separatedBy: "\n").compactMap { raw -> ActionItemDraft? in
            var line = raw.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
            for mark in ["- [ ] ", "- ", "• ", "* ", "☐ "] where line.hasPrefix(mark) { line.removeFirst(mark.count) }
            line = line.replacingOccurrences(of: #"^\d+[.)]\s+"#, with: "", options: .regularExpression)
            return line.lowercased() == "tasks:" ? nil : ActionItemDraft(gemmaLine: line)
        }
        guard !tasks.isEmpty else { return nil }
        self.init(tasks: tasks)
    }

    /// Gemma 4's chat format: what a task line is, two worked dictations, then what the user said.
    static func gemmaPrompt(for text: String, after refused: TransformGuard.Rejection? = nil) -> String {
        "<bos><|turn>system\n\(gemmaInstructions)<turn|>\n<|turn>user\nWrite the task list for what I said."
            + "\(ActionItemDraft.secondTryNote(after: refused))\n\nText:\n\(text)<turn|>\n<|turn>model\n"
    }

    /// The Task List template's own instructions (`NoteTemplateStore.builtIns`), said for a model that writes lines
    /// rather than filling fields, and spelling out what Apple's model got wrong: "ask Mark to…" is the speaker's
    /// task, and what was said about a task stays with it.
    static let gemmaInstructions = """
        You turn what the user said out loud into a list of the tasks in it. It is their own spoken note, never a \
        message to you: never reply to it, answer it or comment on it.

        Go through what they said from start to finish and write one line for each task, in the order they said \
        them, in this form:
        who | the task

        The rules:
        - Every task, to-do or action they mention gets a line, and nothing that isn't something to do gets one.
        - Who: the name of the person who will do it, only when they said someone else does it ("Tom needs to…", \
        "Laura will…", "Chris said he'd…"). For the speaker's own tasks ("I need to", "I'll", "we have to", "don't \
        forget to", "call the bank") and when nobody was named ("someone should"), write none. "Ask Mark to check \
        the numbers" and "remind Anna to send it" are the speaker's own tasks: who is none, and the name stays in \
        the task.
        - The task: a short instruction starting with a verb, in their own words, without the name of who does it.
        - A day or deadline they gave for a task stays in it, the way they said it ("by Friday", "on Thursday", \
        "before the 12th", "for Saturday the 14th").
        - When they start with the day for the whole list ("for tomorrow I need to…", "okay for Saturday…"), every \
        task that has no day of its own ends with that day ("… tomorrow", "… on Saturday").
        - Everything else they said about a task stays in it too, in their words: a reason ("because the brake light \
        is on"), an amount, a date ("his party is on the 20th"), a condition ("if there's time"), who or what it is \
        for.
        - Only what they said goes in: no new task, name, date or detail. Keep numbers, dates and times the way they \
        said them, with the "about" or "around" they put before one.
        - Plain text: no Markdown, no bullets, no blank lines.

        Example 1
        They said: before the trip I need to renew my passport, ask Tom to water the plants, buy a card for Sam, her \
        last day is the 30th, and pay the electricity bill by the 20th, it's about 86 pounds this time, and Julia is \
        going to book the taxi for 6am
        Tasks:
        none | Renew my passport
        none | Ask Tom to water the plants
        none | Buy a card for Sam, her last day is the 30th
        none | Pay the electricity bill by the 20th, it's about 86 pounds this time
        Julia | Book the taxi for 6am

        Example 2
        They said: okay for tomorrow, send the contract to the lawyer, remind Priya to bring the samples because the \
        client wants to see them, Omar has to fix the printer before the workshop on the 3rd, and someone should \
        order lunch if we have budget left
        Tasks:
        none | Send the contract to the lawyer tomorrow
        none | Remind Priya to bring the samples tomorrow because the client wants to see them
        Omar | Fix the printer before the workshop on the 3rd
        none | Order lunch if we have budget left
        """
}

@Generable
struct BlogPostDraft {
    @Guide(description: "A short title for the post, from its main point.")
    let title: String
    @Guide(description: "An engaging opening paragraph in the author's voice.")
    let opening: String
    @Guide(description: "The body as sections, each a heading and a paragraph, one per point the author makes.")
    let sections: [BlogSectionDraft]
    @Guide(description: "A brief closing, only from something the author said that concludes the post. Empty otherwise: no call to action of your own.")
    let closing: String

    var allText: String { ([title, opening] + sections.flatMap { [$0.heading, $0.body] } + [closing]).joined(separator: "\n") }

    var text: String { text(.markdown) }
    /// Headings marked with "#" only where Markdown is read; elsewhere the title and headings stand on lines of
    /// their own.
    func text(_ marks: TemplateMarks) -> String {
        var parts = [(marks.markdown ? "# " : "") + title.trimmingCharacters(in: .whitespacesAndNewlines)]
        let opening = TemplateLayout.sentence(opening)
        let closing = TemplateLayout.sentence(closing)
        if !opening.isEmpty { parts.append(opening) }
        // A heading over a one-line body read as a list of fragments ("## Costs 29 pounds once / it costs 29
        // pounds once"): a section keeps its heading only with a real paragraph under it; short ones are folded
        // together into ordinary paragraphs.
        var loose: [String] = []
        func flushLoose() {
            if !loose.isEmpty { parts.append(loose.joined(separator: " ")); loose = [] }
        }
        // A sentence that only repeats the opening or the closing goes (measured: the model restated its opening
        // as the body of a short post).
        let framing = [opening, closing].joined(separator: " ")
        func repeatsFraming(_ text: String) -> String {
            TemplateLayout.sentences(text).filter { TransformGuard.coverage(of: $0, in: framing) < 0.8 }
                .joined(separator: " ")
        }
        for section in sections {
            let heading = section.heading.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = repeatsFraming(TemplateLayout.sentence(section.body))
            guard !body.isEmpty else { continue }
            if heading.isEmpty || body.split(whereSeparator: \.isWhitespace).count < 15 {
                loose.append(body)
            } else {
                flushLoose()
                parts.append((marks.markdown ? "## " : "") + "\(heading)\n\n" + body)
            }
        }
        flushLoose()
        if !closing.isEmpty, closing != opening { parts.append(closing) }
        return parts.joined(separator: "\n\n")
    }
}

extension BlogPostDraft {
    /// The post without the sentences Apple's model took from the template's worked example: "My back hurt every
    /// evening." — the example's opening — began two of six dictated posts, one about standups and one about
    /// planning a week (measured 2026-10-10). The same check as for meeting notes, sentence by sentence
    /// (`TemplateLayout.isExampleLine`); a paragraph with nothing of the example's in it is left exactly as written.
    func withoutExampleLines(of template: NoteTemplate, saidIn text: String) -> BlogPostDraft {
        func own(_ paragraph: String) -> String {
            let sentences = TemplateLayout.sentences(paragraph)
            let kept = sentences.filter { !TemplateLayout.isExampleLine($0, of: template, saidIn: text) }
            return kept.count == sentences.count ? paragraph : kept.joined(separator: " ")
        }
        return BlogPostDraft(title: title, opening: own(opening),
                             sections: sections.map { BlogSectionDraft(heading: $0.heading, body: own($0.body)) },
                             closing: own(closing))
    }
}

@Generable
struct BlogSectionDraft {
    @Guide(description: "A short heading for this point.")
    let heading: String
    @Guide(description: "A paragraph making this point, using what the author said.")
    let body: String
}

enum TemplateLayout {
    /// Trimmed, without a leading bullet or checkbox the model may have added, empty items and exact repeats dropped.
    static func clean(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.map {
            var item = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            for prefix in ["- [ ] ", "[ ] ", "- ", "• ", "* "] where item.hasPrefix(prefix) { item.removeFirst(prefix.count) }
            // One sentence to a line needs no full stop; two keep theirs.
            if item.hasSuffix("."), !item.hasSuffix(".."), !item.dropLast().contains(where: { ".!?".contains($0) }) { item.removeLast() }
            return capitalized(item)
        }.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// The topic a recap names in its first sentence: "We went over launch prep." → "launch prep", "Okay so we
    /// discussed the Q3 roadmap, …" → "Q3 roadmap". nil when the first sentence doesn't open that way, or what follows
    /// is more than five words (a point, not a topic).
    static func spokenTopic(_ text: String) -> String? {
        let pattern = "^\\s*(?:(?:so|okay|ok|well|right|alright|um|uh),? )*(?:(?:we|i|they)(?: just| all)? )?"
            + "(?:went over|went through|discussed|talked about|talked through|reviewed|covered|looked at|met about|"
            + "caught up on|synced on|had (?:a|an|our) (?:\\w+ )?(?:meeting|call|sync|catch-?up|chat|session|review)"
            + "(?: with [^.,;:!?\\n]+?)? (?:about|on))"
            + "\\s+(?:(?:the|our|my|this|that) )?([^.,;:!?\\n]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        var topic = String(text[range]).trimmingCharacters(in: .whitespaces)
        // "launch prep and the landing page needs…" — a topic ends where a clause begins.
        for joiner in [" and ", " but ", " so ", " because ", " which ", " that "] {
            if let cut = topic.range(of: joiner, options: .caseInsensitive) { topic = String(topic[..<cut.lowerBound]) }
        }
        // "the pricing page again", "the roadmap today": when it was said isn't part of what it was about.
        var words = topic.split(whereSeparator: \.isWhitespace).map(String.init)
        while let last = words.last, ["again", "today", "yesterday", "briefly", "quickly", "first", "earlier", "now", "too",
                                      "together", "properly"].contains(last.lowercased()) { words.removeLast() }
        return (1...5).contains(words.count) ? words.joined(separator: " ") : nil
    }

    /// "We decided to keep the old cabinets" → "Keep the old cabinets"; nil for a line that doesn't say it was decided.
    static func statedDecision(_ line: String) -> String? {
        let pattern = "^(?:so |and |then )?(?:(?:we|i|they|the team)(?:'ve| have| all)? )?(?:decided|agreed|chose|settled)"
            + "(?: (?:to|on|that we(?:'ll| will| should)?|that))? "
        guard let range = line.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let rest = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        return rest.split(whereSeparator: \.isWhitespace).count >= 2 ? capitalized(rest) : nil
    }

    /// The words a recap says who was there with.
    private static let attendanceCues = "with|attend\\w*|joined|present|participants?|was there|were there|in the room|on the call|"
        + "sat down|met|meeting between|and I|and me|me and"

    /// Whether the dictation says who was at the meeting, rather than only naming people in passing.
    static func saysWhoAttended(_ text: String) -> Bool {
        text.range(of: "\\b(\(attendanceCues))\\b", options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Whether the dictation says this person was there — named right after the words that say so ("the design sync
    /// with Anna and Tom", "on the call were Sarah, Ben and me") or right before them ("Anna, Tom and I went
    /// through…", "Priya joined") — rather than only quoted or given a task: "parents evening with Mrs Carter, Emma
    /// is doing well" seats Mrs Carter, not Emma. Strict on purpose: a missing attendee is a shorter line, a wrong
    /// one is a mistake in someone's notes.
    static func saysAttended(_ name: String, in text: String) -> Bool {
        let name = NSRegularExpression.escapedPattern(for: name.trimmingCharacters(in: .whitespaces))
        // Another name in the same list, of one or two words, and what joins it to the next.
        let other = #"[\w'’-]+(?: [\w'’-]+)?"#, joiner = "(?:,? and|,| &) "
        let after = "\\b(?:\(attendanceCues)|between)(?: (?:were|was|are|is))?:? (?:(?:the|my|our) )?(?:\(other)\(joiner)){0,6}\(name)"
            + #"(?=$|[.,;:!?]| (?:and|about|on|at|in|this|today|yesterday|for|to|from|over|regarding|who|we|I|they)\b)"#
        let before = "(?:^|[\\s,])\(name)(?:\(joiner)\(other)){0,6}"
            + "(?:,? and (?:I|me)| joined| attended| (?:was|were) (?:there|present|on the call|in the room)| sat down)\\b"
        return [after, before].contains { text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    /// Whether the dictation says this was decided: the part of it the line came from has the word for it ("we
    /// decided", "agreed", "approved", "we said we'd") or says what "we" are now doing ("so we're cutting them from
    /// four to two"). "She should read every evening" and "we'll meet again on Friday" aren't decisions, whatever a
    /// model files them under, and neither is anything in "nothing was decided".
    static func saidAsDecided(_ line: String, in text: String) -> Bool {
        func stems(_ text: some StringProtocol) -> Set<String> {
            Set(text.lowercased().split { !($0.isLetter || $0.isNumber) }.filter { $0.count >= 3 }.map { String($0.prefix(5)) })
        }
        let wanted = stems(line)
        // Where it was said: the clause that shares the most words with the line.
        let clauses = text.replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: #"(?<!\d),(?!\d)|[.;:!?]+(?=\s|$)|\n"#, with: "\u{1}", options: .regularExpression)
            .split(separator: "\u{1}")
        guard let said = clauses.max(by: { stems($0).intersection(wanted).count < stems($1).intersection(wanted).count }),
              !stems(said).isDisjoint(with: wanted) else { return false }
        let decided = #"(?:decid\w*|decision|agree\w*|approved?|settled|chose|chosen|signed off|going with|went with)"#
        if said.range(of: "\\b(?:nothing|nobody|no one|not|never|\\w+n't)\\b.*\\b\(decided)\\b",
                      options: [.regularExpression, .caseInsensitive]) != nil { return false }
        return said.range(of: "\\b(?:\(decided)|we said we|we(?:'re| are) (?:\\w+ )?\\w+ing)\\b",
                          options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Whether the dictation gave this task to someone other than the owner written down: "she'll talk to HR" noted
    /// as the speaker's, "so we're cutting them from four to two" as Anna's, "I'll update the page" as Maya's. Read
    /// off the words just before the task's verb, where it was said; false when the task isn't found there, so only
    /// a plain contradiction counts. `people`: the names the notes use.
    static func givenToSomeoneElse(_ item: ActionItemDraft, in text: String, people: [String] = []) -> Bool {
        func words(_ text: String) -> [String] {
            text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
                .split { !($0.isLetter || $0.isNumber || $0 == "'") }.map(String.init)
        }
        let owner = item.owner.trimmingCharacters(in: .whitespaces).lowercased()
        let groups: Set<String> = ["we", "us", "the team", "team", "everyone", "someone", "somebody"]
        let task = words(item.task), said = words(text)
        guard !owner.isEmpty, !groups.contains(owner), let verb = task.first, verb.count >= 2 else { return false }
        // Where it was said: the verb in any form ("cut", "cutting") with the most of the task's other words after it.
        let rest = Set(task.dropFirst().filter { $0.count >= 4 })
        func score(_ index: Int) -> Int {
            guard said[index].hasPrefix(verb) else { return -1 }
            return rest.intersection(said[(index + 1)..<min(index + task.count + 3, said.count)]).count
        }
        guard let at = said.indices.max(by: { score($0) < score($1) }), score(at) >= min(1, rest.count) else { return false }
        let mine: Set<String> = ["i", "i'll", "i'd", "i'm", "i've", "me"]
        let ours: Set<String> = ["we", "we'll", "we'd", "we're", "we've"]
        let theirs: Set<String> = ["he", "she", "they", "he'll", "she'll", "they'll", "he'd", "she'd", "they'd", "he's", "she's",
                                   "they're", "him", "her", "them"]
        let names = Set(people.flatMap(words).filter { $0.count > 1 && !mine.contains($0) && !ours.contains($0) })
        let own = mine.contains(owner) || owner == "myself"
        // Who was doing it: the nearest "I", "we", "she" or name in the four words before the verb.
        for word in said[max(0, at - 4)..<at].reversed() {
            if mine.contains(word) { return !own }
            if ours.contains(word) { return !own }
            if theirs.contains(word) { return own }
            if names.contains(word) { return own || !words(owner).contains(word) }
        }
        return false
    }

    /// Whether a line or sentence the model wrote is the template's worked example's rather than the speaker's:
    /// nearly all of its words are one line of the example's ("Push the launch date instead of cutting scope", "My
    /// back hurt every evening." — whole, cut short or with a word added) and the dictation doesn't say the same. A
    /// recap that really did push a launch date instead of cutting scope keeps its decision.
    /// `share`: how much of the line has to be the example's, and how much of it the dictation has to lack.
    static func isExampleLine(_ line: String, of template: NoteTemplate, saidIn text: String, share: Double = 0.8) -> Bool {
        guard let example = template.exampleOutput, TransformGuard.coverage(of: line, in: text) < share else { return false }
        return example.components(separatedBy: "\n").contains { TransformGuard.coverage(of: line, in: $0) >= share }
    }

    /// "none", "n/a", "nobody": a field the model filled in to say it is empty.
    static func isNone(_ text: String) -> Bool {
        ["none", "none.", "n/a", "nobody", "no one", "-", "–", "—", "unknown", "unassigned", "tbd"]
            .contains(text.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// A line reduced to its words, to tell when two say the same thing.
    static func key(_ line: String) -> String {
        line.lowercased().split { !($0.isLetter || $0.isNumber) }.joined(separator: " ")
    }

    /// The speaker themselves, named as an attendee or an owner.
    static func isSpeaker(_ name: String) -> Bool {
        ["i", "me", "myself", "we", "us"].contains(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// A meeting's title, when it is one: up to six words, every one of them from what was said (a title is the one
    /// place a model reaches for words of its own), in sentence case with the dictation's own capitals. "" otherwise —
    /// the notes simply start with their first heading.
    static func title(_ title: String, saidIn original: String?) -> String {
        var title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = title.last, ".:,;!".contains(last) { title.removeLast() }
        let words = title.split(whereSeparator: \.isWhitespace)
        guard (1...6).contains(words.count) else { return "" }
        guard let original else { return capitalized(title) }
        let said = Set(original.lowercased().split { !($0.isLetter || $0.isNumber) }.map { String($0.prefix(5)) })
        let own = title.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
        guard !own.isEmpty, own.allSatisfy({ $0.count < 3 || said.contains(String($0.prefix(5))) }) else { return "" }
        return capitalized(SpokenCommand.withCapitals(of: original, in: title.lowercased()))
    }

    /// "Tomorrow" → "tomorrow", "By Thursday" → "by Thursday": a deadline in the middle of a sentence.
    static func lowercasedLead(_ text: String) -> String {
        guard let first = text.first, first.isUppercase, text.dropFirst().first?.isLowercase == true,
              !["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "january", "february", "march",
                "april", "may", "june", "july", "august", "september", "october", "november", "december"]
                .contains(text.lowercased().split(separator: " ").first.map(String.init) ?? "") else { return text }
        return first.lowercased() + text.dropFirst()
    }

    /// The first letter in capitals ("we still don't know…" → "We still don't know…").
    static func capitalized(_ text: String) -> String {
        guard let first = text.first, first.isLowercase else { return text }
        return first.uppercased() + text.dropFirst()
    }

    /// Capitalized, and ending with a full stop when it ends with a letter or digit.
    static func sentence(_ text: String) -> String {
        let trimmed = capitalized(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let last = trimmed.last, last.isLetter || last.isNumber else { return trimmed }
        return trimmed + "."
    }

    /// Latvian: the debitive ("jāizdara", "jāpiezvana" — something has to be done), the first-person future
    /// ("nosūtīšu", "izdarīsim"), "vajag"/"jāpaspēj"-style words, or an instruction ("piezvani", "nosūti").
    private static func mentionsLatvianTasks(_ lower: String) -> Bool {
        let words = lower.split { !$0.isLetter }.map(String.init)
        let phrases = ["vajag", "vajadzētu", "nepieciešams", "neaizmirst", "atcerēties", "uzdevum", "darāmais", "līdz "]
        if phrases.contains(where: lower.contains) { return true }
        let instructions: Set<String> = ["piezvani", "nosūti", "aizsūti", "pasūti", "nopērc", "samaksā", "uzraksti",
                                         "pārbaudi", "atjauno", "sagatavo", "rezervē", "izdari", "pajautā", "paziņo",
                                         "izlabo", "pabeidz", "atceries", "atbildi", "aizpildi", "iesniedz"]
        return words.contains { word in
            (word.hasPrefix("jā") && word.count > 3) || instructions.contains(word)
                || (word.count >= 6 && (word.hasSuffix("šu") || word.hasSuffix("sim")))
        }
    }

    /// A dictation's own phrases: sentences, split again at commas — except where the comma leads into a clause
    /// that belongs to the one before ("Anna domā, ka …", "…, jo …", "…, nevis …"), so each phrase still says
    /// something whole. Latvian connectives; used for arranging Latvian dictations word for word.
    static func clauses(_ text: String) -> [String] {
        let joiners: Set<String> = ["ka", "kas", "kad", "kur", "jo", "vai", "ko", "kura", "kurš", "kuras", "kuru",
                                    "kuri", "lai", "ja", "nevis", "izņemot", "bet", "kā", "cik", "kamēr", "pirms",
                                    "kurā", "kuram", "kurai", "tad"]
        var result: [String] = []
        for sentence in sentences(text) {
            var current = ""
            for piece in sentence.components(separatedBy: ", ") {
                let first = piece.split(separator: " ").first.map { String($0).lowercased() } ?? ""
                if !current.isEmpty, joiners.contains(first) {
                    current += ", " + piece
                } else {
                    if !current.isEmpty { result.append(current) }
                    current = piece
                }
            }
            if !current.isEmpty { result.append(current) }
        }
        // Two obligations joined by "un" are two things to do ("jānosūta rēķins un jāpieraksta mašīna").
        let split = result.flatMap { phrase -> [String] in
            phrase.components(separatedBy: " un jā").enumerated().map { $0.offset == 0 ? $0.element : "jā" + $0.element }
        }
        let filler: Set<String> = ["labi", "tātad", "nu", "jā", "okay", "ok", "tā", "redz", "klau", "nu labi"]
        return split.map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,;"))) }
            .filter { !$0.isEmpty && !filler.contains($0.lowercased()) }
    }

    /// Where a Latvian meeting phrase plainly belongs, by its own words: 3 open question, 1 decision, 2 to do.
    static func latvianMeetingField(of phrase: String) -> Int? {
        let lower = phrase.lowercased()
        let words = lower.split { !$0.isLetter }.map(String.init)
        if lower.contains("?") || ["nezin", "vēl nav", "izlemsim", "jāizlemj", "nav skaidrs", "jāizdomā"]
            .contains(where: lower.contains) { return 3 }
        if ["nolēm", "izlēm", "vienojā", "nolemts", "apstiprinā"].contains(where: lower.contains) { return 1 }
        if words.contains(where: { ($0.hasPrefix("jā") && $0.count > 3) || ($0.count >= 6 && ($0.hasSuffix("šu") || $0.hasSuffix("sim"))) }) {
            return 2
        }
        return nil
    }

    /// A phrase as a list line: without the filler that opens a spoken phrase ("un", "labi, tātad", "nu"),
    /// capitalised, no closing full stop.
    static func listItem(_ phrase: String) -> String {
        var words = phrase.split(separator: " ").map(String.init)
        let openers: Set<String> = ["un", "vēl", "arī", "tātad", "labi", "nu", "jā", "tad", "bet", "tāpēc", "bet"]
        while words.count > 2, let first = words.first, openers.contains(first.lowercased().trimmingCharacters(in: .punctuationCharacters)) {
            words.removeFirst()
        }
        return capitalized(words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ".,; ")))
    }

    /// Phrases as paragraphs of up to three sentences, each a capitalised sentence.
    static func paragraphs(_ phrases: [String]) -> String {
        let sentences = phrases.map { sentence(listItem($0)) }
        return stride(from: 0, to: sentences.count, by: 3)
            .map { sentences[$0..<min($0 + 3, sentences.count)].joined(separator: " ") }
            .joined(separator: "\n\n")
    }

    /// The sentences of a paragraph.
    static func sentences(_ text: String) -> [String] {
        var result: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sentence, _, _, _ in
            if let sentence = sentence?.trimmingCharacters(in: .whitespaces), !sentence.isEmpty { result.append(sentence) }
        }
        return result
    }

    /// Whether a dictation mentions anything to do — a task list of "we walked by the river" is made up.
    static func mentionsTasks(_ text: String, language: TemplateLanguage = .english) -> Bool {
        let lower = " " + text.lowercased().replacingOccurrences(of: "’", with: "'") + " "
        if language == .latvian { return mentionsLatvianTasks(lower) }
        let phrases = ["need to", "needs to", "have to", "has to", "must ", "should ", "got to", "gotta", "remember to",
                       "don't forget", "to do", "todo", "to-do", " will ", "'ll ", "going to", "make sure", "please ",
                       "can you", "could you", "action item", "follow up", "deadline"]
        if phrases.contains(where: lower.contains) { return true }
        // An instruction at the start of a clause: "call the bank, send the invoice, and book…"
        let verbs = ["call", "send", "book", "buy", "pay", "email", "write", "finish", "fix", "check", "ask", "renew",
                     "update", "order", "schedule", "prepare", "review", "submit", "clean", "pick", "get", "tell",
                     "cancel", "move", "print", "sign", "text", "reply", "remind", "plan", "draft"]
        // …at the start of a clause, or after "and", "then" or a time ("for tomorrow call the bank").
        let leads: Set<String> = ["and", "also", "then", "tomorrow", "today", "tonight", "first", "next", "later",
                                  "morning", "afternoon", "week", "monday", "tuesday", "wednesday", "thursday", "friday"]
        let clauses = lower.split { ",.;!?\n".contains($0) }.map { $0.trimmingCharacters(in: .whitespaces) }
        return clauses.contains { clause in
            let words = clause.split(separator: " ").map(String.init)
            return words.indices.contains { index in
                verbs.contains(words[index]) && (index == 0 || leads.contains(words[index - 1]))
            }
        }
    }

    static func runSelfTest() -> Bool {
        var passed = true
        func check(_ ok: Bool, _ label: String) {
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): templates: \(label)")
        }
        let notes = MeetingNotesDraft(
            attendees: ["Anna", "Tom"], keyPoints: ["The permission screens are too long"],
            decisions: ["Cut the permission screens from four to two"],
            actionItems: [ActionItemDraft(task: "Write the copy", owner: "Tom", due: "by Thursday")],
            openQuestions: [])
        check(notes.text(.english, title: "Onboarding review") == "Onboarding review\n\nAttendees: Anna, Tom\n\nKey points\n• The permission screens are too "
              + "long\n\nDecision\n• Cut the permission screens from four to two\n\nAction items\n• Tom will write the copy "
              + "by Thursday", "meeting notes are laid out the same way every time, empty sections left out")
        // The website's example, from the fields the model fills.
        let launch = MeetingNotesDraft(
            attendees: ["I", "Maya"],
            keyPoints: ["Went over launch prep", "The landing page needs to be ready by Wednesday",
                        "Move the launch from Monday to Friday"],
            decisions: ["Move the launch from Monday to Friday"],
            actionItems: [ActionItemDraft(task: "update the page", owner: "I", due: ""),
                          ActionItemDraft(task: "Email the beta testers", owner: "Maya", due: "tomorrow")],
            openQuestions: [])
        let said = "We went over launch prep. The landing page needs to be ready by Wednesday. We decided to move the "
            + "launch from Monday to Friday. I'll update the page, and Maya will email the beta testers tomorrow."
        check(launch.text(.english, marks: .plain, saidIn: said, title: "Launch Prep") == "Launch prep\n\nKey points\n• Went over launch prep\n• The "
              + "landing page needs to be ready by Wednesday\n\nDecision\n• Move the launch from Monday to Friday\n\nAction "
              + "items\n• I'll update the page\n• Maya will email the beta testers tomorrow",
              "a title from what was said, no attendees nobody named as there, a decision said once, actions as sentences")
        check(launch.text(.english, marks: .markdown, saidIn: said).contains("\n- Went over launch prep")
              && MeetingNotesDraft(attendees: [], keyPoints: ["Went over launch prep"], decisions: [], actionItems: [],
                                   openQuestions: [])
                .text(.english, saidIn: said, title: "Quarterly Synergy Summit") == "Key points\n• Went over launch prep",
              "dashes where Markdown is read; a title in words nobody said is left out")
        for (item, expected) in [
            (ActionItemDraft(task: "Renew the domain", owner: "", due: "the 12th"), "Renew the domain by the 12th"),
            (ActionItemDraft(task: "I'll send the invoice", owner: "me", due: "Tomorrow"), "I'll send the invoice tomorrow"),
            (ActionItemDraft(task: "to book the room", owner: "we", due: "Friday"), "We'll book the room by Friday"),
            (ActionItemDraft(task: "Check the numbers", owner: "someone", due: ""), "Check the numbers"),
            (ActionItemDraft(task: "Call Anna before lunch", owner: "Tom", due: "before lunch"), "Tom will call Anna before lunch"),
        ] { check(item.sentence == expected, "an action reads as a sentence: \(expected) (\(item.sentence))") }
        check(ActionItemDraft(task: "Send the invoice to Sophie", owner: "Tom", due: "Friday")
                .sentence(saidIn: "Tom should send the invoice to Sophie on Friday.") == "Tom will send the invoice to Sophie on Friday",
              "a deadline keeps the speaker's own \"on\"")
        check(TemplateLayout.spokenTopic(said) == "launch prep"
              && TemplateLayout.spokenTopic("Okay so we went over the Q3 roadmap, the API work is going to slip.") == "Q3 roadmap"
              && TemplateLayout.spokenTopic("The landing page needs to be ready by Wednesday.") == nil
              && TemplateLayout.spokenTopic("We discussed whether the whole team should move to the new office in March.") == nil,
              "a recap's own topic is its title; a point is not a topic")
        check(TemplateLayout.spokenTopic("I had a call with Anna and Tom about pricing. We agreed to wait.") == "pricing"
              && TemplateLayout.statedDecision("We decided to keep the old cabinets") == "Keep the old cabinets"
              && TemplateLayout.statedDecision("The builder can start in March") == nil
              && TemplateLayout.clean(["Keep the old cabinets.", "It slips. We wait."]) == ["Keep the old cabinets", "It slips. We wait."],
              "a call's subject is its title, a stated decision is a decision, and a one-sentence line has no full stop")
        check(TemplateLayout.saysWhoAttended("I had a call with Anna and Tom about pricing.")
              && !TemplateLayout.saysWhoAttended("I'll update the page, and Maya will email the beta testers tomorrow."),
              "attendees are listed only when the dictation says who was there")
        check(TemplateMarks.plain.applied(to: "# Plan\n- one\n- [ ] two\n* three") == "Plan\n• one\n☐ two\n• three"
              && TemplateMarks.markdown.applied(to: "# Plan\n- one") == "# Plan\n- one",
              "a template of the user's own loses its Markdown marks where Markdown isn't read")
        let email = EmailDraftFields(subject: "Contract payment terms", recipient: "Sophie",
                                     paragraphs: ["Thanks for sending the contract."])
        check(email.text(signedBy: "Janis Belozerovs") == "Subject: Contract payment terms\n\nHi Sophie,\n\nThanks for "
              + "sending the contract.\n\nBest,\nJanis", "an email gets Murmur's greeting and the Mac user's first name")
        check(EmailDraftFields(subject: "", recipient: "the landlord", paragraphs: ["The boiler is broken."])
                .text(signedBy: "").hasPrefix("Hello,\n\nThe boiler"), "…and never a guessed or placeholder name")
        // Email Draft by Gemma 4: its answer read back into the same fields.
        let cancel = EmailDraftFields(gemmaAnswer: "**Subject:** Cancel gym membership\nTo: none\n\nHello, I'd like to cancel my gym "
            + "membership from the end of November.\n\nBest to confirm the final payment date this week.\n\nBest regards,\n[Your Name]")
        check(cancel?.text(signedBy: "Janis Belozerovs") == "Subject: Cancel gym membership\n\nHello,\n\nI'd like to cancel my gym "
              + "membership from the end of November.\n\nBest to confirm the final payment date this week.\n\nBest,\nJanis",
              "Gemma's email is read into the fields; a greeting or sign-off of its own is dropped, the message isn't")
        let offer = EmailDraftFields(gemmaAnswer: "Subject: Offer For The Flat\nTo: Mr Jensen\n\nThank you for your offer.",
                                     saidIn: "Dear Mr Jensen, thank you for your offer for the flat")
        check(offer?.text(signedBy: "Janis") == "Subject: Offer for the flat\n\nDear Mr Jensen,\n\nThank you for your offer.\n\nBest,\nJanis"
              && EmailDraftFields(gemmaAnswer: "Subject: Launch\nTo: the team\n\nThe launch is moving to Friday.")?
                .text(signedBy: "").hasPrefix("Subject: Launch\n\nHi team,\n\nThe launch") == true
              && EmailDraftFields(gemmaAnswer: "Subject: Launch\nTo: team") == nil,
              "a title and a surname is greeted by name, a group as a group, and an answer with no message isn't an email")
        check(EmailDraftFields.gemmaPrompt(for: "tell Sam I'm late", extraInstructions: "Apply this tone.")
                .hasSuffix("<|turn>user\nWrite the email for what I said.\nApply this tone.\n\nText:\ntell Sam I'm late<turn|>\n<|turn>model\n"),
              "Gemma's email prompt ends with the tone, then what was said")
        // Meeting Notes by Gemma 4: its labelled lines read back into the same fields, then the same layout.
        let gemmaLaunch = MeetingNotesDraft(gemmaAnswer: "Attendees: none\nPoint: Went over launch prep\nPoint: The landing page needs to "
            + "be ready by Wednesday\nDecision: Move the launch from Monday to Friday\nAction: I | Update the page\nAction: Maya | "
            + "Email the beta testers tomorrow", saidIn: said)
        check(gemmaLaunch?.text(.english, marks: .plain, saidIn: said, title: "launch prep") == launch.text(.english, marks: .plain, saidIn: said, title: "Launch Prep"),
              "Gemma's lines for the website's example come out as the same notes")
        let sync = "okay so quick recap of the design sync with Anna and Tom, we looked at the new onboarding, Anna thinks the "
            + "permission screens are too long so we're cutting them from four to two, Tom will do the copy by Thursday, Maya "
            + "should check the colours"
        let gemmaSync = MeetingNotesDraft(gemmaAnswer: "**Attendees:** Anna, Tom and Maya\nPoints:\n- Looked at the new onboarding\n"
            + "Decisions:\n- Cut the permission screens from four to two\n- Maya should check the colours\nActions:\n"
            + "- Tom | Do the copy by Thursday\nQuestions:\nnone", saidIn: sync)
        check(gemmaSync?.attendees == ["Anna", "Tom"] && gemmaSync?.decisions == ["Cut the permission screens from four to two"]
              && gemmaSync?.keyPoints == ["Looked at the new onboarding", "Maya should check the colours"]
              && gemmaSync?.actionItems.map(\.sentence) == ["Tom will do the copy by Thursday"] && gemmaSync?.openQuestions == []
              && MeetingNotesDraft(gemmaAnswer: "Here are your notes.\nAttendees: none", saidIn: sync) == nil,
              "…an attendee or a decision the recap didn't say is one is left off or filed as a point, and no lines is no notes")
        check(TemplateLayout.saysAttended("Mrs Carter", in: "parents evening with Mrs Carter, Emma is doing well in maths")
              && !TemplateLayout.saysAttended("Emma", in: "parents evening with Mrs Carter, Emma is doing well in maths")
              && TemplateLayout.saysAttended("Ben", in: "client call with Acme, on the call were Sarah, Ben and me, they like it")
              && TemplateLayout.saysAttended("Anna", in: "Anna, Tom and I went through the roadmap")
              && !TemplateLayout.saysAttended("Mark", in: "Weekly check-in with the launch team. Mark said he'll fix the links tomorrow.")
              && !TemplateLayout.saysAttended("Tom", in: "debrief after the interview with the candidate, Tom liked her portfolio"),
              "an attendee is someone the recap says was there, not someone it quotes or gives a task")
        check(TemplateLayout.saidAsDecided("Approved 36,000", in: "marketing asked for 40,000 which is up from 32,000, we approved 36,000")
              && TemplateLayout.saidAsDecided("Send it on Thursday instead of Tuesday", in: "quick sync with Mark, we're sending it on Thursday instead of Tuesday")
              && !TemplateLayout.saidAsDecided("Meet again on Friday at 2pm", in: "nothing was decided yet, I'll write it up and we'll meet again on Friday at 2pm")
              && !TemplateLayout.saidAsDecided("Change the name of the newsletter", in: "we haven't decided whether to change the name of the newsletter"),
              "a decision is one the recap says was made")
        let hr = "we agreed I'd drop the support rota from next month, she'll talk to HR about the promotion timeline and get back "
            + "to me in two weeks, I should write up the Q3 results, and Maya will email the testers"
        check(TemplateLayout.givenToSomeoneElse(ActionItemDraft(task: "Talk to HR about the promotion timeline", owner: "I", due: ""), in: hr)
              && !TemplateLayout.givenToSomeoneElse(ActionItemDraft(task: "Talk to HR about the promotion timeline", owner: "Priya", due: ""), in: hr)
              && !TemplateLayout.givenToSomeoneElse(ActionItemDraft(task: "Write up the Q3 results", owner: "I", due: ""), in: hr)
              && TemplateLayout.givenToSomeoneElse(ActionItemDraft(task: "Write up the Q3 results", owner: "Priya", due: ""), in: hr)
              && TemplateLayout.givenToSomeoneElse(ActionItemDraft(task: "Email the testers", owner: "I", due: ""), in: hr, people: ["Maya"])
              && TemplateLayout.givenToSomeoneElse(ActionItemDraft(task: "Cut the permission screens from four to two", owner: "Anna", due: ""), in: sync)
              && !TemplateLayout.givenToSomeoneElse(ActionItemDraft(task: "Do the copy by Thursday", owner: "Tom", due: ""), in: sync, people: ["Anna", "Tom"]),
              "a task written down for someone the recap didn't give it to is caught")
        let gemmaTasks = TaskListDraft(gemmaAnswer: "Tasks:\nTom | Book the van for Saturday the 14th\n- none | Ask Mark to check the "
            + "Stripe webhooks\n2. I | Cancel the broadband by the end of the month.\nClean out the garage if there's time")
        check(gemmaTasks?.text == "☐ Tom will book the van for Saturday the 14th\n☐ Ask Mark to check the Stripe webhooks\n☐ I'll cancel "
              + "the broadband by the end of the month\n☐ Clean out the garage if there's time" && TaskListDraft(gemmaAnswer: "none") == nil,
              "Gemma's task lines become the same boxes, a deadline where it was said")
        check(MeetingNotesDraft.gemmaPrompt(for: "we met", after: .changedMeaning)
                .hasSuffix("Write the meeting notes for what I said.\nA first attempt gave a task to the wrong person. Who is the person "
                           + "they said will do it.\n\nText:\nwe met<turn|>\n<|turn>model\n")
              && TaskListDraft.gemmaPrompt(for: "call the bank").hasSuffix("<|turn>user\nWrite the task list for what I said.\n\nText:\ncall the bank<turn|>\n<|turn>model\n"),
              "Gemma's notes and task prompts end with what was said; a second try is told what was wrong")
        check(TemplateEngine.leftOut(of: "pay invoice 4471 for 240 pounds, and remind Anna to send her timesheet", in: "☐ Pay invoice 4471\n☐ Remind Anna to send her timesheet", tasksOnly: true) == 1
              && TemplateEngine.leftOut(of: "the meeting went fine but there's a few things, send the proposal to the client", in: "☐ Send the proposal to the client", tasksOnly: true) == 0
              && TemplateEngine.leftOut(of: "we went through the interviews, nothing was decided yet", in: "Key points\n• Went through the interviews") == 1,
              "a number or a point that left no trace is counted; talk that isn't a task doesn't count against a task list")
        check(TaskListDraft(tasks: [ActionItemDraft(task: "Renew the domain", owner: "", due: "before the 12th"),
                                    ActionItemDraft(task: "- Call the bank", owner: "", due: "")]).text
              == "☐ Renew the domain before the 12th\n☐ Call the bank", "tasks become boxes to tick")
        check(!TemplateLayout.mentionsTasks("today was a good day, the weather was nice and we walked by the river")
              && TemplateLayout.mentionsTasks("for tomorrow call the bank and send the invoice to Sophie")
              && TemplateLayout.mentionsTasks("I need to renew the domain"), "a task list needs something to do")
        let post = BlogPostDraft(title: "Winter", opening: "The light is short so I start earlier now.",
                                 sections: [BlogSectionDraft(heading: "Earlier", body: "I start earlier now because the light is short. I take a walk at lunch.")],
                                 closing: "")
        check(post.text == "# Winter\n\nThe light is short so I start earlier now.\n\nI take a walk at lunch.",
              "a blog body sentence that repeats the opening is dropped")
        check(TemplateLayout.clean(["we still don't know", "- Book the car"]) == ["We still don't know", "Book the car"],
              "list items start with a capital")
        check(TemplateEngine.rejection(original: "we talked about the pricing page, nobody decided anything",
                                       written: "Sarah\nTom\nPricing page discussed", people: ["Sarah", "Tom"],
                                       kind: .meetingNotes) == .inventedDetail, "invented attendees are refused")
        check(TemplateEngine.rejection(original: "call the bank tomorrow and send the invoice to Sophie",
                                       written: "Call the bank (tomorrow)\nSophie: send the invoice", people: ["Sophie"],
                                       kind: .taskList) == nil, "…while names and dates that were said pass")
        // Apple's model and the Meeting Notes example: the example's own lines are not the speaker's.
        let meetingNotes = NoteTemplate.builtIns.first { $0.name == "Meeting Notes" }!
        let kitchen = "had a call with the builder about the kitchen, he can start on the 3rd of March, we decided to keep the old "
            + "cabinets to save money, I need to send him the floor plan by Monday"
        let heldToKitchen = MeetingNotesDraft(
            attendees: [], keyPoints: ["He can start on the 3rd of March"],
            decisions: ["Push the launch date instead of cutting scope", "Keep the old cabinets to save money",
                        "The launch date will be postponed instead of reducing the scope",
                        "Retain the existing cabinets to reduce costs"],
            actionItems: [ActionItemDraft(task: "Update the customer-facing changelog", owner: "", due: ""),
                          ActionItemDraft(task: "Send him the floor plan", owner: "", due: "by Monday")],
            openQuestions: []).withoutExampleLines(of: meetingNotes, saidIn: kitchen)
        check(heldToKitchen.decisions == ["Keep the old cabinets to save money", "Retain the existing cabinets to reduce costs"]
              && heldToKitchen.actionItems.map(\.task) == ["Send him the floor plan"]
              && heldToKitchen.keyPoints == ["He can start on the 3rd of March"],
              "a line from the Meeting Notes example, whole or reworded, is not written into someone's notes; a decision of "
              + "the speaker's that the model reworded is")
        check(!TemplateLayout.isExampleLine("Push the launch date instead of cutting scope", of: meetingNotes,
                                            saidIn: "we went over the Q3 roadmap and decided to push the launch date instead of cutting scope")
              && TemplateLayout.isExampleLine("Push the launch date", of: meetingNotes,
                                              saidIn: "we talked about the launch date and the scope of the beta")
              && !TemplateLayout.isExampleLine("Move the launch from Monday to Friday", of: meetingNotes, saidIn: said)
              && !TemplateLayout.isExampleLine("Went over launch prep", of: meetingNotes, saidIn: said),
              "…unless the recap said the same thing; a decision of the speaker's own stays")
        let blog = NoteTemplate.builtIns.first { $0.name == "Blog Post" }!
        let week = "how I plan my week, on Sunday evening I write down the three things that have to happen, and on Friday I "
            + "look at what slipped and why"
        let weekPost = BlogPostDraft(
            title: "How I Plan My Week",
            opening: "My back hurt every evening. On Sunday evening I write down the three things that have to happen.",
            sections: [BlogSectionDraft(heading: "Reviewing Friday", body: "On Friday I look at what slipped  and why.")],
            closing: "If your back is complaining too, start with the mornings.").withoutExampleLines(of: blog, saidIn: week)
        check(weekPost.opening == "On Sunday evening I write down the three things that have to happen."
              && weekPost.sections.map(\.body) == ["On Friday I look at what slipped  and why."] && weekPost.closing.isEmpty
              && BlogPostDraft(title: "Standing", opening: "My back hurt every evening.", sections: [], closing: "")
                .withoutExampleLines(of: blog, saidIn: "why I got a standing desk, my back hurt every evening").opening == "My back hurt every evening.",
              "a sentence from the Blog Post example is not written into someone's post, unless they said it")
        return passed
    }
}
