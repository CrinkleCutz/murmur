import AppKit
import Carbon.HIToolbox
import Foundation
import SwiftUI

enum NotetakerState: Equatable {
    case idle
    case capturing(startedAt: Date)
    case processing
}

/// Notetaker's own global hotkey — same rebindable mechanism as
/// `ScratchpadHotkeyMonitor`, just triggering a capture instead of toggling
/// a panel. Default ⌥M, matching Wispr Flow's own "Press Opt + M to join a
/// meeting or start the Notetaker" — free of collision with every other
/// fixed combo this app owns (Transforms' ⌥1/⌥2 and the profile slots'
/// ⌃⇧1…9 are on different keys entirely).
@MainActor
final class NotetakerHotkeyMonitor {
    private var monitor: Any?
    var onTrigger: (() -> Void)?

    static let defaultKeyCode = UInt16(kVK_ANSI_M)
    static let defaultModifiers: NSEvent.ModifierFlags = [.option]

    func startMonitoring() {
        stopMonitoring()
        // Hidden build: no global shortcut at all, so ⌥M stays free for whatever else it does on the user's Mac.
        guard Notetaker.isAvailable else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            let modifiers = event.modifierFlags.intersection(
                [.command, .option, .control, .shift])
            guard modifiers == Settings.notetakerHotkeyModifiers,
                  event.keyCode == Settings.notetakerHotkeyKeyCode
            else { return }
            Task { @MainActor in self.onTrigger?() }
        }
    }

    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// Owns the whole Notetaker feature end to end: detecting a likely
/// meeting, capturing both sides of the call, diarizing and transcribing
/// them, summarizing the result, and persisting it — kept as its own
/// controller rather than folded into `AppDelegate` (already large, and
/// shared with whatever else is being worked on there at the same time)
/// so this feature's own state lives in one place.
@MainActor
final class NotetakerController: ObservableObject {
    @Published private(set) var state: NotetakerState = .idle
    @Published private(set) var notes: [MeetingNote] = []
    @Published private(set) var screenRecordingAuthorized = CGPreflightScreenCaptureAccess()
    @Published var lastError: String?
    /// A rough, best-effort live transcript while `.capturing` — the same
    /// "reassurance, not the real transcript" role `LivePreviewTranscriber`
    /// already plays for normal dictation's own HUD, just shown split by
    /// side of the call instead of diarized: real per-speaker diarization
    /// only happens once, on the complete recording, in `stop()` below.
    /// Neither of these ever feeds that batch pipeline or the saved note.
    @Published private(set) var liveTranscriptYou = ""
    @Published private(set) var liveTranscriptOthers = ""

    let detector = MeetingDetector()
    private let store = MeetingNoteStore()
    private let knownSpeakers = KnownSpeakerStore()
    private let systemAudio = MeetingAudioCapture()
    private let micRecorder = AudioRecorder()
    private let transcriber = MeetingTranscriber()
    // Two separate instances, not one shared: `micLivePreview` sees only
    // `micRecorder`'s tap, `systemLivePreview` only `systemAudio`'s — each
    // is its own independent Flash-model session (see
    // `LivePreviewTranscriber`'s own header for why that model in
    // particular), mirroring `AppDelegate`'s own `livePreviewTranscriber`
    // for normal dictation rather than sharing that instance, which is
    // reserved for the main dictation HUD's own session bookkeeping.
    private let micLivePreview = LivePreviewTranscriber()
    private let systemLivePreview = LivePreviewTranscriber()
    private var activeApp: MeetingApp?
    // Read from Calendar the moment capture *starts*, not when it stops —
    // `MeetingDetector`'s own lookup only matches an event whose window
    // contains "now" within five minutes either side. Re-querying at
    // `stop()` instead used the time capture actually *ended*, so any
    // meeting that ran even a little past its scheduled slot (the common
    // case) would already have fallen outside that window by the time the
    // lookup ran, silently losing both the real title and the attendee
    // seed for the exact meetings most likely to still be the right one.
    private var capturedCalendarTitle: String?
    private var capturedAttendeeHint: String?
    /// Captured the same way and for the same reason as the calendar title
    /// above — "Google Meet", not nil, if `detector` matched a browser tab
    /// at the moment capture started. Falls back to the captured app's own
    /// name when this is nil (a native app, or browser detection off).
    private var capturedServiceName: String?
    /// Polls every 5s while `.capturing`, enforcing
    /// `Settings.notetakerAutoStopOnCallEnd`/`notetakerMaxRecordingMinutes` —
    /// see `checkWatchdog()` for what each actually checks.
    private var watchdogTimer: Timer?

