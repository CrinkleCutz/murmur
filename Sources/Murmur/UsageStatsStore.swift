import Foundation

/// One day's dictation totals — counts only, never text.
struct DailyUsage: Codable, Equatable {
    var date: Date
    var dictations = 0
    var words = 0
    /// Words and seconds from dictations whose recording length is known —
    /// kept apart from `words` so a speaking pace (words ÷ minutes) never
    /// mixes timed and untimed dictations.
    var timedWords = 0
    var seconds: Double = 0
    /// Words per target app (bundle ID) — what Insights' Top apps and
    /// Usage by category read for any range. Optional only so a file
    /// written before this field existed still decodes.
    var appWords: [String: Int]? = [:]
}

/// Lifetime usage, one small record per day, kept indefinitely.
///
/// `HistoryStore` keeps full transcripts but only the latest 5,000 or 90 days
/// (it was 500 / 30 — under two weeks for a heavy user), so any total
/// counted from it stops growing at the cap and any comparison reaching
/// past it silently loses data. A day here is a few numbers, so a year
/// costs a few kilobytes; this is what Insights' totals, trends and chart
/// and Home's streak read instead. Same
/// shape as `PipelineStatsStore`, minus its retention window.
final class UsageStatsStore {
    private(set) var days: [DailyUsage] = []
    private var fileURL: URL {
        AppPaths.supportDirectory.appendingPathComponent("usage_stats.json")
    }

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([DailyUsage].self, from: data) {
            days = saved
        }
    }

    /// First launch with this store: start from whatever history still
    /// holds. Anything the history cap already dropped is gone for good —
    /// from here on nothing is. Also rebuilds a file from before
    /// `appWords` existed (no day has it): everything such a file holds
    /// came from this same history plus dictations history also kept, so
    /// rebuilding loses nothing and fills in the per-app words.
    func seedIfEmpty(from entries: [HistoryEntry]) {
        let predatesAppWords = !days.isEmpty && days.allSatisfy { $0.appWords == nil }
        guard days.isEmpty || predatesAppWords, !entries.isEmpty else { return }
        days = []
        for entry in entries {
            add(entry.wordCount, duration: entry.duration, bundleID: entry.targetBundleID, on: entry.date)
        }
        save()
    }

    func record(words: Int, duration: TimeInterval?, bundleID: String?) {
        add(words, duration: duration, bundleID: bundleID, on: Date())
        save()
    }

    /// The first day anything was recorded — where "All" starts, and the
    /// point before which the chart has no data (rather than zero words).
    var firstDay: Date? { days.map(\.date).min() }

    /// Every recorded day from `start` (a day's start) through today.
    func days(from start: Date) -> [DailyUsage] {
        days.filter { $0.date >= start }
    }

    var lifetimeDictations: Int { days.reduce(0) { $0 + $1.dictations } }
    var lifetimeWords: Int { days.reduce(0) { $0 + $1.words } }

    /// The record for one calendar day (zeroes if nothing was dictated).
    func day(_ date: Date) -> DailyUsage {
        days.first { Calendar.current.isDate($0.date, inSameDayAs: date) }
            ?? DailyUsage(date: Calendar.current.startOfDay(for: date))
    }

    private func add(_ words: Int, duration: TimeInterval?, bundleID: String?, on date: Date) {
        let start = Calendar.current.startOfDay(for: date)
        let index = days.firstIndex { $0.date == start } ?? {
            days.append(DailyUsage(date: start))
            return days.count - 1
        }()
        days[index].dictations += 1
        days[index].words += words
        // Over a second only — a sub-second blip would imply an absurd pace.
        if let duration, duration > 1 {
            days[index].timedWords += words
            days[index].seconds += duration
        }
        if let bundleID {
            days[index].appWords = (days[index].appWords ?? [:]).merging([bundleID: words], uniquingKeysWith: +)
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(days) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
