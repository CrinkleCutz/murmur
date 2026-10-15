import AppKit
import Foundation

/// Learning from corrections in an app whose text box Murmur can't read (Codex's composer shows no text to other apps).
///
/// The agents keep what was actually sent on this Mac — Codex under `~/.codex/sessions`, Claude Code under
/// `~/.claude/projects`. So for a dictation pasted into such a field, the message the user sent afterwards is found
/// there, the stretch of it that is the dictation is cut out, and what the user changed goes through the same filter
/// as an edit seen in the field (`EditLearner.pairs`: names and unusual words only; an everyday word swapped for
/// another is never learned).
///
/// Only the one matching message is looked at, nothing is stored or sent anywhere, and the session files are only
/// read while a dictation of this kind is waiting for its message. `defaults write local.murmur learnFromSentMessages
/// -bool false` turns it off.
enum SentMessageLearner {
    private struct Pending {
        let text: String
        let date: Date
        let draft: EditRecordDraft?
        let pid: pid_t
    }

    private static let queue = DispatchQueue(label: "local.murmur.sent-learner", qos: .utility)
    // Only touched on `queue`.
    nonisolated(unsafe) private static var pending: [Pending] = []
    nonisolated(unsafe) private static var scheduled = false

    static var isEnabled: Bool { UserDefaults.standard.object(forKey: "learnFromSentMessages") as? Bool ?? true }

    /// A dictation waits this long for its message before it is given up on.
    static let expiry: TimeInterval = 30 * 60
    /// Looked for no sooner than this after the paste: the message can't have been sent before it was read through.
    static let minimumAge: TimeInterval = 10
    static let codexBundleID = "com.openai.codex"

    /// The dictation was pasted into a field Murmur can't read (or into Codex, which never shows its text).
    static func expect(inserted: String, bundleID: String?, fieldWasReadable: Bool, draft: EditRecordDraft? = nil) {
        guard isEnabled, bundleID == codexBundleID || !fieldWasReadable else { return }
        let text = inserted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard words(in: text).count >= 3 else { return }
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        queue.async {
            pending.append(Pending(text: text, date: Date(), draft: draft, pid: pid))
            if pending.count > 20 { pending.removeFirst(pending.count - 20) }
            schedule()
        }
    }

    /// A new dictation is starting: a good moment to look, since the last message has most likely been sent.
    static func dictationStarted() {
        guard isEnabled else { return }
        queue.async { check() }
    }

    private static func schedule() {
        guard !scheduled, !pending.isEmpty else { return }
        scheduled = true
        queue.asyncAfter(deadline: .now() + 45) {
            scheduled = false
            check()
            schedule()
        }
    }

    // MARK: - Looking

    private static func check() {
        let now = Date()
        pending.removeAll { now.timeIntervalSince($0.date) > expiry }
        let ready = pending.filter { now.timeIntervalSince($0.date) >= minimumAge }
        guard let earliest = ready.map(\.date).min() else { return }
        let messages = sentMessages(since: earliest)
        guard !messages.isEmpty else { return }
        var learned: [LearnedNotice] = []
        for item in ready {
            guard let message = messages.first(where: { $0.date >= item.date && region(of: item.text, in: $0.text) != nil }),
                  let found = region(of: item.text, in: message.text) else { continue }
            pending.removeAll { $0.date == item.date && $0.text == item.text }
            // Nothing typed in that app between the paste and the message: the user changed nothing (`TypingEvidence`).
            guard TypingEvidence.count(pid: item.pid, since: item.date, until: message.date) > 0 else {
                dictationLog.notice("sent-message learning: found the message, nothing was typed — not learned")
                continue
            }
            var notices: [LearnedNotice] = EditLearner.pairs(original: item.text, edited: found).compactMap { pair in
                LearnedStore.addTracked(heard: pair.heard, intended: pair.intended)
                    .map { LearnedNotice(heard: pair.heard, intended: pair.intended, receipt: $0) }
            }
            if EditLearner.stillHolds(item.text, in: found), !EditLearner.grewTooMuch(item.text, found) {
                notices += LearnedStore.addNewWordsTracked(original: item.text, corrected: found)
                    .filter { new in !notices.contains { $0.intended.lowercased() == new.intended.lowercased() } }
            }
            dictationLog.notice("sent-message learning: found the message, learned \(notices.count)")
            if let draft = item.draft {
                EditRecordStore.complete(draft, final: found, reason: "sent message", learned: notices.count)
            }
            learned += notices
        }
        guard !learned.isEmpty else { return }
        DispatchQueue.main.async { EditLearner.onLearned?(learned) }
    }

