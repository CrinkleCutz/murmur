import AppKit
import SwiftUI

// MARK: - Scratchpad
//
// Rebuilt to match what Wispr Flow's own Scratchpad actually is (confirmed
// by opening it directly, not going off the name): a fast, location-
// independent quick-capture tool, not one more page holding one more
// text box. The real editing surface is `ScratchpadPanelController`'s
// floating panel — summonable with Control+Shift+Space from anywhere,
// no need to even have Murmur's window open. This page is what Wispr
// Flow's own main-window Scratchpad screen is: a hero explaining the
// idea plus "Start new note", and "Recents" — every note, searchable,
// click one to reopen it in the floating panel.
//
// The previous version's single autosaving buffer (`scratchpad.txt`) is
// migrated into this store's first note on first launch — see
// `ScratchpadStore`'s own note on that.

struct ScratchpadPage: View {
    @ObservedObject var app: AppDelegate
    /// Observed directly, not only through `app`: the floating panel edits
    /// notes through this store, and `AppDelegate` doesn't republish the
    /// store's own changes — which is why this page used to need a manual
    /// Refresh button to see a note written in the panel.
    @ObservedObject private var store: ScratchpadStore
    @State private var searchOpen = false
    @State private var searchText = ""
    @State private var showingHotkeyEditor = false
    @State private var rowHover = ScratchpadRowHover()
    // `Settings.scratchpadHotkey*` is plain `UserDefaults`, not
    // `@Published` — mirrored here so the chip actually re-renders once
    // the editor sheet saves a rebind, instead of silently going stale
    // until this page happens to reload some other way.
    @State private var hotkeyKeyCode = Settings.scratchpadHotkeyKeyCode
    @State private var hotkeyModifiers = Settings.scratchpadHotkeyModifiers

    init(app: AppDelegate) {
        self.app = app
        _store = ObservedObject(wrappedValue: app.scratchpadStore)
    }

    /// How far a row's hover highlight reaches past the text column — the
    /// same 10pt Home's history rows use.
    static let bleed: CGFloat = 10

