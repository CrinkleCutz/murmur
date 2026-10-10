import AppKit
import SwiftUI

// MARK: - Insights
//
// Redesigned per the "Main" canvas (Insights.dc.html): same `GlassPanelPage`
// shell as Home, warm ink/sunset palette instead of the shared dynamic
// `Palette`. The line-chart math (monotone interpolation, hover crosshair)
// is untouched — this is a View-layer rewrite only.
//
// The design replaced the old saturated bar chart with a line + soft area
// wash (the dataviz rule: "trend over time" is a line, not bars), a 2.5px
// stroke, recessive hairline gridlines and a hover crosshair. The value
// readout (today's, or the hovered day's) sits in the card header, not on
// the plot: the design's direct end-label and a floating tooltip both got
// crossed by the curve whenever it moved steeply next to them.

struct InsightsPage: View {
    @ObservedObject var app: AppDelegate
    @State private var hoverIndex: Int?
    @State private var chartMetric: ChartMetric = .words
    /// Scopes the whole Usage tab, not just the chart — remembered, so
    /// Insights reopens on the range it was left on.
    @AppStorage("insightsRange") private var chartRange: ChartRange = .month
    @State private var tab: InsightsTab = .usage

    enum InsightsTab: CaseIterable {
        case usage, voice
        var label: String {
            switch self {
            case .usage: return "Your usage"
            case .voice: return "Your voice"
            }
        }
    }

    enum ChartMetric: CaseIterable {
        case words, wpm
        var label: String {
            switch self {
            case .words: return "Words"
            case .wpm: return "Pace (wpm)"
            }
        }
    }

    enum ChartRange: String, CaseIterable {
        case week, month, all
        var label: String {
            switch self {
            case .week: return "7D"
            case .month: return "30D"
            case .all: return "All"
            }
        }
    }

