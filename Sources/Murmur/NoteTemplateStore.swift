import Foundation

/// Restructures a transcript into a specific document shape via the
/// on-device LLM — Murmur's take on Heidi Health's note templates
/// (record a conversation, pick a template, get a structured note).
struct NoteTemplate: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var icon: String
    var instructions: String
    var isBuiltIn = false
    /// Say this phrase at the very start of a dictation to apply the
    /// template automatically, with no clicks. Empty = manual only.
    var voiceTrigger: String = ""
    /// An optional worked input/output pair, appended to `instructions` as a
    /// concrete example. `instructions` states the output *shape* in the
    /// abstract (e.g. "omit Attendees if none are named") — a model can
    /// satisfy that in spirit while still drifting on the specific
    /// formatting; one worked example pins the exact shape down the way an
    /// abstract rule alone doesn't. Optional, not `String = ""`: Swift's
    /// synthesized `Decodable` only tolerates a *missing* JSON key when the
    /// property type is Optional, and `NoteTemplateStore.loadCustom()`
    /// swallows decode failures into an empty array — a non-Optional default
    /// here would silently wipe every custom template the first time it
    /// decoded a `templates.json` written before this field existed.
    var exampleInput: String? = nil
    var exampleOutput: String? = nil
    /// More phrases that apply it — the built-ins' Latvian ones ("sapulces piezīmes"). Optional for the same decoding
    /// reason as the example above.
    var otherTriggers: [String]? = nil
    /// The parts a template of the user's own asks for, worked out from its description when it was saved
    /// (`TemplateEngine.planSections`); nil when it isn't laid out in parts.
    var sections: [TemplateSectionSpec]? = nil

    /// Every phrase that applies it: its own, any extra ones, and for a built-in its Latvian phrase.
    var triggers: [String] {
        ([voiceTrigger] + (otherTriggers ?? []) + (isBuiltIn ? Self.latvianTriggers[name] ?? [] : []))
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The built-ins' Latvian phrases (templates also work for Latvian dictation — `TemplateLanguage`).
    static let latvianTriggers: [String: [String]] = [
        "Meeting Notes": ["sapulces piezīmes"], "Summary": ["kopsavilkums"],
        "Email Draft": ["e-pasta melnraksts", "epasta melnraksts", "e-pasts"], "Task List": ["uzdevumu saraksts"],
        "Blog Post": ["bloga ieraksts"]]

    /// Empty unless both halves of the example are present, so a template
    /// with no example composes into `instructions` unchanged.
    var workedExampleBlock: String {
        guard let input = exampleInput, let output = exampleOutput,
              !input.isEmpty, !output.isEmpty else { return "" }
        return """


            Example — dictated input:
            \(input)

            Correct output:
            \(output)
            """
    }

    /// The built-ins, rewritten 2026-09-30 for `TemplateEngine` (fields the model fills, laid out by Murmur): each
    /// says what to keep and why a guess hurts, with one worked example in the finished layout.
    static let builtIns: [NoteTemplate] = [
        NoteTemplate(
            name: "Meeting Notes", icon: "person.2.wave.2",
            instructions: """
            Turn the dictation into meeting notes. It is the user's own spoken recap, so keep only what they said: \
            the people named, what was discussed, what was decided, who will do what and by when, and what is still \
            open. A name, decision or deadline that wasn't said would end up in someone's notes as fact, so leave a \
            part empty rather than guess.
            """, isBuiltIn: true, voiceTrigger: "meeting notes",
            exampleInput: """
            Okay so we went over the Q3 roadmap, the API work is going to slip about two weeks because of the auth \
            rewrite, and we decided to just push the launch date instead of cutting scope. Someone needs to update \
            the customer-facing changelog before we tell anyone.
            """,
            exampleOutput: """
            Key points
            - Went over the Q3 roadmap
            - The API work will slip about two weeks because of the auth rewrite

            Decisions
            - Push the launch date instead of cutting scope

            Action items
            - Update the customer-facing changelog before telling anyone
            """),
        NoteTemplate(
            name: "Summary", icon: "text.line.first.and.arrowtriangle.forward",
            instructions: """
            Summarize the dictation in one short paragraph with only its main points, about a quarter of its length, \
            in the speaker's own voice (I, we). Start straight with the content, never with "This text discusses", \
            and keep every number, name and date you use exactly as said.
            """, isBuiltIn: true, voiceTrigger: "summarize this",
            exampleInput: """
            so the plan for the kitchen is we keep the old cabinets but paint them dark green, the new worktop is \
            oak, the builder can start on the 3rd of March and says it takes about two weeks, and the budget is \
            4,000 euros including the sink, which is more than we wanted but still okay
            """,
            exampleOutput: """
            We're keeping the old cabinets but painting them dark green, with a new oak worktop. The builder starts \
            on the 3rd of March for about two weeks, and the budget is 4,000 euros including the sink: more than we \
            wanted, but okay.
            """),
        NoteTemplate(
            name: "Email Draft", icon: "envelope",
            instructions: """
            Turn the dictation into an email the user is sending. They say who it is to and what they want to say, \
            often as "to Sophie, …" or "ask the team whether …": write a short subject and the body in their voice, \
            addressed to the recipient: "can she ask legal" becomes "Could you ask legal", and "ask the team whether \
            anyone can cover support on Friday" is written to the team as "Could anyone cover support on Friday?". \
            Murmur adds the greeting and the sign-off, so the body has neither. Keep every fact, date and number as said.
            """, isBuiltIn: true, voiceTrigger: "email draft",
            exampleInput: """
            to Marco, the photos from Saturday are ready, I'll send the link tonight, can he let me know which ones \
            he wants printed by Wednesday
            """,
            exampleOutput: """
            Subject: Photos from Saturday

            Hi Marco,

            The photos from Saturday are ready, and I'll send you the link tonight.

            Could you let me know which ones you'd like printed by Wednesday?

            Best,
            """),
        NoteTemplate(
            name: "Task List", icon: "checklist",
            instructions: """
            List every task, to-do or action in the dictation, one per item, as a short instruction, with who does \
            it and when only if the user said so. A story or a description with nothing to do has no tasks: a made-up \
            task is worse than none.
            """, isBuiltIn: true, voiceTrigger: "task list",
            exampleInput: """
            before the trip I need to renew my passport, ask Tom to water the plants, and pay the electricity bill \
            by the 20th
            """,
            exampleOutput: """
            - [ ] Renew my passport
            - [ ] Ask Tom to water the plants
            - [ ] Pay the electricity bill (by the 20th)
            """),
        NoteTemplate(
            name: "Blog Post", icon: "doc.richtext",
            instructions: """
            Turn the dictation into a blog post draft in the author's voice: a title, an opening paragraph, a section \
            with a short heading for each point they make, and a brief closing. Build it from their points and their \
            words, and add no facts, numbers or claims they didn't make.
            """, isBuiltIn: true, voiceTrigger: "blog post",
            exampleInput: """
            why I switched to a standing desk, my back hurt every evening, I raised it in the mornings only at first, \
            now I stand about half the day, and the surprise was that I focus better in the afternoon
            """,
            exampleOutput: """
            # Why I Switched to a Standing Desk

            My back hurt every evening.

            ## Starting slowly

            At first I only raised the desk in the mornings.

            ## Half the day, standing

            Now I stand about half the day.

            ## The surprise

            I focus better in the afternoon, which I didn't expect.

            If your back is complaining too, start with the mornings.
            """),
    ]
}

