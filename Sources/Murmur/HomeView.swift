import AppKit
import SwiftUI

// MARK: - Home
//
// Redesigned per the "Main" canvas (Main.dc.html): the capture zone becomes
// a warm sunset-gradient hero instead of the old dark banner, and the whole
// page now sits on its own frosted glass panel over a sage-to-cream
// backdrop rather than the shell's flat panel background. Every store call
// and binding is unchanged from the previous implementation — this is a
// View-layer rewrite only.

struct HomePage: View {
    @ObservedObject var app: AppDelegate
    @Binding var page: Page
    @State private var searchText = ""
    @State private var searchOpen = false
    @State private var showClearConfirm = false
    @State private var editingEntry: HistoryEntry?
    /// The dictation a problem is being reported about (History row ▸ More ▸ Report a problem).
    @State private var reportingEntry: HistoryEntry?
    @State private var editText = ""
    @State private var learnFeedback: String?
    // Shared so opening a second row's overflow menu can't leave two open
    // at once — each row only shows its own menu when this matches its own
    // entry (see `HistoryRowView.isMenuOpen`).
    @State private var openMenuEntryID: HistoryEntry.ID?
    @State private var historyHover = HistoryHover()

    private var openMenuEntry: HistoryEntry? {
        guard let id = openMenuEntryID else { return nil }
        return app.entries.first { $0.id == id }
    }

    var body: some View {
        GlassPanelPage {
            VStack(alignment: .leading, spacing: 20) {
                captureZone
                statStrip
                historySection
            }
        }
        .sheet(item: $editingEntry) { entry in correctionSheet(entry) }
        .sheet(item: $reportingEntry) { entry in
            SupportReportSheet(onDone: { reportingEntry = nil },
                               dictation: SupportReport.DictationContext.make(pasted: entry.text))
        }
        // Rendered here — above `historySection`'s own `ScrollView`, not
        // nested inside it — so the menu is never a `LazyVStack` sibling
        // of the rows below it. A same-row `.overlay` plus `.zIndex` (tried
        // first) still lost to those rows in practice: `LazyVStack` only
        // *sometimes* honored the raised index, likely the same known
        // unreliability other SwiftUI/AppKit lazy-stack z-ordering reports
        // describe — not something to keep fighting. `RowMenuAnchorKey` is
        // the row's own action-icons bounds, reported only while its menu
        // is open; resolving it against this `GeometryReader` gives a
        // position independent of that row's place in the list, and of
        // scroll offset.
        .overlayPreferenceValue(RowMenuAnchorKey.self) { anchor in
            if let anchor, let entry = openMenuEntry {
                GeometryReader { proxy in
                    let rect = proxy[anchor]
                    // `RowActionsMenu` is a fixed 190×~84 card, so its
                    // placement only needs that constant, not a measured
                    // round-trip: right-aligned under the icon by default,
                    // flipped upward when there isn't 84pt of headroom
                    // below, and kept clear of the left/right edges.
                    let menuWidth: CGFloat = 190
                    let menuHeight: CGFloat = 122
                    let opensUpward = rect.maxY + 6 + menuHeight > proxy.size.height
                    let x = max(0, min(rect.maxX - menuWidth, proxy.size.width - menuWidth))
                    let y = opensUpward ? rect.minY - 6 - menuHeight : rect.maxY + 6

                    // An almost-invisible, page-filling tap catcher behind
                    // the card: clicking anywhere outside the menu closes
                    // it, while the opaque card in front always takes the
                    // tap first wherever the two overlap.
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture { openMenuEntryID = nil }
                    RowActionsMenu(
                        onTemplate: {
                            openMenuEntryID = nil
                            app.pendingTemplateText = entry.text
                            page = .templates
                        },
                        onReport: {
                            openMenuEntryID = nil
                            reportingEntry = entry
                        },
                        onDelete: {
                            openMenuEntryID = nil
                            app.deleteHistoryEntry(id: entry.id)
                        },
                        onDismiss: { openMenuEntryID = nil })
                        .offset(x: x, y: y)
                }
            }
        }
        .animation(.murmurEase(0.14), value: openMenuEntryID)
    }

    // MARK: Capture zone

