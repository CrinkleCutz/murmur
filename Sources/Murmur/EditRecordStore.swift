import Foundation

/// What was heard, what was pasted, and what the user made of it — kept on this Mac, only when switched on (Settings ▸
/// Dictation ▸ Learning). It is the real-voice test set the synthetic recordings can't be: for each dictation Murmur
/// watched, the recognizer's own words, the pasted words and the words the user left, so the errors that really cost
/// a fix can be counted and seen — which words, in which app, and at which stage they went wrong (a word that is
/// already wrong in `raw` came from the recognizer; one that is right there and wrong in `pasted` was changed after).
///
/// Never sent anywhere. Capped at the last 500; `defaults write local.murmur keepEditRecords -bool true` (or the
/// switch) turns it on, and "Delete the record" in Settings clears it.
struct EditRecordDraft: Equatable {
    var raw: String
    var pasted: String
    var app: String
    var engine: String
    var model: String
    var date = Date()
}

struct EditRecord: Codable, Identifiable, Equatable {
    struct Change: Codable, Equatable {
        var before: String
        var after: String
    }
    var id = UUID()
    var date: Date
    var app: String
    var engine: String
    var model: String
    /// The recognizer's words (after its own name fix), before Murmur's clean-up.
    var raw: String
    /// What Murmur pasted.
    var pasted: String
    /// What the field held when the user was done with it.
    var final: String
    var changes: [Change]
    /// How the watch ended: "sent", "next dictation", "left the field", "sent message" …
    var endReason: String
    /// How many corrections Murmur learned from it.
    var learned: Int
}

enum EditRecordStore {
    static let limit = 500
    private static let queue = DispatchQueue(label: "local.murmur.edit-records", qos: .utility)

    static var isEnabled: Bool { UserDefaults.standard.object(forKey: "keepEditRecords") as? Bool ?? false }

    static var fileURL: URL { AppPaths.supportDirectory.appendingPathComponent("edit_records.json") }

    /// Stores the outcome of one watched dictation. `final` is the dictation's own stretch of the field.
    static func complete(_ draft: EditRecordDraft, final: String, reason: String, learned: Int) {
        guard isEnabled else { return }
        let record = EditRecord(
            date: draft.date, app: draft.app, engine: draft.engine, model: draft.model, raw: draft.raw,
            pasted: draft.pasted, final: final, changes: changes(from: draft.pasted, to: final), endReason: reason,
            learned: learned)
        queue.async {
            var all = load()
            all.append(record)
            if all.count > limit { all.removeFirst(all.count - limit) }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(all) { try? data.write(to: fileURL, options: .atomic) }
        }
    }