enum NoteTemplateStore {
    static var fileURL: URL {
        AppPaths.supportDirectory.appendingPathComponent("templates.json")
    }

    static func loadCustom() -> [NoteTemplate] {
        guard let data = try? Data(contentsOf: fileURL),
              let templates = try? JSONDecoder().decode([NoteTemplate].self, from: data)
        else { return [] }
        return templates
    }

    static func saveCustom(_ templates: [NoteTemplate]) {
        if let data = try? JSONEncoder().encode(templates) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Built-ins first, then the user's own templates.
    static func all() -> [NoteTemplate] {
        NoteTemplate.builtIns + loadCustom()
    }

    /// If `text` opens with a template's voice trigger phrase, returns that
    /// template plus the remaining text with the trigger stripped off.
    /// Requires a real word boundary after the phrase and at least two
    /// words left over, so ordinary sentences that merely start with a
    /// similar word ("Email John about...") don't misfire.
    static func matchVoiceTrigger(in text: String) -> (template: NoteTemplate, remainder: String)? {
        for template in all() {
            for trigger in template.triggers {
                let escaped = NSRegularExpression.escapedPattern(for: trigger)
                // A recognizer may end the phrase with a full stop ("Sapulces piezīmes. Labi, tātad…").
                let pattern = "(?i)^\\s*\(escaped)\\b\\s*[:,.!\\-—]?\\s*"
                guard let range = text.range(
                    of: pattern, options: .regularExpression) else { continue }
                let remainder = String(text[range.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard remainder.split(whereSeparator: { $0.isWhitespace }).count >= 2
                else { continue }
                return (template, remainder)
            }
        }
        return nil
    }

    // MARK: - Self test (matcher)

    static func runSelfTest() -> Bool {
        let cases: [(input: String, expectedName: String?, expectedRemainder: String?)] = [
            ("Meeting notes, we discussed the roadmap and Sarah owns the API work.",
             "Meeting Notes", "we discussed the roadmap and Sarah owns the API work."),
            ("Email draft: thanks for joining the call today, let's follow up Friday.",
             "Email Draft", "thanks for joining the call today, let's follow up Friday."),
            ("Summarize this - the launch moved to October because design slipped.",
             "Summary", "the launch moved to October because design slipped."),
            ("Sapulces piezīmes. Labi, tātad mēs runājām par mājaslapu.",
             "Meeting Notes", "Labi, tātad mēs runājām par mājaslapu."),
            ("uzdevumu saraksts: rīt jāpiezvana bankai un jānosūta rēķins",
             "Task List", "rīt jāpiezvana bankai un jānosūta rēķins"),
            // Should NOT trigger: real sentence merely starting with a similar word.
            ("Email John about the pricing sheet before tomorrow.", nil, nil),
            // Should NOT trigger: bare trigger with no real content after it.
            ("Task list.", nil, nil),
            ("Just a normal sentence with no trigger phrase at all.", nil, nil),
        ]
        var passed = true
        for testCase in cases {
            let got = matchVoiceTrigger(in: testCase.input)
            let ok: Bool
            if let expectedName = testCase.expectedName {
                ok = got?.template.name == expectedName
                    && got?.remainder == testCase.expectedRemainder
            } else {
                ok = got == nil
            }
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): matchVoiceTrigger(\"\(testCase.input)\") " +
                  "= \(got.map { "\($0.template.name) -> \"\($0.remainder)\"" } ?? "nil")")
        }

        func check(_ ok: Bool, _ label: String) {
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): \(label)")
        }

        // A template with no example composes unchanged.
        let bare = NoteTemplate(name: "T", icon: "", instructions: "BODY")
        check(bare.workedExampleBlock.isEmpty, "no example -> empty block")
        check(bare.instructions + bare.workedExampleBlock == "BODY",
              "empty block leaves instructions untouched when composed")

        // A template with only one half set still composes as if it had none
        // — a dangling example half is worse than no example at all.
        let halfExample = NoteTemplate(
            name: "T", icon: "", instructions: "BODY", exampleInput: "only input")
        check(halfExample.workedExampleBlock.isEmpty,
              "example with only one half set -> still empty block")

        // Meeting Notes carries a worked example (verified to actually
        // change model behavior, not just assumed to), and it reaches the
        // composed instructions untouched.
        let meetingNotes = NoteTemplate.builtIns.first { $0.name == "Meeting Notes" }!
        check(meetingNotes.exampleInput != nil && meetingNotes.exampleOutput != nil,
              "Meeting Notes has a worked example")
        check((meetingNotes.instructions + meetingNotes.workedExampleBlock)
                .contains(meetingNotes.exampleOutput!),
              "Meeting Notes example output reaches the composed instructions")

        // Every built-in carries a complete worked example since the structured engine (`TemplateEngine`).
        check(NoteTemplate.builtIns.allSatisfy { !$0.workedExampleBlock.isEmpty },
              "every built-in template has a complete worked example")

        return passed
    }
}

/// Legacy per-app template rule. No longer written; retained so
/// `AppProfileStore` can decode and migrate rules saved by older builds.
struct AppTemplateRule: Codable, Equatable {
    var appName: String
    var templateID: UUID
}
