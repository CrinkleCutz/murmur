import Foundation

struct HistoryEntry: Codable, Identifiable, Equatable {
    let text: String
    let date: Date
    /// Length of the recording, if known. Used for words-per-minute stats.
    var duration: TimeInterval?
    /// The frontmost app when this dictation started, if known. Optional
    /// with a default so entries saved before this field existed still
    /// decode fine — they just carry no app association, same as one
    /// recorded with no frontmost app resolvable (e.g. focus lost mid-hold).
    var targetBundleID: String? = nil

    var id: String { "\(date.timeIntervalSince1970)-\(text.hashValue)" }

    var wordCount: Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
}

/// Persists the most recent transcripts, like Wispr Flow's history panel.
final class HistoryStore {
    private(set) var entries: [HistoryEntry] = []
    /// Bounded on two axes, whichever is hit first. Pure day-based
    /// retention has no ceiling for a heavy user — dozens of short
    /// dictations a day adds up fast — and a pure count cap doesn't
    /// guarantee any particular time range is actually available, which is
    /// what Home's day-grouped history list needs to be useful rather than
    /// just "however many entries happened to fit."
    ///
    /// 90 days / 5,000 (was 30 / 500, which a heavy user filled in under two
    /// weeks): this is everything Ask Murmur can answer from, so it should
    /// reach back months, not days. Transcripts are small — 5,000 is about
    /// a megabyte. Lifetime counts don't depend on it (`UsageStatsStore`).
    private let retentionDays = 90
    private let maxEntries = 5_000
    private var fileURL: URL {
        AppPaths.supportDirectory.appendingPathComponent("history.json")
    }

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = saved
            // Entries can age past the retention window purely from time
            // passing, with no new dictation to trigger a prune — catch
            // that here too, not just in `add()`, so a file from before a
            // long gap doesn't linger unpruned indefinitely.
            prune()
            save()
        }
    }

    func add(_ text: String, duration: TimeInterval? = nil, targetBundleID: String? = nil) {
        entries.insert(
            HistoryEntry(text: text, date: Date(), duration: duration, targetBundleID: targetBundleID),
            at: 0)
        prune()
        save()
    }

    private func prune() {
        if let cutoff = Calendar.current.date(
            byAdding: .day, value: -retentionDays, to: Date()) {
            entries.removeAll { $0.date < cutoff }
        }
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
    }

    func delete(id: String) {
        entries.removeAll { $0.id == id }
        save()
    }

    func update(id: String, text: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index] = HistoryEntry(
            text: text, date: entries[index].date, duration: entries[index].duration,
            targetBundleID: entries[index].targetBundleID)
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Case-insensitive substring match, shared by Home's search field and
    /// the `--history-search` CLI mode. An empty query returns everything.
    static func matching(_ query: String, in entries: [HistoryEntry]) -> [HistoryEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return entries }
        return entries.filter { $0.text.localizedCaseInsensitiveContains(trimmed) }
    }
}