    var body: some View {
        GlassPanelPage {
            ThinScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    hero.padding(.top, 24)
                    if store.notes.isEmpty {
                        starters.padding(.top, 28)
                    } else {
                        notesToolbar.padding(.top, 24)
                        notesList
                    }
                }
                .padding(.horizontal, Self.bleed)
            }
            // Widened by the rows' highlight bleed so the scroll view's
            // clip doesn't cut it off; the content is inset back above.
            .padding(.horizontal, -Self.bleed)
        }
        .sheet(isPresented: $showingHotkeyEditor, onDismiss: {
            hotkeyKeyCode = Settings.scratchpadHotkeyKeyCode
            hotkeyModifiers = Settings.scratchpadHotkeyModifiers
        }) { ScratchpadHotkeyEditor() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Scratchpad")
                .font(.manrope(22, .medium))
                .tracking(-0.33)
                .foregroundStyle(Palette.warmInk)
            Text("A fast place to park a thought — dictate or type it, come back and develop it later.")
                .font(.manrope(12.5))
                .foregroundStyle(Palette.warmInkFaint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var shortcutKeys: [String] {
        KeyComboLabel.symbols(for: hotkeyModifiers) + [KeyComboLabel.keyName(for: hotkeyKeyCode)]
    }

    /// Home's hero anatomy — small uppercase label left, the shortcut chip
    /// right (click to rebind), headline, one line, primary action — on a
    /// white card: orange is an accent in Murmur, never a card fill, so here
    /// it's only the label. 27pt, not Home's 33: at 33 on white it read
    /// like a second Home.
    private var hero: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Text("QUICK CAPTURE")
                    .font(.manrope(10, .bold))
                    .kerning(0.9)
                    .foregroundStyle(Palette.sunsetDeep)
                Spacer()
                Button { showingHotkeyEditor = true } label: {
                    HStack(spacing: 6) {
                        Text("Open anywhere")
                            .font(.manrope(12, .medium))
                        Text(shortcutKeys.joined())
                            .font(.manrope(12, .semibold))
                        MurmurIconView(icon: .edit)
                            .frame(width: 10, height: 10)
                            .opacity(0.7)
                    }
                    .foregroundStyle(Palette.warmInk)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Palette.warmRowBorder, in: RoundedRectangle(cornerRadius: Radius.sm))
                }
                .buttonStyle(.plain)
                .help("Change the Scratchpad shortcut")
            }
            Text("For quick thoughts you want to come back to.")
                .font(.manrope(27, .medium))
                .tracking(-0.54)
                .foregroundStyle(Palette.warmInk)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 18)
            Text("Hold \(app.hotkey.displayName) to dictate straight into a note — "
                 + "Murmur's window doesn't need to be open.")
                .font(.manrope(14))
                .foregroundStyle(Palette.warmInkSoft)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 560, alignment: .leading)
                .padding(.top, 8)
            Button { openNewNote() } label: {
                PrimaryActionLabel(title: "Start new note")
            }
            .buttonStyle(PressScaleButtonStyle(scale: 0.97))
            .padding(.top, 18)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    // MARK: Empty state

    private static let starterKinds: [(icon: MurmurIcon, title: String, line: String)] = [
        (.check, "To-do list", "Jot down what needs doing, in any order."),
        (.ask, "Message draft", "Get the wording right before it goes anywhere."),
        (.wave, "Brain dump", "Talk it through now, shape it later."),
    ]

    /// The first thing a new user sees here: the three things the page is
    /// for, each one click from a note that's already started, plus the
    /// real shortcut (read from settings — the old text had ⌃⇧Space written
    /// in, so it went stale after a rebind) as keycaps.
    private var starters: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("START WITH")
                .font(.manrope(10, .semibold))
                .kerning(0.9)
                .foregroundStyle(Palette.warmInkSoft)
                .padding(.bottom, 10)
            HStack(spacing: 16) {
                ForEach(Self.starterKinds, id: \.title) { kind in
                    StarterCard(icon: kind.icon, title: kind.title, line: kind.line) {
                        openNewNote(firstLine: kind.title)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text("Open it from any app with")
                    .font(.manrope(12.5))
                    .foregroundStyle(Palette.warmInkSoft)
                HStack(spacing: 4) {
                    ForEach(shortcutKeys, id: \.self) { key in ShortcutKeycap(label: key) }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 28)
        }
    }

    /// A new note, opened in the floating panel. A starter's title goes on
    /// the first line (which is what `ScratchpadNote.title` reads), with the
    /// writing starting on the line below it.
    private func openNewNote(firstLine: String? = nil) {
        let note = store.createNote()
        if let firstLine { store.update(id: note.id, text: firstLine + "\n") }
        app.openScratchpadPanel(noteID: note.id)
    }

    // MARK: Notes

    /// Search and new note, right-aligned like Home's history controls. No
    /// Refresh — the list follows the store live now.
    private var notesToolbar: some View {
        HStack(spacing: 10) {
            Spacer()
            if searchOpen {
                HStack(spacing: 8) {
                    MurmurIconView(icon: .search)
                        .frame(width: 12, height: 12)
                        .foregroundStyle(Palette.warmInkFaint)
                    TextField("Search notes", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.manrope(12.5))
                        .foregroundStyle(Palette.warmInk)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Palette.warmRowBorder, in: RoundedRectangle(cornerRadius: Radius.sm))
                .frame(width: 200)
            }
            IconButton(icon: searchOpen ? .plus : .search,
                       rotated: searchOpen,
                       hoverFill: Palette.hoverWash,
                       help: searchOpen ? "Close search" : "Search notes") {
                searchOpen.toggle()
                if !searchOpen { searchText = "" }
            }
            IconButton(icon: .plus, hoverFill: Palette.hoverWash, help: "New note") { openNewNote() }
        }
        .padding(.bottom, 14)
    }

    private var filteredNotes: [ScratchpadNote] {
        ScratchpadStore.matching(searchText, in: store.notesByRecency)
    }

    /// Grouped by day and styled exactly like Home's history: an uppercase
    /// day label, the time on the left, title and a one-line preview, and
    /// actions that appear on hover.
    private var notesList: some View {
        let notes = filteredNotes
        let calendar = Calendar.current
        let days = Dictionary(grouping: notes) { calendar.startOfDay(for: $0.updatedAt) }
        let order = days.keys.sorted(by: >)
        return VStack(alignment: .leading, spacing: 0) {
            if notes.isEmpty {
                Text("No notes match \u{201c}\(searchText)\u{201d}.")
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
                let dayNotes = days[day] ?? []
                ForEach(Array(dayNotes.enumerated()), id: \.element.id) { i, note in
                    ScratchpadNoteRow(
                        note: note,
                        noteAboveID: i > 0 ? dayNotes[i - 1].id : nil,
                        hover: rowHover,
                        onOpen: { app.openScratchpadPanel(noteID: note.id) },
                        onDelete: { store.delete(id: note.id) })
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

/// Which note row the pointer is over — shared so the row below a lit row
/// can hide its top rule too (the same approach as Home's `HistoryHover`).
@Observable
private final class ScratchpadRowHover {
    var id: UUID?
}

/// One of the empty page's three starting points — a white card in the
/// same language as Insights' cards, with a sunset hairline on hover.
private struct StarterCard: View {
    let icon: MurmurIcon
    let title: String
    let line: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7).fill(Palette.warmRowBorder)
                    MurmurIconView(icon: icon)
                        .frame(width: 13, height: 13)
                        .foregroundStyle(Palette.sunsetDeep)
                }
                .frame(width: 28, height: 28)
                Text(title)
                    .font(.manrope(13, .semibold))
                    .foregroundStyle(Palette.warmInk)
                    .padding(.top, 14)
                Text(line)
                    .font(.manrope(12.5))
                    .foregroundStyle(Palette.warmInkSoft)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Palette.sunset.opacity(hovering ? 0.5 : 0), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(PressScaleButtonStyle(scale: 0.98))
        .onHover { hovering = $0 }
        .animation(.murmurEase(0.12), value: hovering)
    }
}

/// A shortcut key drawn as a keycap — Manrope on white with a hairline, not
/// the shared monospaced `Keycap`, to sit with this page's own type.
private struct ShortcutKeycap: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.manrope(11.5, .semibold))
            .foregroundStyle(Palette.warmInk)
            .padding(.horizontal, 7)
            .frame(minWidth: 24, minHeight: 22)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.glassDivider, lineWidth: 0.5))
    }
}