    /// One solid ink surface with one job: Murmur's line at headline scale,
    /// a live status readout above it and the waveform beside it.
    ///
    /// Ink (`navActivePill`), the app's own dark — the selected rail row, the
    /// primary buttons, the dictation pill — rather than the sunset fill it
    /// used to be: orange is kept for accents, so here it's the voice (the
    /// bars, and the dot while listening) instead of a whole surface. Text is
    /// white (~18:1). No drop shadow: the dark fill separates from the glass
    /// panel on its own, and a shadow there reads as a grey smear.
    private var captureZone: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                HStack(spacing: 8) {
                    PulsingDot(
                        color: app.uiState == .idle ? .white.opacity(0.55) : Palette.sunset,
                        size: 6, maxScale: 2.2, active: app.uiState != .idle)
                    Text(captureStatusLabel.uppercased())
                        .font(.manrope(10, .bold))
                        .kerning(0.9)
                        .foregroundStyle(.white)
                }
                Spacer()
                // A plain Keycap here just displayed the hotkey; this
                // needs to also let you change it without a trip to
                // Settings — same underlying `app.hotkey`/`setHotkey`
                // Settings already drives (SettingsView.swift's own
                // "Dictation key" row), just reachable from the one place
                // you're already looking at when you'd want to change it.
                FieldSelect(
                    options: HotkeyMonitor.Hotkey.allCases,
                    label: { "Hold \($0.displayName)" },
                    selection: Binding(
                        get: { app.hotkey },
                        set: { app.setHotkey($0) }),
                    tint: .white,
                    background: .white.opacity(0.10),
                    borderColor: .white.opacity(0.18))
            }
            // Side by side, not stacked: the headline anchors the left
            // edge and takes whatever width is left over once the
            // waveform's own fixed size is reserved on the right, so the
            // two read as one deliberately composed row instead of a
            // block of text with a small animation floating somewhere
            // beneath it.
            HStack(alignment: .center, spacing: 36) {
                Text(Self.captureHeadline)
                    .font(.manrope(33, .medium))
                    .tracking(-0.66)
                    .lineSpacing(8)
                    .lineLimit(3)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // Orange bars, like the dictation pill's level bars; the shortest kept at 0.6 so none turn brown on ink.
                HeroCaptureWaveform(color: Palette.sunset, minOpacity: 0.6)
            }
            .padding(.top, 22)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
        .background(Palette.navActivePill, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    /// "Ready"/"Listening" wording, matching what `StatusHUD.swift`
    /// already established for ambient, HUD-style status — this surface
    /// is now the app's one titlebar-adjacent status readout (the old
    /// titlebar `StatusPill` duplicated it and was removed).
    private var captureStatusLabel: String {
        if let status = app.transformStatus { return status }
        switch app.uiState {
        case .idle: return "Ready"
        case .recording: return app.isHandsFree ? "Listening — hands-free" : "Listening"
        case .processing: return "Working"
        }
    }

    /// A fixed brand line, matching Main.dc.html's own copy exactly
    /// (explicit line breaks, not natural wrapping) — not the user's own
    /// recent dictation, which would duplicate the history list directly
    /// beneath it. Names Murmur's own two most-differentiated pillars
    /// specifically: per-app formatting and on-device privacy.
    private static let captureHeadline =
        "Speak naturally.\nMurmur formats it for every app,\nright on your Mac."

    // MARK: Stat strip

    /// Words-today, wpm, and streak used to be two boxed `Card`s with big
    /// colored numerals fighting the capture zone for top billing. One
    /// quiet inline row instead — the trend arrow and the 7-day pip strip
    /// stay on Insights, which already exists for exactly this, rather
    /// than duplicating them here too.
    private var statStrip: some View {
        HStack(spacing: 20) {
            statItem(wordsToday.formatted(), "words today")
            stripDivider
            if let wpm = wpmToday {
                statItem("\(wpm)", "wpm")
                stripDivider
            }
            statItem("\(dayStreak)", dayStreak == 1 ? "day streak" : "day streak")
            Spacer()
            Button { page = .appProfiles } label: {
                Text("Dictate differently per app →")
                    .font(.manrope(13, .medium))
                    .foregroundStyle(Palette.sunsetDeep)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
    }

    private func statItem(_ value: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(value)
                .font(.manrope(17, .medium))
                .tracking(-0.3)
                .monospacedDigit()
                .foregroundStyle(Palette.warmInk)
            Text(label)
                .font(.manrope(11.5))
                .foregroundStyle(Palette.warmInkSoft)
        }
    }

    private var stripDivider: some View {
        Rectangle().fill(Palette.warmDivider).frame(width: 1, height: 14)
    }

    // MARK: History
    //
    // No card of its own anymore — by request, this now lives directly on
    // the glass panel instead of a separate white surface floating inside
    // it. `warmRowBorder`'s near-white hairline read fine against solid
    // white but all but disappeared against the frosted, gradient-tinted
    // material, so row dividers switched to `glassDivider` (a translucent
    // black that keeps working regardless of exactly what's blurred behind
    // it); the faintest ink/dot tones moved one step darker for the same
    // reason.

    /// Fills whatever height the hero and stat strip leave behind.
    private var historySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            historyHeader
            ThinScrollView(bottomInset: 12) {
                historyRows
            }
            // Widened by the rows' highlight bleed on both sides so the
            // scroll view's clip doesn't cut the highlight off; each row
            // and day label insets its own content back to the column.
            .padding(.horizontal, -HistoryRowView.bleed)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Stays fixed above the scrolling list.
    private var historyHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                // Each day group below carries its own label ("Today",
                // "July 12, 2026", …) — a static label here would either
                // repeat the first one or, worse, go stale exactly like
                // the old fixed "Today" did once the list scrolled past
                // it. "Results" is the one case worth stating up front,
                // since a search match isn't otherwise obvious from the
                // day grouping alone.
                if searchOpen && !searchText.isEmpty {
                    Text("RESULTS")
                        .font(.manrope(10, .semibold))
                        .kerning(0.9)
                        .foregroundStyle(Palette.warmInkSoft)
                }
                Spacer()
                if showClearConfirm {
                    Text("Clear all \(app.entries.count) transcript\(app.entries.count == 1 ? "" : "s")? This can't be undone.")
                        .font(.manrope(12))
                        .foregroundStyle(Palette.warmInkSoft)
                    Button("Cancel") { showClearConfirm = false }
                        .buttonStyle(GhostButtonStyle())
                    Button("Clear History") {
                        app.clearHistoryEntries()
                        showClearConfirm = false
                    }
                    .buttonStyle(DangerButtonStyle())
                } else {
                    if searchOpen {
                        HStack(spacing: 8) {
                            MurmurIconView(icon: .search)
                                .frame(width: 13, height: 13)
                                .foregroundStyle(Palette.warmInkFaint)
                            TextField("Search transcripts", text: $searchText)
                                .textFieldStyle(.plain)
                                .font(.manrope(12.5))
                                .foregroundStyle(Palette.warmInk)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Palette.warmRowBorder, in: RoundedRectangle(cornerRadius: Radius.sm))
                        .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Palette.warmDivider, lineWidth: 1))
                        .frame(width: 200)
                    }
                    IconButton(icon: searchOpen ? .plus : .search,
                               rotated: searchOpen,
                               help: searchOpen ? "Close search" : "Search transcripts") {
                        searchOpen.toggle()
                        if !searchOpen { searchText = "" }
                    }
                    IconButton(icon: .trash, help: "Clear all history") {
                        showClearConfirm = true
                    }
                }
            }
            .padding(.bottom, 14)

            if let feedback = learnFeedback {
                HStack(spacing: 6) {
                    MurmurIconView(icon: .check).frame(width: 12, height: 12)
                    Text(feedback).font(.manrope(12, .medium))
                }
                .foregroundStyle(Palette.sunsetDeep)
                .padding(.bottom, 10)
                .task {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    learnFeedback = nil
                }
            }
        }
    }

    /// The only part of Home that scrolls. Grouped by calendar day — the
    /// fixed header above can only ever say one static thing, which is
    /// what let a flat, ungrouped list read as if everything in it were
    /// from today even once older days scrolled into view. Each row now
    /// carries a small leading dot and its own hairline top rule (matching
    /// the mockup) instead of the old per-day bordered/filled card — the
    /// dot is only lit (sunset orange) on the single newest entry across
    /// the whole list, not once per day.
    ///
    /// Flattened into one `ForEach` (day labels and entries as siblings)
    /// rather than a `ForEach` of day-groups each containing its own
    /// nested `ForEach` of rows — `LazyVStack` only lazily instantiates
    /// its own *direct* children, so the nested version made it treat an
    /// entire day (however many transcripts that turned out to be) as one
    /// unsplittable unit of work instead of one row at a time.
    private var historyRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            if app.entries.isEmpty {
                emptyState(
                    "No transcripts yet — click into any text field, hold \(app.hotkey.displayName), and speak.")
            } else if filteredEntries.isEmpty {
                emptyState("No transcripts match “\(searchText)”.")
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let rows = flatHistoryRows
                    // Once per render, not once per row — each call regroups
                    // the whole history, which now holds up to 5,000.
                    let newestID = newestEntryID
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        switch row {
                        case .day(let date):
                            daySectionLabel(date, isFirst: index == 0)
                        case .entry(let entry):
                            HistoryRowView(
                                entry: entry,
                                isNewest: entry.id == newestID,
                                entryAboveID: index > 0 ? rows[index - 1].entryID : nil,
                                hover: historyHover,
                                openMenuEntryID: $openMenuEntryID,
                                onCopy: {
                                    let pb = NSPasteboard.general
                                    pb.clearContents()
                                    pb.setString(entry.text, forType: .string)
                                },
                                onCorrect: {
                                    editText = entry.text
                                    editingEntry = entry
                                })
                        }
                    }
                }
            }
        }
    }

    private func daySectionLabel(_ day: Date, isFirst: Bool) -> some View {
        Text(dayLabel(day).uppercased())
            .font(.manrope(10, .semibold))
            .kerning(0.9)
            .foregroundStyle(Palette.warmInkSoft)
            .padding(.top, isFirst ? 0 : 14)
            .padding(.bottom, 6)
            .padding(.horizontal, HistoryRowView.bleed)
    }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(.manrope(12.5))
            .italic()
            .foregroundStyle(Palette.warmInkFaint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .background(Palette.warmRowBorder, in: RoundedRectangle(cornerRadius: Radius.lg))
            .padding(.horizontal, HistoryRowView.bleed)
    }

    private func correctionSheet(_ entry: HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Correct this transcript").font(.manrope(15, .semibold))
            Text("Fix what Murmur misheard. It compares your fix with the "
                 + "original and learns the corrections for future dictations.")
                .font(.manrope(12))
                .foregroundStyle(Palette.inkSoft)
            TextEditor(text: $editText)
                .font(.manrope(13))
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(width: 460, height: 140)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: Radius.md))
            HStack {
                Spacer()
                Button("Cancel") { editingEntry = nil }
                Button("Save & Learn") {
                    let learnedCount = app.correctHistoryEntry(id: entry.id, newText: editText)
                    learnFeedback = learnedCount > 0
                        ? "Learned \(learnedCount) correction\(learnedCount == 1 ? "" : "s") from your fix."
                        : "Transcript updated."
                    editingEntry = nil
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    // MARK: Derived data

    private var filteredEntries: [HistoryEntry] {
        HistoryStore.matching(searchText, in: app.entries)
    }

    /// `filteredEntries` grouped by calendar day, most recent day first.
    /// `app.entries` (and so `filteredEntries`) is already newest-first —
    /// appending each day the first time it's seen preserves that order
    /// for the groups too, with no separate sort needed.
    private var groupedEntries: [(day: Date, entries: [HistoryEntry])] {
        let calendar = Calendar.current
        var order: [Date] = []
        var byDay: [Date: [HistoryEntry]] = [:]
        for entry in filteredEntries {
            let day = calendar.startOfDay(for: entry.date)
            if byDay[day] == nil { order.append(day) }
            byDay[day, default: []].append(entry)
        }
        return order.map { (day: $0, entries: byDay[$0] ?? []) }
    }

    /// The id of the single most recent entry across every group — what
    /// `HistoryRowView` uses to decide which one row (not one per day) gets
    /// the accent treatment.
    private var newestEntryID: String? {
        groupedEntries.first?.entries.first?.id
    }

    /// `groupedEntries` flattened into one list of day-labels and entries
    /// as equal siblings, so `historyRows`' `ForEach` can hand `LazyVStack`
    /// one row at a time instead of one whole day at a time.
    private var flatHistoryRows: [HistoryListRow] {
        groupedEntries.flatMap { group in
            [.day(group.day)] + group.entries.map { .entry($0) }
        }
    }

    private func dayLabel(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.month(.abbreviated).day())
    }

    // Home's strip reads the same lifetime daily totals Insights does
    // (`UsageStatsStore`), not `app.entries` — history only keeps the
    // latest 5,000 dictations / 90 days (500 / 30 until 2026-09-24), which capped the streak and
    // could drop part of today for a heavy user.

    private var wordsToday: Int { app.usageStats.day(Date()).words }

    /// Words per minute across today's timed dictations only. The trend
    /// vs. yesterday and the 7-day pip strip that used to sit alongside
    /// these numbers stay on Insights, which already exists for exactly
    /// this — Home's stat strip is a teaser, not a second copy of it.
    private var wpmToday: Int? {
        let today = app.usageStats.day(Date())
        guard today.seconds > 0 else { return nil }
        return Int(Double(today.timedWords) / (today.seconds / 60))
    }

    private var dayStreak: Int {
        let calendar = Calendar.current
        let days = Set(app.usageStats.days.filter { $0.dictations > 0 }.map(\.date))
        var day = calendar.startOfDay(for: Date())
        if !days.contains(day) {
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        var streak = 0
        while days.contains(day) {
            streak += 1
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        return streak
    }

}

/// One flattened item of `historyRows`' single `ForEach` — a day-section
/// label or a transcript, as equal siblings (see `flatHistoryRows`).
private enum HistoryListRow: Identifiable {
    case day(Date)
    case entry(HistoryEntry)

    var id: String {
        switch self {
        case .day(let date): return "day-\(date.timeIntervalSince1970)"
        case .entry(let entry): return entry.id
        }
    }

    /// The entry this row shows, if it's an entry row — what the row below
    /// it checks to hide its own top rule while this one is lit.
    var entryID: HistoryEntry.ID? {
        if case .entry(let entry) = self { return entry.id }
        return nil
    }
}

/// Which history row the pointer is over, shared so the row *below* a lit
/// row can hide its top rule too. An `@Observable` reference held by
/// `HomePage` rather than a plain `@State` value: only the rows that read
/// `id` re-render when it changes, never `HomePage.body` — see
/// `HistoryRowView`'s note on why that matters while the list scrolls
/// under a stationary pointer.
@Observable
private final class HistoryHover {
    var id: HistoryEntry.ID?
}

// MARK: - History row

/// Its own `View` rather than a method on `HomePage` returning `some View`,
/// specifically so `hovering` is local `@State` scoped to one row instead
/// of a single `String?` shared on `HomePage` for every row to compare
/// itself against. With the shared version, scrolling the list under a
/// stationary cursor fires an enter/exit on every row that passes under
/// it, and each one reassigned `HomePage`'s own state — which invalidated
/// `HomePage.body` and re-evaluated every row in the list on every single
/// one of those events, not just the row whose own hover actually changed.
/// A real `View` type gives SwiftUI a stable identity to diff against, so
/// a hover change here only ever re-renders this one row.
private struct HistoryRowView: View {
    /// How far the highlight reaches past the text column on each side.
    /// The time and text keep the column's left edge (lined up with the
    /// day label, stat strip and capture card) while still sitting 10pt
    /// inside the highlight — the way a native Mac list insets content
    /// within its selection instead of running it into the edge.
    static let bleed: CGFloat = 10

    let entry: HistoryEntry
    let isNewest: Bool
    /// The entry directly above this one in the same day group, if any —
    /// while it's lit, the rule between the two (this row's top rule)
    /// steps aside as well.
    let entryAboveID: HistoryEntry.ID?
    let hover: HistoryHover
    @Binding var openMenuEntryID: HistoryEntry.ID?
    let onCopy: () -> Void
    let onCorrect: () -> Void

    @State private var hovering = false

    /// Shared across rows (`openMenuEntryID` lives on `HomePage`) so
    /// opening a second row's menu can't leave two open at once.
    private var isMenuOpen: Bool { openMenuEntryID == entry.id }

    /// Lit while hovered *or* while this row's overflow menu is open, so
    /// the menu stays visibly attached to its row once the pointer moves
    /// onto it.
    private var isLit: Bool { hovering || isMenuOpen }

    /// Mail/Notes-style: the rules on either side of a lit row step aside,
    /// so the highlight floats instead of being boxed in by two hairlines.
    /// A row owns only its top rule; the one below it belongs to the next
    /// row, which checks `entryAboveID` against the same shared state.
    private var hidesTopRule: Bool {
        isLit || (entryAboveID != nil
            && (hover.id == entryAboveID || openMenuEntryID == entryAboveID))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Palette.glassDivider).frame(height: 1)
                .padding(.horizontal, Self.bleed)
                .opacity(hidesTopRule ? 0 : 1)
            HStack(alignment: .top, spacing: 13) {
                // No leading dot — just the time, top-aligned with the
                // entry text so both start at the same line regardless of
                // whether the text wraps to a second line.
                Text(entry.date, format: .dateTime.hour().minute())
                    .font(.manrope(12, .semibold))
                    .foregroundStyle(isNewest ? Palette.sunsetDeep : Palette.warmInkSoft)
                    // `font-variant-numeric: tabular-nums`. Verified Manrope
                    // ships Monospaced Numbers, so this stays in Manrope
                    // rather than falling back to a substitute face.
                    .monospacedDigit()
                    .frame(width: 40, alignment: .leading)
                Text(entry.text.replacingOccurrences(of: "\n", with: " "))
                    .font(.manrope(13))
                    .lineSpacing(4)
                    .foregroundStyle(isNewest ? Palette.warmInk : Palette.warmInkSoft)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // Actions stay laid out and only fade, so hovering a row
                // never reflows its text. Copy and Correct & learn are the
                // two used on almost every row, so they stay a single
                // click away; Turn into a note and Delete move behind one
                // overflow trigger, which also leaves room to append a
                // future action without adding another permanent icon.
                // Their hover fill is the row's own wash stacked once more,
                // so it shows on the lit row (`cardHover`, the default,
                // was the same grey as the old row fill and vanished).
                HStack(spacing: 6) {
                    IconButton(icon: .copy, hoverFill: Palette.hoverWash, help: "Copy", action: onCopy)
                    IconButton(icon: .edit, hoverFill: Palette.hoverWash, help: "Correct & learn",
                               action: onCorrect)
                    IconButton(icon: .moreVertical, hoverFill: Palette.hoverWash, help: "More") {
                        openMenuEntryID = isMenuOpen ? nil : entry.id
                    }
                }
                .opacity(isLit ? 1 : 0)
                // Reports this HStack's own bounds up to `HomePage`'s
                // `overlayPreferenceValue(RowMenuAnchorKey.self)` whenever
                // this row's menu is open, rather than drawing the menu
                // here directly — see that overlay's own comment for why a
                // same-row overlay isn't good enough inside a `LazyVStack`.
                .anchorPreference(key: RowMenuAnchorKey.self, value: .bounds) {
                    isMenuOpen ? $0 : nil
                }
            }
            .padding(.horizontal, Self.bleed)
            .padding(.vertical, 12)
            // The translucent wash the rail's hover uses, not the opaque
            // `cardHover` grey (made for white cards): on the frosted
            // panel it takes on the panel's own warmth instead of sitting
            // on it as a flat cool block.
            .background(
                RoundedRectangle(cornerRadius: Radius.sm)
                    .fill(isLit ? Palette.hoverWash : Color.clear))
            // Without an explicit hit-testable shape, SwiftUI only counts
            // actually-drawn content (the text glyphs) as hoverable when the
            // background is .clear — the padding and inter-column gaps read as
            // "not part of the view" for hover purposes until the background
            // is already filled, so entering the row anywhere but directly on
            // the text failed to reveal the actions. This makes the whole
            // padded frame one hoverable region regardless of what's drawn.
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside {
                    hover.id = entry.id
                } else if hover.id == entry.id {
                    hover.id = nil
                }
            }
        }
        .animation(.easeOut(duration: 0.1), value: isLit)
        .animation(.easeOut(duration: 0.1), value: hidesTopRule)
    }
}

