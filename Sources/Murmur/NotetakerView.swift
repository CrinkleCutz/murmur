import AppKit
import SwiftUI

// MARK: - Notetaker
//
// One white "now" card that follows the capture state (idle / listening /
// processing, or the Screen Recording prompt), with browser detection and
// calendar as real option rows inside it; below, saved notes grouped by day
// like Home's history, or — before the first one — an example of what a
// note looks like. No orange card: orange is an accent in Murmur, never a fill.

struct NotetakerPage: View {
    @ObservedObject var app: AppDelegate
    @State private var selectedNote: MeetingNote?
    @State private var searchText = ""
    @State private var searchOpen = false
    /// Mirrors `Settings.browserMeetingDetectionEnabled` — plain
    /// `UserDefaults`, not `@Published`, so this needs its own state to
    /// actually re-render once the button below flips it, the same
    /// pattern Scratchpad's own hotkey chip already uses for the same
    /// reason.
    @State private var browserDetectionEnabled = Settings.browserMeetingDetectionEnabled

    private var controller: NotetakerController { app.notetaker }

    /// Title, calendar title, and transcript text all match — a note
    /// found by what was actually said, not just by its title, the same
    /// substring search `HistoryStore.matching` already does for History.
    private var filteredNotes: [MeetingNote] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return controller.notes }
        return controller.notes.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || ($0.calendarTitle?.localizedCaseInsensitiveContains(query) ?? false)
                || $0.transcriptText.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        GlassPanelPage {
            ThinScrollView(bottomInset: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    statusCard.padding(.top, 24)
                    if controller.notes.isEmpty {
                        exampleCard.padding(.top, 24)
                    } else {
                        notesToolbar.padding(.top, 20)
                        notesList
                    }
                }
                .padding(.horizontal, Self.bleed)
            }
            // Widened by the rows' highlight bleed so the scroll view's clip
            // doesn't cut it off; the content is inset back above.
            .padding(.horizontal, -Self.bleed)
        }
        .onAppear { controller.refreshScreenRecordingStatus() }
        .sheet(item: $selectedNote) { note in
            // Only `note.id` is actually used below — `MeetingDetailSheet`
            // re-reads the live note from `controller` itself on every
            // render, rather than holding the snapshot from the moment the
            // sheet opened, so a rename or a checkbox toggle inside it
            // shows up immediately instead of only after closing and
            // reopening.
            MeetingDetailSheet(controller: controller, noteID: note.id) { selectedNote = nil }
        }
    }

    /// How far a note row's hover highlight reaches past the text — the
    /// same 10pt as Home's history rows.
    static let bleed: CGFloat = 10

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Notetaker")
                .font(.manrope(22, .medium))
                .tracking(-0.33)
                .foregroundStyle(Palette.warmInk)
            // The old orange card's promise, folded into the subtitle.
            Text("Automatic notes for your calls, made on this Mac — no bot joins your call, and nothing "
                 + "about the people on it is looked up online.")
                .font(.manrope(12.5))
                .foregroundStyle(Palette.warmInkFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Now card

    @ViewBuilder
    private var statusCard: some View {
        if !controller.screenRecordingAuthorized {
            permissionCard
        } else {
            captureCard
        }
    }

    private var permissionCard: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(Palette.warmRowBorder)
                MurmurIconView(icon: .notetaker)
                    .frame(width: 16, height: 16)
                    .foregroundStyle(Palette.sunsetDeep)
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text("Screen Recording access needed")
                    .font(.manrope(15, .semibold))
                    .foregroundStyle(Palette.warmInk)
                Text("Notetaker uses this only to hear the other side of a call through the "
                     + "meeting app's own audio — it never records your screen.")
                    .font(.manrope(12.5))
                    .foregroundStyle(Palette.warmInkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                Button { controller.requestScreenRecordingAccess() } label: {
                    PrimaryActionLabel(title: "Enable in System Settings", icon: nil)
                }
                .buttonStyle(PressScaleButtonStyle(scale: 0.97))
                .padding(.top, 10)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// Follows the capture state. Starting is sunset (it starts recording
    /// now — the same rule as Record elsewhere), stopping is red; the
    /// options only show while idle. Errors sit inside the card.
    private var captureCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                switch controller.state {
                case .idle:
                    statusDot(color: Palette.warmInkFainter)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(idleStatusLabel)
                            .font(.manrope(15, .semibold))
                            .foregroundStyle(Palette.warmInk)
                        Text(controller.isDiarizerReady
                             ? "Start it before or during a call — it captures your mic and the call's own audio."
                             : "Preparing the on-device speaker model — capture still works meanwhile.")
                            .font(.manrope(12.5))
                            .foregroundStyle(Palette.warmInkSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Button { controller.start(app: controller.detector.activeMeetingApp) } label: {
                        HStack(spacing: 7) {
                            Circle().fill(.white).frame(width: 9, height: 9)
                            Text("Start Notetaker").font(.manrope(13, .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 36)
                        .background(Palette.sunset, in: RoundedRectangle(cornerRadius: Radius.md))
                    }
                    .buttonStyle(PressScaleButtonStyle(scale: 0.97))

                case .capturing(let startedAt):
                    statusDot(color: Palette.sunset, pulsing: true)
                    VStack(alignment: .leading, spacing: 3) {
                        // A running timer, not just the start time.
                        TimelineView(.periodic(from: startedAt, by: 1)) { context in
                            Text("Listening · \(Self.elapsed(from: startedAt, to: context.date))")
                                .font(.manrope(15, .semibold))
                                .monospacedDigit()
                                .foregroundStyle(Palette.warmInk)
                        }
                        // A rough, live-updating caption of each side — not
                        // the real transcript (that's diarized properly once
                        // capture stops), just reassurance Murmur is hearing
                        // the call. Head-truncated so the newest words show.
                        if !controller.liveTranscriptYou.isEmpty {
                            liveLine("You", controller.liveTranscriptYou)
                        }
                        if !controller.liveTranscriptOthers.isEmpty {
                            liveLine("Them", controller.liveTranscriptOthers)
                        }
                    }
                    Spacer(minLength: 12)
                    Button("Cancel") { controller.cancel() }
                        .buttonStyle(.plain)
                        .font(.manrope(13, .medium))
                        .foregroundStyle(Palette.warmInkSoft)
                    Button { controller.stop() } label: {
                        HStack(spacing: 7) {
                            RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: 10, height: 10)
                            Text("Stop & save").font(.manrope(13, .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 36)
                        .background(Palette.danger, in: RoundedRectangle(cornerRadius: Radius.md))
                    }
                    .buttonStyle(PressScaleButtonStyle(scale: 0.97))

                case .processing:
                    statusDot(color: Palette.warmInkFainter)
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Transcribing and summarizing…")
                            .font(.manrope(15, .semibold))
                            .foregroundStyle(Palette.warmInk)
                    }
                    Spacer(minLength: 0)
                }
            }
            if let error = controller.lastError {
                Text(error)
                    .font(.manrope(12))
                    .foregroundStyle(Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                    .padding(.leading, 34)
            }
            if isIdle {
                NotetakerOptions(detector: controller.detector,
                                 browserDetectionEnabled: $browserDetectionEnabled)
                    .padding(.top, 18)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, isIdle ? 10 : 22)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var isIdle: Bool {
        if case .idle = controller.state { return true }
        return false
    }

    private static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(Int(now.timeIntervalSince(start)), 0)
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "Google Meet looks like it's running" for a browser match, same as
    /// a native app's own name — the raw browser name ("Chrome looks like
    /// it's running") would say nothing useful about whether there's
    /// actually a call to capture.
    private var idleStatusLabel: String {
        guard let app = controller.detector.activeMeetingApp else { return "No meeting detected" }
        let name = controller.detector.activeMeetingServiceName ?? app.displayName
        return "\(name) looks like it's running"
    }

    private func statusDot(color: Color, pulsing: Bool = false) -> some View {
        PulsingDot(color: color, size: 9, maxScale: 2.0, active: pulsing)
            .frame(width: 20, height: 20)
    }

    private func liveLine(_ label: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("\(label):")
                .font(.manrope(11.5, .semibold))
                .foregroundStyle(Palette.warmInkFainter)
            Text(text)
                .font(.manrope(12))
                .foregroundStyle(Palette.warmInkSoft)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .frame(maxWidth: 460, alignment: .leading)
    }

    // MARK: Before the first note

    /// What a note looks like, faded and labelled as an example — instead
    /// of a grey box with one sentence.
    private var exampleCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .lastTextBaseline) {
                Text("Your meeting notes will appear here")
                    .font(.manrope(15, .semibold))
                    .foregroundStyle(Palette.warmInk)
                Spacer()
                Text("Example")
                    .font(.manrope(11.5))
                    .foregroundStyle(Palette.warmInkFaint)
            }
            Text("Each one has a summary, action items you can tick off, and the full transcript with who "
                 + "said what.")
                .font(.manrope(12.5))
                .foregroundStyle(Palette.warmInkSoft)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Weekly sync with Anna").font(.manrope(13.5, .semibold))
                    Spacer()
                    Text("Zoom · 32 min").font(.manrope(11.5)).foregroundStyle(Palette.warmInkFaint)
                }
                Text("Agreed to move the launch to Thursday so the demo video is ready; Anna tells the team today.")
                    .font(.manrope(12.5))
                    .foregroundStyle(Palette.warmInkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 6) {
                    exampleActionItem("Record the demo video — you, Wednesday")
                    exampleActionItem("Tell the team about the new date — Anna")
                }
            }
            .foregroundStyle(Palette.warmInk)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Palette.warmRowBorder, lineWidth: 1))
            .opacity(0.6)
            .allowsHitTesting(false)
            .padding(.top, 16)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func exampleActionItem(_ text: String) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 4)
                .stroke(Palette.warmDivider, lineWidth: 1.2)
                .frame(width: 13, height: 13)
            Text(text).font(.manrope(12.5))
        }
    }

    // MARK: Notes

    /// Search on the right, like Home's history — only once there are notes.
    private var notesToolbar: some View {
        HStack(spacing: 10) {
            Spacer()
            if searchOpen {
                HStack(spacing: 8) {
                    MurmurIconView(icon: .search)
                        .frame(width: 12, height: 12)
                        .foregroundStyle(Palette.warmInkFaint)
                    TextField("Search meetings", text: $searchText)
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
                       hoverFill: Palette.hoverWash,
                       help: searchOpen ? "Close search" : "Search meetings") {
                searchOpen.toggle()
                if !searchOpen { searchText = "" }
            }
        }
        .padding(.bottom, 4)
    }

    /// Grouped by day and styled like Home's history.
    private var notesList: some View {
        let notes = filteredNotes
        let calendar = Calendar.current
        let days = Dictionary(grouping: notes) { calendar.startOfDay(for: $0.date) }
        let order = days.keys.sorted(by: >)
        return VStack(alignment: .leading, spacing: 0) {
            if notes.isEmpty {
                Text("No meetings match \u{201c}\(searchText)\u{201d}.")
                    .font(.manrope(12.5))
                    .italic()
                    .foregroundStyle(Palette.warmInkFaint)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                    .background(Palette.warmRowBorder, in: RoundedRectangle(cornerRadius: Radius.lg))
            }
            ForEach(Array(order.enumerated()), id: \.element) { index, day in
                Text(dayLabel(day).uppercased())
                    .font(.manrope(10, .semibold))
                    .kerning(0.9)
                    .foregroundStyle(Palette.warmInkSoft)
                    .padding(.top, index == 0 ? 0 : 14)
                    .padding(.bottom, 6)
                ForEach((days[day] ?? []).sorted { $0.date > $1.date }) { note in
                    MeetingRow(note: note) { selectedNote = note }
                }
            }
        }
    }

    private func dayLabel(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// Browser detection and calendar as proper option rows (they used to be
/// orange links that switched a setting on and then vanished, with no way
/// to switch it back off here). Observes the detector directly so
/// "Connect" becomes "Connected" the moment access is granted.
private struct NotetakerOptions: View {
    @ObservedObject var detector: MeetingDetector
    @Binding var browserDetectionEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Palette.warmRowBorder).frame(height: 1)
            row("Detect meetings in your browser",
                "Chrome, Safari, Edge, Arc, Brave — reads the tab's address only to spot a meeting link.") {
                NotetakerToggle(isOn: Binding(
                    get: { browserDetectionEnabled },
                    set: { value in
                        browserDetectionEnabled = value
                        Settings.browserMeetingDetectionEnabled = value
                    }))
            }
            Rectangle().fill(Palette.warmRowBorder).frame(height: 1)
            row("Titles and names from your calendar",
                "Names a note after the calendar event and its guests. Never changes your calendar.") {
                if detector.calendarAuthorized {
                    HStack(spacing: 5) {
                        MurmurIconView(icon: .check).frame(width: 11, height: 11)
                        Text("Connected").font(.manrope(12.5, .medium))
                    }
                    .foregroundStyle(Palette.warmInkSoft)
                } else {
                    Button { Task { await detector.requestCalendarAccess() } } label: {
                        Text("Connect")
                            .font(.manrope(12.5, .semibold))
                            .foregroundStyle(Palette.warmInk)
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .background(Palette.panel, in: RoundedRectangle(cornerRadius: Radius.sm))
                            .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Palette.warmDivider, lineWidth: 1))
                    }
                    .buttonStyle(PressScaleButtonStyle(scale: 0.96))
                }
            }
        }
    }

    private func row<Trailing: View>(_ title: String, _ detail: String,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.manrope(12.5, .semibold))
                    .foregroundStyle(Palette.warmInk)
                Text(detail)
                    .font(.manrope(12))
                    .foregroundStyle(Palette.warmInkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            trailing()
        }
        .padding(.vertical, 12)
    }
}