/// Styled like Home's `HistoryRowView`: time column, title + one-line
/// preview, translucent hover wash reaching `ScratchpadPage.bleed` past
/// the text, the rules beside a lit row stepping aside, actions on hover.
private struct ScratchpadNoteRow: View {
    let note: ScratchpadNote
    let noteAboveID: UUID?
    let hover: ScratchpadRowHover
    let onOpen: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    private var hidesTopRule: Bool {
        hovering || (noteAboveID != nil && hover.id == noteAboveID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Palette.glassDivider).frame(height: 1)
                .padding(.horizontal, ScratchpadPage.bleed)
                .opacity(hidesTopRule ? 0 : 1)
            HStack(alignment: .top, spacing: 13) {
                Text(note.updatedAt, format: .dateTime.hour().minute())
                    .font(.manrope(12, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Palette.warmInkSoft)
                    .frame(width: 40, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    Text(note.title)
                        .font(.manrope(13, .semibold))
                        .foregroundStyle(Palette.warmInk)
                        .lineLimit(1)
                    Text(preview)
                        .font(.manrope(13))
                        .foregroundStyle(Palette.warmInkSoft)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    IconButton(icon: .copy, hoverFill: Palette.hoverWash, help: "Copy") {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(note.text, forType: .string)
                    }
                    IconButton(icon: .trash, hoverFill: Palette.hoverWash, help: "Delete", action: onDelete)
                }
                .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, ScratchpadPage.bleed)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: Radius.sm)
                    .fill(hovering ? Palette.hoverWash : Color.clear))
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)
            .onHover { inside in
                hovering = inside
                if inside {
                    hover.id = note.id
                } else if hover.id == note.id {
                    hover.id = nil
                }
            }
        }
        .padding(.horizontal, -ScratchpadPage.bleed)
        .animation(.easeOut(duration: 0.1), value: hovering)
        .animation(.easeOut(duration: 0.1), value: hidesTopRule)
    }

    /// The note's text after its first line (the title) — or a quiet
    /// placeholder when that's all there is.
    private var preview: String {
        let rest = note.text.split(separator: "\n", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
        let flat = rest.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return flat.isEmpty ? (note.isEmpty ? "Empty note" : "No more text") : flat
    }
}