/// Reports the open row's action-icons bounds up to `HomePage`, which
/// resolves it against its own `GeometryReader` to place `RowActionsMenu`
/// outside the scrolling list entirely. `reduce` just keeps whichever
/// candidate is non-nil — `openMenuEntryID` already guarantees at most one
/// row ever reports itself open at a time.
private struct RowMenuAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

/// The history row's overflow menu. Positioned by `HomePage`'s
/// `overlayPreferenceValue` (see `RowMenuAnchorKey`) — this view itself
/// knows nothing about where it ends up. Styled after the nav bar HUD's
/// own popovers (`NavPopover`/`NavPopoverRow` in NavBarHUD.swift) — not a
/// system `.popover` (generic native chrome, not the app's own design) —
/// re-themed onto Home's white/warm palette, but flat rather than
/// elevated: no shadow, matching this app's own standing rule that a
/// glass-panel-page card never gets one (`HistoryRowView`'s own hover
/// background is the same plain fill, no shadow, right next to this).
/// A later action just becomes another `MenuRow` above the divider.
private struct RowActionsMenu: View {
    let onTemplate: () -> Void
    let onReport: () -> Void
    let onDelete: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuRow(icon: .tpl, label: "Turn into a note", action: onTemplate)
            MenuRow(icon: .help, label: "Report a problem", action: onReport)
            Rectangle().fill(Palette.warmRowBorder).frame(height: 1).padding(.vertical, 5)
            MenuRow(icon: .trash, label: "Delete", tint: Palette.danger, action: onDelete)
        }
        .padding(6)
        .frame(width: 190)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.panel))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.warmRowBorder, lineWidth: 1))
        .onExitCommand(perform: onDismiss)
        .transition(.opacity.combined(with: .scale(0.96, anchor: .topTrailing)))
    }
}