/// The warm on/off switch used across these pages.
private struct NotetakerToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(.murmurEase(0.18)) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Palette.sunset : Palette.warmDivider)
                    .frame(width: 32, height: 19)
                Circle()
                    .fill(.white)
                    .frame(width: 15, height: 15)
                    .padding(.horizontal, 2)
            }
            .frame(width: 32, height: 19)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Styled like Home's history row: time on the left, title and summary
/// line, "App · 32 min" on the right, the hover wash reaching
/// `NotetakerPage.bleed` past the text.
private struct MeetingRow: View {
    let note: MeetingNote
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Rectangle().fill(Palette.glassDivider).frame(height: 1)
                    .padding(.horizontal, NotetakerPage.bleed)
                    .opacity(hovering ? 0 : 1)
                HStack(alignment: .top, spacing: 13) {
                    Text(note.date, format: .dateTime.hour().minute())
                        .font(.manrope(12, .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Palette.warmInkSoft)
                        .frame(width: 40, alignment: .leading)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(note.title)
                            .font(.manrope(13, .semibold))
                            .foregroundStyle(Palette.warmInk)
                            .lineLimit(1)
                        Text(note.summary?.isEmpty == false ? note.summary! : "\(note.wordCount) words transcribed")
                            .font(.manrope(13))
                            .foregroundStyle(Palette.warmInkSoft)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(metaLabel)
                        .font(.manrope(11.5))
                        .foregroundStyle(Palette.warmInkFaint)
                }
                .padding(.horizontal, NotetakerPage.bleed)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: Radius.sm)
                        .fill(hovering ? Palette.hoverWash : Color.clear))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -NotetakerPage.bleed)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.1), value: hovering)
    }

    private var metaLabel: String {
        let minutes = Int(note.duration / 60)
        let length = minutes < 1 ? "< 1 min" : "\(minutes) min"
        guard let bundleID = note.appBundleID,
              NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
        else { return length }
        return "\(AppProfilesPage.resolveApp(bundleID: bundleID).name) · \(length)"
    }
}