    /// Set once by `AppDelegate` at launch to its own existing
    /// `recognize(fileAt:bundleID:)` — the same engine-selection and
    /// fallback logic every normal dictation already goes through, so a
    /// meeting clip is transcribed by whichever engine the user has
    /// configured, not a second, separate pipeline. Notetaker simply
    /// can't transcribe anything until this is wired up.
    var transcribeFile: ((URL) async throws -> String)?
    var rewriteEngine: RewriteEngine?
    /// Set by `AppDelegate` to its own `pipelineStats.record(...)` — lets a
    /// meeting's Harper/dictionary fix counts feed Insights' "Fixes made by
    /// Murmur" card the same way every normal dictation's do, instead of
    /// vanishing the moment `MeetingTranscriber` finishes with them.
    var recordPipelineStats: ((_ harperFixes: Int, _ dictionaryFixes: Int, _ snippetExpansions: Int) -> Void)?
    /// Set by `AppDelegate` to exclude/include its main window from screen
    /// recording (`NSWindow.sharingType`) — toggled around a capture when
    /// `Settings.notetakerHideFromScreenCapture` is on. `NotetakerController`
    /// has no window reference of its own to do this directly.
    var setWindowExcludedFromCapture: ((Bool) -> Void)?

    init() {
        notes = store.notes
        // Hidden build: no meeting detection (it watches running apps, the mic and the browser tab) and no
        // speaker-model download — a feature nobody can reach shouldn't run, ask for anything, or fetch anything.
        if Notetaker.isAvailable {
            detector.startWatching()
            Task { await transcriber.prepareDiarizer() }
        }
        micLivePreview.onUpdate = { [weak self] text in self?.liveTranscriptYou = text }
        systemLivePreview.onUpdate = { [weak self] text in self?.liveTranscriptOthers = text }
    }

    func refreshScreenRecordingStatus() {
        screenRecordingAuthorized = CGPreflightScreenCaptureAccess()
    }

    /// Shows the system permission prompt the first time; every call
    /// after the user has already answered it just re-reads their choice.
    func requestScreenRecordingAccess() {
        screenRecordingAuthorized = CGRequestScreenCaptureAccess()
    }

    var canStart: Bool {
        if case .idle = state { return true }
        return false
    }

    var isDiarizerReady: Bool { transcriber.isDiarizerReady }

    /// `app` nil means "capture my own mic only" — still useful (a solo
    /// voice memo of a call Murmur can't see the other side of, e.g. a
    /// phone call on speaker), just without diarized other-speaker turns.
    func start(app: MeetingApp?) {
        guard Notetaker.isAvailable, canStart else { return }
        // Needs an active license in an official release build, like dictation. Silent: this also runs on its own
        // when a meeting starts, and a sound out of nowhere mid-call would be worse than the note on the page.
        if let paused = LicenseStore.shared.pausedExplanation {
            lastError = paused
            return
        }
        lastError = nil
        activeApp = app
        capturedCalendarTitle = detector.currentEventTitle()
        capturedAttendeeHint = detector.currentEventAttendeeNames().first
        capturedServiceName = detector.activeMeetingServiceName
        liveTranscriptYou = ""
        liveTranscriptOthers = ""
        let startedAt = Date()
        do {
            try micRecorder.start()
        } catch {
            lastError = "Could not start recording: \(error.localizedDescription)"
            return
        }
        state = .capturing(startedAt: startedAt)
        if Settings.notetakerHideFromScreenCapture { setWindowExcludedFromCapture?(true) }
        startWatchdog(startedAt: startedAt)

        if Settings.notetakerLiveTranscriptEnabled {
            micLivePreview.start()
            micRecorder.onLivePreviewBuffer = { [weak self] buffer in
                Task { @MainActor in self?.micLivePreview.enqueue(buffer) }
            }
        }

        guard screenRecordingAuthorized, let app else { return }
        if Settings.notetakerLiveTranscriptEnabled {
            systemLivePreview.start()
            systemAudio.onLiveBuffer = { [weak self] buffer in
                Task { @MainActor in self?.systemLivePreview.enqueue(buffer) }
            }
        }
        Task {
            do {
                try await systemAudio.start(bundleID: app.rawValue)
            } catch {
                // The mic side alone still produces a usable (if
                // one-sided) note — this isn't fatal to the capture
                // already under way, just quietly narrower.
                lastError = "Couldn't capture the other side of the call " +
                    "(\(error.localizedDescription)) — still recording your own audio."
            }
        }
    }