    var body: some View {
        GlassPanelPage {
            // A third card (Top apps) can now push the page taller than a
            // short window — this used to be a bare `VStack`, fine when the
            // chart card was the last thing on the page and just stretched
            // to fill whatever was left. `ThinScrollView` matches Home's own
            // choice for the same reason: content that can now exceed the
            // visible height needs to be reachable, not just clipped.
            ThinScrollView(bottomInset: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    header

                    if app.entries.isEmpty {
                        // Replaces the whole strip + chart rather than
                        // showing four zeroes and a flat line at zero —
                        // `emptyState` matches Home's own (HomeView.swift's
                        // own function of the same name), the one other
                        // page with this problem.
                        emptyState.padding(.top, 24)
                    } else {
                        tabBar.padding(.top, InsightsPage.sectionGap)

                        switch tab {
                        case .usage: usageTab
                        case .voice: voiceTab
                        }
                    }
                }
            }
        }
    }

    /// Underlined text tabs, deliberately not another
    /// `WarmSegmentedPicker` pill — the chart card already has two of
    /// those for its own in-card options (metric, range); a third pill
    /// control at the page level would read as one more of the same thing
    /// rather than the page's own top-level navigation.
    private var tabBar: some View {
        HStack(spacing: 20) {
            ForEach(InsightsTab.allCases, id: \.self) { candidate in
                Button {
                    tab = candidate
                } label: {
                    Text(candidate.label)
                        .font(.manrope(13.5, .semibold))
                        .foregroundStyle(tab == candidate ? Palette.warmInk : Palette.warmInkFaint)
                        .padding(.bottom, 10)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(tab == candidate ? Palette.sunsetDeep : .clear)
                                .frame(height: 2)
                        }
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            // The one period control for everything on the Usage tab —
            // here at the page level rather than inside the chart card,
            // where it read as scoping that card alone. Nothing on the
            // Voice tab depends on a range, so it steps aside there.
            if tab == .usage {
                WarmSegmentedPicker(options: ChartRange.allCases, label: \.label, selection: $chartRange)
                    .padding(.bottom, 8)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.warmDivider).frame(height: 1)
        }
    }

    private var usageTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            // `.pcard flat stat-row`: a flat strip on the pane with
            // hairline dividers — no card fill, not three boxed cards.
            Card(flat: true) {
                HStack(alignment: .top, spacing: 0) {
                    statTile(.lines, rangeTotals.dictations.formatted(), "dictations",
                             trend: dictationsTrend, isFirst: true)
                    statTile(.wave, compact(rangeTotals.words), "words",
                             trend: wordsTrend, isFirst: false)
                    statTile(.calendar, avgWords, "avg words / dictation",
                             trend: nil, isFirst: false)
                    statTile(.clock, timeSavedLabel, "time saved",
                             trend: nil, isFirst: false)
                }
                // Every tile takes the tallest one's height, so the
                // dividers run the full strip even beside a tile with no
                // "vs last week" line.
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, Self.sectionGap)

            chartCard
                .padding(.top, Self.sectionGap)

            // Both cards end on the same line — the shorter one stretches
            // to the taller one's natural height (`fixedSize` keeps that
            // bounded inside the scroll view).
            HStack(alignment: .top, spacing: 20) {
                fixesCard
                categoryCard
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, Self.sectionGap)

            topAppsCard
                .padding(.top, Self.sectionGap)
        }
    }

    /// The one vertical gap between every section on the page — tabs,
    /// stat strip, chart, card rows — instead of the 20/22/26/16 mix it
    /// had grown into.
    static let sectionGap: CGFloat = 24

    private var voiceTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            personaCard
                .padding(.top, Self.sectionGap)
            factsCard
                .padding(.top, Self.sectionGap)
        }
    }

    private var emptyState: some View {
        Text("No dictations yet — once you've spoken a few things, your word-count "
             + "trend, speaking pace, and time saved will show up here.")
            .font(.manrope(12.5))
            .italic()
            .foregroundStyle(Palette.warmInkFaint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .background(Palette.warmRowBorder, in: RoundedRectangle(cornerRadius: Radius.lg))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Insights")
                .font(.manrope(22, .medium))
                .tracking(-0.33)
                .foregroundStyle(Palette.warmInk)
            Text("How your dictation is trending.")
                .font(.manrope(12.5))
                .foregroundStyle(Palette.warmInkFaint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(chartMetric == .words ? "Words dictated" : "Speaking pace")
                .font(.manrope(13, .semibold))
                .foregroundStyle(Palette.warmInk)
            HStack(alignment: .center, spacing: 12) {
                chartReadout
                Spacer(minLength: 12)
                WarmSegmentedPicker(options: ChartMetric.allCases, label: \.label, selection: $chartMetric)
            }
            .padding(.top, 4)
            TrendChart(points: chartPoints, knownFrom: chartKnownFrom, hoverIndex: $hoverIndex)
                .padding(.top, 14)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        // `maxHeight: .infinity` (stretch to fill the page) made sense
        // when this was the last, only element below the stat strip — now
        // that `topAppsCard` sits below it and the whole thing scrolls,
        // this needs its own natural height instead: inside a
        // `ScrollView`, an unbounded height proposal plus `maxHeight:
        // .infinity` is exactly the "expands to fill nothing in
        // particular" shape that produced HomeView's row-menu stretch bug.
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onChange(of: chartMetric) { _, _ in hoverIndex = nil }
        .onChange(of: chartRange) { _, _ in hoverIndex = nil }
        // No drop shadow, by request (same call as Scratchpad's editor
        // card and Ask Murmur's composer) — it read as an odd smear along
        // the bottom edge sitting on the frosted glass panel.
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// Today's value, or the hovered day's — the chart's one number, kept
    /// in the header (as Health and Stocks do) rather than drawn on the
    /// plot, where the curve could run straight through it whenever it
    /// fell or rose steeply next to the label.
    private var chartReadout: some View {
        let points = chartPoints
        let index = hoverIndex.flatMap { points.indices.contains($0) ? $0 : nil } ?? points.indices.last
        let unit = chartMetric == .words ? "words" : "wpm"
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text((index.map { points[$0].value } ?? 0).formatted())
                .font(.manrope(27))
                .tracking(-0.54)
                .monospacedDigit()
                .foregroundStyle(Palette.warmInk)
            Text(hoverIndex == nil || index == nil ? "\(unit) today" : "\(unit) on \(points[index!].label)")
                .font(.manrope(11.5))
                .foregroundStyle(Palette.warmInkFaint)
        }
    }

    private var topAppsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .lastTextBaseline) {
                Text("Top apps")
                    .font(.manrope(13, .semibold))
                    .foregroundStyle(Palette.warmInk)
                Spacer()
                Text("\(periodLabel) · by words")
                    .font(.manrope(11.5))
                    .foregroundStyle(Palette.warmInkFaint)
            }
            if topApps.isEmpty {
                // Every entry recorded before this shipped has no
                // `targetBundleID` at all (see `HistoryEntry`) — this
                // fills in as new dictations happen, not retroactively.
                Text("Not enough data yet — this fills in as you keep dictating.")
                    .font(.manrope(12.5))
                    .italic()
                    .foregroundStyle(Palette.warmInkFaint)
                    .padding(.top, 16)
            } else {
                VStack(spacing: 0) {
                    let maxWords = topApps.first?.words ?? 1
                    ForEach(Array(topApps.enumerated()), id: \.element.id) { index, usage in
                        AppUsageRow(usage: usage, maxWords: maxWords, isFirst: index == 0)
                    }
                }
                .padding(.top, 14)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// Counts read from `PipelineStatsStore` — see that type's own header
    /// for why these are plain before/after tallies taken at each pipeline
    /// stage's existing call site, not a change to what any of the three
    /// stages (Harper, the Dictionary, Snippets) actually do.
    private var fixesCard: some View {
        let stats = app.pipelineStats.totals(from: rangeStart)
        let total = stats.harperFixes + stats.dictionaryFixes + stats.snippetExpansions
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .lastTextBaseline) {
                Text("Fixes made by Murmur")
                    .font(.manrope(13, .semibold))
                    .foregroundStyle(Palette.warmInk)
                Spacer()
                Text(periodLabel)
                    .font(.manrope(11.5))
                    .foregroundStyle(Palette.warmInkFaint)
            }
            if total == 0 {
                Text("Nothing to show yet — this fills in as Harper, your Dictionary, "
                     + "and Snippets catch things in new dictations.")
                    .font(.manrope(12.5))
                    .italic()
                    .foregroundStyle(Palette.warmInkFaint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(total)")
                        .font(.manrope(27))
                        .tracking(-0.5)
                        .foregroundStyle(Palette.warmInk)
                    Text("fixes")
                        .font(.manrope(11.5))
                        .foregroundStyle(Palette.warmInkFaint)
                }
                .padding(.top, 10)
                let maxFix = max(stats.harperFixes, stats.dictionaryFixes, stats.snippetExpansions, 1)
                VStack(spacing: 0) {
                    UsageBarRow(icon: .check, name: "Words corrected", detail: "Harper grammar",
                                value: stats.harperFixes, maxValue: maxFix,
                                figureText: "\(stats.harperFixes)", isFirst: true)
                    UsageBarRow(icon: .tpl, name: "Dictionary corrections", detail: nil,
                                value: stats.dictionaryFixes, maxValue: maxFix,
                                figureText: "\(stats.dictionaryFixes)", isFirst: false)
                    UsageBarRow(icon: .trans, name: "Snippets expanded", detail: nil,
                                value: stats.snippetExpansions, maxValue: maxFix,
                                figureText: "\(stats.snippetExpansions)", isFirst: false)
                }
                .padding(.top, 14)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// Not a literal copy of Wispr Flow's own category set — see
    /// `UsageCategory`'s own header for why this app leans toward
    /// Code editors/AI assistants over their Documents/Work-messages split.
    private var categoryCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .lastTextBaseline) {
                Text("Usage by category")
                    .font(.manrope(13, .semibold))
                    .foregroundStyle(Palette.warmInk)
                Spacer()
                Text(periodLabel)
                    .font(.manrope(11.5))
                    .foregroundStyle(Palette.warmInkFaint)
            }
            if categoryUsage.isEmpty {
                Text("Not enough data yet — this fills in as you keep dictating.")
                    .font(.manrope(12.5))
                    .italic()
                    .foregroundStyle(Palette.warmInkFaint)
                    .padding(.top, 16)
            } else {
                let total = categoryUsage.reduce(0) { $0 + $1.words }
                let maxWords = categoryUsage.first?.words ?? 1
                VStack(spacing: 0) {
                    ForEach(Array(categoryUsage.enumerated()), id: \.element.category) { index, usage in
                        let percent = total > 0 ? Int((Double(usage.words) / Double(total) * 100).rounded()) : 0
                        UsageBarRow(icon: usage.category.icon, name: usage.category.rawValue, detail: nil,
                                    value: usage.words, maxValue: maxWords,
                                    figureText: "\(percent)%", isFirst: index == 0)
                    }
                }
                .padding(.top, 14)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// The shared persona card (VoicePersonaCard.swift) — the same one the
    /// Voice Profile page shows, so one persona has one design.
    private var personaCard: some View {
        VoicePersonaCard(app: app)
    }

    /// Catchphrase, most-used and most-corrected words, and peak time —
    /// real, computed facts, as four cards in the same language as the
    /// Usage tab's (card title, a note in the corner, the value at the
    /// stat-number size) instead of a settings-style list with the values
    /// pushed 700pt away from their labels.
    private var factsCard: some View {
        let catchphrase = catchphrase
        let mostUsed = mostUsedWord
        let mostCorrected = mostCorrectedWord
        let peak = peakTime
        return VStack(spacing: 20) {
            HStack(alignment: .top, spacing: 20) {
                factCard("Catchphrase",
                         note: catchphrase.map { "said \($0.count) times" },
                         value: catchphrase.map { "“\($0.phrase)”" })
                factCard("Most used word",
                         note: mostUsed.map { "\($0.count) times" },
                         value: mostUsed.map { "“\($0.word)”" })
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 20) {
                factCard("Most corrected word",
                         note: mostCorrected.map { $0.times == 1 ? "taught once" : "taught \($0.times) times" },
                         value: mostCorrected?.word)
                factCard("Peak time",
                         note: peak.map { "\($0.count) dictations" },
                         value: peak?.when) {
                    if let app = peak?.app {
                        HStack(spacing: 7) {
                            if let icon = app.icon {
                                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                            }
                            Text("usually in \(app.name)")
                                .font(.manrope(12))
                                .foregroundStyle(Palette.warmInkSoft)
                        }
                        .padding(.top, 8)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func factCard(
        _ title: String, note: String?, value: String?,
        @ViewBuilder extra: () -> some View = { EmptyView() }
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .lastTextBaseline) {
                Text(title)
                    .font(.manrope(13, .semibold))
                    .foregroundStyle(Palette.warmInk)
                Spacer()
                if let note {
                    Text(note)
                        .font(.manrope(11.5))
                        .foregroundStyle(Palette.warmInkFaint)
                }
            }
            if let value {
                Text(value)
                    .font(.manrope(27))
                    .tracking(-0.54)
                    .foregroundStyle(Palette.warmInk)
                    .lineLimit(2)
                    .padding(.top, 14)
                extra()
            } else {
                Text("Not enough data yet")
                    .font(.manrope(12.5))
                    .italic()
                    .foregroundStyle(Palette.warmInkFaint)
                    .padding(.top, 14)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func statTile(
        _ icon: MurmurIcon, _ value: String, _ label: String,
        trend: String?, isFirst: Bool
    ) -> some View {
        // The divider is an *overlay*, not a layout sibling. A bare
        // `Rectangle` with only a width set expands to whatever height is
        // offered, so as a sibling it competed with the chart for free
        // vertical space and stretched this whole strip. As an overlay it
        // paints inside the tile's content-derived height and can never
        // influence layout.
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.manrope(27))
                .tracking(-0.54)
                .foregroundStyle(Palette.warmInk)
            HStack(spacing: 5) {
                MurmurIconView(icon: icon)
                    .frame(width: 12, height: 12)
                    .foregroundStyle(Palette.warmInkFaint)
                Text(label)
                    .font(.manrope(11.5))
                    .foregroundStyle(Palette.warmInkFaint)
            }
            .padding(.top, 4)
            // Every tile states its period on its third line — the trend
            // when there's an earlier period to compare against, otherwise
            // the period itself — so all four read as the same range and
            // stay the same height.
            Group {
                if let trend {
                    HStack(spacing: 4) {
                        MurmurIconView(icon: .arrowRight)
                            .frame(width: 10, height: 10)
                            .rotationEffect(.degrees(-45))
                        Text(trend).font(.manrope(12, .semibold))
                    }
                    .foregroundStyle(Palette.sunsetDeep)
                } else {
                    Text(periodLabel)
                        .font(.manrope(12))
                        .foregroundStyle(Palette.warmInkFainter)
                }
            }
            .padding(.top, 6)
        }
        .padding(.trailing, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.leading, isFirst ? 0 : 20)
        .overlay(alignment: .leading) {
            // Sits exactly on the tile boundary (outside this tile's own
            // 20pt leading inset), the same seam `.stat-row > div` draws it
            // on in the design.
            if !isFirst {
                Rectangle().fill(Palette.warmDivider).frame(width: 1)
                    .padding(.leading, -20)
            }
        }
    }

    // MARK: Derived data

    // Everything on the Usage tab reads one range (`chartRange`) from
    // `UsageStatsStore`'s lifetime daily totals — never `app.entries`,
    // which only holds the latest 5,000 dictations / 90 days.

    /// The first day in the selected range. "All" starts at the first day
    /// the store has anything for.
    private var rangeStart: Date {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        switch chartRange {
        case .week: return calendar.date(byAdding: .day, value: -6, to: today)!
        case .month: return calendar.date(byAdding: .day, value: -29, to: today)!
        case .all: return app.usageStats.firstDay ?? today
        }
    }

    /// What every card says its numbers cover.
    private var periodLabel: String {
        switch chartRange {
        case .week: return "last 7 days"
        case .month: return "last 30 days"
        case .all:
            guard let first = app.usageStats.firstDay else { return "all time" }
            return "since \(first.formatted(.dateTime.day().month(.abbreviated)))"
        }
    }

    private var rangeDays: [DailyUsage] { app.usageStats.days(from: rangeStart) }

    private var rangeTotals: (dictations: Int, words: Int, seconds: Double) {
        rangeDays.reduce((0, 0, 0)) { ($0.0 + $1.dictations, $0.1 + $1.words, $0.2 + $1.seconds) }
    }

    private var avgWords: String {
        let totals = rangeTotals
        return totals.dictations == 0 ? "—" : "\(totals.words / totals.dictations)"
    }

    private func compact(_ number: Int) -> String {
        number >= 1000 ? String(format: "%.1fK", Double(number) / 1000) : "\(number)"
    }

    /// Days the chart spans: a fixed 7 or 30, or every day since the first
    /// recorded one for "All" (at least a week, so a new user's chart isn't
    /// two points). `TrendChart` thins its x-axis labels as this grows.
    private var chartDayCount: Int {
        switch chartRange {
        case .week: return 7
        case .month: return 30
        case .all:
            let calendar = Calendar.current
            let days = calendar.dateComponents(
                [.day], from: rangeStart, to: calendar.startOfDay(for: Date())
            ).day ?? 0
            return max(days + 1, 7)
        }
    }

    private var chartPoints: [(label: String, value: Int)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<chartDayCount).reversed().map { offset in
            let day = calendar.date(byAdding: .day, value: -offset, to: today)!
            let usage = app.usageStats.day(day)
            let value = chartMetric == .words
                ? usage.words
                : (usage.seconds > 0 ? Int(Double(usage.timedWords) / (usage.seconds / 60)) : 0)
            return (day.formatted(.dateTime.day().month(.abbreviated)), value)
        }
    }

    /// Index of the first chart day Murmur has any record for. Days before
    /// it aren't days with zero words — they're days it knows nothing
    /// about — so the chart doesn't draw them at all.
    private var chartKnownFrom: Int {
        guard let first = app.usageStats.firstDay else { return 0 }
        let calendar = Calendar.current
        let firstPlotted = calendar.date(byAdding: .day, value: -(chartDayCount - 1), to: calendar.startOfDay(for: Date()))!
        let gap = calendar.dateComponents([.day], from: firstPlotted, to: first).day ?? 0
        return min(max(gap, 0), chartDayCount - 1)
    }

    /// A commonly-cited average typing speed, so the gap between it and
    /// the measured dictation time reads as time actually saved — not just
    /// another word count restated as minutes.
    private static let assumedTypingWPM: Double = 40

    private var timeSavedLabel: String {
        let totals = rangeTotals
        guard totals.words > 0 else { return "—" }
        let typingMinutes = Double(totals.words) / Self.assumedTypingWPM
        let savedMinutes = max(0, typingMinutes - totals.seconds / 60)
        guard savedMinutes >= 1 else { return "< 1 min" }
        return savedMinutes >= 60
            ? String(format: "%.1f hrs", savedMinutes / 60)
            : "\(Int(savedMinutes.rounded())) min"
    }

    /// Notetaker's notes in the selected range — counted alongside
    /// dictations in `topApps`/`categoryUsage` so a meeting's words count
    /// toward the same app/category totals a dictation's do.
    private var rangeMeetings: [MeetingNote] {
        guard Notetaker.isAvailable else { return [] }
        return app.notetaker.notes.filter { $0.date >= rangeStart }
    }

    /// Words per app over the selected range: dictations (from the daily
    /// store's `appWords`) plus Notetaker notes.
    private var rangeAppWords: [String: Int] {
        var words: [String: Int] = [:]
        for day in rangeDays {
            words.merge(day.appWords ?? [:], uniquingKeysWith: +)
        }
        for note in rangeMeetings {
            guard let bundleID = note.appBundleID else { continue }
            words[bundleID, default: 0] += note.wordCount
        }
        return words
    }

    /// One row of `topAppsCard` — the app's real name and icon, resolved
    /// from the bundle ID recorded at dictation time (`AppDelegate`'s own
    /// `recordingTargetBundleID`, threaded through `HistoryEntry` since
    /// this card needed it and nothing was persisting it before).
    struct AppUsage: Identifiable {
        let bundleID: String
        let name: String
        let icon: NSImage?
        let words: Int
        var id: String { bundleID }
    }

    /// Resolves via the *installed* app, not the running-apps list
    /// `AppProfilesView`'s own picker uses — a dictation's target app may
    /// well have quit by the time this page is looked at.
    private func resolveApp(bundleID: String) -> (name: String, icon: NSImage?) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return (bundleID, nil)
        }
        let name = FileManager.default.displayName(atPath: url.path)
        return (name, NSWorkspace.shared.icon(forFile: url.path))
    }

    private var topApps: [AppUsage] {
        rangeAppWords
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map { bundleID, words in
                let resolved = resolveApp(bundleID: bundleID)
                return AppUsage(bundleID: bundleID, name: resolved.name, icon: resolved.icon, words: words)
            }
    }

    /// The range's words grouped by `UsageCategory`, highest first.
    /// Dictations with no recorded target app aren't in `appWords` at all
    /// rather than folded into `.other` — "we don't know what app this
    /// was" and "we know the app but not its category" are different
    /// things, and only the second one is what `.other` means.
    private var categoryUsage: [(category: UsageCategory, words: Int)] {
        var totals: [UsageCategory: Int] = [:]
        for (bundleID, words) in rangeAppWords {
            totals[AppCategoryClassifier.category(forBundleID: bundleID), default: 0] += words
        }
        return totals.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }

    // MARK: Your voice

    /// Function words and spoken filler, for the single most used word. The old list stopped at the most
    /// basic function words, so the "most used word" came out as "how" and
    /// "like" — true, but it says nothing about the person.
    private static let wordCatalogStopWords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "in", "on", "at", "to", "for",
        "of", "is", "are", "was", "were", "what", "when", "where", "who",
        "did", "do", "does", "i", "my", "me", "this", "that", "with",
        "about", "have", "has", "had", "you", "your", "it", "be", "been",
        "so", "just", "can", "will", "would", "there", "here", "we", "us",
        "how", "why", "which", "like", "also", "then", "than", "them", "they",
        "their", "these", "those", "some", "any", "all", "from", "into", "out",
        "not", "no", "yes", "yeah", "okay", "ok", "um", "uh", "well", "now",
        "get", "got", "make", "made", "need", "want", "see", "look", "know",
        "think", "should", "could", "one", "more", "very", "really", "much",
        "its", "it's", "i'm", "don't", "doesn't", "that's", "there's", "let's",
        "can't", "i've", "i'll", "i'd", "you're", "we're", "he", "she", "his",
        "her", "our", "if", "as", "by", "up", "down", "again", "other", "same",
    ]

    /// Only the basic function words — for catchphrases, where a phrase
    /// like "we need to" *is* how someone talks, even though each of its
    /// words alone is filler.
    private static let phraseStopWords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "in", "on", "at", "to", "for",
        "of", "is", "are", "was", "were", "what", "when", "where", "who",
        "did", "do", "does", "i", "my", "me", "this", "that", "with",
        "about", "have", "has", "had", "you", "your", "it", "be", "been",
        "so", "just", "can", "will", "would", "there", "here", "we", "us",
    ]

    /// Lowercased words with apostrophes kept inside them — splitting on
    /// every non-letter turned "don't" into "don" + "t", so a catchphrase
    /// could read "i don t". Curly apostrophes are normalised first.
    private func words(in text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
    }

    /// A lowercased phrase as it should read: "I", "I'm", "I've"…
    /// capitalised, everything else as said.
    private func displayPhrase(_ words: [String]) -> String {
        words.map { $0 == "i" || $0.hasPrefix("i'") ? "I" + $0.dropFirst() : $0 }
            .joined(separator: " ")
    }

    /// The single word (stopwords aside) said most often across all of
    /// History — a plain frequency count, no AI involved.
    private var mostUsedWord: (word: String, count: Int)? {
        var counts: [String: Int] = [:]
        for entry in app.entries {
            for word in words(in: entry.text) where word.count > 2 && !Self.wordCatalogStopWords.contains(word) {
                counts[word, default: 0] += 1
            }
        }
        return counts.max(by: { $0.value < $1.value }).map { ($0.key, $0.value) }
    }

    /// The recurring 3-word phrase said most often — a sliding trigram
    /// count over every entry, skipping any window that's entirely
    /// stopwords (otherwise "in the" + one more common word wins every
    /// time, which says nothing about how this person actually talks).
    private var catchphrase: (phrase: String, count: Int)? {
        var counts: [[String]: Int] = [:]
        for entry in app.entries {
            let tokens = words(in: entry.text)
            guard tokens.count >= 3 else { continue }
            for i in 0...(tokens.count - 3) {
                let gram = Array(tokens[i..<(i + 3)])
                guard gram.contains(where: { !Self.phraseStopWords.contains($0) }) else { continue }
                counts[gram, default: 0] += 1
            }
        }
        return counts.filter { $0.value > 1 }.max(by: { $0.value < $1.value })
            .map { (displayPhrase($0.key), $0.value) }
    }

    /// The correction Murmur's Dictionary has been taught most often —
    /// `LearnedCorrection.timesSeen` already counts exactly this, so this
    /// reads that store directly rather than re-deriving anything.
    private var mostCorrectedWord: (word: String, times: Int)? {
        LearnedStore.load().corrections.max(by: { $0.timesSeen < $1.timesSeen })
            .map { ($0.intended, $0.timesSeen) }
    }

    /// The (weekday, hour) bucket with the most dictations, and whichever
    /// app was most common within it — a plain mode over History, not an
    /// AI-written summary, so it stays accurate even for a small sample.
    private var peakTime: (when: String, count: Int, app: (name: String, icon: NSImage?)?)? {
        guard !app.entries.isEmpty else { return nil }
        let calendar = Calendar.current
        var buckets: [DateComponents: [HistoryEntry]] = [:]
        for entry in app.entries {
            let comps = calendar.dateComponents([.weekday, .hour], from: entry.date)
            buckets[comps, default: []].append(entry)
        }
        guard let (comps, bucketEntries) = buckets.max(by: { $0.value.count < $1.value.count }),
              let weekday = comps.weekday, let hour = comps.hour
        else { return nil }

        let hour12 = hour % 12 == 0 ? 12 : hour % 12
        let when = "\(calendar.weekdaySymbols[weekday - 1])s, \(hour12)\(hour < 12 ? "am" : "pm")"
        let appCounts = Dictionary(grouping: bucketEntries.compactMap(\.targetBundleID)) { $0 }
            .mapValues(\.count)
        let topApp = appCounts.max(by: { $0.value < $1.value }).map { resolveApp(bundleID: $0.key) }
        return (when, bucketEntries.count, topApp)
    }

    /// The selected range against the one just before it, same length —
    /// "vs previous 7 days" / "vs previous 30 days". None for "All"
    /// (nothing before it), and none while the earlier period reaches back
    /// past the first recorded day: comparing against a partly unknown
    /// period is exactly what used to inflate these percentages.
    private func periodOverPeriod(_ metric: (Range<Int>) -> Int) -> String? {
        let length: Int
        switch chartRange {
        case .week: length = 7
        case .month: length = 30
        case .all: return nil
        }
        let calendar = Calendar.current
        let priorStart = calendar.date(byAdding: .day, value: -(2 * length - 1), to: calendar.startOfDay(for: Date()))!
        guard let first = app.usageStats.firstDay, first <= priorStart else { return nil }
        let this = metric(0..<length)
        let prior = metric(length..<(2 * length))
        guard prior > 0, this > prior else { return nil }
        let change = Double(this - prior) / Double(prior) * 100
        return "\(Int(change))% vs previous \(length) days"
    }

    private var wordsTrend: String? {
        periodOverPeriod { range in dayTotals(range, \.words) }
    }

    private var dictationsTrend: String? {
        periodOverPeriod { range in dayTotals(range, \.dictations) }
    }

    /// `keyPath` summed over the days `range` days back from today.
    private func dayTotals(_ range: Range<Int>, _ keyPath: KeyPath<DailyUsage, Int>) -> Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return range.reduce(0) { sum, offset in
            sum + app.usageStats.day(calendar.date(byAdding: .day, value: -offset, to: today)!)[keyPath: keyPath]
        }
    }
}