    static func load() -> [EditRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([EditRecord].self, from: data)) ?? []
    }

    static func clear() {
        queue.async { try? FileManager.default.removeItem(at: fileURL) }
    }

    // MARK: - Reading it

    /// The word-level differences between two texts, in order: each run of words that differs, before → after. A word is
    /// compared without its punctuation and case, so "working." → "working" and "Now" → "now" are not changes.
    static func changes(from before: String, to after: String) -> [EditRecord.Change] {
        func tokens(_ text: String) -> [(shown: String, key: String)] {
            text.split(whereSeparator: \.isWhitespace).map { piece in
                let shown = String(piece)
                let key = shown.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "’" }
                return (shown, key)
            }.filter { !$0.key.isEmpty }
        }
        let a = tokens(before), b = tokens(after)
        guard !a.isEmpty || !b.isEmpty else { return [] }
        // Longest common subsequence of the keys.
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i].key == b[j].key ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var out: [EditRecord.Change] = []
        var i = 0, j = 0
        var removed: [String] = [], added: [String] = []
        func flush() {
            guard !removed.isEmpty || !added.isEmpty else { return }
            out.append(EditRecord.Change(before: removed.joined(separator: " "), after: added.joined(separator: " ")))
            removed = []
            added = []
        }
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i].key == b[j].key {
                flush()
                i += 1
                j += 1
            } else if j < b.count, i == a.count || table[i][j + 1] >= table[i + 1][j] {
                added.append(b[j].shown)
                j += 1
            } else {
                removed.append(a[i].shown)
                i += 1
            }
        }
        flush()
        return Array(out.prefix(30))
    }

    /// A plain-words account of a record set, for the command line and for reading with the user: how many dictations
    /// were watched, how many needed a fix, and the changes made most often — split by whether the recognizer's own
    /// words already had the problem.
    static func summary(of records: [EditRecord]) -> String {
        guard !records.isEmpty else { return "No edit records yet. Switch it on in Settings ▸ Dictation ▸ Learning." }
        let changed = records.filter { !$0.changes.isEmpty }
        let pastedWords = records.reduce(0) { $0 + $1.pasted.split(whereSeparator: \.isWhitespace).count }
        let changedWords = records.reduce(0) { total, record in
            total + record.changes.reduce(0) { $0 + max($1.before.split(separator: " ").count, 1) }
        }
        var lines: [String] = []
        lines.append("\(records.count) dictations watched; \(changed.count) needed a fix "
                     + "(\(Int((100 * Double(changed.count) / Double(records.count)).rounded()))%).")
        lines.append("Words changed: \(changedWords) of \(pastedWords) "
                     + "(\(String(format: "%.1f", 100 * Double(changedWords) / Double(max(pastedWords, 1))))%).")
        // Where a changed word first went wrong.
        var fromRecognizer = 0, afterRecognizer = 0
        for record in records {
            let rawWords = Set(record.raw.lowercased().split(whereSeparator: \.isWhitespace)
                .map { $0.filter { $0.isLetter || $0.isNumber } })
            for change in record.changes where !change.before.isEmpty {
                let beforeKeys = change.before.lowercased().split(separator: " ").map { $0.filter { $0.isLetter || $0.isNumber } }
                if beforeKeys.allSatisfy({ rawWords.contains($0) }) { fromRecognizer += 1 } else { afterRecognizer += 1 }
            }
        }
        lines.append("Changed words that were already in the recognizer's own text: \(fromRecognizer); "
                     + "ones Murmur's later steps wrote: \(afterRecognizer).")
        var counts: [String: Int] = [:]
        for record in changed {
            for change in record.changes { counts["\(change.before)  →  \(change.after)", default: 0] += 1 }
        }
        lines.append("Most common changes:")
        for (change, count) in counts.sorted(by: { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }).prefix(15) {
            lines.append("  \(count)×  \(change)")
        }
        var byApp: [String: (total: Int, changed: Int)] = [:]
        for record in records {
            var entry = byApp[record.app, default: (0, 0)]
            entry.total += 1
            if !record.changes.isEmpty { entry.changed += 1 }
            byApp[record.app] = entry
        }
        lines.append("By app:")
        for (app, entry) in byApp.sorted(by: { $0.value.total > $1.value.total }).prefix(8) {
            lines.append("  \(app): \(entry.changed) of \(entry.total) needed a fix")
        }
        return lines.joined(separator: "\n")
    }

    static func runSelfTest() -> Bool {
        var passed = true
        func check(_ ok: Bool, _ label: String) {
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): edit records: \(label)")
        }
        let swapped = changes(from: "Yeah, the last fix is not working.", to: "Yeah, the last fix is now working.")
        check(swapped == [EditRecord.Change(before: "not", after: "now")], "a swapped word is one change (got \(swapped))")
        check(changes(from: "So that means.", to: "so that means") .isEmpty, "case and punctuation alone are not changes")
        let longer = changes(from: "I have to go to the bar for it to close so that means.",
                             to: "I have to go to the bar for it to close so that needs fixed.")
        check(longer == [EditRecord.Change(before: "means.", after: "needs fixed.")],
              "several words replace one, as one change (got \(longer))")
        let inserted = changes(from: "send it to Anna", to: "send it to Anna and Ben")
        check(inserted == [EditRecord.Change(before: "", after: "and Ben")], "words added are a change with nothing before")
        let deleted = changes(from: "well I think so", to: "I think so")
        check(deleted == [EditRecord.Change(before: "well", after: "")], "words removed are a change with nothing after")
        let two = changes(from: "the Manrog font is not working", to: "the Manrope font is now working")
        check(two.count == 2 && two[0].after == "Manrope" && two[1].after == "now", "two separate fixes stay two changes")
        let record = EditRecord(date: Date(), app: "com.openai.codex", engine: "whispercpp", model: "large-v3", raw: "the manrog font",
                                pasted: "The Manrog font.", final: "The Manrope font.", changes: two, endReason: "sent", learned: 1)
        check(summary(of: [record]).contains("1 dictations watched") && summary(of: []).contains("No edit records"),
              "the summary counts what was watched")
        return passed
    }
}