    /// Checked every 5s while `.capturing`. Two independent triggers, either
    /// one calls `stop()`:
    /// - `notetakerAutoStopOnCallEnd`: the captured *native* app has fully
    ///   quit (not just lost focus — see the setting's own doc comment for
    ///   why frontmost-ness would false-trigger on simply tabbing away).
    ///   Skipped for a browser-detected meeting: a browser staying open
    ///   says nothing about whether the *call tab* is still active.
    /// - `notetakerMaxRecordingMinutes`: elapsed time since `startedAt`
    ///   exceeds the configured cap (`0` disables this check).
    private func startWatchdog(startedAt: Date) {
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkWatchdog(startedAt: startedAt) }
        }
    }

    private func stopWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }

    private func checkWatchdog(startedAt: Date) {
        guard case .capturing = state else { return }

        let maxMinutes = Settings.notetakerMaxRecordingMinutes
        if maxMinutes > 0, Date().timeIntervalSince(startedAt) >= Double(maxMinutes) * 60 {
            lastError = "Stopped automatically after \(maxMinutes) minutes."
            stop()
            return
        }

        if Settings.notetakerAutoStopOnCallEnd, let app = activeApp, !app.isBrowser {
            let stillRunning = NSWorkspace.shared.runningApplications
                .contains { $0.bundleIdentifier == app.rawValue }
            if !stillRunning { stop() }
        }
    }

    func cancel() {
        guard case .capturing = state else { return }
        _ = micRecorder.stop()
        micRecorder.onLivePreviewBuffer = nil
        systemAudio.onLiveBuffer = nil
        micLivePreview.stop()
        systemLivePreview.stop()
        stopWatchdog()
        setWindowExcludedFromCapture?(false)
        Task {
            if systemAudio.isCapturing {
                _ = await systemAudio.stop()
            }
        }
        state = .idle
        activeApp = nil
        capturedCalendarTitle = nil
        capturedAttendeeHint = nil
        capturedServiceName = nil
        liveTranscriptYou = ""
        liveTranscriptOthers = ""
    }

    func stop() {
        guard case .capturing(let startedAt) = state else { return }
        let capturedApp = activeApp
        let calendarTitle = capturedCalendarTitle
        let attendeeHint = capturedAttendeeHint
        let serviceName = capturedServiceName
        state = .processing
        activeApp = nil
        capturedCalendarTitle = nil
        capturedAttendeeHint = nil
        capturedServiceName = nil
        // Left on screen through the brief "Transcribing…" moment rather
        // than cleared immediately — same call `LivePreviewTranscriber`
        // itself makes for the main dictation HUD — then cleared for real
        // the next time `start()` runs.
        micRecorder.onLivePreviewBuffer = nil
        systemAudio.onLiveBuffer = nil
        micLivePreview.stop()
        systemLivePreview.stop()
        stopWatchdog()
        setWindowExcludedFromCapture?(false)

        Task {
            let micURL = micRecorder.stop()
            let systemURL = systemAudio.isCapturing ? await systemAudio.stop() : nil
            defer {
                if let micURL { try? FileManager.default.removeItem(at: micURL) }
                if let systemURL { try? FileManager.default.removeItem(at: systemURL) }
            }

            guard let transcribeFile else {
                lastError = "Notetaker isn't wired up to a transcription engine yet."
                state = .idle
                return
            }

            let transcription = await transcriber.transcribe(
                micURL: micURL, systemAudioURL: systemURL,
                knownSpeakers: knownSpeakers.speakers,
                attendeeHint: attendeeHint,
                transcribeFile: transcribeFile)
            guard !transcription.segments.isEmpty else {
                lastError = "Didn't catch any speech in that meeting — nothing was saved."
                state = .idle
                return
            }
            recordPipelineStats?(transcription.harperFixes, transcription.dictionaryFixes, 0)

            var note = MeetingNote(
                title: calendarTitle ?? serviceName ?? capturedApp?.displayName ?? "Meeting",
                date: startedAt, duration: Date().timeIntervalSince(startedAt),
                appBundleID: capturedApp?.rawValue, calendarTitle: calendarTitle,
                segments: transcription.segments)

            if let rewriteEngine,
               let result = await MeetingSummarizer.summarize(note, engine: rewriteEngine) {
                note.summary = result.summary
                note.decisions = result.decisions
                note.actionItems = result.actionItems.map { ActionItem(text: $0) }
            }

            store.add(note)
            notes = store.notes
            state = .idle
        }
    }

    /// Renames every segment sharing `speakerIndex` within one note at
    /// once, and — given a real name and at least one of those segments
    /// having its own diarized embedding — enrolls that voice in
    /// `KnownSpeakerStore` too, so the *next* meeting with this same
    /// person recognizes them automatically instead of asking again.
    /// Clearing a name back to empty only un-names this note's segments;
    /// it deliberately doesn't un-enroll the speaker (a typo fixed by
    /// clearing-then-retyping shouldn't cost the enrollment).
    func rename(noteID: UUID, speakerIndex: Int, to name: String) {
        guard let index = notes.firstIndex(where: { $0.id == noteID }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        var enrollmentEmbedding: [Float]?
        for i in notes[index].segments.indices where notes[index].segments[i].speakerIndex == speakerIndex {
            notes[index].segments[i].speakerName = trimmed.isEmpty ? nil : trimmed
            if enrollmentEmbedding == nil { enrollmentEmbedding = notes[index].segments[i].embedding }
        }
        store.update(notes[index])
        if !trimmed.isEmpty, let embedding = enrollmentEmbedding {
            knownSpeakers.upsert(name: trimmed, embedding: embedding)
        }
    }

    func toggleActionItem(noteID: UUID, itemID: UUID) {
        guard let noteIndex = notes.firstIndex(where: { $0.id == noteID }),
              let itemIndex = notes[noteIndex].actionItems.firstIndex(where: { $0.id == itemID })
        else { return }
        notes[noteIndex].actionItems[itemIndex].isDone.toggle()
        store.update(notes[noteIndex])
    }

    func delete(id: UUID) {
        store.delete(id: id)
        notes = store.notes
    }
}

