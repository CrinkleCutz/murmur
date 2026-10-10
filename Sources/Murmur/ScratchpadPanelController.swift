import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Formats a keyCode + modifier combo as the keycap glyphs
/// `ScratchpadHotkeyEditor` and the nav bar HUD's "New note" row both show
/// — the two places a rebound combo needs to redisplay correctly.
enum KeyComboLabel {
    static func symbols(for modifiers: NSEvent.ModifierFlags) -> [String] {
        var out: [String] = []
        if modifiers.contains(.control) { out.append("⌃") }
        if modifiers.contains(.option) { out.append("⌥") }
        if modifiers.contains(.shift) { out.append("⇧") }
        if modifiers.contains(.command) { out.append("⌘") }
        return out
    }

    // Standard US ANSI virtual keycodes — covers what anyone would
    // realistically bind a global shortcut to (a letter, digit, or Space).
    // Not exhaustive of every key on every layout; falls back to a numeric
    // label rather than showing nothing for anything outside this set.
    private static let keyNames: [UInt16: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I",
        38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P", 12: "Q",
        15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7",
        28: "8", 25: "9", 49: "Space", 36: "Return", 48: "Tab", 51: "Delete",
        53: "Escape", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    static func keyName(for keyCode: UInt16) -> String {
        keyNames[keyCode] ?? "Key \(keyCode)"
    }

    /// e.g. "⌃⇧Space" — the compact form used in tooltips/labels that
    /// aren't rendering individual keycap chips.
    static func compact(modifiers: NSEvent.ModifierFlags, keyCode: UInt16) -> String {
        symbols(for: modifiers).joined() + keyName(for: keyCode)
    }
}

/// Toggles the floating Scratchpad panel with a global hotkey — Control+
/// Shift+Space by default, and user-rebindable via `ScratchpadHotkeyEditor`
/// (unlike `ProfileHotkeyMonitor`'s fixed Control+Shift+1…9 or
/// `TransformManager`'s fixed Option+1/2). Reads `Settings.scratchpadHotkey*`
/// fresh on every event rather than caching it, so a rebind via the editor
/// takes effect immediately with no need to restart this monitor.
///
/// The default is deliberately disjoint from every other combo this app
/// already owns, and `ScratchpadHotkeyEditor` refuses to save a rebind that
/// collides with the profile slots or Transforms — but a *user-chosen*
/// combo could still coincide with the main dictation hotkey's own bare
/// modifier if they pick that same modifier alone; unlike the fixed combos
/// above, this one can't be exhaustively pre-checked against a setting the
/// user can also change.
@MainActor
final class ScratchpadHotkeyMonitor {
    private var monitor: Any?
    var onTrigger: (() -> Void)?

    static let defaultKeyCode = UInt16(kVK_Space)
    static let defaultModifiers: NSEvent.ModifierFlags = [.control, .shift]

    func startMonitoring() {
        stopMonitoring()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self else { return }
            let modifiers = event.modifierFlags.intersection(
                [.command, .option, .control, .shift])
            guard modifiers == Settings.scratchpadHotkeyModifiers,
                  event.keyCode == Settings.scratchpadHotkeyKeyCode
            else { return }
            Task { @MainActor in self.onTrigger?() }
        }
    }

    func stopMonitoring() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}

@MainActor
private final class ScratchpadPanelModel: ObservableObject {
    @Published var activeNoteID: UUID?
    @Published var showingList = false
}

/// The floating quick-capture window the hotkey (or the in-app Scratchpad
/// page's "Start new note"/note rows) opens — a real `NSPanel`, not a page,
/// so it works from anywhere without switching apps or even opening
/// Murmur's own window.
///
/// Same construction as `StatusHUDController`/`NavBarHUDController`, except
/// this one *does* take keyboard focus on purpose: typing and dictating
/// into it is the entire point, unlike either HUD. `.nonactivatingPanel`
/// is still what makes that safe — a panel with that flag can become key
/// (so the text view can be first responder) without activating Murmur
/// itself, which is exactly what both HUDs' own comments already
/// established this flag does ("without it, showing this window activates
/// Murmur and breaks the paste"). That in turn is why dictating into this
/// panel needs no special-casing: `HotkeyMonitor` already runs a local
/// monitor specifically to catch the dictation key while *any* Murmur
/// window has focus (its own comment names the old single-buffer
/// Scratchpad as one such case), and `TextInserter` pastes via a raw
/// `CGEvent` keystroke, which lands wherever has real keyboard focus
/// regardless of which application AppKit considers frontmost.
@MainActor
final class ScratchpadPanelController {
    private var panel: NSPanel?
    private let store: ScratchpadStore
    private let app: AppDelegate
    private let model = ScratchpadPanelModel()