/// One row of `topAppsCard`: real icon (a plain rounded square placeholder
/// when the app can't be resolved, e.g. long since uninstalled — never a
/// fabricated one), name, a proportional bar, and the word count.
/// One row of `fixesCard`/`categoryCard`: a `MurmurIcon` (not a resolved
/// app icon — `AppUsageRow` below is for that), name (with an optional
/// faint detail line under it), a proportional bar, and a trailing figure.
/// Shared rather than two near-duplicates since both cards are otherwise
/// the same shape.
private struct UsageBarRow: View {
    let icon: MurmurIcon
    let name: String
    let detail: String?
    let value: Int
    let maxValue: Int
    let figureText: String
    let isFirst: Bool

    var body: some View {
        InsightsBarRow(value: value, maxValue: maxValue, figureText: figureText, isFirst: isFirst) {
            ZStack {
                RoundedRectangle(cornerRadius: 7).fill(Palette.warmRowBorder)
                MurmurIconView(icon: icon)
                    .frame(width: 13, height: 13)
                    .foregroundStyle(Palette.sunsetDeep)
            }
            .frame(width: 26, height: 26)
        } title: {
            // The detail rides inline after the name while there's room
            // and drops out when there isn't — the name itself never
            // truncates.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    barRowName(name)
                    if let detail {
                        Text(detail)
                            .font(.manrope(10.5))
                            .foregroundStyle(Palette.warmInkFainter)
                    }
                }
                barRowName(name)
            }
        }
    }
}