/// `NotetakerHotkeyEditor`'s capture field — a local monitor scoped to that
/// sheet, mirroring `HotkeyCaptureModel` (Scratchpad's twin) exactly, just
/// writing to `Settings.notetakerHotkey*` and checking conflicts against
/// Scratchpad's own now-rebindable combo too, not just the fixed ones.
@MainActor
private final class NotetakerHotkeyCaptureModel: ObservableObject {
    @Published var isRecording = false
    @Published var pendingKeyCode = Settings.notetakerHotkeyKeyCode
    @Published var pendingModifiers = Settings.notetakerHotkeyModifiers
    @Published var conflictMessage: String?

    private var monitor: Any?

    func startRecording() {
        conflictMessage = nil
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.capture(event)
            return nil
        }
    }

    func stopRecording() {
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func capture(_ event: NSEvent) {
        guard event.keyCode != UInt16(kVK_Escape) else {
            stopRecording()
            return
        }
        let modifiers = event.modifierFlags.intersection(
            [.command, .option, .control, .shift])
        guard !modifiers.isEmpty else { return }

        if let conflict = Self.conflict(modifiers: modifiers, keyCode: event.keyCode) {
            conflictMessage = conflict
            stopRecording()
            return
        }
        conflictMessage = nil
        pendingKeyCode = event.keyCode
        pendingModifiers = modifiers
        Settings.notetakerHotkeyKeyCode = event.keyCode
        Settings.notetakerHotkeyModifiers = modifiers
        stopRecording()
    }

    private static func conflict(modifiers: NSEvent.ModifierFlags, keyCode: UInt16) -> String? {
        if modifiers == .option, Transform.all.contains(where: { $0.keyCode == keyCode }) {
            return "That combination is already used by Transforms."
        }
        if modifiers == [.control, .shift],
           ProfileHotkeySlot.allCases.contains(where: { $0.keyCode == keyCode }) {
            return "That combination is already used by an App Profile hotkey."
        }
        if modifiers == Settings.scratchpadHotkeyModifiers, keyCode == Settings.scratchpadHotkeyKeyCode {
            return "That combination already opens Scratchpad."
        }
        return nil
    }
}

/// The rebind sheet for Notetaker's own hotkey — same shape as
/// `ScratchpadHotkeyEditor`, opened from the Notetaker tab of Settings
/// instead of from a page-level chip.
struct NotetakerHotkeyEditor: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var capture = NotetakerHotkeyCaptureModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Start Notetaker")
                .font(.manrope(16, .semibold))
                .foregroundStyle(Palette.warmInk)
            Text("Press a key combination to start capturing the current call from anywhere.")
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