    private static let size = NSSize(width: 480, height: 440)

    init(store: ScratchpadStore, app: AppDelegate) {
        self.store = store
        self.app = app
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    /// Opens on a specific note — used when the in-app page's note list is
    /// clicked, so that note is what's showing, not whatever was last
    /// active or a fresh blank one.
    func open(noteID: UUID) {
        model.activeNoteID = noteID
        show()
    }

    func show() {
        if model.activeNoteID == nil || store.note(id: model.activeNoteID!) == nil {
            model.activeNoteID = store.notesByRecency.first?.id ?? store.createNote().id
        }
        let panel = existingOrNewPanel()
        panel.setFrameOrigin(centerOrigin(for: panel.frame.size))
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func centerOrigin(for size: NSSize) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return .zero }
        return NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2)
    }

    private func existingOrNewPanel() -> NSPanel {
        if let panel { return panel }

        let hosting = NSHostingView(rootView: ScratchpadPanelView(
            app: app, store: store, model: model,
            onClose: { [weak self] in self?.hide() }))
        hosting.frame = NSRect(origin: .zero, size: Self.size)

        let newPanel = NSPanel(
            contentRect: hosting.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        newPanel.contentView = hosting
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        // Drawn by the SwiftUI content itself instead (see its own
        // `.shadow`) — same call `StatusHUDController`/`NavBarHUDController`
        // made, for the same reason: a transparent borderless panel's own
        // system shadow applies to its full rectangular bounds, not the
        // rounded shape actually drawn inside them.
        newPanel.hasShadow = false
        newPanel.level = .floating
        newPanel.isReleasedWhenClosed = false
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel = newPanel
        return newPanel
    }
}

private struct ScratchpadPanelView: View {
    @ObservedObject var app: AppDelegate
    @ObservedObject var store: ScratchpadStore
    @ObservedObject var model: ScratchpadPanelModel
    let onClose: () -> Void

    @FocusState private var editorFocused: Bool
    @State private var searchText = ""

    private var activeNote: ScratchpadNote? {
        model.activeNoteID.flatMap(store.note(id:))
    }