/// The bar every Insights card uses — thin and fully rounded so it reads
/// as a crisp line: 3pt is exactly 6 device pixels at 2×.
enum InsightsBar {
    static let height: CGFloat = 3
}

/// A bar row's name — never truncated by the figure beside it.
private func barRowName(_ name: String) -> some View {
    Text(name)
        .font(.manrope(12.5, .semibold))
        .foregroundStyle(Palette.warmInk)
        .lineLimit(1)
}

/// Shared layout for `UsageBarRow` and `AppUsageRow`: icon, then name and
/// figure on one line with a full-width bar under them. The old version
/// laid name, bar and figure side by side with fixed-width name/figure
/// columns, so a long name truncated ("Dictionary correcti…") and at the
/// narrowest window the bar got no width at all and vanished.
private struct InsightsBarRow<Icon: View, Title: View>: View {
    let value: Int
    let maxValue: Int
    let figureText: String
    let isFirst: Bool
    @ViewBuilder var icon: Icon
    @ViewBuilder var title: Title

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    title.frame(maxWidth: .infinity, alignment: .leading)
                    Text(figureText)
                        .font(.manrope(11.5, .medium))
                        .monospacedDigit()
                        .foregroundStyle(Palette.warmInkSoft)
                        .fixedSize()
                }
                GeometryReader { geo in
                    Capsule()
                        .fill(Palette.warmRowBorder)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(Palette.sunset)
                                .frame(width: geo.size.width * CGFloat(value) / CGFloat(max(maxValue, 1)))
                        }
                }
                .frame(height: InsightsBar.height)
            }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .top) {
            if !isFirst { Rectangle().fill(Palette.warmRowBorder).frame(height: 1) }
        }
    }
}