    // MARK: - Reading the agents' own files

    private struct Sent {
        let date: Date
        let text: String
    }

    /// Messages the user sent to Codex or Claude Code since `date`, oldest first. Only files written since then are read.
    private static func sentMessages(since date: Date) -> [Sent] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let floor = date.addingTimeInterval(-60)
        var files: [(url: URL, codex: Bool)] = []
        func collect(_ root: URL, codex: Bool, depth: Int) {
            guard let items = try? fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]) else { return }
            for url in items {
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
                if values?.isDirectory == true {
                    if depth > 0 { collect(url, codex: codex, depth: depth - 1) }
                } else if url.pathExtension == "jsonl", (values?.contentModificationDate ?? .distantPast) >= floor {
                    files.append((url, codex))
                }
            }
        }
        // Codex: sessions/YYYY/MM/DD; Claude Code: projects/<project>/<session>.jsonl.
        collect(home.appendingPathComponent(".codex/sessions"), codex: true, depth: 3)
        collect(home.appendingPathComponent(".claude/projects"), codex: false, depth: 1)
        var out: [Sent] = []
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for file in files {
            guard let size = (try? file.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size < 80_000_000,
                  let data = try? Data(contentsOf: file.url, options: .mappedIfSafe) else { continue }
            for line in data.split(separator: UInt8(ascii: "\n")) {
                guard line.count > 20, line.range(of: Data("\"user\"".utf8)) != nil,
                      let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let when = (object["timestamp"] as? String).flatMap({ stamp.date(from: $0) }), when >= date
                else { continue }
                if let text = userText(object, codex: file.codex) { out.append(Sent(date: when, text: text)) }
            }
        }
        return out.sorted { $0.date < $1.date }
    }

    /// The words the user sent in one line of a session file, or nil for anything else (the agent's own turns, tool
    /// results, the context Codex adds around a message).
    static func userText(_ object: [String: Any], codex: Bool) -> String? {
        let content: Any?
        if codex {
            guard let payload = object["payload"] as? [String: Any], payload["type"] as? String == "message",
                  payload["role"] as? String == "user" else { return nil }
            content = payload["content"]
        } else {
            guard object["type"] as? String == "user", let message = object["message"] as? [String: Any],
                  message["role"] as? String == "user" else { return nil }
            content = message["content"]
        }
        var parts: [String] = []
        if let string = content as? String { parts = [string] }
        else if let items = content as? [[String: Any]] {
            parts = items.compactMap { ($0["type"] as? String).map { ["input_text", "text"].contains($0) } == true ? $0["text"] as? String : nil }
        }
        let text = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.hasPrefix("<"), !text.hasPrefix("# AGENTS.md"),
              !text.hasPrefix("The following is the Codex agent history") else { return nil }
        return text
    }

    // MARK: - Finding the dictation in the message (pure, self-tested)

    private static let wordPattern = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}'’]+")

    private static func tokens(_ text: String) -> [(word: String, range: NSRange)] {
        let ns = text as NSString
        return wordPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            (ns.substring(with: $0.range).lowercased().replacingOccurrences(of: "’", with: "'"), $0.range)
        }
    }

    static func words(in text: String) -> [String] { tokens(text).map(\.word) }

    /// The stretch of `message` that is the dictation, as the user left it: from where its opening words are found to
    /// where its closing words end, the stretch no shorter or longer than a corrected dictation could be. Nil when the message doesn't contain it (or a correction touched both of its ends).
    static func region(of dictation: String, in message: String) -> String? {
        let dictated = words(in: dictation)
        guard dictated.count >= 3 else { return nil }
        let found = tokens(message)
        let sent = found.map(\.word)
        func occurrences(of run: [String]) -> [Int] {
            guard run.count <= sent.count else { return [] }
            return (0...(sent.count - run.count)).filter { Array(sent[$0..<$0 + run.count]) == run }
        }
        // Where the opening words (three, else two) and the closing words are found. A run that turns up more than
        // once (a phrase said twice, the message pasted twice) is not a reason to give up: the pair of ends that makes
        // the stretch closest to the dictation's own length is the one.
        var starts: [Int] = []
        for length in [3, 2] where starts.isEmpty && dictated.count >= length {
            starts = occurrences(of: Array(dictated.prefix(length)))
        }
        var ends: [Int] = []
        for length in [3, 2] where ends.isEmpty && dictated.count >= length {
            ends = occurrences(of: Array(dictated.suffix(length))).map { $0 + length - 1 }
        }
        var best: (start: Int, end: Int, distance: Int)?
        for candidateStart in starts {
            for candidateEnd in ends where candidateEnd > candidateStart {
                let count = candidateEnd - candidateStart + 1
                guard Double(count) >= Double(dictated.count) * 0.6,
                      Double(count) <= Double(dictated.count) * 1.3 + 2 else { continue }
                let distance = abs(count - dictated.count)
                if best == nil || distance < best!.distance { best = (candidateStart, candidateEnd, distance) }
            }
        }
        guard let best else { return nil }
        let start = best.start, end = best.end
        let ns = message as NSString
        let from = found[start].range.location
        let to = NSMaxRange(found[end].range)
        // Whatever punctuation closes the last word belongs to the dictation too.
        var stop = to
        while stop < ns.length, let scalar = UnicodeScalar(ns.character(at: stop)), ".,!?;:…".unicodeScalars.contains(scalar) { stop += 1 }
        return ns.substring(with: NSRange(location: from, length: stop - from))
    }

    static func runSelfTest() -> Bool {
        var passed = true
        func check(_ ok: Bool, _ label: String) {
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): sent-message learning: \(label)")
        }
        let dictated = "We moved the build to Vercel and the Manrog font is not working on the pricing page."
        let message = "Quick one before lunch. We moved the build to Vercel and the Manrope font is now working on the pricing page. Thanks!"
        let found = region(of: dictated, in: message)
        check(found == "We moved the build to Vercel and the Manrope font is now working on the pricing page.",
              "the dictation is cut out of a longer message, closing full stop included (got \(found ?? "nil"))")
        check(region(of: dictated, in: "Something else entirely, said in another message.") == nil,
              "a message without the dictation is not matched")
        check(region(of: dictated, in: message + " " + message) == found,
              "a message pasted twice gives the same stretch")
        check(region(of: "so we did it and then we did it again later today",
                     in: "so we did it and then we did it again later today.") != nil,
              "a phrase said twice inside the dictation is not ambiguous")
        check(region(of: "Short one", in: "Short one here") == nil, "fewer than three words is never matched")
        check(region(of: dictated, in: "We moved the build to Vercel. Later I wrote a very long extra paragraph about something unrelated that goes on and on and on, then: on the pricing page.") == nil,
              "a stretch far longer than the dictation is not taken")
        let pairs = EditLearner.pairs(original: dictated, edited: found ?? "")
        check(pairs.contains { $0.heard.lowercased() == "manrog" && $0.intended == "Manrope" } && pairs.count == 1,
              "a corrected name is learned and the swapped everyday word (not → now) is not")
        let codexLine: [String: Any] = ["payload": ["type": "message", "role": "user",
            "content": [["type": "input_text", "text": "Hello from the user"]]]]
        let contextLine: [String: Any] = ["payload": ["type": "message", "role": "user",
            "content": [["type": "input_text", "text": "<environment_context>cwd</environment_context>"]]]]
        let claudeLine: [String: Any] = ["type": "user", "message": ["role": "user", "content": "Hi there from the user"]]
        let assistantLine: [String: Any] = ["type": "assistant", "message": ["role": "assistant", "content": "ok"]]
        check(userText(codexLine, codex: true) == "Hello from the user" && userText(contextLine, codex: true) == nil
              && userText(claudeLine, codex: false) == "Hi there from the user" && userText(assistantLine, codex: false) == nil,
              "only the user's own words are read from the session files")
        return passed
    }
}
