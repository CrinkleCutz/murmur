import Foundation

/// One day's tally of automatic corrections — feeds Insights' "Fixes made
/// by Murmur" card. Deliberately just counts, not the corrections
/// themselves: unlike `HistoryEntry` or `LearnedCorrection`, there's no
/// reason to keep the actual before/after text around once the day's total
/// is recorded.
struct DailyPipelineStats: Codable {
    var date: Date
    var harperFixes: Int = 0
    var dictionaryFixes: Int = 0
    var snippetExpansions: Int = 0
}

/// Persists daily counts of what each pipeline stage actually changed.
/// Populated from `AppDelegate.stopAndTranscribe()`'s own before/after
/// snapshots of `formatted` at each stage — this store only tallies what
/// it's handed, it doesn't call into Harper/LearnedStore/SnippetStore
/// itself.
final class PipelineStatsStore {
    private(set) var days: [DailyPipelineStats] = []
    // Kept indefinitely (it used to prune at 180 days): a day here is three
    // integers, and Insights' "All" range should mean all.
    private var fileURL: URL {
        AppPaths.supportDirectory.appendingPathComponent("pipeline_stats.json")
    }

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([DailyPipelineStats].self, from: data) {
            days = saved
        }
    }

    /// Adds today's counts, merging into an existing entry for today if
    /// `stopAndTranscribe` already recorded something earlier today. A
    /// no-op call (everything zero — the common case, most dictations
    /// trigger no corrections at all) never touches disk.
    func record(harperFixes: Int, dictionaryFixes: Int, snippetExpansions: Int) {
        guard harperFixes > 0 || dictionaryFixes > 0 || snippetExpansions > 0 else { return }
        let today = Calendar.current.startOfDay(for: Date())
        if let index = days.firstIndex(where: { Calendar.current.isDate($0.date, inSameDayAs: today) }) {
            days[index].harperFixes += harperFixes
            days[index].dictionaryFixes += dictionaryFixes
            days[index].snippetExpansions += snippetExpansions
        } else {
            days.append(DailyPipelineStats(
                date: today, harperFixes: harperFixes, dictionaryFixes: dictionaryFixes,
                snippetExpansions: snippetExpansions))
        }
        save()
    }

    /// Summed counts from `start` (a day's start) through today — what
    /// Insights' "Fixes made by Murmur" card reads for its selected range.
    func totals(from start: Date) -> DailyPipelineStats {
        let inRange = days.filter { $0.date >= start }
        return DailyPipelineStats(
            date: Date(),
            harperFixes: inRange.reduce(0) { $0 + $1.harperFixes },
            dictionaryFixes: inRange.reduce(0) { $0 + $1.dictionaryFixes },
            snippetExpansions: inRange.reduce(0) { $0 + $1.snippetExpansions })
    }

    private func save() {
        if let data = try? JSONEncoder().encode(days) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

/// Pure helpers for turning a pipeline stage's before/after text into a
/// rough count, kept independent of any one store or call site.
enum PipelineDiff {
    /// A rough count of how many word *positions* differ between two
    /// strings — not a true edit distance, just "how many words did this
    /// stage touch." That's the right granularity for a stats tally
    /// (Harper and the Dictionary both substitute word-for-word almost
    /// always) and, critically, this only ever *reads* the before/after
    /// text a call site already has — it doesn't change what either stage
    /// does or re-run any correction logic itself.
    static func wordChangeCount(from before: String, to after: String) -> Int {
        guard before != after else { return 0 }
        let beforeWords = before.split(whereSeparator: { $0.isWhitespace })
        let afterWords = after.split(whereSeparator: { $0.isWhitespace })
        let overlap = min(beforeWords.count, afterWords.count)
        var changed = abs(beforeWords.count - afterWords.count)
        for i in 0..<overlap where beforeWords[i] != afterWords[i] { changed += 1 }
        return changed
    }
}