private struct AppUsageRow: View {
    let usage: InsightsPage.AppUsage
    let maxWords: Int
    let isFirst: Bool

    var body: some View {
        InsightsBarRow(value: usage.words, maxValue: maxWords, figureText: usage.words.formatted(),
                       isFirst: isFirst) {
            Group {
                if let icon = usage.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    RoundedRectangle(cornerRadius: 6).fill(Palette.warmRowBorder)
                }
            }
            .frame(width: 26, height: 26)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } title: {
            barRowName(usage.name)
        }
    }
}

/// A native-style segmented control: a quiet neutral track, a white thumb
/// under the selected option that slides between options, ink text. The
/// sunset fill it used to have made the period switch the loudest thing on
/// the page — louder than the numbers it scopes — and matched the chart's
/// own line; the accent is for data, not chrome. No shadow on the thumb
/// (a hairline edge instead), per the app's no-shadow rule for anything on
/// the glass panel. Generic over any `Hashable` option: this page has two
/// (range, metric). Not the shared `SegmentedPicker` (DesignSystem.swift),
/// which draws with the cooler dynamic light/dark `Palette`.
struct WarmSegmentedPicker<T: Hashable>: View {
    let options: [T]
    let label: (T) -> String
    @Binding var selection: T

    @Namespace private var thumb

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) { selection = option }
                } label: {
                    Text(label(option))
                        .font(.manrope(11.5, selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Palette.warmInk : Palette.warmInkSoft)
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(Palette.panel)
                                    .overlay(Capsule().strokeBorder(Palette.glassDivider, lineWidth: 0.5))
                                    .matchedGeometryEffect(id: "thumb", in: thumb)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Palette.hoverWash, in: Capsule())
        .fixedSize()
    }
}