// MARK: - Detail sheet

private struct MeetingDetailSheet: View {
    @ObservedObject var controller: NotetakerController
    let noteID: UUID
    let onDismiss: () -> Void

    @State private var renamingSpeaker: Int?
    @State private var renameText = ""
    @State private var justCopied = false

    /// Re-read from `controller.notes` on every render rather than held as
    /// a frozen snapshot — a rename or a checkbox toggle updates `notes`
    /// through the store, and this makes that show up in the still-open
    /// sheet immediately. Nil only in the brief moment between "user
    /// deleted this note" and the sheet actually dismissing.
    private var note: MeetingNote? { controller.notes.first { $0.id == noteID } }

    var body: some View {
        Group {
            if let note {
                content(for: note)
            } else {
                Color.clear.onAppear(perform: onDismiss)
            }
        }
        .frame(width: 580, height: 640)
        .background(Palette.homeGradient)
    }

    private func content(for note: MeetingNote) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sheetHeader(for: note)
            Rectangle().fill(Palette.warmDivider).frame(height: 1)
            ThinScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let summary = note.summary, !summary.isEmpty {
                        section("Summary") {
                            Text(summary)
                                .font(.manrope(13))
                                .foregroundStyle(Palette.warmInk)
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if !note.decisions.isEmpty {
                        section("Decisions") { bulletList(note.decisions) }
                    }
                    if !note.actionItems.isEmpty {
                        section("Action items") { actionItemsList(note.actionItems) }
                    }
                    section("Transcript") { transcript(for: note) }
                }
                .padding(24)
            }
        }
    }

    private func sheetHeader(for note: MeetingNote) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(note.title)
                    .font(.manrope(16, .semibold))
                    .foregroundStyle(Palette.warmInk)
                Text("\(note.date.formatted(date: .abbreviated, time: .shortened)) · \(note.wordCount) words")
                    .font(.manrope(11.5))
                    .foregroundStyle(Palette.warmInkFaint)
            }
            Spacer()
            IconButton(icon: justCopied ? .check : .copy, tint: justCopied ? Palette.sunset : nil,
                       help: "Copy note") {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(note.formattedNoteText, forType: .string)
                justCopied = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    justCopied = false
                }
            }
            IconButton(icon: .trash, help: "Delete") {
                controller.delete(id: note.id)
                onDismiss()
            }
            IconButton(icon: .plus, rotated: true, help: "Close", action: onDismiss)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.manrope(10.5, .bold))
                .kerning(0.6)
                .foregroundStyle(Palette.warmInkFaint)
            content()
        }
    }

    private func bulletList(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(Palette.sunset).frame(width: 4, height: 4).padding(.top, 6)
                    Text(item)
                        .font(.manrope(13))
                        .foregroundStyle(Palette.warmInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Same shape as `bulletList` but each row is a checkbox toggling that
    /// item's own `isDone` through `controller` — action items used to be
    /// read-only text with no way to mark one handled.
    private func actionItemsList(_ items: [ActionItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items) { item in
                Button {
                    controller.toggleActionItem(noteID: noteID, itemID: item.id)
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        // No dedicated checkbox glyph in `MurmurIcons` — a
                        // small rounded square reusing the existing `.check`
                        // mark, same "reuse what's already in the icon set"
                        // rule the rest of this page follows.
                        ZStack {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(item.isDone ? Palette.sunset : Color.clear)
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(item.isDone ? Color.clear : Palette.warmInkFainter, lineWidth: 1.4)
                            if item.isDone {
                                MurmurIconView(icon: .check)
                                    .frame(width: 8, height: 8)
                                    .foregroundStyle(.white)
                            }
                        }
                        .frame(width: 14, height: 14)
                        .padding(.top, 1)
                        Text(item.text)
                            .font(.manrope(13))
                            .foregroundStyle(item.isDone ? Palette.warmInkFaint : Palette.warmInk)
                            .strikethrough(item.isDone, color: Palette.warmInkFaint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Distinct speakers in this note, in first-appearance order — what
    /// drives both the transcript's own speaker headers and which ones
    /// `renameSpeakerRow` offers to rename. Index 0 ("You") is skipped:
    /// it's never ambiguous, so there's nothing to rename it to.
    private func speakerIndices(for note: MeetingNote) -> [Int] {
        var seen = Set<Int>()
        var ordered: [Int] = []
        for segment in note.segments where segment.speakerIndex != 0 {
            if seen.insert(segment.speakerIndex).inserted { ordered.append(segment.speakerIndex) }
        }
        return ordered
    }

    private func transcript(for note: MeetingNote) -> some View {
        let indices = speakerIndices(for: note)
        return VStack(alignment: .leading, spacing: 14) {
            if !indices.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(indices, id: \.self) { renameSpeakerRow($0, in: note) }
                }
                .padding(.bottom, 4)
            }
            VStack(alignment: .leading, spacing: 12) {
                ForEach(note.segments) { segment in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(segment.speakerName ?? "Speaker \(segment.speakerIndex + 1)")
                            .font(.manrope(11.5, .semibold))
                            .foregroundStyle(segment.speakerIndex == 0 ? Palette.sunsetDeep : Palette.warmInkSoft)
                        Text(segment.text)
                            .font(.manrope(13))
                            .foregroundStyle(Palette.warmInk)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func renameSpeakerRow(_ index: Int, in note: MeetingNote) -> some View {
        let currentName = note.segments.first { $0.speakerIndex == index }?.speakerName
        return HStack(spacing: 8) {
            if renamingSpeaker == index {
                TextField("Name", text: $renameText)
                    .textFieldStyle(.plain)
                    .font(.manrope(12))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Palette.panel, in: RoundedRectangle(cornerRadius: Radius.sm))
                    .frame(width: 140)
                    .onSubmit {
                        controller.rename(noteID: note.id, speakerIndex: index, to: renameText)
                        renamingSpeaker = nil
                    }
                Button("Save") {
                    controller.rename(noteID: note.id, speakerIndex: index, to: renameText)
                    renamingSpeaker = nil
                }
                .buttonStyle(GhostButtonStyle())
            } else {
                Text(currentName ?? "Speaker \(index + 1)")
                    .font(.manrope(12, .medium))
                    .foregroundStyle(Palette.warmInkSoft)
                Button("Rename") {
                    renameText = currentName ?? ""
                    renamingSpeaker = index
                }
                .buttonStyle(GhostButtonStyle())
            }
        }
    }
}