    var body: some View {
        HStack(spacing: 0) {
            rail
            Rectangle().fill(Palette.warmRowBorder).frame(width: 1)
            if model.showingList {
                noteList
                Rectangle().fill(Palette.warmRowBorder).frame(width: 1)
            }
            VStack(spacing: 0) {
                topBar
                Rectangle().fill(Palette.warmRowBorder).frame(height: 1)
                if let note = activeNote {
                    editor(for: note)
                } else {
                    Text("No notes — press + to start one")
                        .font(.manrope(12.5))
                        .italic()
                        .foregroundStyle(Palette.warmInkFaint)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(width: 480, height: 440)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.panel))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        // `0 20px 40px rgba(20,20,19,.32)` — same shadow spec as the nav
        // bar HUD's own `NavPopover` (NavBarHUD.swift), the other floating
        // card in this app that isn't docked flat against a page.
        .shadow(color: .black.opacity(0.32), radius: 20, y: 14)
        .onAppear { editorFocused = true }
        .onChange(of: model.activeNoteID) { _, _ in editorFocused = true }
        .onExitCommand(perform: onClose)
    }

    private var rail: some View {
        VStack(spacing: 4) {
            IconButton(icon: .apps, size: 28, iconSize: 13,
                       tint: model.showingList ? Palette.sunsetDeep : nil,
                       help: model.showingList ? "Hide notes" : "Show notes") {
                model.showingList.toggle()
            }
            IconButton(icon: .plus, size: 28, iconSize: 13, help: "New note") {
                model.activeNoteID = store.createNote().id
                editorFocused = true
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .frame(width: 40)
    }

    private var noteList: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Search notes", text: $searchText)
                .textFieldStyle(.plain)
                .font(.manrope(11.5))
                .foregroundStyle(Palette.warmInk)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            Rectangle().fill(Palette.warmRowBorder).frame(height: 1)
            ThinScrollView {
                VStack(spacing: 1) {
                    ForEach(filteredNotes) { note in
                        NoteRow(note: note, selected: note.id == model.activeNoteID) {
                            model.activeNoteID = note.id
                        } onDelete: {
                            deleteNote(note)
                        }
                    }
                }
                .padding(6)
            }
        }
        .frame(width: 168)
    }

    private var filteredNotes: [ScratchpadNote] {
        ScratchpadStore.matching(searchText, in: store.notesByRecency)
    }

    private func deleteNote(_ note: ScratchpadNote) {
        store.delete(id: note.id)
        if model.activeNoteID == note.id {
            model.activeNoteID = store.notesByRecency.first?.id
        }
    }

    private var topBar: some View {
        HStack(spacing: 4) {
            Text(activeNote?.title ?? "Untitled")
                .font(.manrope(12.5, .semibold))
                .foregroundStyle(Palette.warmInk)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let note = activeNote, !note.isEmpty {
                IconButton(icon: .trans, size: 24, iconSize: 12, help: "Send to Transforms") {
                    app.pendingTransformText = note.text
                    app.pendingNavigateToPage = .transforms
                    app.showMainWindow()
                    onClose()
                }
                IconButton(icon: .arrowRight, size: 24, iconSize: 12, help: "Open in Murmur") {
                    app.pendingNavigateToPage = .scratchpad
                    app.showMainWindow()
                    onClose()
                }
            }
            IconButton(icon: .plus, size: 24, iconSize: 12, rotated: true, help: "Close") {
                onClose()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func editor(for note: ScratchpadNote) -> some View {
        TextEditor(text: Binding(
            get: { note.text },
            set: { store.update(id: note.id, text: $0) }))
            .font(.manrope(13.5))
            .lineSpacing(3)
            .foregroundStyle(Palette.warmInk)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .focused($editorFocused)
            .overlay(alignment: .topLeading) {
                if note.text.isEmpty {
                    Text("Start typing or dictate…")
                        .font(.manrope(13.5))
                        .italic()
                        .foregroundStyle(Palette.warmInkFaint)
                        .padding(.horizontal, 19)
                        .padding(.vertical, 20)
                        .allowsHitTesting(false)
                }
            }
    }
}

private struct NoteRow: View {
    let note: ScratchpadNote
    let selected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.title)
                        .font(.manrope(11.5, .semibold))
                        .foregroundStyle(Palette.warmInk)
                        .lineLimit(1)
                    Text(note.updatedAt, format: .relative(presentation: .named))
                        .font(.manrope(10))
                        .foregroundStyle(Palette.warmInkFaint)
                }
                Spacer(minLength: 4)
                if hovering {
                    IconButton(icon: .trash, size: 20, iconSize: 10, help: "Delete", action: onDelete)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(selected ? Palette.warmRowBorder : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Hotkey rebinding

/// Records the *next* key combination pressed while active, for
/// `ScratchpadHotkeyEditor`'s capture field. A local monitor, not global —
/// this only ever runs while that field is focused inside Murmur's own
/// sheet, so it has no business seeing keys typed into any other app.
@MainActor
private final class HotkeyCaptureModel: ObservableObject {
    @Published var isRecording = false
    @Published var pendingKeyCode = Settings.scratchpadHotkeyKeyCode
    @Published var pendingModifiers = Settings.scratchpadHotkeyModifiers
    @Published var conflictMessage: String?

    private var monitor: Any?

    func startRecording() {
        conflictMessage = nil
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.capture(event)
            // Swallows the keystroke — it's being recorded as a shortcut,
            // not typed anywhere, so it shouldn't also land in the field.
            return nil
        }
    }

    func stopRecording() {
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func capture(_ event: NSEvent) {
        // Escape cancels the *recording*, not the combo already saved —
        // leaves `pendingKeyCode`/`pendingModifiers` untouched.
        guard event.keyCode != UInt16(kVK_Escape) else {
            stopRecording()
            return
        }
        let modifiers = event.modifierFlags.intersection(
            [.command, .option, .control, .shift])
        // A bare key with no modifier would fire on every ordinary
        // keystroke system-wide — not a valid global shortcut. Keep
        // listening rather than accepting it.
        guard !modifiers.isEmpty else { return }

        if let conflict = Self.conflict(modifiers: modifiers, keyCode: event.keyCode) {
            conflictMessage = conflict
            stopRecording()
            return
        }
        conflictMessage = nil
        pendingKeyCode = event.keyCode
        pendingModifiers = modifiers
        Settings.scratchpadHotkeyKeyCode = event.keyCode
        Settings.scratchpadHotkeyModifiers = modifiers
        stopRecording()
    }

    /// Checked against the app's other *fixed* global combos — reusing
    /// their real definitions rather than re-transcribing keycodes by hand,
    /// since Mac virtual keycodes don't run in visual key order (1…9 are
    /// 18,19,20,21,23,22,26,28,25) and a hand-typed range would silently
    /// cover the wrong keys. Can't check against the main dictation hotkey
    /// the same way — that one is itself user-configurable, and structurally
    /// a bare-modifier hold rather than a modifier+key combo, so there's no
    /// fixed value to compare against here.
    private static func conflict(modifiers: NSEvent.ModifierFlags, keyCode: UInt16) -> String? {
        if modifiers == .option, Transform.all.contains(where: { $0.keyCode == keyCode }) {
            return "That combination is already used by Transforms."
        }
        if modifiers == [.control, .shift],
           ProfileHotkeySlot.allCases.contains(where: { $0.keyCode == keyCode }) {
            return "That combination is already used by an App Profile hotkey."
        }
        return nil
    }
}

/// The rebind sheet Wispr Flow's own "Click to enable shortcut" opens —
/// click the field, press a combination, it's saved immediately (no
/// separate save step to forget), Done just closes the sheet.
struct ScratchpadHotkeyEditor: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var capture = HotkeyCaptureModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Open Scratchpad")
                .font(.manrope(16, .semibold))
                .foregroundStyle(Palette.warmInk)
            Text("Press a key combination to open the floating Scratchpad panel from anywhere.")
                .font(.manrope(12.5))
                .foregroundStyle(Palette.warmInkFaint)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: capture.startRecording) {
                HStack {
                    if capture.isRecording {
                        Text("Press a key combination…")
                            .font(.manrope(12.5))
                            .foregroundStyle(Palette.warmInkFaint)
                    } else {
                        HStack(spacing: 3) {
                            ForEach(KeyComboLabel.symbols(for: capture.pendingModifiers), id: \.self) { symbol in
                                keycap(symbol)
                            }
                            keycap(KeyComboLabel.keyName(for: capture.pendingKeyCode))
                        }
                    }
                    Spacer()
                    MurmurIconView(icon: .edit)
                        .frame(width: 12, height: 12)
                        .foregroundStyle(Palette.warmInkFaint)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Palette.warmRowBorder, in: RoundedRectangle(cornerRadius: Radius.md))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.md)
                        .stroke(capture.isRecording ? Palette.sunsetDeep : .clear, lineWidth: 1.5))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let message = capture.conflictMessage {
                Text(message)
                    .font(.manrope(11.5))
                    .foregroundStyle(Palette.danger)
            }

            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("Done")
                        .font(.manrope(12.5, .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Palette.navActivePill, in: RoundedRectangle(cornerRadius: Radius.sm))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(22)
        .frame(width: 340)
        .onDisappear { capture.stopRecording() }
    }

    private func keycap(_ label: String) -> some View {
        Text(label)
            .font(.manrope(11, .semibold))
            .foregroundStyle(Palette.warmInk)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 5))
    }
}