// MARK: - Trend chart

struct TrendChart: View {
    let points: [(label: String, value: Int)]
    /// Points before this index are days with no record at all (before
    /// Murmur started keeping one) — the x-axis still spans them, but the
    /// line starts here instead of claiming zero words for them.
    var knownFrom: Int = 0
    @Binding var hoverIndex: Int?

    /// The plot and the y-axis labels must be laid out at exactly the same
    /// height or the ticks stop lining up with their gridlines. A seven-
    /// point weekly trend doesn't get more readable past roughly this
    /// height — it just leaves the line stranded in empty space — so the
    /// chart is deliberately sized, not stretched to fill the window. 200,
    /// not 240: with the readout above it, 240 let the chart card fill the
    /// default window's whole first screen and cut the cards below off at
    /// their titles.
    private let plotHeight: CGFloat = 200

    /// Every Nth x-axis label is shown once a range has more days than fit
    /// legibly — a week's worth never thins, a month shows roughly one
    /// label per five days, and a year+ "All" thins further still, rather
    /// than cramming 30+ overlapping date strings under the plot.
    private var labelStep: Int {
        switch points.count {
        case ...7: return 1
        case ...31: return 5
        default: return max(points.count / 8, 10)
        }
    }

    private var maxValue: Int {
        max(points.map(\.value).max() ?? 0, 1)
    }