private struct MenuRow: View {
    let icon: MurmurIcon
    let label: String
    var tint: Color = Palette.warmInk
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                MurmurIconView(icon: icon).frame(width: 13, height: 13)
                Text(label).font(.manrope(12.5, .semibold)).lineLimit(1)
                Spacer(minLength: 8)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(hovering ? Palette.warmRowBorder : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Hero waveform

/// Home hero's own waveform (also on the voice-profile card, so the two
/// heroes match) — distinct from the app-wide `CaptureWaveform`
/// (DesignSystem.swift), which keeps its dark-surface, lime-center look for
/// Onboarding. This one matches Main.dc.html's `.hero-bar`s: 13 bars,
/// heights mirrored around the centre, animated as a `scaleY` breathe (CSS
/// `heroWave`) rather than a height change. White on the solid sunset
/// card, brightest at the peak: opacity runs from 0.45 on the shortest bar
/// to 1 on the tallest.
struct HeroCaptureWaveform: View {
    var active: Bool = true
    /// The loop only runs while Murmur is the app in front. Left running behind other apps it kept the main thread
    /// about half busy and the app at 25–30% of a core while idle (sampled 2026-10-10) — at exactly the moment a
    /// dictation into another app needs the processor and the graphics chip.
    @Environment(\.controlActiveState) private var windowState
    private var running: Bool { active && windowState != .inactive }
    /// Sunset on Home's ink card (passed in); the accent on a white card
    /// (the voice profile), where white bars would vanish.
    var color: Color = .white
    /// The shortest bar's opacity — the tallest is always 1.
    var minOpacity: Double = 0.45

    @State private var tall = false

    private static let bars: [(height: CGFloat, delay: Double)] = [
        (16, 0),
        (32, 0.06),
        (48, 0.12),
        (64, 0.18),
        (45, 0.24),
        (80, 0.30),
        (100, 0.36),
        (80, 0.30),
        (45, 0.24),
        (64, 0.18),
        (48, 0.12),
        (32, 0.06),
        (16, 0),
    ]

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            ForEach(Array(Self.bars.enumerated()), id: \.offset) { _, bar in
                Capsule()
                    .fill(color.opacity(minOpacity + (1 - minOpacity) * (bar.height - 16) / 84))
                    .frame(width: 6, height: bar.height)
                    .scaleEffect(y: tall ? 1 : 0.55, anchor: .center)
                    .animation(
                        tall
                            ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true).delay(bar.delay)
                            : .easeOut(duration: 0.3),
                        value: tall)
            }
        }
        .frame(height: 108)
        .onAppear { tall = running }
        .onChange(of: running) { _, isRunning in tall = isRunning }
    }
}

// MARK: - Button styles

struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.manrope(11.5, .semibold))
            .foregroundStyle(Palette.accentText)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(Palette.accentSoft, in: RoundedRectangle(cornerRadius: Radius.sm))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}

struct DangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.manrope(11.5, .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(Palette.danger, in: RoundedRectangle(cornerRadius: Radius.sm))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}
