import Foundation

/// Answers questions about the user's own dictation history, entirely
/// on-device — Murmur's take on Granola's "Chat with your notes". Uses
/// lightweight keyword retrieval (no embeddings, no network) to pull
/// relevant transcripts into context, then asks the on-device model to
/// answer only from what's there.
enum AskMurmur {
    private static let stopWords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "in", "on", "at", "to", "for",
        "of", "is", "are", "was", "were", "what", "when", "where", "who",
        "did", "do", "does", "i", "my", "me", "this", "that", "with",
        "about", "have", "has", "had", "you", "your", "it", "be", "been",
    ]

    private static func keywords(in text: String) -> Set<String> {
        Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init))
            .subtracting(stopWords)
            .filter { $0.count > 1 }
    }

    // MARK: - Time windows

    /// A date range a question asked about ("yesterday", "last week").
    struct TimeWindow: Equatable {
        let start: Date
        let end: Date
        func contains(_ date: Date) -> Bool { date >= start && date < end }
    }

    /// Pulls a date range out of a question, returning it along with the
    /// question minus the phrase that produced it.
    ///
    /// The phrase has to be removed: leaving "last week" in the keyword set
    /// makes every note containing the ordinary word "week" look relevant,
    /// which is the opposite of what the user asked for.
    static func timeWindow(
        in question: String, now: Date = Date(), calendar: Calendar = .current
    ) -> (window: TimeWindow?, residual: String) {
        let startOfToday = calendar.startOfDay(for: now)
        let lowered = question.lowercased()

        // Longest phrases first so "last week" wins over a bare "week".
        let candidates: [(phrase: String, window: () -> TimeWindow?)] = [
            ("the day before yesterday", {
                guard let start = calendar.date(byAdding: .day, value: -2, to: startOfToday),
                      let end = calendar.date(byAdding: .day, value: -1, to: startOfToday)
                else { return nil }
                return TimeWindow(start: start, end: end)
            }),
            ("last month", {
                guard let start = calendar.date(byAdding: .month, value: -1,
                                                to: startOfMonth(startOfToday, calendar))
                else { return nil }
                return TimeWindow(start: start, end: startOfMonth(startOfToday, calendar))
            }),
            ("this month", {
                let start = startOfMonth(startOfToday, calendar)
                guard let end = calendar.date(byAdding: .month, value: 1, to: start)
                else { return nil }
                return TimeWindow(start: start, end: end)
            }),
            ("last week", {
                guard let start = calendar.date(byAdding: .weekOfYear, value: -1,
                                                to: startOfWeek(startOfToday, calendar))
                else { return nil }
                return TimeWindow(start: start, end: startOfWeek(startOfToday, calendar))
            }),
            ("this week", {
                let start = startOfWeek(startOfToday, calendar)
                guard let end = calendar.date(byAdding: .weekOfYear, value: 1, to: start)
                else { return nil }
                return TimeWindow(start: start, end: end)
            }),
            ("yesterday", {
                guard let start = calendar.date(byAdding: .day, value: -1, to: startOfToday)
                else { return nil }
                return TimeWindow(start: start, end: startOfToday)
            }),
            // Runs to the end of the day, not to `now`: `contains` is
            // half-open, so an end of `now` would exclude a note dictated
            // this very instant from its own window.
            ("today", {
                guard let end = calendar.date(byAdding: .day, value: 1, to: startOfToday)
                else { return nil }
                return TimeWindow(start: startOfToday, end: end)
            }),
        ]

        for candidate in candidates where lowered.contains(candidate.phrase) {
            guard let window = candidate.window() else { continue }
            let residual = lowered.replacingOccurrences(of: candidate.phrase, with: " ")
            return (window, residual)
        }
        return (nil, question)
    }

    private static func startOfWeek(_ date: Date, _ calendar: Calendar) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
    }

    private static func startOfMonth(_ date: Date, _ calendar: Calendar) -> Date {
        calendar.dateInterval(of: .month, for: date)?.start ?? date
    }

    // MARK: - Retrieval

    /// Shared IDF + recency scoring core for `relevantEntries` and
    /// `relevantMeetings` below — ranks any dated-text collection by how
    /// well it matches `questionWords`, weighting rare shared words far
    /// more than common ones (matching "Kubernetes" says more than matching
    /// "design") and giving newer items a mild edge without letting age
    /// outrank relevance. Returns indices into `pool`, ranked best-first;
    /// each caller maps those back to its own concrete type.
    private static func rankedIndices(
        matching questionWords: Set<String>, pool: [(text: String, date: Date)], now: Date
    ) -> [Int] {
        let documents = pool.map { keywords(in: $0.text) }
        let total = Double(pool.count)

        // Document frequency, computed only for the words actually asked about.
        var documentFrequency: [String: Int] = [:]
        for word in questionWords {
            documentFrequency[word] = documents.reduce(0) {
                $0 + ($1.contains(word) ? 1 : 0)
            }
        }

        let scored = zip(pool.indices, documents).compactMap {
            index, words -> (Int, Double)? in
            let matches = questionWords.intersection(words)
            guard !matches.isEmpty else { return nil }

            let relevance = matches.reduce(0.0) { sum, word in
                let frequency = Double(documentFrequency[word] ?? 0)
                // +1 smoothing keeps this finite when a word is in every note.
                return sum + log((total + 1) / (frequency + 1)) + 1
            }
            let ageDays = max(0, now.timeIntervalSince(pool[index].date) / 86_400)
            let recency = exp(-ageDays / 45)
            return (index, relevance * (1 + 0.35 * recency))
        }

        return scored
            .sorted { $0.1 == $1.1 ? pool[$0.0].date > pool[$1.0].date : $0.1 > $1.1 }
            .map(\.0)
    }

    /// Picks the entries most relevant to the question.
    static func relevantEntries(
        for question: String, in entries: [HistoryEntry], limit: Int = 40,
        now: Date = Date()
    ) -> [HistoryEntry] {
        let (window, residual) = timeWindow(in: question, now: now)

        var pool = entries
        if let window {
            pool = entries.filter { window.contains($0.date) }
            // A time-scoped question with nothing in range returns nothing,
            // rather than quietly answering about some other period.
            if pool.isEmpty { return [] }
        }

        let questionWords = keywords(in: residual)
        // No distinctive words left ("summarize this week") — the window,
        // or plain recency, is the whole answer. Entries are newest-first.
        guard !questionWords.isEmpty else { return Array(pool.prefix(limit)) }

        let indices = rankedIndices(
            matching: questionWords, pool: pool.map { (text: $0.text, date: $0.date) }, now: now)
        let matched = indices.prefix(limit).map { pool[$0] }
        return matched.isEmpty ? Array(pool.prefix(limit)) : Array(matched)
    }

    /// Same retrieval as `relevantEntries`, over meeting notes instead of
    /// dictations — a meeting's whole transcript plus its summary form the
    /// searchable text. `limit` is far smaller than `relevantEntries`'
    /// default: a single meeting is much longer than a single dictation, so
    /// fewer of them still fill the same context budget.
    static func relevantMeetings(
        for question: String, in notes: [MeetingNote], limit: Int = 6,
        now: Date = Date()
    ) -> [MeetingNote] {
        let (window, residual) = timeWindow(in: question, now: now)

        var pool = notes
        if let window {
            pool = notes.filter { window.contains($0.date) }
            if pool.isEmpty { return [] }
        }

        let questionWords = keywords(in: residual)
        guard !questionWords.isEmpty else { return Array(pool.prefix(limit)) }

        let indices = rankedIndices(
            matching: questionWords,
            pool: pool.map { (text: "\($0.title) \($0.summary ?? "") \($0.transcriptText)", date: $0.date) },
            now: now)
        let matched = indices.prefix(limit).map { pool[$0] }
        return matched.isEmpty ? Array(pool.prefix(limit)) : Array(matched)
    }

    /// One turn's question paired with the answer Murmur gave it — the
    /// minimal shape `ask` needs from prior turns to stay coherent across a
    /// follow-up, independent of however the caller's own chat-turn type
    /// stores everything else (sources, an id, …).
    struct PriorTurn {
        let question: String
        let answer: String
    }

    /// One thing an answer was actually generated from — a past dictation
    /// or a meeting note — letting `Answer.sources` cite both kinds under
    /// one citation list instead of only ever pointing at dictation
    /// history, which is all it could reference before Notetaker existed.
    struct AskSource: Identifiable {
        enum Kind: Equatable { case dictation, meeting }
        let id: String
        let date: Date
        /// A one-line preview for `SourcesDisclosure` — the dictation's own
        /// text, or a meeting's title.
        let preview: String
        let kind: Kind
    }

    struct Answer {
        let text: String
        /// The notes actually retrieved for this question, in the order
        /// they were scored — empty for the two early-return cases (no
        /// history, or a time-scoped question with nothing in range), since
        /// neither one asked the model anything.
        let sources: [AskSource]
    }

    static func ask(
        _ question: String, history: [HistoryEntry], meetings: [MeetingNote] = [],
        engine: RewriteEngine, conversation: [PriorTurn] = [], voice: VoiceProfile? = nil
    ) async throws -> Answer {
        guard !history.isEmpty || !meetings.isEmpty else {
            return Answer(
                text: Notetaker.isAvailable
                    ? "You don't have any dictations or meeting notes yet — dictate " +
                      "something, or capture a meeting with Notetaker, then ask again."
                    : "You don't have any dictations yet — dictate something, then ask again.",
                sources: [])
        }
        // A follow-up like "who owns it?" carries almost no keywords of its
        // own — folding in the last couple of questions (not answers, which
        // are the model's own prose and would just add noise) keeps
        // retrieval anchored to what the conversation is actually about,
        // not just this one short question.
        let retrievalQuery = (conversation.suffix(2).map(\.question) + [question]).joined(separator: " ")
        let candidates = relevantEntries(for: retrievalQuery, in: history)
        let meetingCandidates = relevantMeetings(for: retrievalQuery, in: meetings)
        // Only a time-scoped question can come back empty on both; saying
        // so beats answering about a period the user didn't ask about.
        guard !candidates.isEmpty || !meetingCandidates.isEmpty else {
            return Answer(
                text: "You didn't dictate anything or have any meetings in that time range.",
                sources: [])
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        var context = ""
        for entry in candidates {
            let line = "[\(formatter.string(from: entry.date))] \(entry.text)\n"
            // Keep a safe prompt size for the on-device model's context window.
            if context.count + line.count > 4000 { break }
            context += line
        }

        // A separate, smaller budget than dictations above — a single
        // meeting transcript is already much longer than a single
        // dictation, so it needs its own cap rather than crowding out every
        // dictation candidate from the shared one.
        var meetingContext = ""
        for note in meetingCandidates {
            let label = note.calendarTitle ?? note.title
            let body = note.summary?.isEmpty == false ? note.summary! : note.transcriptText
            let line = "[\(formatter.string(from: note.date)) — Meeting: \(label)] \(body)\n"
            if meetingContext.count + line.count > 4000 { break }
            meetingContext += line
        }

        // The profile tells the model who it's summarising, which helps it
        // read shorthand and recurring names the way the author meant them.
        let voiceLine = voice.map {
            "\nFor context, this person's dictation style: \($0.voiceContext)\n"
        } ?? ""

        // Recent turns, not the whole thread — each call still gets its own
        // fresh, bounded session (see `RewriteEngine.rewrite`'s own note on
        // why a session is never reused across turns); this just repeats a
        // short recap of what was already asked so "it"/"that" resolve,
        // without the prompt growing over an entire conversation.
        let conversationBlock: String
        if conversation.isEmpty {
            conversationBlock = ""
        } else {
            let recap = conversation.suffix(3)
                .map { "Q: \($0.question)\nA: \($0.answer)" }
                .joined(separator: "\n\n")
            conversationBlock = """

            RECENT CONVERSATION (for context only — answer the NEW question below):
            \(recap)

            """
        }

        let sections = [
            context.isEmpty ? nil : "PAST DICTATIONS:\n\(context)",
            meetingContext.isEmpty ? nil : "MEETING NOTES:\n\(meetingContext)",
        ].compactMap { $0 }.joined(separator: "\n\n")

        let instructions = """
        Answer the user's question using ONLY the timestamped notes below — \
        their own past dictations and/or meeting notes. If the answer isn't \
        in them, say so plainly instead of guessing or inventing details. Be \
        concise: a few sentences or a short list, not an essay. You may \
        reference a note's date naturally when it helps.
        \(voiceLine)\(conversationBlock)
        \(sections)
        """
        let text = try await engine.rewrite(question, instructions: instructions)
        let sources = candidates.map { AskSource(id: $0.id, date: $0.date, preview: $0.text, kind: .dictation) }
            + meetingCandidates.map {
                AskSource(id: $0.id.uuidString, date: $0.date, preview: $0.calendarTitle ?? $0.title, kind: .meeting)
            }
        return Answer(text: text, sources: sources)
    }

    // MARK: - Self test (retrieval)

    static func runSelfTest() -> Bool {
        let now = Date()
        let entries = [
            HistoryEntry(text: "Roadmap review: Sarah owns the API migration.",
                         date: now),
            HistoryEntry(text: "Buy milk and eggs on the way home.",
                         date: now.addingTimeInterval(-3600)),
            HistoryEntry(text: "Follow up with the vendor about pricing.",
                         date: now.addingTimeInterval(-7200)),
        ]

        var passed = true

        // Distinctive keyword should surface the matching entry first.
        let roadmapMatch = relevantEntries(for: "What did we say about the roadmap?",
                                            in: entries)
        let roadmapOK = roadmapMatch.first?.text.contains("Roadmap") == true
        if !roadmapOK { passed = false }
        print("\(roadmapOK ? "PASS" : "FAIL"): keyword retrieval surfaces the " +
              "roadmap entry first")

        // No distinctive keywords ("summarize this") -> falls back to
        // recency, returning everything rather than nothing.
        let broad = relevantEntries(for: "Summarize this", in: entries)
        let broadOK = broad.count == entries.count
        if !broadOK { passed = false }
        print("\(broadOK ? "PASS" : "FAIL"): broad question falls back to all " +
              "\(entries.count) entries, got \(broad.count)")

        // Empty history never crashes the matcher.
        let empty = relevantEntries(for: "anything", in: [])
        let emptyOK = empty.isEmpty
        if !emptyOK { passed = false }
        print("\(emptyOK ? "PASS" : "FAIL"): empty history returns no entries")

        func check(_ ok: Bool, _ label: String) {
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): \(label)")
        }

        // A rare term must outrank a common one. "design" appears in every
        // note here, so it carries almost no information; "Kubernetes"
        // appears once and should decide the ranking. Plain overlap
        // counting scored these equally.
        let calendar = Calendar.current
        let idfEntries = [
            HistoryEntry(text: "design review notes", date: now),
            HistoryEntry(text: "design work on Kubernetes clusters", date: now),
            HistoryEntry(text: "design sync with the team", date: now),
        ]
        let idfTop = relevantEntries(
            for: "design Kubernetes", in: idfEntries, now: now).first
        check(idfTop?.text.contains("Kubernetes") == true,
              "rare term outranks a term common to every note")

        // Temporal phrases must filter by date, and must not leak into the
        // keyword set (or every note containing "week" would match).
        let dayAgo = calendar.date(byAdding: .day, value: -1, to: now)!
        let weekAgo = calendar.date(byAdding: .day, value: -9, to: now)!
        let dated = [
            HistoryEntry(text: "shipped the parser", date: now),
            HistoryEntry(text: "reviewed the contract", date: dayAgo),
            HistoryEntry(text: "planned the quarter", date: weekAgo),
        ]
        let todayOnly = relevantEntries(for: "what did I do today", in: dated, now: now)
        check(todayOnly.count == 1 && todayOnly.first?.text == "shipped the parser",
              "\"today\" filters to today's entries only")

        let window = timeWindow(in: "what did I say yesterday", now: now).window
        check(window?.contains(dayAgo) == true && window?.contains(now) == false,
              "\"yesterday\" window covers yesterday but excludes today")

        let residual = timeWindow(in: "summarize last week", now: now).residual
        check(!residual.contains("week"),
              "matched time phrase is stripped from the keywords")

        // A time-scoped question with nothing in range returns nothing,
        // instead of falling back to a period the user didn't ask about.
        let farFuture = calendar.date(byAdding: .day, value: 400, to: now)!
        let noneToday = relevantEntries(
            for: "what did I do today",
            in: [HistoryEntry(text: "old note", date: weekAgo)],
            now: farFuture)
        check(noneToday.isEmpty,
              "empty time range returns nothing rather than unrelated notes")

        return passed
    }
}