    /// Rounds the axis top up to a clean tick so gridlines read as round
    /// numbers rather than arbitrary maxima.
    private var axisTop: Int {
        let raw = Double(maxValue) * 1.15
        let magnitude = pow(10, floor(log10(max(raw, 1))))
        return max(Int(ceil(raw / magnitude) * magnitude), 1)
    }

    private var ticks: [Int] {
        (0...3).map { axisTop * $0 / 3 }
    }

    /// The y a given tick sits at. Used by both the gridlines and the axis
    /// labels so the two can't drift apart.
    private func gridY(for tick: Int, in height: CGFloat) -> CGFloat {
        height - (CGFloat(tick) / CGFloat(axisTop)) * height
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Y axis. Each label is positioned on its gridline's exact y,
            // not spread evenly down the column: four labels in four equal
            // slices only ever agrees with four gridlines at thirds for the
            // topmost one, which left "0" floating far below the baseline.
            ZStack(alignment: .topTrailing) {
                Color.clear
                ForEach(ticks, id: \.self) { tick in
                    Text("\(tick)")
                        .font(.manrope(10))
                        .foregroundStyle(Palette.warmInkFainter)
                        .alignmentGuide(.top) { d in d.height / 2 }
                        .offset(y: gridY(for: tick, in: plotHeight))
                }
            }
            .frame(width: 34, height: plotHeight, alignment: .topTrailing)

            VStack(spacing: 6) {
                GeometryReader { geo in
                    let w = geo.size.width
                    let h = geo.size.height
                    let coords = coordinates(in: CGSize(width: w, height: h))
                    let known = Array(coords[min(knownFrom, coords.count - 1)...])

                    ZStack(alignment: .topLeading) {
                        // Recessive gridlines
                        ForEach(ticks, id: \.self) { tick in
                            let y = gridY(for: tick, in: h)
                            Path { p in
                                p.move(to: CGPoint(x: 0, y: y))
                                p.addLine(to: CGPoint(x: w, y: y))
                            }
                            .stroke(Palette.warmRowBorder, lineWidth: 1)
                        }

                        // Area wash — ~10% opacity, never a saturated block
                        smoothPath(known, closedTo: h)
                            .fill(Palette.sunset.opacity(0.1))

                        // 2.5px line
                        smoothPath(known, closedTo: nil)
                            .stroke(Palette.sunset,
                                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

                        // Crosshair + hovered point
                        if let i = hoverIndex, coords.indices.contains(i) {
                            Path { p in
                                p.move(to: CGPoint(x: coords[i].x, y: 0))
                                p.addLine(to: CGPoint(x: coords[i].x, y: h))
                            }
                            .stroke(Palette.warmDivider, lineWidth: 1)
                            Circle()
                                .fill(Palette.sunset)
                                .frame(width: 8, height: 8)
                                .overlay(Circle().stroke(.white, lineWidth: 2))
                                .position(coords[i])
                        }

                        // Today's point. Its value lives in the card header
                        // (`InsightsPage.chartReadout`), never on the plot.
                        if let last = coords.last {
                            Circle()
                                .fill(Palette.sunset)
                                .frame(width: 8, height: 8)
                                .overlay(Circle().stroke(.white, lineWidth: 2))
                                .position(last)
                        }

                    }
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            let step = w / CGFloat(max(points.count - 1, 1))
                            hoverIndex = min(max(Int((location.x / step).rounded()), knownFrom), points.count - 1)
                        case .ended:
                            hoverIndex = nil
                        }
                    }
                }
                .frame(height: plotHeight)

                // X axis — `justify-content: space-between`, matching how
                // the points themselves run edge to edge. Centering each
                // label in an equal-width column instead (as this did)
                // offsets every label from the dot it belongs to, worst at
                // the two ends. The last day (today) is always bold/dark,
                // matching the mockup's own static emphasis — every other
                // day is faint unless actively hovered.
                //
                // Every point still gets a slot (and the same `Spacer`
                // between slots) regardless of `labelStep` — only the text
                // itself is skipped for thinned-out points, so the labels
                // that do show stay aligned under their own dot rather
                // than redistributing across the freed-up space.
                HStack(spacing: 4) {
                    ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                        let isLast = index == points.count - 1
                        let isHighlighted = isLast || index == hoverIndex
                        let shown = isLast || index % labelStep == 0
                        Text(shown ? point.label : "")
                            .font(.manrope(10.5, isLast ? .semibold : .regular))
                            .foregroundStyle(isHighlighted ? Palette.warmInk : Palette.warmInkFainter)
                            .fixedSize()
                        if index != points.count - 1 { Spacer(minLength: 0) }
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    private func coordinates(in size: CGSize) -> [CGPoint] {
        let n = max(points.count - 1, 1)
        return points.enumerated().map { index, point in
            CGPoint(
                x: size.width * CGFloat(index) / CGFloat(n),
                y: size.height - (CGFloat(point.value) / CGFloat(axisTop)) * size.height)
        }
    }

    /// Monotone cubic (Fritsch–Carlson) Hermite interpolation.
    ///
    /// The mockup smooths with plain Catmull-Rom, which is fine for its
    /// hand-picked sample data but **overshoots** on real data: a flat run
    /// of zero-word days followed by a spike makes the curve swing below
    /// the baseline, drawing days with negative words. Word counts can't
    /// be negative, so the chart must not be able to draw one.
    ///
    /// This variant limits each tangent to the slope of its neighbouring
    /// segments, so the curve is guaranteed to stay within the range of
    /// the two points it connects — it can never dip under a zero day.
    private func smoothPath(_ pts: [CGPoint], closedTo bottom: CGFloat?) -> Path {
        var path = Path()
        guard let first = pts.first else { return path }
        path.move(to: first)
        guard pts.count > 1 else { return path }

        let n = pts.count
        // Secant slope of each segment.
        var slopes = [CGFloat](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            let dx = pts[i + 1].x - pts[i].x
            slopes[i] = dx == 0 ? 0 : (pts[i + 1].y - pts[i].y) / dx
        }
        // Tangents: average of adjacent secants, endpoints one-sided.
        var tangents = [CGFloat](repeating: 0, count: n)
        tangents[0] = slopes[0]
        tangents[n - 1] = slopes[n - 2]
        for i in 1..<(n - 1) {
            tangents[i] = slopes[i - 1] * slopes[i] <= 0
                ? 0                                     // local extremum: flatten
                : (slopes[i - 1] + slopes[i]) / 2
        }
        // Fritsch–Carlson limiter — the step that actually prevents overshoot.
        for i in 0..<(n - 1) {
            if slopes[i] == 0 {
                tangents[i] = 0
                tangents[i + 1] = 0
                continue
            }
            let alpha = tangents[i] / slopes[i]
            let beta = tangents[i + 1] / slopes[i]
            let magnitude = alpha * alpha + beta * beta
            if magnitude > 9 {
                let tau = 3 / magnitude.squareRoot()
                tangents[i] = tau * alpha * slopes[i]
                tangents[i + 1] = tau * beta * slopes[i]
            }
        }
        for i in 0..<(n - 1) {
            let p1 = pts[i]
            let p2 = pts[i + 1]
            let dx = (p2.x - p1.x) / 3
            let c1 = CGPoint(x: p1.x + dx, y: p1.y + tangents[i] * dx)
            let c2 = CGPoint(x: p2.x - dx, y: p2.y - tangents[i + 1] * dx)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        if let bottom, let last = pts.last {
            path.addLine(to: CGPoint(x: last.x, y: bottom))
            path.addLine(to: CGPoint(x: first.x, y: bottom))
            path.closeSubpath()
        }
        return path
    }
}
