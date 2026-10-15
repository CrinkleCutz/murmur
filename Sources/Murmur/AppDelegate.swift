import AppKit
import AVFoundation
import Combine
import Foundation
import OSLog
import SwiftUI
import UserNotifications

/// Dictation-path tracing. The pipeline runs entirely while the app's own
/// window is hidden behind whatever you're dictating into, so when it
/// stalls there is otherwise nothing at all to inspect — read it back with:
/// `log show --predicate 'subsystem == "local.murmur"' --last 10m`
let dictationLog = Logger(subsystem: "local.murmur", category: "dictation")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate,
    UNUserNotificationCenterDelegate, ObservableObject {

    enum UIState {
        case idle, recording, processing
    }

    // Observable state for the dashboard window.
    @Published var uiState: UIState = .idle { didSet {
        updateIcon(); updateHUD(); updateEscapeInterceptor()
        if uiState == .idle, !pendingCorrectionNotices.isEmpty {
            let waiting = pendingCorrectionNotices
            pendingCorrectionNotices = []
            // After the check mark has had its moment.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, self.uiState == .idle else { return }
                self.correctionToast.show(waiting)
            }
        } else if uiState != .idle {
            pendingCorrectionNotices += correctionToast.interrupt()
        }
        // Other sound down while the microphone is open, back the moment it closes — see `AudioDuck`.
        if uiState == .recording, oldValue != .recording {
            AudioDuck.shared.begin()
        } else if oldValue == .recording, uiState != .recording {
            AudioDuck.shared.end()
        }
    } }
    @Published var isHandsFree = false { didSet { updateHUD() } }
    @Published var entries: [HistoryEntry] = []
    @Published var micAuthorized = false
    @Published var axTrusted = false
    @Published var hotkey: HotkeyMonitor.Hotkey = Settings.hotkey
    @Published var localeID: String = Settings.locale.identifier
    /// Settings ▸ Dictation ▸ Translate into — a language code, or nil when off. See `TranslateInto`.
    @Published var translateInto: String? = TranslateInto.target
    @Published var lastError: String?
    /// Onboarding's "bring your words over" row: the Dictionary opens with its import sheet.
    @Published var pendingDictionaryImport = false
    /// What was learned while a dictation was in progress — shown on the card once it is idle again.
    private var pendingCorrectionNotices: [LearnedNotice] = []
    private let correctionToast = CorrectionToastController()
    private let pasteLastShortcut = PasteLastShortcut()
    /// A Bluetooth headset is still switching into call mode: the start sound waits until it can hear you.
    private var startSoundWaitsForHeadset = false
    /// One line while macOS secure input has been on long enough to matter (see `SecureInputMonitor`); nil otherwise.
    @Published var secureInputNotice: String?
    private var secureInputObserver: AnyCancellable?

    /// Height of the custom titlebar strip drawn in SwiftUI; the traffic
    /// lights are aligned to its vertical center.
    static let titlebarHeight: CGFloat = 44
    /// AppKit's own traffic-light position per window, before `alignTrafficLights(in:)` moves them.
    private var trafficLightBaselines: [ObjectIdentifier: CGFloat] = [:]

    private var statusItem: NSStatusItem!
    private var window: NSWindow?
    private var onboardingWindow: NSWindow?
    private let navBarHUD = NavBarHUDController()
    private let recorder = AudioRecorder()
    /// A long whisper.cpp dictation being transcribed while it's still spoken — see `LiveChunkSession`.
    private var liveChunks: LiveChunkSession?
    /// Between the key's release and the recording actually stopping (`AudioRecorder.stopAfterTail`).
    private var isFinishingRecording = false
    /// The app that had keyboard focus when the key came up — where the text is meant to go.
    private var releaseTargetPID: pid_t?
    /// The Murmur field the keyboard was in when the key came up, if any — the dictation goes there (`OwnTextField`).
    private weak var releaseOwnField: NSTextView?
    private let history = HistoryStore()
    let pipelineStats = PipelineStatsStore()
    /// Lifetime daily totals — outlive `history`'s 5,000-entry/90-day cap.
    let usageStats = UsageStatsStore()
    let notetaker = NotetakerController()
    private let notetakerHotkeyMonitor = NotetakerHotkeyMonitor()
    let scratchpadStore = ScratchpadStore()
    private lazy var scratchpadPanel = ScratchpadPanelController(store: scratchpadStore, app: self)
    private lazy var scratchpadHotkey = ScratchpadHotkeyMonitor()
    private var transcriber = Transcriber(locale: Settings.locale)
    private lazy var hotkeyMonitor = HotkeyMonitor(hotkey: Settings.hotkey)
    private lazy var profileHotkeyMonitor = ProfileHotkeyMonitor()
    let rewriteEngine = RewriteEngine()
    let whisperEngine = WhisperEngine()
    let whisperCppEngine = WhisperCppEngine()
    let parakeetEngine = ParakeetEngine()
    let sherpaEngine = SherpaOnnxEngine()
    let vadEngine = VadEngine()
    private lazy var turnDetector = TurnDetector(vadEngine: vadEngine)
    @Published var engine: String = Settings.engine
    @Published var whisperModel: String = Settings.whisperModel
    @Published var whisperReady = false
    @Published var whisperCppModel: String = Settings.whisperCppModel
    @Published var whisperCppReady = false
    @Published var parakeetModel: String = Settings.parakeetModel
    @Published var parakeetReady = false
    @Published var sherpaModel: String = Settings.sherpaModel
    @Published var sherpaReady = false
    @Published var voiceProfile: VoiceProfile? = VoiceProfileStore.load()
    // Dark theme is shelved (Settings' own picker for this is gone too) —
    // pinned to `.light` here rather than `Settings.appearance` so anyone
    // who'd previously picked Dark/System still launches into light, not
    // whatever they last chose. `AppearanceSetting`/`Settings.appearance`
    // are left in place for when dark mode is revisited.
    @Published var appearance: AppearanceSetting = .light
    private(set) lazy var transformManager = TransformManager(engine: rewriteEngine)

    /// Extra status line shown in the top bar while a transform runs.
    @Published var transformStatus: String? { didSet { updateHUD() } }
    /// A moment's message in the HUD instead of a dictation — "Trial over — dictation paused".
    @Published var hudNotice: String? { didSet { updateHUD() } }
    private var hudNoticeTask: Task<Void, Never>?
    /// How the last dictation ended, shown for a moment as the pill goes — a check, or why it didn't work.
    @Published var hudFlash: HUDState? { didSet { updateHUD() } }
    private var hudFlashTask: Task<Void, Never>?
    /// Esc cancels a dictation while one is recording.
    private let escapeInterceptor = EscapeInterceptor()
    /// Set to open Settings' License tile (the activation link from the receipt email); Settings clears it.
    @Published var openLicenseTile = false
    /// Set when a History row is sent to Templates; the Templates page
    /// picks it up and clears it.
    @Published var pendingTemplateText: String?
    /// Set when a Scratchpad note is sent to Transforms; that page's own
    /// "Try it here" box picks it up and clears it, mirroring
    /// `pendingTemplateText`.
    @Published var pendingTransformText: String?
    /// Set when a notification click (or other outside prompt) should jump
    /// the dashboard to a specific page; `AppShellRoot` picks it up and
    /// clears it, mirroring `pendingTemplateText`.
    @Published var pendingNavigateToPage: Page?
    /// A real, newer GitHub release — set once by `checkForUpdates()` at
    /// launch, `nil` otherwise. `AppShellRoot` presents the update sheet
    /// via `.sheet(item:)` off this.
    @Published var availableUpdate: AppUpdate?
    /// Non-nil while `installUpdate(_:)` is downloading/unpacking/
    /// installing — `SoftwareUpdateSheet` shows it as the "Update Now"
    /// button's label so the user isn't left staring at a button that
    /// looks unresponsive during the download.
    @Published var updateInstallProgress: String?
    /// Ask Murmur's whole conversation, kept here rather than as `@State`
    /// on `AskPage` — that page is a fresh `View` struct every time the
    /// rail navigates to it, so `@State` reset the thread to empty on every
    /// visit. Living on `AppDelegate` instead means it survives navigating
    /// away and back for as long as the app stays open (not across a
    /// relaunch — that would need its own on-disk store, not asked for
    /// here). Also why an in-flight question's `Task` still lands
    /// correctly even if the user leaves the page before it resolves: it
    /// writes into this shared, long-lived object rather than into a
    /// `View` instance that may already be gone.
    @Published var askTurns: [AskPage.ChatTurn] = []
    @Published var askThinking = false

    private let statusHUD = StatusHUDController()

    /// Mirrors the app's live state onto the floating HUD, which is the only
    /// status visible while dictating into another app — the main window is
    /// behind it. Reads three properties; called from all three `didSet`s.
    /// What the HUD should show right now.
    private var hudState: HUDState {
        switch uiState {
        case .recording:
            return .recording(handsFree: isHandsFree)
        case .processing:
            return .processing(transformStatus ?? HUDState.transcribing)
        case .idle:
            // A transform (⌥1/⌥2) runs with no recording in flight, so idle
            // plus a status line still means work is happening.
            return hudNotice.map { .notice($0) } ?? hudFlash ?? transformStatus.map { .processing($0) } ?? .hidden
        }
    }

    private func updateHUD() {
        let state = hudState
        // Deferred, never inline. These observers fire during a @Published
        // change — i.e. in the middle of SwiftUI's own update pass — and
        // building an NSHostingView/NSPanel there would start a nested
        // SwiftUI update on the same actor. Hopping to the next main-actor
        // turn keeps all window work out of that cycle.
        Task { @MainActor [statusHUD, navBarHUD, weak self] in
            statusHUD.update(state)
            // The bottom pill grows out of the nav bar's resting line, so the line steps aside as it does — unless the
            // HUD is up in the notch, which leaves the bottom free. It comes back once the pill has shrunk into it
            // again (`statusHUD.onCollapsed`), not before, so the two read as one object.
            if let self, state != .hidden {
                // With the bar staying put (the notch case), a dictation closes any menu that was open on it.
                if state.isRecording { navBarHUD.closeMenu() }
                navBarHUD.setActive(statusHUD.isInNotch, app: self)
            }
        }
    }

    /// Shows how a dictation ended — `.done`, `.failure`, `.info` — for a moment, as the pill goes. Set before
    /// `uiState` returns to idle, so the pill goes straight from transcribing to this without disappearing in between.
    private func flashHUD(_ state: HUDState, for seconds: Double) {
        hudFlashTask?.cancel()
        hudFlash = state
        hudFlashTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.hudFlash = nil
        }
    }

    private func updateEscapeInterceptor() {
        if uiState == .recording { escapeInterceptor.start() } else { escapeInterceptor.stop() }
    }

    /// The HUD's own wiring: the microphone's level for the bars, hands-free's Stop and Cancel, Esc, and the nav bar's
    /// line coming back once the pill has shrunk into it.
    private func wireHUD() {
        recorder.onLevel = { [weak self] level in
            DispatchQueue.main.async { self?.statusHUD.setLevel(Double(level)) }
        }
        // The audio hardware changed under a recording (a headset connected, a dock, the Mac waking): the engine has
        // already stopped itself, so finish the dictation with what it caught and say why it ended early.
        recorder.onInterrupted = { [weak self] in
            guard let self, self.uiState == .recording else { return }
            self.recorder.onLiveBuffer = nil
            self.turnDetector.stop()
            self.hotkeyMonitor.resetHandsFree()
            self.lastError = "The microphone changed during the dictation (a headset or display was connected or "
                + "disconnected), so Murmur transcribed what it had heard up to then."
            self.stopAndTranscribe()
        }
        statusHUD.onStop = { [weak self] in self?.finishHandsFree() }
        statusHUD.onCancel = { [weak self] in self?.cancelDictation() }
        statusHUD.onCollapsed = { [weak self] in
            guard let self, self.hudState == .hidden else { return }
            self.navBarHUD.setActive(true, app: self)
        }
        // The pill grows out of the nav bar just as it is — the line or the open bar — at the height it's riding at.
        statusHUD.startSize = { [weak self] in self?.navBarHUD.visibleSize ?? StatusHUDView.restingSize }
        statusHUD.startLift = { [weak self] in self?.navBarHUD.lift ?? 0 }
        statusHUD.startVisible = { [weak self] in self?.navBarHUD.isShowing ?? false }
        escapeInterceptor.onEscape = { [weak self] in self?.cancelDictation() }
    }

    /// ⌃⌥V: the newest dictation in History, pasted at the cursor again. Not while one is in progress.
    private func pasteLastDictation() {
        guard uiState == .idle, let text = history.entries.first?.text, !text.isEmpty else { return }
        Task { @MainActor in
            // The chord's own ⌃ and ⌥ are still down; a paste sent now would arrive as ⌃⌥⌘V.
            await TextInserter.waitForModifierRelease()
            TextInserter.insert(text)
        }
    }

    /// Hands-free's Stop button: the same as tapping the dictation key again.
    private func finishHandsFree() {
        guard uiState == .recording else { return }
        recorder.onLiveBuffer = nil
        turnDetector.stop()
        hotkeyMonitor.resetHandsFree()
        stopAndTranscribe()
    }

    /// Esc, or hands-free's Cancel button: throw the recording away — nothing is transcribed or pasted.
    private func cancelDictation() {
        guard uiState == .recording else { return }
        recorder.onLiveBuffer = nil
        endLiveChunks()?.cancel()
        turnDetector.stop()
        // Also forgets a key still held down, so letting go of it afterwards doesn't count as a new dictation.
        hotkeyMonitor.resetHandsFree()
        isHandsFree = false
        recorder.cancel()
        recordingStartedAt = nil
        activeProfileHotkeySlot = nil
        flashHUD(.info("Cancelled", symbol: "xmark"), for: 1.1)
        uiState = .idle
    }

    /// The nav bar's microphone: a hands-free dictation into the app in front — the same as double-tapping the key, so
    /// the pill has Stop and Cancel and the key stops it too — or, while one is going, stop and paste.
    func toggleDictationFromBar() {
        switch uiState {
        case .recording:
            finishHandsFree()
        case .idle:
            startRecording()
            guard uiState == .recording else { return }
            hotkeyMonitor.enterHandsFree()
            isHandsFree = true
            updateIcon()
            if Settings.handsFreeAutoStop {
                turnDetector.start()
                recorder.onLiveBuffer = { [weak self] buffer in
                    Task { @MainActor in await self?.turnDetector.ingest(buffer) }
                }
            }
        case .processing:
            break
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        startDebugHooks()
        // The name fix keeps a short local record of what it changed, so it can be checked as the app is used.
        NameFixLog.isRecording = true
        // ⌘X ⌘C ⌘V ⌘A ⌘Z in Murmur's own fields — see `OwnTextField.editMenu`.
        if NSApp.mainMenu == nil { NSApp.mainMenu = OwnTextField.editMenu() }
        // A name corrected by hand right after a dictation is learned — say what, where it can be undone.
        correctionToast.onUndo = { receipts in
            receipts.forEach(LearnedStore.undo)
            NotificationLog.add(
                title: "Took back \(receipts.count == 1 ? "a correction" : "\(receipts.count) corrections")",
                message: "Murmur won’t use \(receipts.count == 1 ? "it" : "them"). Corrections you keep are in Voice Profile.",
                kind: .learnedFromEdit)
        }
        EditLearner.onLearned = { [weak self] learned in
            guard let self, let first = learned.first else { return }
            let names = learned.map { "“\($0.intended)”" }.joined(separator: ", ")
            NotificationLog.add(
                title: "Learned \(names)",
                message: "You corrected “\(first.heard)” to “\(first.intended)”, so Murmur writes it that way from now "
                    + "on. Wrong? Remove it in Voice Profile.",
                kind: .learnedFromEdit)
            // The card is for the moment, while the edit is fresh; one still on its way waits for the dictation in
            // progress to land rather than sit over its pill.
            if self.uiState == .idle {
                self.correctionToast.show(learned)
            } else {
                self.pendingCorrectionNotices += learned
            }
        }
        // A dictation that never ended (Murmur quit mid-way) may have left other sound turned down.
        AudioDuck.shared.restoreAfterCrash()
        // A Bluetooth headset takes seconds to switch into call mode; the start sound says when it can hear you.
        recorder.onFirstAudio = { [weak self] in
            guard let self, self.startSoundWaitsForHeadset else { return }
            self.startSoundWaitsForHeadset = false
            if self.uiState == .recording { SoundEffect.play("Pop") }
        }
        // Edit learning only trusts a changed box when the user typed in it — see `TypingEvidence`.
        TypingEvidence.start()
        // ⌃⌥V pastes the last dictation again, wherever the cursor is.
        pasteLastShortcut.onTrigger = { [weak self] in self?.pasteLastDictation() }
        pasteLastShortcut.start()
        // And each dictation's microphone start-up, which decides whether a warm microphone is ever worth it.
        recorder.recordsStartup = true
        FontLoader.registerManrope()
        refreshTranslationPair()
        usageStats.seedIfEmpty(from: history.entries)
        if let rebased = VoiceProfileStore.rebaseIfAhead(of: usageStats.lifetimeWords) {
            voiceProfile = rebased
        }
        // Forces `NSApp.appearance` to `.aqua` before any window exists —
        // without this, a Mac already in Dark Mode would still hand the
        // app a dark `effectiveAppearance` by default, `appearance`'s
        // pinned `.light` above notwithstanding.
        setAppearance(appearance)
        entries = history.entries
        setUpStatusItem()
        UNUserNotificationCenter.current().delegate = self
        // First run asks for these itself, at the moment `OnboardingRoot`'s
        // own permission step explains why — not silently the instant the
        // process launches, before that screen has even drawn.
        refreshPermissions(promptAccessibility: Settings.hasCompletedOnboarding)
        wireHotkey()
        wireHUD()
        hotkeyMonitor.startMonitoring()
        // `updateHUD` only runs on later `uiState` changes, not this
        // property's own initial value — the nav bar's default-visible
        // state needs this explicit kick to exist from launch, same as
        // the hotkey monitor already runs regardless of onboarding.
        navBarHUD.setActive(true, app: self)
        profileHotkeyMonitor.onTrigger = { [weak self] slot in
            DispatchQueue.main.async { self?.handleProfileHotkey(slot) }
        }
        profileHotkeyMonitor.startMonitoring()
        scratchpadHotkey.onTrigger = { [weak self] in
            DispatchQueue.main.async { self?.scratchpadPanel.toggle() }
        }
        scratchpadHotkey.startMonitoring()
        transformManager.onStatus = { [weak self] status in
            guard let self else { return }
            // A transform works on the selection in the app in front, so that's the icon the HUD shows for it.
            if status != nil, self.transformStatus == nil, self.uiState == .idle {
                self.statusHUD.setTargetAppIcon(NSWorkspace.shared.frontmostApplication?.icon)
            }
            self.transformStatus = status
        }
        transformManager.onError = { [weak self] message in
            self?.lastError = message
        }
        // "Select some text first", in the pill over the app you're in — not only in Murmur's own window.
        transformManager.onFailure = { [weak self] message, symbol in
            self?.flashHUD(.info(message, symbol: symbol), for: 2.2)
        }
        transformManager.startMonitoring()
        whisperEngine.onStatus = { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                self.transformStatus = status
                self.whisperReady = self.whisperEngine.isReady(
                    model: Settings.whisperModel)
            }
        }
        whisperCppEngine.onStatus = { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                self.transformStatus = status
                self.whisperCppReady = self.whisperCppEngine.isReady(
                    model: Settings.whisperCppModel)
            }
        }
        parakeetEngine.onStatus = { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                self.transformStatus = status
                self.parakeetReady = self.parakeetEngine.isReady(
                    model: Settings.parakeetModel)
            }
        }
        sherpaEngine.onStatus = { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                self.transformStatus = status
                self.sherpaReady = self.sherpaEngine.isReady(
                    model: Settings.sherpaModel)
            }
        }
        if Settings.engine == "whisper" {
            whisperEngine.preload(model: Settings.whisperModel)
        } else if Settings.engine == "whispercpp" {
            whisperCppEngine.preload(model: Settings.whisperCppModel)
        } else if Settings.engine == "parakeet" {
            parakeetEngine.preload(model: Settings.parakeetModel)
        } else if Settings.engine == "sherpa" {
            sherpaEngine.preload(model: Settings.sherpaModel)
        }
        // Unconditional, unlike the engine preloads above — VAD refines the
        // silence gate for every recognition engine, not just one choice.
        vadEngine.preload()
        if Settings.hasCompletedOnboarding {
            showMainWindow()
            Task {
                micAuthorized = await AudioRecorder.requestMicrophoneAccess()
            }
        } else {
            showOnboarding()
        }
        // Warm up the on-device speech model in the background.
        Task.detached { [transcriber] in
            try? await transcriber.ensureModelInstalled()
        }
        // Same idea for the rewrite model — so the first dictation's
        // cleanup pass isn't the one paying the cold-start cost.
        if rewriteEngine.isAvailable {
            Task.detached { [rewriteEngine] in
                rewriteEngine.prewarm()
            }
        }
        // The grammar pass and the personal-corrections store each pay a
        // one-time start-up cost on first use (measured ~85 ms and ~200 ms).
        // Pay it here, in the background, so it isn't the first dictation's
        // wait. Output is unaffected — these calls' results are discarded.
        Task.detached(priority: .utility) {
            _ = HarperChecker.fix("Warming up.")
            _ = LearnedStore.apply(in: "warming up", includeDeveloperVocabulary: false)
        }
        refreshVoiceProfileIfDue()
        checkForUpdates()
        // Official release builds only — both return at once in a source build, which touches no Keychain, no
        // licensing server and no Sparkle: the trial / license check-in, then signed updates the license covers.
        LicenseStore.shared.start()
        SparkleUpdater.shared.start()
        // Notices when macOS secure input is on (a password field, an app that
        // forgot to turn it off) — while it is, key-based shortcuts can't hear
        // the keyboard. Observation only; what to show is a separate decision.
        SecureInputMonitor.shared.start()
        secureInputObserver = SecureInputMonitor.shared.$isWorthWarning.sink { [weak self] _ in
            self?.secureInputNotice = SecureInputMonitor.shared.notice
            self?.rebuildMenu()
        }
        // Lets the paste path tell a smooth main thread from a busy one (see `MainThreadHealth`).
        MainThreadHealth.start()

        // Always Parakeet v3, not whatever engine the user picked for
        // normal dictation — see `recognizeForNotetaker`'s own doc comment
        // for why a meeting-length clip can't safely inherit that choice.
        notetaker.transcribeFile = { [weak self] url in
            try await self?.recognizeForNotetaker(fileAt: url) ?? ""
        }
        notetaker.rewriteEngine = rewriteEngine
        notetaker.recordPipelineStats = { [weak self] harper, dictionary, snippets in
            self?.pipelineStats.record(
                harperFixes: harper, dictionaryFixes: dictionary, snippetExpansions: snippets)
        }
        notetaker.setWindowExcludedFromCapture = { [weak self] excluded in
            self?.window?.sharingType = excluded ? .none : .readOnly
        }

        notetakerHotkeyMonitor.onTrigger = { [weak self] in
            guard let self else { return }
            if self.notetaker.canStart {
                self.notetaker.start(app: self.notetaker.detector.activeMeetingApp)
            } else if case .capturing = self.notetaker.state {
                self.notetaker.stop()
            }
        }
        notetakerHotkeyMonitor.startMonitoring()
        keyMonitorsStarted = true
    }

    /// Checks GitHub's own Releases API for this repo — no appcast, no
    /// Sparkle. Silent on any failure (offline, rate-limited): a missed
    /// check just means no sheet this launch, never an error surfaced to
    /// the user. Skips a release the user already dismissed via "Skip
    /// This Version", but a newer one past that still shows.
    private func checkForUpdates() {
        // An official release build updates through Sparkle only — signed, and limited to what its license covers
        // (`SparkleUpdater`) — never through this unsigned path.
        guard BuildChannel.current == .source else { return }
        Task {
            guard let update = await UpdateChecker.checkLatest() else { return }
            guard update.version != Settings.skippedUpdateVersion else { return }
            availableUpdate = update
            let title = "Murmur \(update.version) is available"
            // The check runs every launch, and the same real release
            // stays "latest" across many of them — without this, each
            // relaunch logged its own duplicate entry for a release the
            // user had already been told about.
            let alreadyLogged = NotificationLog.load().contains {
                $0.kind == .updateAvailable && $0.title == title
            }
            guard !alreadyLogged else { return }
            NotificationLog.add(
                title: title,
                message: update.notes.first ?? "A new version is ready to download.",
                kind: .updateAvailable)
        }
    }

    /// Tries a real in-place install via `AppInstaller`, then relaunches
    /// into it. Falls back to opening `update.downloadURL` in the browser
    /// — today's behavior — if the release has no `.zip` asset or the
    /// download/unpack/replace fails at any step; the user is never left
    /// with a half-updated app or a dead-end button.
    func installUpdate(_ update: AppUpdate) async {
        do {
            try await AppInstaller.install(update) { [weak self] message in
                Task { @MainActor in self?.updateInstallProgress = message }
            }
            relaunch()
        } catch {
            updateInstallProgress = nil
            NSWorkspace.shared.open(update.downloadURL)
        }
    }

    /// Regenerates the Voice Profile persona once enough new dictation has
    /// accumulated. Runs quietly in the background; failures keep the old one.
    func refreshVoiceProfileIfDue(force: Bool = false) {
        // Lifetime, not history's total: history is capped, so its total can
        // shrink and never reach the next refresh point.
        let totalWords = usageStats.lifetimeWords
        guard force || VoiceProfileStore.shouldRefresh(totalWords: totalWords)
        else { return }
        guard totalWords >= VoiceProfileStore.minimumWords else { return }
        let snapshot = entries
        Task { [rewriteEngine] in
            if let profile = await VoiceProfileStore.generate(
                from: snapshot, totalWords: totalWords, engine: rewriteEngine) {
                voiceProfile = profile
            }
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    /// whisper.cpp's Metal backend keeps a static C++ registry of Metal
    /// devices. Something in its cleanup path aborts when that registry's
    /// destructor runs during normal process exit — `exit()` finalizes C++
    /// static-storage objects after AppKit has already begun tearing down,
    /// and ggml's Metal teardown doesn't tolerate that ordering. It only
    /// fires once whisper.cpp has actually been used this session, but from
    /// then on it hits on every ordinary quit — confirmed via a real crash
    /// report (`ggml_metal_rsets_free` → `ggml_abort` → SIGABRT, inside the
    /// vector-of-devices destructor called from `__cxa_finalize_ranges`).
    ///
    /// The bug is inside the vendored library, not this app's code, so
    /// rather than let AppKit's normal `terminate:` → `exit()` path reach
    /// that destructor at all, everything this app actually needs saved is
    /// flushed here and the process ends immediately via `_exit`, which
    /// skips atexit handlers and C++ static destructors entirely. Every
    /// termination route — Cmd+Q, the Quit menu item, an AppleEvent, and
    /// `relaunch()`'s `NSApp.terminate(nil)` — funnels through this one
    /// delegate method first, so this is the single place that needs it.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        UserDefaults.standard.synchronize()
        _exit(0)
    }

    // MARK: - Onboarding

    /// Set once every key monitor has been installed at launch, so
    /// `refreshPermissions` only re-installs monitors that exist.
    private var keyMonitorsStarted = false

    private func restartKeyMonitors() {
        hotkeyMonitor.startMonitoring()
        profileHotkeyMonitor.startMonitoring()
        scratchpadHotkey.startMonitoring()
        transformManager.startMonitoring()
        notetakerHotkeyMonitor.startMonitoring()
    }

    /// First run, and Settings → General → "Run setup again". A second call while it's open just brings it forward.
    func showOnboarding() {
        if let onboardingWindow, onboardingWindow.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            onboardingWindow.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(
            rootView: OnboardingRoot(app: self) { [weak self] in
                self?.completeOnboarding()
            })
        hosting.sizingOptions = []
        let onboarding = NSWindow(contentViewController: hosting)
        onboarding.styleMask = [.titled, .closable, .fullSizeContentView]
        onboarding.titleVisibility = .hidden
        onboarding.titlebarAppearsTransparent = true
        // Pinned light regardless of the system/app appearance — by
        // request, and the same idea as `Palette.homeGradient` always
        // staying its own fixed tone: one deliberately fixed surface, this
        // time the other direction. `Palette`'s colors resolve dynamically
        // off the *window's* effective appearance, so overriding it here
        // is enough; nothing in `OnboardingRoot` itself needs to change.
        onboarding.appearance = NSAppearance(named: .aqua)
        // 720×660: room for the main window's titlebar band and each step's
        // picture — and still well inside a 13" MacBook Air's screen with the
        // menu bar and Dock showing.
        onboarding.setContentSize(NSSize(width: 720, height: 660))
        onboarding.isReleasedWhenClosed = false
        onboarding.center()
        onboarding.delegate = self
        onboardingWindow = onboarding
        NSApp.activate(ignoringOtherApps: true)
        onboarding.makeKeyAndOrderFront(nil)
        alignTrafficLights(in: onboarding)
    }

    private func completeOnboarding() {
        Settings.hasCompletedOnboarding = true
        refreshPermissions()
        onboardingWindow?.close()
        onboardingWindow = nil
        showMainWindow()
    }

    /// The in-app Scratchpad page's own "Start new note"/note-row clicks
    /// route here — same floating panel the global hotkey opens, just
    /// landed on a specific note (or a fresh one) instead of whatever was
    /// last active.
    func openScratchpadPanel(noteID: UUID? = nil) {
        if let noteID {
            scratchpadPanel.open(noteID: noteID)
        } else {
            scratchpadPanel.show()
        }
    }

    // MARK: - Main window

    func showMainWindow() {
        if window == nil {
            let hosting = NSHostingController(rootView: AppShellRoot(app: self))
            // By default a hosting controller pushes its SwiftUI content's
            // ideal size up to the window, so a long transcript list would
            // stretch the window to fit rather than scrolling inside it.
            // The window's size belongs to the user; content scrolls within.
            hosting.sizingOptions = []
            let newWindow = NSWindow(contentViewController: hosting)
            newWindow.title = "Murmur"
            newWindow.styleMask = [
                .titled, .closable, .miniaturizable, .resizable, .fullSizeContentView,
            ]
            newWindow.titleVisibility = .hidden
            newWindow.titlebarAppearsTransparent = true
            newWindow.setContentSize(NSSize(width: 1180, height: 840))
            newWindow.minSize = NSSize(width: 900, height: 600)
            newWindow.isReleasedWhenClosed = false
            newWindow.delegate = self
            newWindow.center()
            // `NSApp.appearance` (set in `setAppearance`) is supposed to
            // cascade to every window, but the native chrome this window
            // still owns despite `titlebarAppearsTransparent` — its
            // border stroke and the reserved titlebar sliver above
            // `fullSizeContentView` — kept rendering light regardless: a
            // known AppKit gap where a `.titled` window's own chrome
            // doesn't reliably re-resolve off a later app-wide appearance
            // change. Setting it here directly, not just on `NSApp`,
            // guarantees this window's own chrome actually matches
            // `appearance` from the moment it's created.
            newWindow.appearance = appearance.nsAppearance
            window = newWindow
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        alignTrafficLights()
        refreshPermissions()
    }

    /// macOS centers the traffic lights for its own 28pt titlebar, putting
    /// them 16pt below the window top. Our titlebar strip is 44pt, so its
    /// content — the status pill, the bell — centers at 22pt, leaving the
    /// buttons sitting visibly high. Nudge the buttons onto the same line.
    ///
    /// Works off AppKit's own baseline captured once, rather than measuring
    /// across view hierarchies: the buttons live in the window's theme
    /// frame, not in contentView, so converting between the two produces
    /// meaningless offsets (which previously pushed them out of sight).
    private func alignTrafficLights() {
        if let window { alignTrafficLights(in: window) }
    }

    /// Centres a window's traffic lights in the 44pt titlebar band — the main window's, and first-run setup's,
    /// which draws the same band.
    private func alignTrafficLights(in window: NSWindow) {
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
        guard let reference = buttons.first else { return }

        // Capture AppKit's unmodified layout the first time only, per window.
        let key = ObjectIdentifier(window)
        if trafficLightBaselines[key] == nil {
            trafficLightBaselines[key] = reference.frame.origin.y
        }
        guard let baseline = trafficLightBaselines[key] else { return }

        // Titlebar content centers at 22pt; AppKit centers buttons at 16pt.
        // NSView is bottom-up, so subtracting moves them down.
        let target = baseline - (Self.titlebarHeight / 2 - 16)
        for button in buttons where abs(button.frame.origin.y - target) > 0.5 {
            button.frame.origin.y = target
        }
    }

    // AppKit re-lays out the titlebar on these, undoing the alignment.
    func windowDidResize(_ notification: Notification) { realignTrafficLights(notification) }
    func windowDidExitFullScreen(_ notification: Notification) { realignTrafficLights(notification) }
    func windowDidBecomeKey(_ notification: Notification) { realignTrafficLights(notification) }

    private func realignTrafficLights(_ notification: Notification) {
        if let window = notification.object as? NSWindow { alignTrafficLights(in: window) }
    }

    // MARK: - Permissions

    func refreshPermissions(promptAccessibility: Bool = false) {
        let wasTrusted = axTrusted
        defer {
            // A global key monitor installed before Accessibility was granted
            // doesn't start hearing keys once it is — which left the
            // dictation key dead in other apps after first-run setup until
            // Murmur was relaunched. Re-installing every monitor the moment
            // the grant lands fixes that; each `startMonitoring()` removes
            // its old monitor first, so this is safe to repeat.
            if keyMonitorsStarted, !wasTrusted, axTrusted { restartKeyMonitors() }
        }
        if promptAccessibility {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            axTrusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        } else {
            axTrusted = AXIsProcessTrusted()
        }
        micAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        whisperReady = whisperEngine.isReady(model: Settings.whisperModel)
        whisperCppReady = whisperCppEngine.isReady(model: Settings.whisperCppModel)
        parakeetReady = parakeetEngine.isReady(model: Settings.parakeetModel)
        sherpaReady = sherpaEngine.isReady(model: Settings.sherpaModel)
    }

    // MARK: - Settings changes (from window or menu)

    func setHotkey(_ key: HotkeyMonitor.Hotkey) {
        Settings.hotkey = key
        hotkey = key
        hotkeyMonitor.hotkey = key
        rebuildMenu()
    }

    /// Applies the chosen theme app-wide. `nil` hands control back to
    /// macOS, so the app follows the system — including live switching
    /// when the system is set to Auto.
    func setAppearance(_ newValue: AppearanceSetting) {
        Settings.appearance = newValue
        appearance = newValue
        NSApp.appearance = newValue.nsAppearance
        // `showMainWindow()`'s own note explains why the window needs
        // this directly, not just via the `NSApp` cascade — same reason
        // it has to be kept current here too, for a theme change made
        // while that window is already open and on screen.
        window?.appearance = newValue.nsAppearance
    }

    func setEngine(_ newEngine: String) {
        Settings.engine = newEngine
        engine = newEngine
        if newEngine == "whisper" {
            whisperEngine.preload(model: Settings.whisperModel)
        } else if newEngine == "whispercpp" {
            whisperCppEngine.preload(model: Settings.whisperCppModel)
        } else if newEngine == "parakeet" {
            parakeetEngine.preload(model: Settings.parakeetModel)
        } else if newEngine == "sherpa" {
            sherpaEngine.preload(model: Settings.sherpaModel)
        }
        reconcileLocaleWithEngine()
    }

    func setWhisperModel(_ model: String) {
        Settings.whisperModel = model
        whisperModel = model
        if Settings.engine == "whisper" {
            whisperEngine.preload(model: model)
        }
        reconcileLocaleWithEngine()
    }

    func setWhisperCppModel(_ model: String) {
        Settings.whisperCppModel = model
        whisperCppModel = model
        if Settings.engine == "whispercpp" {
            whisperCppEngine.preload(model: model)
        }
        reconcileLocaleWithEngine()
    }

    func setParakeetModel(_ model: String) {
        Settings.parakeetModel = model
        parakeetModel = model
        if Settings.engine == "parakeet" {
            parakeetEngine.preload(model: model)
        }
        reconcileLocaleWithEngine()
    }

    func setSherpaModel(_ model: String) {
        Settings.sherpaModel = model
        sherpaModel = model
        if Settings.engine == "sherpa" {
            sherpaEngine.preload(model: model)
        }
        reconcileLocaleWithEngine()
    }

    /// Language codes the active recognition engine (and, for Whisper/
    /// Parakeet, its selected model) can actually transcribe. `nil` for
    /// Apple's on-device engine: its supported set is a fixed, per-locale
    /// asset list that only `SpeechTranscriber` knows, which the Settings
    /// and HUD language pickers already load and cache themselves.
    func supportedLanguageIDs() -> [String]? {
        Self.supportedLanguageIDs(
            engine: engine, whisperModel: whisperModel, whisperCppModel: whisperCppModel,
            parakeetModel: parakeetModel, sherpaModel: sherpaModel)
    }

    /// Same logic as the instance method above, generalized to take
    /// explicit engine/model values instead of reading this instance's own
    /// published state — so `AppProfilesPage`'s per-profile language
    /// picker can compute "what's supported by the engine *this profile*
    /// would use" (its own override, or else the global default) without
    /// duplicating the per-engine switch.
    static func supportedLanguageIDs(
        engine: String, whisperModel: String, whisperCppModel: String,
        parakeetModel: String, sherpaModel: String
    ) -> [String]? {
        switch engine {
        case "whisper":
            return WhisperEngine.isEnglishOnly(whisperModel)
                ? ["en"] : WhisperEngine.supportedLanguageCodes
        case "whispercpp":
            if let restricted = WhisperCppEngine.restrictedLanguage(for: whisperCppModel) {
                return [restricted]
            }
            return WhisperEngine.supportedLanguageCodes
        case "parakeet":
            return ParakeetEngine.supportedLanguageCodes(for: parakeetModel)
        case "sherpa":
            return SherpaOnnxEngine.supportedLanguageCodes(for: sherpaModel)
        default:
            return nil
        }
    }

    /// Falls back to English whenever the engine or model just switched to
    /// one that no longer covers the selected language — e.g. Parakeet v2
    /// or Whisper's English-only Distil model, neither of which reads the
    /// language hint at all. Without this, Settings would keep showing
    /// (say) German while dictation silently kept transcribing as English.
    ///
    /// Prefers restoring the last language the user deliberately chose
    /// over hardcoding English, if the newly active engine/model can
    /// actually support it — e.g. briefly trying Parakeet v2 to see its
    /// English-only label, then switching back to v3, should land back on
    /// German, not get stuck silently on the safety fallback. Confirmed
    /// live: this exact one-way reset is what silently turned a working
    /// Latvian dictation setup back to English mid-session, without the
    /// user ever explicitly choosing English again.
    private func reconcileLocaleWithEngine() {
        guard let supported = supportedLanguageIDs() else { return }
        let current = String(localeID.prefix(while: { $0 != "-" })).lowercased()
        guard !supported.contains(current) else { return }
        if let remembered = Settings.lastNonEnglishLocaleIdentifier {
            let rememberedCode = String(remembered.prefix(while: { $0 != "-" })).lowercased()
            if supported.contains(rememberedCode) {
                setLocale(remembered)
                return
            }
        }
        setLocale("en-US")
    }

    func setLocale(_ identifier: String) {
        Settings.localeIdentifier = identifier
        localeID = identifier
        // Remembered so `reconcileLocaleWithEngine` can restore a
        // deliberate non-English choice later, instead of leaving the
        // user stuck on English once an incompatible engine/model forces
        // a temporary fallback.
        if String(identifier.prefix(while: { $0 != "-" })).lowercased() != "en" {
            Settings.lastNonEnglishLocaleIdentifier = identifier
        }
        transcriber = Transcriber(locale: Locale(identifier: identifier))
        Task.detached { [transcriber] in
            try? await transcriber.ensureModelInstalled()
        }
        refreshTranslationPair()
    }

    /// Translate into: from Settings, the bar's language menu, the menu bar or the first-run language step.
    func setTranslateInto(_ code: String?) {
        TranslateInto.target = code
        translateInto = code
        if code != nil { UserDefaults.standard.set(true, forKey: "translateIntoTried") }
        rebuildMenu()
        refreshTranslationPair()
    }

    /// What macOS's translator can do for the pair in use, read again whenever either language changes.
    func refreshTranslationPair() {
        guard let to = translateInto else { return }
        let from = TranslateInto.code(forLocale: localeID)
        Task { await TranslationModels.shared.refreshApple(from: from, to: to) }
    }

    func clearHistoryEntries() {
        history.clear()
        entries = []
        rebuildMenu()
    }

    /// Deletes any stale Accessibility grant (recorded against an older
    /// build's signature) and relaunches so macOS asks again — the new grant
    /// is recorded against the stable certificate and survives updates.
    func resetAccessibilityGrant() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = [
            "reset", "Accessibility",
            Bundle.main.bundleIdentifier ?? "local.murmur",
        ]
        try? process.run()
        process.waitUntilExit()
        relaunch()
    }

    /// Starts a fresh instance of the app and quits this one. Needed after
    /// granting Accessibility, which macOS only applies to new processes.
    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    func deleteHistoryEntry(id: String) {
        history.delete(id: id)
        entries = history.entries
        rebuildMenu()
    }

    /// Applies a user correction to a transcript and learns the
    /// misheard → intended word mappings from it. Returns how many were learned.
    @discardableResult
    func correctHistoryEntry(id: String, newText: String) -> Int {
        guard let entry = history.entries.first(where: { $0.id == id }),
              entry.text != newText else { return 0 }
        let learned = LearnedStore.learnTracked(original: entry.text, corrected: newText)
        history.update(id: id, text: newText)
        entries = history.entries
        rebuildMenu()
        // The same "Saved … Undo" card as a correction made where the dictation landed.
        if !learned.isEmpty, uiState == .idle { correctionToast.show(learned) }
        return learned.count
    }

    /// What dictation hears in a Voice Training recording: the user's own engine and vocabulary, with the word being
    /// taught already in it as it will be from now on — so a mishearing learned here is the one dictation would make.
    /// (It used to be Apple's engine whatever the user dictated with, which taught Apple's mishearings to everyone.)
    func transcribeForTraining(fileAt url: URL, teaching term: String) async throws -> String {
        LearnedStore.addTerm(term)
        ScreenContext.refresh(pid: nil)  // the last dictation's screen isn't this recording's
        return try await recognize(fileAt: url, bundleID: nil)
    }

    /// Runs the user's chosen recognition engine. Dictation never waits on
    /// Whisper: while its model is still downloading or loading, Apple's
    /// engine handles the dictation, and Whisper takes over once ready.
    /// Whisper failures also fall back to Apple so a keypress always
    /// produces text.
    /// `bundleID` also resolves a per-app engine/language override
    /// (`AppProfile.engine`/`.localeIdentifier`) — most dictations have
    /// neither set, so `effectiveEngine`/`effectiveLocale` are just
    /// `Settings.engine`/`.localeIdentifier` read through one extra
    /// indirection, not a behavior change for anyone who hasn't set one.
    private func recognize(
        fileAt originalURL: URL, bundleID: String?, speechEnd: TimeInterval? = nil,
        liveChunks: LiveChunkSession? = nil, prompt: String? = nil
    ) async throws -> String {
        // Whatever happens below, the live session stops listening once recognition is over.
        defer { liveChunks?.cancel() }
        let developerVocabulary = AppProfileStore.developerVocabularyEnabled(forBundleID: bundleID)
        let biasTerms = LearnedStore.biasTerms(includeDeveloperVocabulary: developerVocabulary)
        let effectiveEngine = AppProfileStore.engine(forBundleID: bundleID)
        let effectiveModel = AppProfileStore.model(forBundleID: bundleID)
        let effectiveLocale = AppProfileStore.localeIdentifier(forBundleID: bundleID)
        // Whisper-family engines invent "Thank you." for the silent
        // leftover window past their 30-second frame, so those get the
        // recording without its trailing silence — see
        // `TrailingSilenceTrimmer`. Every other engine, and any failure to
        // trim, uses the recording as recorded.
        var url = originalURL
        if let speechEnd, effectiveEngine == "whisper" || effectiveEngine == "whispercpp",
           let trimmed = TrailingSilenceTrimmer.trimmedCopy(of: originalURL, speechEnd: speechEnd) {
            dictationLog.info("recognize: trimmed trailing silence after \(speechEnd, format: .fixed(precision: 1))s")
            url = trimmed
        }
        defer { if url != originalURL { try? FileManager.default.removeItem(at: url) } }
        // A single cheap header read, reused by whichever branch below
        // actually runs — see `TranscriptionPlausibility.isPlausible`'s own
        // doc comment for what this feeds.
        let audioDuration = TranscriptionPlausibility.audioDurationSeconds(of: url) ?? 0
        dictationLog.info(
            "recognize: engine=\(effectiveEngine, privacy: .public) model=\(effectiveModel, privacy: .public) locale=\(effectiveLocale, privacy: .public) developerVocabulary=\(developerVocabulary) parakeetReady=\(self.parakeetEngine.isReady(model: Settings.parakeetModel)) whisperReady=\(self.whisperEngine.isReady(model: Settings.whisperModel)) whisperCppReady=\(self.whisperCppEngine.isReady(model: Settings.whisperCppModel)) sherpaReady=\(self.sherpaEngine.isReady(model: Settings.sherpaModel))")
        if effectiveEngine == "whisper" {
            if whisperEngine.isReady(model: effectiveModel) {
                do {
                    let (text, confidence) = try await whisperEngine.transcribe(
                        fileAt: url, model: effectiveModel,
                        localeID: effectiveLocale, biasTerms: biasTerms)
                    if TranscriptionPlausibility.isPlausible(
                        text, audioDurationSeconds: audioDuration, confidence: confidence) {
                        return text
                    }
                    lastError = "Whisper's result looked implausible for this " +
                        "recording — used Apple engine instead."
                    dictationLog.error("recognize: \(self.lastError ?? "", privacy: .public)")
                } catch {
                    lastError = "Whisper engine failed " +
                        "(\(error.localizedDescription)) — used Apple engine instead."
                    dictationLog.error("recognize: \(self.lastError ?? "", privacy: .public)")
                }
            } else {
                whisperEngine.preload(model: effectiveModel)
                lastError = "Whisper model is still preparing — used Apple " +
                    "engine for this dictation. Whisper takes over when ready."
                dictationLog.error("recognize: \(self.lastError ?? "", privacy: .public)")
            }
        } else if effectiveEngine == "whispercpp" {
            // Transcribed while it was spoken: only what came after the last cut is left to decode. Used only when the
            // session was set up for exactly this engine, model, language and vocabulary; otherwise, or when nothing
            // was cut (every shorter dictation) or anything failed, the whole recording is decoded below as before.
            if let liveChunks, liveChunks.model == effectiveModel, liveChunks.localeID == effectiveLocale,
               liveChunks.biasTerms == biasTerms, liveChunks.prompt == prompt,
               let result = await liveChunks.finish(recording: url) {
                dictationLog.info("recognize: live chunks, \(result.stretches) stretches")
                if TranscriptionPlausibility.isPlausible(
                    result.text, audioDurationSeconds: audioDuration, confidence: result.confidence) {
                    return result.text
                }
                dictationLog.error("recognize: live chunks implausible, decoding the whole recording")
            } else {
                liveChunks?.cancel()
            }
            if whisperCppEngine.isReady(model: effectiveModel) {
                do {
                    let (text, confidence) = try await whisperCppEngine.transcribe(
                        fileAt: url, model: effectiveModel,
                        localeID: effectiveLocale, biasTerms: biasTerms, prompt: prompt)
                    if TranscriptionPlausibility.isPlausible(
                        text, audioDurationSeconds: audioDuration, confidence: confidence) {
                        return text
                    }
                    lastError = "whisper.cpp's result looked implausible for this " +
                        "recording — used Apple engine instead."
                    dictationLog.error("recognize: \(self.lastError ?? "", privacy: .public)")
                } catch {
                    lastError = "whisper.cpp engine failed " +
                        "(\(error.localizedDescription)) — used Apple engine instead."
                    dictationLog.error("recognize: \(self.lastError ?? "", privacy: .public)")
                }
            } else {
                whisperCppEngine.preload(model: effectiveModel)
                lastError = "whisper.cpp model is still preparing — used Apple " +
                    "engine for this dictation. whisper.cpp takes over when ready."
                dictationLog.error("recognize: \(self.lastError ?? "", privacy: .public)")
            }
        } else if effectiveEngine == "parakeet" {
            if parakeetEngine.isReady(model: effectiveModel) {
                do {
                    let (text, confidence) = try await parakeetEngine.transcribe(
                        fileAt: url, model: effectiveModel,
                        localeID: effectiveLocale, biasTerms: biasTerms,
                        boostVocabulary: developerVocabulary)
                    if TranscriptionPlausibility.isPlausible(
                        text, audioDurationSeconds: audioDuration, confidence: confidence) {
                        return text
                    }
                    lastError = "Parakeet's result looked implausible for this " +
                        "recording — used Apple engine instead."
                    dictationLog.error("recognize: \(self.lastError ?? "", privacy: .public)")
                } catch {
                    lastError = "Parakeet engine failed " +
                        "(\(error.localizedDescription)) — used Apple engine instead."
                    dictationLog.error("recognize: \(self.lastError ?? "", privacy: .public)")
                }
            } else {
                parakeetEngine.preload(model: effectiveModel)
                lastError = "Parakeet model is still preparing — used Apple " +
                    "engine for this dictation. Parakeet takes over when ready."
                dictationLog.error("recognize: \(self.lastError ?? "", privacy: .public)")
            }
        } else if effectiveEngine == "sherpa" {
            if sherpaEngine.isReady(model: effectiveModel) {
                do {
                    let text = try await sherpaEngine.transcribe(
                        fileAt: url, model: effectiveModel,
                        localeID: effectiveLocale, biasTerms: biasTerms,
                        vadManager: await vadEngine.loadedManager())
                    if TranscriptionPlausibility.isPlausible(text, audioDurationSeconds: audioDuration) {
                        return text
                    }
                    lastError = "sherpa-onnx's result looked implausible for this " +
                        "recording — used Apple engine instead."
                    dictationLog.error("recognize: \(self.lastError ?? "", privacy: .public)")
                } catch {
                    lastError = "sherpa-onnx engine failed " +
                        "(\(error.localizedDescription)) — used Apple engine instead."
                    dictationLog.error("recognize: \(self.lastError ?? "", privacy: .public)")
                }
            } else {
                sherpaEngine.preload(model: effectiveModel)
                lastError = "sherpa-onnx model is still preparing — used Apple " +
                    "engine for this dictation. sherpa-onnx takes over when ready."
                dictationLog.error("recognize: \(self.lastError ?? "", privacy: .public)")
            }
        }
        dictationLog.info(
            "recognize: falling back to Apple engine, locale=\(effectiveLocale, privacy: .public)")
        // The shared `transcriber` stays pinned to the global locale (it's
        // kept warm there), so a per-profile locale override that differs
        // from it needs its own instance — the common case (no override)
        // skips this and reuses the already-warm one.
        if effectiveLocale == Settings.localeIdentifier {
            return try await transcriber.transcribe(fileAt: url, biasTerms: biasTerms)
        }
        let overrideTranscriber = Transcriber(locale: Locale(identifier: effectiveLocale))
        return try await overrideTranscriber.transcribe(fileAt: url, biasTerms: biasTerms)
    }

    /// Copies dictated text to the clipboard as a side effect of a paste
    /// that couldn't happen (auto-paste off, or Accessibility not granted)
    /// — never a deliberate "Copy" the user asked for (History's own copy
    /// action writes the clipboard directly, not through this). Marked
    /// `org.nspasteboard.TransientType` alongside the real string — a
    /// convention popular clipboard managers (Paste, Maccy, CleanShot's
    /// clipboard, …) already respect to skip recording a change into their
    /// history. Spoken dictation landing here by necessity shouldn't also
    /// mean it sits in someone's clipboard history forever.
    nonisolated private static func copyToClipboardTransiently(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
    }

    /// Notetaker's own transcription path — deliberately does *not* go
    /// through `recognize(fileAt:bundleID:)`'s engine selection. A meeting's
    /// mic track is sent as one unchunked file for the whole call, however
    /// long that is (see `MeetingTranscriber`) — nothing like a push-to-talk
    /// dictation's few-seconds-to-a-minute range. sherpa-onnx's LLM-backed
    /// models (FunASR Nano, Qwen3-ASR) hit a hard, unfixable context-window
    /// wall well under a minute in — silently empty or silently wrong past
    /// it — which is a real risk here since whichever engine the user has
    /// chosen for normal dictation is exactly what this used to inherit.
    /// Parakeet v3's transducer decode has no such ceiling (verified
    /// directly: a 156s clip round-tripped complete and accurate through
    /// this exact call), so Notetaker always uses it, independent of the
    /// user's chosen engine. Falls back to Apple — same as every other
    /// engine's "not ready yet" case above — if v3 isn't downloaded/loaded,
    /// rather than blocking the meeting on a cold start.
    private func recognizeForNotetaker(fileAt url: URL) async throws -> String {
        ScreenContext.refresh(pid: nil)  // the last dictation's screen isn't this meeting's
        let biasTerms = LearnedStore.biasTerms(includeDeveloperVocabulary: false)
        if parakeetEngine.isReady(model: "v3") {
            do {
                return try await parakeetEngine.transcribe(
                    fileAt: url, model: "v3", localeID: Settings.localeIdentifier,
                    biasTerms: biasTerms, boostVocabulary: false).text
            } catch {
                dictationLog.error(
                    "notetaker recognize: Parakeet v3 failed (\(error.localizedDescription, privacy: .public)) — used Apple engine instead.")
            }
        } else {
            parakeetEngine.preload(model: "v3")
            dictationLog.info("notetaker recognize: Parakeet v3 still preparing — used Apple engine for this meeting.")
        }
        return try await transcriber.transcribe(fileAt: url, biasTerms: biasTerms)
    }

    // MARK: - Hotkey wiring

    private func wireHotkey() {
        hotkeyMonitor.onStart = { [weak self] in
            DispatchQueue.main.async { self?.startRecording() }
        }
        hotkeyMonitor.onStop = { [weak self] in
            DispatchQueue.main.async { self?.stopAndTranscribe() }
        }
        hotkeyMonitor.onCancel = { [weak self] in
            DispatchQueue.main.async {
                self?.endLiveChunks()?.cancel()
                self?.recorder.cancel()
                self?.uiState = .idle
                self?.activeProfileHotkeySlot = nil
            }
        }
        hotkeyMonitor.onHandsFreeChange = { [weak self] active in
            DispatchQueue.main.async {
                guard let self else { return }
                if active, !LicenseStore.shared.dictationAllowed {
                    self.hotkeyMonitor.resetHandsFree()
                    return
                }
                self.isHandsFree = active
                self.updateIcon()
                if active {
                    SoundEffect.play("Pop")
                    if Settings.handsFreeAutoStop {
                        self.turnDetector.start()
                        self.recorder.onLiveBuffer = { [weak self] buffer in
                            Task { @MainActor in await self?.turnDetector.ingest(buffer) }
                        }
                    }
                } else {
                    self.recorder.onLiveBuffer = nil
                    self.turnDetector.stop()
                }
            }
        }
        turnDetector.onTurnEnd = { [weak self] in
            guard let self else { return }
            self.recorder.onLiveBuffer = nil
            self.hotkeyMonitor.resetHandsFree()
            self.stopAndTranscribe()
        }
    }

    private var recordingStartedAt: Date?
    private var recordingTargetBundleID: String?
    /// Captured alongside the bundle ID rather than looked up again later —
    /// by the time a dictation finishes and a discovery notification might
    /// fire, the target app could have quit, and `localizedName` needs it
    /// still running.
    private var recordingTargetAppName: String?
    /// Set only when a profile hotkey force-started this recording. Kept
    /// separate from `recordingTargetBundleID` rather than overwriting it:
    /// the discovery-prompt check further down still needs to know the
    /// *actually* frontmost app, not the forced one, or it would silently
    /// stop pitching a profile for whatever app genuinely has none yet.
    private var recordingForcedBundleID: String?
    /// The text selected when the dictation key went down, read through Accessibility while the user talks — for
    /// editing it by voice (`SpokenCommand`). nil inside: nothing selected, or the app doesn't say.
    private var selectionAtKeyDown: Task<(selection: CursorContext.Selection, editable: Bool?), Never>?
    /// The coding field the dictation key went down in — a prompt box, code editor or shell — and its project
    /// (`CodeField`), read while the user talks.
    private var codeFieldAtKeyDown: Task<CodeField.Context?, Never>?
    /// Which profile-hotkey slot (if any) started the current recording, so
    /// a *different* slot pressed mid-recording is a no-op instead of
    /// stopping a dictation some other slot started.
    private var activeProfileHotkeySlot: ProfileHotkeySlot?

    private func startRecording(forcedBundleID: String? = nil) {
        guard uiState != .recording else { return }
        // An official release build needs an active license or a running trial; a build from source always has one.
        guard LicenseStore.shared.dictationAllowed else {
            showLicensePausedNotice()
            return
        }
        // Denied microphone access doesn't fail the recording — macOS just hands over silence — so say so up front.
        if [.denied, .restricted].contains(AVCaptureDevice.authorizationStatus(for: .audio)) {
            lastError = "Murmur doesn't have microphone access. Allow it in System Settings → Privacy & Security → "
                + "Microphone."
            showHUDNotice("Microphone access is off")
            return
        }
        // Whatever the last dictation's field shows now is what the user made of it — see `EditLearner`.
        EditLearner.dictationStarted()
        SentMessageLearner.dictationStarted()
        do {
            try recorder.start()
            recordingStartedAt = Date()
            let frontmost = NSWorkspace.shared.frontmostApplication
            // The names on screen, and where the text is going, read while the user talks — see `ScreenContext`
            // and `DestinationDetector`.
            ScreenContext.refresh(pid: frontmost?.processIdentifier)
            DestinationDetector.refresh(bundleID: forcedBundleID ?? frontmost?.bundleIdentifier,
                                        pid: forcedBundleID == nil ? frontmost?.processIdentifier : nil)
            // What's selected, if anything — off the main thread, so the key never waits on another app.
            selectionAtKeyDown = SpokenCommand.enabled && forcedBundleID == nil
                && frontmost?.bundleIdentifier != Bundle.main.bundleIdentifier
                ? Task.detached(priority: .userInitiated) {
                    let selection = CursorContext.selection()
                    // Text is selected: an instruction may be coming, so the model that would carry it out is loaded
                    // while the user talks.
                    if case .text = selection, SpokenCommand.usesGemma { Task { await Translator.shared.prewarm(.gemma) } }
                    return (selection, CursorContext.focusedIsEditable())
                } : nil
            let (frontID, frontPID) = (frontmost?.bundleIdentifier, frontmost?.processIdentifier)
            codeFieldAtKeyDown = forcedBundleID == nil
                ? Task.detached(priority: .userInitiated) { CodeField.detect(bundleID: frontID, pid: frontPID) } : nil
            recordingTargetBundleID = frontmost?.bundleIdentifier
            recordingTargetAppName = frontmost?.localizedName
            prewarmTranslation(bundleID: forcedBundleID ?? frontmost?.bundleIdentifier)
            prewarmWriter(bundleID: forcedBundleID ?? frontmost?.bundleIdentifier)
            statusHUD.setTargetAppIcon(frontmost?.icon)
            statusHUD.setLevel(0)
            recordingForcedBundleID = forcedBundleID
            startLiveChunks(bundleID: forcedBundleID ?? recordingTargetBundleID)
            // A shell: whisper.cpp gets commands as its example, for what's decoded while the user is still talking too.
            if let task = codeFieldAtKeyDown, let session = liveChunks {
                Task { if await task.value?.kind == .shell { session.prompt = WhisperPrompt.shell } }
            }
            uiState = .recording
            // After `uiState`, never before: with the state still idle, clearing the last dictation's check or
            // message would briefly ask the HUD to hide — which let go of the app icon just set above.
            hudFlashTask?.cancel()
            hudFlash = nil
            lastError = nil
            if recorder.inputIsBluetooth, !recorder.hasDeliveredAudio {
                startSoundWaitsForHeadset = true
                dictationLog.notice("mic: waiting for the Bluetooth headset before the start sound")
            } else {
                startSoundWaitsForHeadset = false
                SoundEffect.play("Pop")
            }
        } catch {
            lastError = "Could not start recording: \(error.localizedDescription)"
            SoundEffect.play("Basso")
            flashHUD(.failure("Couldn’t start the microphone"), for: 2.4)
        }
    }

    /// The dictation key was pressed while the license is paused: the usual "can't" sound, a moment in the HUD over the
    /// app being dictated into, and the full reason in the main window's error line.
    private func showLicensePausedNotice() {
        let store = LicenseStore.shared
        lastError = store.pausedExplanation
        showHUDNotice(store.pausedNotice ?? LicensePanelState.PausedReason.trialEnded.hudNotice)
    }

    /// A moment's message in the HUD, over the app in front, with the usual "can't" sound — what a paused dictation key
    /// press shows. Also the license preview's "Show the paused HUD", which pauses nothing.
    func showHUDNotice(_ text: String) {
        statusHUD.setTargetAppIcon(NSWorkspace.shared.frontmostApplication?.icon)
        hudNotice = text
        SoundEffect.play("Basso")
        hudNoticeTask?.cancel()
        hudNoticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            self?.hudNotice = nil
        }
    }

    /// `murmurmac://activate?key=…` — the link in the receipt email. Opens Settings at the License tile and activates
    /// the key there, so the result shows where the buyer can see it. A build from source has no license to activate.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let key = urls.lazy.compactMap(LicenseLinks.activationKey(from:)).first else { return }
        // A build from source has no license to activate — unless the preview is on, where the link can be tried out.
        let store: LicenseStore
        if LicenseStore.shared.channel == .release {
            store = LicenseStore.shared
        } else if UserDefaults.standard.bool(forKey: LicensePreview.defaultsKey) {
            store = LicensePreview.shared.store
        } else {
            return
        }
        pendingNavigateToPage = .settings
        openLicenseTile = true
        showMainWindow()
        Task { await store.activateFromSettings(key: key) }
    }

    /// Handles a Control+Shift+digit press: forces a dictation resolved
    /// against whichever profile owns this slot, regardless of the
    /// frontmost app. A toggle, not hold-to-talk — the same slot pressed
    /// again stops the recording it started; a different slot pressed while
    /// any dictation is already active is a no-op, so one profile hotkey
    /// can never yank away a recording a different mechanism started.
    private func handleProfileHotkey(_ slot: ProfileHotkeySlot) {
        if uiState == .recording {
            guard activeProfileHotkeySlot == slot else { return }
            stopAndTranscribe()
            return
        }
        guard uiState == .idle else { return }
        guard let bundleID = AppProfileStore.profiles.first(
            where: { $0.value.hotkeySlot == slot })?.key
        else { return }
        activeProfileHotkeySlot = slot
        startRecording(forcedBundleID: bundleID)
    }

    /// Transcribe while you talk, for whisper.cpp: the finished part of a long dictation is decoded while the rest is
    /// still being spoken. Only when that engine and model will handle this dictation and are already loaded;
    /// `defaults write local.murmur liveChunking -bool false` turns it off (read per dictation, no restart).
    /// The usual check after a paste — or, when a translation couldn't be used, what went in and why.
    private func flashPasted(translationNote: String?) {
        if let translationNote {
            flashHUD(.info("Pasted as you said it — \(translationNote)", symbol: "globe"), for: 3.2)
        } else {
            flashHUD(.done, for: 0.75)
        }
    }

    /// An app with a tone or a template of its own: Gemma 4, which writes those when it is on this Mac, loads while
    /// the user talks. A template asked for by voice ("Meeting notes. …") isn't known yet, and waits for the model.
    private func prewarmWriter(bundleID: String?) {
        guard SpokenCommand.usesGemma, AppProfileStore.style(forBundleID: bundleID).instructions != nil
                || AppProfileStore.template(forBundleID: bundleID) != nil else { return }
        Task { await Translator.shared.prewarm(.gemma) }
    }

    /// Translate into with a downloaded model: it loads while the user talks, so the translation doesn't wait for it.
    private func prewarmTranslation(bundleID: String?) {
        guard let pair = TranslateInto.pair(spokenLocale: AppProfileStore.localeIdentifier(forBundleID: bundleID),
                                            bundleID: bundleID, codeField: nil),
              let engine = TranslationModels.shared.engine(from: pair.from, to: pair.to), engine != .apple
        else { return }
        Task { await Translator.shared.prewarm(engine == .gemma ? .gemma : .euroLLM) }
    }

    private func startLiveChunks(bundleID: String?) {
        endLiveChunks()?.cancel()
        guard UserDefaults.standard.object(forKey: "liveChunking") as? Bool ?? true,
              AppProfileStore.engine(forBundleID: bundleID) == "whispercpp" else { return }
        let model = AppProfileStore.model(forBundleID: bundleID)
        guard whisperCppEngine.isReady(model: model) else { return }
        let session = LiveChunkSession(
            engine: whisperCppEngine, vad: { [vadEngine] in await vadEngine.loadedManager() },
            model: model, localeID: AppProfileStore.localeIdentifier(forBundleID: bundleID),
            biasTerms: LearnedStore.biasTerms(
                includeDeveloperVocabulary: AppProfileStore.developerVocabularyEnabled(forBundleID: bundleID)))
        recorder.onLiveChunkBuffer = { buffer in session.append(buffer) }
        session.start()
        liveChunks = session
    }

    /// Why the microphone delivered nothing but exact zeros, for the error line and the HUD.
    private func microphoneSilenceReason() -> (reason: String, notice: String) {
        if [.denied, .restricted].contains(AVCaptureDevice.authorizationStatus(for: .audio)) {
            return ("Murmur doesn't have microphone access, so macOS gave it silence. Allow it in System Settings → "
                    + "Privacy & Security → Microphone.", "Microphone access is off")
        }
        if recorder.inputIsBluetooth {
            return ("Your Bluetooth headset sent no sound — it may be connected to another device, like your "
                    + "iPhone.", "The headset sent no sound")
        }
        return ("The microphone sent pure silence — another app may be holding it, or it's muted in hardware.",
                "The microphone sent no sound")
    }

    /// Detaches the live session from the recorder and hands it over (or nil) — the caller finishes or cancels it.
    private func endLiveChunks() -> LiveChunkSession? {
        recorder.onLiveChunkBuffer = nil
        defer { liveChunks = nil }
        return liveChunks
    }

    /// The key came up (or hands-free ended): keep listening for the audio still in flight, then transcribe.
    private func stopAndTranscribe() {
        guard uiState == .recording, !isFinishingRecording else { return }
        isFinishingRecording = true
        isHandsFree = false
        releaseTargetPID = FocusedApp.pid()
        releaseOwnField = OwnTextField.focused(
            murmurWasInFront: NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier)
        recorder.stopAfterTail { [weak self] url in
            guard let self else { return }
            self.isFinishingRecording = false
            self.finishRecording(url)
        }
    }

    private func finishRecording(_ url: URL?) {
        guard let url else {
            endLiveChunks()?.cancel()
            uiState = .idle
            return
        }
        let liveChunks = endLiveChunks()
        let pasteTargetPID = releaseTargetPID
        // This recording's selection — a new key press may start the next one before this one is processed.
        let selectionTask = selectionAtKeyDown
        selectionAtKeyDown = nil
        let codeFieldTask = codeFieldAtKeyDown
        codeFieldAtKeyDown = nil
        releaseTargetPID = nil
        let ownField = releaseOwnField
        releaseOwnField = nil
        SoundEffect.play("Tink")
        uiState = .processing
        let duration = recordingStartedAt.map { Date().timeIntervalSince($0) }
        recordingStartedAt = nil
        let targetBundleID = recordingTargetBundleID
        recordingTargetBundleID = nil
        let targetAppName = recordingTargetAppName
        recordingTargetAppName = nil
        // Style/template resolve against the forced bundle ID when a
        // profile hotkey started this recording, but `targetBundleID`
        // itself stays the *actually* frontmost app for the discovery
        // prompt below, which needs to know what's really missing a
        // profile — not what was just force-resolved to one that exists.
        let resolvedBundleID = recordingForcedBundleID ?? targetBundleID
        recordingForcedBundleID = nil
        activeProfileHotkeySlot = nil

        let frames = recorder.capturedFrames
        let rate = recorder.capturedFormat?.sampleRate ?? 0
        dictationLog.info("stop: \(frames) frames @ \(rate, format: .fixed(precision: 0)) Hz")
        guard frames > 0 else {
            // The microphone delivered nothing at all. Previously this still
            // went to the recognizer, which returned an empty string, and the
            // whole dictation vanished with no explanation.
            dictationLog.error("stop: NO AUDIO CAPTURED")
            liveChunks?.cancel()
            lastError = "No audio was captured — the microphone delivered "
                + "nothing. If you're on Bluetooth headphones, try switching "
                + "input to the built-in microphone."
            SoundEffect.play("Basso")
            flashHUD(.failure("The microphone gave no audio"), for: 2.4)
            uiState = .idle
            try? FileManager.default.removeItem(at: url)
            return
        }
        if recorder.deliveredOnlyZeros {
            // Pure digital silence isn't a quiet room: the microphone isn't delivering at all.
            dictationLog.error("stop: the microphone delivered only exact zeros")
            liveChunks?.cancel()
            let (reason, notice) = microphoneSilenceReason()
            lastError = reason
            SoundEffect.play("Basso")
            flashHUD(.failure(notice), for: 2.6)
            uiState = .idle
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard recorder.hasSignal else {
            // Frames exist (room tone, mic self-noise) but no real speech —
            // pressing the key and releasing it without saying anything.
            // Whisper models hallucinate on exactly this: fed silence, they
            // fill it in with a sign-off phrase like "Thank you." rather
            // than admitting there's nothing there, because their training
            // data is full of transcripts that end that way. Skipping the
            // recognizer entirely here is what actually fixes it — no
            // amount of prompting talks a model out of a pattern this deep
            // in its training.
            dictationLog.info("stop: no speech detected, skipping recognition")
            liveChunks?.cancel()
            flashHUD(.failure("Didn’t hear anything"), for: 2.4)
            uiState = .idle
            try? FileManager.default.removeItem(at: url)
            return
        }

        // The cleanup model's fixed prompt is read while recognition runs, so
        // when the text arrives the model only has the dictated words left
        // (~300 ms less waiting, identical output — see `prewarmCleanup`).
        // Plain clean-up only — in English, or another language it runs in (`CleanupLanguage`); anything else doesn't
        // use it.
        let earlyLanguage = CleanupLanguage.rules(forLocale: Settings.localeIdentifier)
        if rewriteEngine.isAvailable,
           String(Settings.localeIdentifier.prefix(while: { $0 != "-" })).lowercased() == "en" || earlyLanguage != nil {
            let earlyStyle = AppProfileStore.style(forBundleID: resolvedBundleID)
            let earlyTemplate = earlyLanguage == nil ? AppProfileStore.template(forBundleID: resolvedBundleID) : nil
            let earlyLevel = StyleSettings.defaultCleanupLevel
            if RewritePlan.isPlainCleanup(template: earlyTemplate, style: earlyStyle, cleanupLevel: earlyLevel),
               let earlyInstructions = RewritePlan.instructions(
                template: earlyTemplate, style: earlyStyle, cleanupLevel: earlyLevel,
                voice: Settings.useVoiceProfile ? voiceProfile : nil, language: earlyLanguage) {
                Task.detached(priority: .userInitiated) { [rewriteEngine] in
                    rewriteEngine.prewarmCleanup(instructions: earlyInstructions)
                }
            }
        }

        Task { [history, rewriteEngine, pipelineStats] in
            defer { try? FileManager.default.removeItem(at: url) }
            // A second, sharper opinion on top of the RMS-based `hasSignal`
            // gate just above — catches what raw amplitude can't, like a
            // loud non-speech sound clearing the floor. Independent of
            // whichever recognition engine is selected below.
            // Where each dictation's milliseconds go — durations only, never
            // text — logged once at the end of the pipeline.
            var stageClock = Date()
            var stageTimes: [String] = []
            func lap(_ stage: String) {
                stageTimes.append("\(stage)=\(Int(Date().timeIntervalSince(stageClock) * 1000))")
                stageClock = Date()
            }
            let vad = await vadEngine.analyze(fileAt: url)
            lap("vad")
            if let vad, !vad.hasSpeech {
                dictationLog.info("recognize: VAD found no speech, skipping recognition")
                liveChunks?.cancel()
                flashHUD(.failure("Didn’t hear anything"), for: 2.4)
                uiState = .idle
                return
            }
            // A site rule takes over from the browser's own generic
            // profile when the active tab matches — shadowing rather than
            // a fresh `let` so every resolver below (`recognize`,
            // `style(forBundleID:)`, `history.add`, …) picks the
            // substitution up automatically, same as if it were the real
            // frontmost bundle ID. Skips the AppleScript round-trip
            // entirely unless both a supported browser is actually
            // frontmost and at least one site rule exists — the common
            // case for most users, who have neither.
            var resolvedBundleID = resolvedBundleID
            if AppProfileStore.hasSiteProfiles,
               let browser = MeetingApp.allCases.first(
                where: { $0.rawValue == resolvedBundleID && $0.isBrowser }) {
                let activeURL = await Task.detached(priority: .utility) {
                    BrowserTabReader.activeTabURL(for: browser)
                }.value
                if let activeURL, let siteKey = AppProfileStore.siteProfileKey(forURL: activeURL) {
                    dictationLog.info("recognize: site rule matched, using \(siteKey, privacy: .public)")
                    resolvedBundleID = siteKey
                }
            }
            do {
                dictationLog.info("recognize: start")
                // The coding field read at key-down (`CodeField`): a shell's recognition gets commands as its example.
                let codeField = await codeFieldTask?.value
                let shellPrompt = codeField?.kind == .shell ? WhisperPrompt.shell : nil
                let raw = try await recognize(
                    fileAt: url, bundleID: resolvedBundleID, speechEnd: vad?.lastSpeechEnd, liveChunks: liveChunks,
                    prompt: shellPrompt)
                if shellPrompt != nil, WhisperPrompt.echoesShell(raw) {
                    dictationLog.error("recognize: the shell example came back instead of speech — discarded")
                    flashHUD(.failure("Didn’t hear anything"), for: 2.4)
                    uiState = .idle
                    return
                }
                dictationLog.info("recognize: done, \(raw.count) chars")
                lap("asr")
                let developerVocabulary = AppProfileStore.developerVocabularyEnabled(
                    forBundleID: resolvedBundleID)

                // Whisper-family engines hallucinate a small, specific set
                // of sign-off phrases ("Thank you.") on near-silent audio
                // that still clears the earlier signal-duration gate — the
                // model's own confidence score doesn't catch this (measured:
                // ~0.00002 "no speech" probability on a confidently
                // hallucinated "Thank you."), so the output itself is
                // checked directly. Caught here, before any further
                // processing spends time or an LLM call on text that's
                // about to be discarded anyway.
                guard !HallucinationFilter.isLikelyHallucination(raw) else {
                    dictationLog.error(
                        "recognize: discarded as a likely hallucination: \(raw, privacy: .public)")
                    flashHUD(.failure("Didn’t hear anything"), for: 2.4)
                    uiState = .idle
                    return
                }

                // A coding field decides by what it is, not by the app (`CodeField`): a prompt box gets the usual clean-up,
                // even inside a terminal; a code editor or shell gets the exact words. An app's own style in App Profiles
                // still wins.
                var style = AppProfileStore.style(forBundleID: resolvedBundleID)
                if let codeField, AppProfileStore.profile(forBundleID: resolvedBundleID)?.style == nil {
                    style = codeField.kind == .prompt ? .none : .raw
                }
                if let codeField {
                    dictationLog.info(
                        "coding field: \(codeField.kind.rawValue, privacy: .public), project names: \(codeField.names.count)")
                }
                dictationLog.info("style resolved: \(style.rawValue, privacy: .public)")

                // Personal-correction stores are English-only by nature:
                // `LearnedStore` holds mishearing fixes, and `TextFormatter`'s
                // dictionary holds spellings, both learned from past
                // *English* dictations. Applied to another language, a short
                // "heard" trigger (e.g. "up", "there") can exact-word-match a
                // coincidental token in the transcript and get swapped for
                // its English "intended" text — corrupting part of an
                // otherwise-correct non-English sentence (this is what was
                // silently reintroducing the Latvian-dictation bug even
                // after Harper below was fixed). Harper has the same problem
                // for the same reason, just for spelling/grammar instead of
                // personal corrections.
                let isEnglishDictation =
                    String(Settings.localeIdentifier.prefix(while: { $0 != "-" }))
                    .lowercased() == "en"
                // Another language the plain clean-up runs in, held to stricter rules — see `CleanupLanguage`.
                let cleanupLanguage = CleanupLanguage.rules(forLocale: Settings.localeIdentifier)
                dictationLog.info(
                    "locale gate: Settings.localeIdentifier=\(Settings.localeIdentifier, privacy: .public) engine=\(Settings.engine, privacy: .public) parakeetModel=\(Settings.parakeetModel, privacy: .public) isEnglishDictation=\(isEnglishDictation)")

                // Editing a selection by voice — see `SpokenCommand`. Text was selected when the key went down and what
                // was said is an instruction about it ("make this shorter"): the selection is rewritten in place and
                // nothing is dictated. Anything else said over a selection is dictated as usual.
                // An app that doesn't say what is selected (a web page, a PDF, an app without Accessibility support)
                // is asked the way a person would: ⌘C — only once the words are known to be an instruction, so an
                // ordinary dictation never touches the clipboard for it.
                if let selected = await selectionTask?.value {
                    let state = switch selected.selection {
                    case .text(let text): "\(text.count) characters"
                    case .nothing: "nothing"
                    case .unknown: "not reported"
                    }
                    dictationLog.notice("selection at key-down: \(state, privacy: .public); instruction: \(SpokenCommand.instruction(in: TextFormatter(dictionary: [:]).format(raw)) != nil, privacy: .public)")
                }
                if isEnglishDictation, !style.skipsAllProcessing, let selected = await selectionTask?.value,
                   await editSelectionIfAsked(said: raw, selected: selected, bundleID: resolvedBundleID,
                                              pasteTargetPID: pasteTargetPID) {
                    uiState = .idle
                    return
                }

                // Tallied for Insights' "Fixes made by Murmur" card only —
                // each count comes from a plain before/after read of
                // `formatted` around a call already made below, never from
                // changing what that call does or re-deriving its result.
                var harperFixCount = 0
                var dictionaryFixCount = 0
                var snippetExpansionCount = 0
                // The dictation starts with a snippet's saved text: it's pasted as written, never lower-cased to
                // continue a sentence.
                var snippetLeads = false
                // Translate into: what's pasted is in this language now, and why the user's own words went in instead
                // when the translation couldn't be used.
                var outputIsEnglish = isEnglishDictation
                var translationNote: String?

                var formatted: String
                if style.skipsAllProcessing {
                    // Raw: exact words, no cleanup, no AI. For terminals and
                    // code editors, where "corrections" would be corruption.
                    formatted = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if isEnglishDictation {
                        let beforeDictionary = formatted
                        formatted = LearnedStore.apply(
                            in: formatted, includeDeveloperVocabulary: developerVocabulary)
                        dictionaryFixCount += PipelineDiff.wordChangeCount(
                            from: beforeDictionary, to: formatted)
                        // A code editor or shell: spoken code as code ("dash dash watch" → --watch) and the project's
                        // own names ("upload client" → UploadClient.swift).
                        if let codeField, codeField.kind != .prompt {
                            formatted = CodeField.exactText(formatted, context: codeField)
                        }
                    }
                    let held = SnippetStore.hold(in: formatted)
                    snippetExpansionCount += held.useCount
                    let restored = held.restore(held.text)
                    formatted = restored.text
                    snippetLeads = restored.startsWithSnippet
                } else {
                    formatted = TextFormatter(
                        dictionary: isEnglishDictation ? TextFormatter.loadDictionary() : [:],
                        speaksEnglish: isEnglishDictation,
                        extraFillers: cleanupLanguage?.fillers ?? []
                    ).format(raw)
                    if isEnglishDictation {
                        let beforeDictionary = formatted
                        formatted = LearnedStore.apply(
                            in: formatted, includeDeveloperVocabulary: developerVocabulary)
                        dictionaryFixCount += PipelineDiff.wordChangeCount(
                            from: beforeDictionary, to: formatted)
                        // "3 p.m." / "3 PM" / "3.30pm" → "3pm" / "3:30pm": one way
                        // of writing a time, whatever the engine made of it.
                        // English only (like everything that reads words) and
                        // before the resolver, which then sees canonical times.
                        formatted = TimeNormalizer.normalize(formatted)
                        // "5pm, actually 6pm" → "6pm". Deterministic and
                        // English-only, and before snippets so a retracted
                        // trigger phrase is never expanded. Raw (above) keeps
                        // every word as spoken, retractions included.
                        let resolved = SelfCorrectionResolver.resolve(formatted)
                        formatted = resolved.text
                        if resolved.corrections > 0 {
                            dictationLog.info("self-correction: resolved \(resolved.corrections)")
                        }
                    }
                    // A prompt box for a coding agent: the project's own names ("the upload client" → UploadClient), kept
                    // through the clean-up and Harper below as the user's own words.
                    var projectTerms: [String] = []
                    if let codeField, codeField.kind == .prompt, !codeField.names.isEmpty {
                        let named = CodeField.promptText(formatted, context: codeField)
                        formatted = named.text
                        projectTerms = named.used
                    }
                    // Snippets: each phrase is swapped for a marker word here and the saved text goes back in at the very
                    // end, so the clean-up, templates, Harper and the per-app shaping only ever touch the user's own
                    // words — see `SnippetStore`. Just a phrase on its own skips all of that.
                    let held = SnippetStore.hold(in: formatted)
                    snippetExpansionCount += held.useCount
                    formatted = held.text
                    if !held.isEmpty {
                        dictationLog.info("snippets: held \(held.slots.count) (whole dictation: \(held.isWholeDictation))")
                    }
                    lap("format")

                    // Everything below needs the model, and the spoken
                    // trigger must not be stripped out of the text unless
                    // something is actually going to act on it.
                    //
                    // English only — see `isEnglishDictation` above, same
                    // reasoning as Harper and the correction stores: the
                    // *named* styles (Formal/Casual/…) each say "keep the
                    // meaning, language and approximate length", but the
                    // baseline `cleanupInstructions` used here for the
                    // default "As spoken" style has no such anchor — it just
                    // says "fix grammar and punctuation." Apple Intelligence
                    // doesn't officially support Latvian (or most languages
                    // beyond a handful), so asked to "fix grammar" on it
                    // without being told to preserve the language, it edits
                    // word endings toward whatever it's more confident
                    // about — not literal English words, but exactly the
                    // "half right, half mangled" damage this was.
                    // Templates also run for Latvian dictation (`TemplateLanguage`); everything else in this step —
                    // clean-up, styles — stays English-only, as measured.
                    let templateLanguage = TemplateLanguage.from(localeIdentifier: Settings.localeIdentifier)
                    if !formatted.isEmpty, !held.isWholeDictation, rewriteEngine.isAvailable,
                       isEnglishDictation || templateLanguage == .latvian || cleanupLanguage != nil {
                        // A spoken trigger ("meeting notes, we discussed…")
                        // beats the app's standing rule: it's an explicit
                        // request for this one dictation.
                        var template: NoteTemplate?
                        var body = formatted
                        if Settings.voiceTemplatesEnabled,
                           let match = NoteTemplateStore.matchVoiceTrigger(in: formatted) {
                            template = match.template
                            body = match.remainder
                        } else {
                            template = AppProfileStore.template(forBundleID: resolvedBundleID)
                        }
                        // Latvian without a template: nothing in this step applies. Another clean-up language: only the
                        // plain clean-up — no template or style (those are written for English) — and only when that's
                        // what the app is set to.
                        if cleanupLanguage != nil {
                            template = nil
                            body = formatted
                            if !RewritePlan.isPlainCleanup(template: nil, style: style,
                                                           cleanupLevel: StyleSettings.defaultCleanupLevel) { body = "" }
                        } else if !isEnglishDictation, template == nil {
                            body = ""
                        }

                        // Structure and tone go in together. Running them as
                        // separate passes meant a template silently threw the
                        // app's style away; composing them keeps both for the
                        // price of one round-trip.
                        if let instructions = RewritePlan.instructions(
                            template: template, style: style,
                            cleanupLevel: StyleSettings.defaultCleanupLevel,
                            voice: Settings.useVoiceProfile ? voiceProfile : nil, language: cleanupLanguage),
                           !body.isEmpty {
                            // "Applying As spoken style…" read oddly once
                            // this became the always-on default cleanup pass
                            // rather than something the user explicitly set.
                            let statusText = template.map { "Formatting as \($0.name)" }
                                ?? (style == .none
                                    ? "Cleaning up"
                                    : "Applying \(style.displayName) style")
                            if RewritePlan.isPlainCleanup(
                                template: template, style: style,
                                cleanupLevel: StyleSettings.defaultCleanupLevel) {
                                // The plain cleanup is held to the words that
                                // went in: a small on-device model asked to
                                // "clean up" a dictation will sometimes answer
                                // it instead ("What the future means." →
                                // "Future means something different for
                                // everyone…"), swap synonyms, or Americanize
                                // spelling, and no prompt wording has ever
                                // fully stopped that. `cleanup` skips the
                                // model when there's nothing to clean, asks it
                                // with a capped, deterministic decode, and
                                // keeps only the edits `LLMEditGuard` allows.
                                // The status only shows if the model runs.
                                let outcome = await rewriteEngine.cleanup(
                                    body, instructions: instructions,
                                    vocabularyTerms: LearnedStore.biasTerms(
                                        includeDeveloperVocabulary: developerVocabulary) + held.markers + projectTerms,
                                    language: cleanupLanguage,
                                    onModelStart: { [weak self] in self?.transformStatus = statusText })
                                // A clean-up that lost a snippet's marker isn't used — the saved text must go back in.
                                formatted = held.keepsAll(outcome.text) ? outcome.text : body
                                dictationLog.info(
                                    "cleanup: ranModel=\(outcome.ranModel) modelFailed=\(outcome.modelFailed) revertedEdits=\(outcome.revertedEdits) discarded=\(outcome.discarded)")
                            } else if let template {
                                // A template: fields the model fills, laid out by Murmur, checked — see
                                // `TemplateEngine`. If it can't be applied safely, the words go in as spoken.
                                transformStatus = statusText
                                do {
                                    let applied = try await TemplateEngine.apply(
                                        template, to: body,
                                        extraInstructions: isEnglishDictation ? RewritePlan.templateExtras(
                                            style: style, cleanupLevel: StyleSettings.defaultCleanupLevel,
                                            voice: Settings.useVoiceProfile ? voiceProfile : nil) : nil,
                                        language: templateLanguage ?? .english,
                                        marks: TemplateMarks.for(bundleID: resolvedBundleID))
                                    if held.keepsAll(applied) {
                                        formatted = applied
                                    } else {
                                        formatted = body
                                        lastError = "\(template.name) left out a snippet, so your words were pasted as spoken."
                                        dictationLog.error("template not applied: it dropped a snippet marker")
                                    }
                                } catch {
                                    formatted = body
                                    lastError = ((error as? TemplateEngine.Failure)?.localizedDescription
                                        ?? "\(template.name) couldn't be applied.") + " Your words were pasted as spoken."
                                    dictationLog.error("template not applied: \(String(describing: error), privacy: .public)")
                                }
                            } else {
                                transformStatus = statusText
                                // A tone on its own runs under its own rules, examples and check (`toned`); a template
                                // with a tone, or Concise alone, goes the way it always has.
                                if template == nil, style.instructions != nil {
                                    let result = await rewriteEngine.toned(
                                        body, as: style, cleanupLevel: StyleSettings.defaultCleanupLevel,
                                        voice: Settings.useVoiceProfile ? voiceProfile : nil)
                                    if let refusal = result.refusal {
                                        dictationLog.error(
                                            "tone rewrite rejected: \(refusal.rawValue, privacy: .public) (\(body.count) chars in, \(result.attempt?.count ?? 0) out) — keeping unrewritten text")
                                    }
                                    if held.keepsAll(result.text) {
                                        formatted = result.text
                                    } else {
                                        dictationLog.error("rewrite rejected: it dropped a snippet marker — keeping unrewritten text")
                                    }
                                } else if let rewritten = try? await rewriteEngine.edit(
                                    body, instructions: instructions), !rewritten.isEmpty {
                                    // A Style or Concise pass may reword, so
                                    // it can't be held to the input's words —
                                    // but it may not multiply the input's
                                    // length (a real incident produced a
                                    // fabricated paragraph from a 3-word
                                    // dictation) or answer it: "Sure, let's
                                    // push the launch" for "Can we push the
                                    // launch?", or a "Hey!" nobody said.
                                    // `StyleRewriteGuard` refuses those, and
                                    // the dictation stays as it was. Templates
                                    // restructure by design and are exempt.
                                    if let rejection = StyleRewriteGuard.rejection(
                                        original: body, rewritten: rewritten, isTemplate: template != nil) {
                                        dictationLog.error(
                                            "rewrite rejected: \(rejection.rawValue) (\(body.count) chars in, \(rewritten.count) out) — keeping unrewritten text")
                                    } else if !held.keepsAll(rewritten) {
                                        dictationLog.error("rewrite rejected: it dropped a snippet marker — keeping unrewritten text")
                                    } else {
                                        formatted = rewritten
                                    }
                                }
                            }
                            transformStatus = nil
                        }
                    }

                    lap("llm")

                    // A fast, local, deterministic grammar pass — runs after
                    // the LLM step (catching whatever it missed) but doesn't
                    // depend on it: Harper needs no Apple Intelligence, so
                    // this still improves grammar on Macs where the pass
                    // above was skipped entirely. Milliseconds, not worth a
                    // status message next to a multi-second LLM round-trip.
                    //
                    // English only — see `isEnglishDictation` above: Harper
                    // hardcodes an English parser/dictionary, so it
                    // "corrects" other languages' real words into the
                    // nearest English one instead of leaving them alone.
                    if !formatted.isEmpty, isEnglishDictation, !held.isWholeDictation {
                        let beforeHarper = formatted
                        let fixed = HarperChecker.fix(
                            formatted,
                            vocabulary: LearnedStore.biasTerms(
                                includeDeveloperVocabulary: developerVocabulary) + held.markers + projectTerms)
                        formatted = held.keepsAll(fixed) ? fixed : beforeHarper
                        harperFixCount += PipelineDiff.wordChangeCount(from: beforeHarper, to: formatted)
                    }
                    // Translate into: the cleaned-up words in another language, checked — see `TranslateInto`. Never in a
                    // code editor or shell; a snippet's marker must come through for its saved text to go back in.
                    if !formatted.isEmpty, !held.isWholeDictation,
                       let pair = TranslateInto.pair(
                        spokenLocale: AppProfileStore.localeIdentifier(forBundleID: resolvedBundleID),
                        bundleID: resolvedBundleID, codeField: codeField?.kind) {
                        transformStatus = "Translating to \(TranslateInto.name(pair.to))"
                        let engine = TranslationModels.shared.engine(from: pair.from, to: pair.to)
                        let outcome = await Translator.shared.translate(
                            formatted, from: pair.from, to: pair.to, engine: engine, markers: held.markers)
                        transformStatus = nil
                        switch outcome {
                        case .translated(let text, let engine):
                            formatted = text
                            outputIsEnglish = pair.to == "en"
                            dictationLog.info("translate: \(pair.from, privacy: .public)→\(pair.to, privacy: .public) via \(engine.rawValue, privacy: .public)")
                        case .kept(let problem):
                            translationNote = problem.sentence
                            dictationLog.info("translate: kept the spoken words — \(problem.rawValue, privacy: .public)")
                        }
                        lap("translate")
                    }
                    // Laid out the way it was meant to be read (`DictationLayout`): points counted out loud as a
                    // numbered list, a new subject as a new paragraph, spoken bullets as real ones. Line breaks and
                    // list numbers only; never a word. Before the per-app shaping, which adds line breaks of its own.
                    let layoutDestination = DestinationDetector.current(for: resolvedBundleID)
                    if !formatted.isEmpty, outputIsEnglish, !held.isWholeDictation, DictationLayout.applies(to: layoutDestination) {
                        var laidOut = DictationLayout.shape(formatted, bullet: SpokenCommand.bullet(forBundleID: resolvedBundleID))
                        // A long dictation with no breaks of its own; a chat message stays one block.
                        if layoutDestination != .messaging { laidOut = await DictationLayout.paragraphed(laidOut) }
                        if held.keepsAll(laidOut) { formatted = laidOut }
                        lap("layout")
                    }
                    // "Auto (match app)" — opt-in via Style. Last, so nothing later undoes it: a spoken greeting
                    // and sign-off on their own lines in email, no full stop after a short chat message. Moves line
                    // breaks and a final full stop only; never a word.
                    if !formatted.isEmpty, outputIsEnglish, !held.isWholeDictation,
                       let destination = AppProfileStore.autoDestination(forBundleID: resolvedBundleID) {
                        formatted = DestinationShaper.shape(formatted, for: destination)
                    }
                    // The saved text back in, exactly as written.
                    let restored = held.restore(formatted)
                    formatted = restored.text
                    snippetLeads = restored.startsWithSnippet
                }
                lap("harper")
                dictationLog.info(
                    "pipeline done: \(formatted.count) chars, \(formatted.split(whereSeparator: \.isWhitespace).count) words; ms \(stageTimes.joined(separator: " "))")
                if !formatted.isEmpty {
                    history.add(formatted, duration: duration, targetBundleID: resolvedBundleID)
                    usageStats.record(
                        words: formatted.split(whereSeparator: \.isWhitespace).count, duration: duration,
                        bundleID: resolvedBundleID)
                    pipelineStats.record(
                        harperFixes: harperFixCount, dictionaryFixes: dictionaryFixCount,
                        snippetExpansions: snippetExpansionCount)
                    entries = history.entries
                    dictationLog.info("history: added, inserting text")
                    refreshVoiceProfileIfDue()
                    if !AppProfileStore.autoPasteEnabled(forBundleID: resolvedBundleID) {
                        // A deliberate choice, not a failure — no error, no
                        // sound, just leave it where the user asked for it.
                        Self.copyToClipboardTransiently(formatted)
                        dictationLog.info("auto-paste disabled for this app — left on clipboard")
                    } else if let field = ownField, field.isEditable, field.window?.isVisible == true {
                        // The key came up in one of Murmur's own fields (Voice Profile, Dictionary, Snippets,
                        // Templates, Scratchpad…): straight in at the cursor, as if typed — see `OwnTextField`. No
                        // need to bring Murmur forward for that.
                        let shapesAtCursor = UserDefaults.standard.object(forKey: "shapeAtCursor") as? Bool ?? true
                        OwnTextField.insert(formatted, into: field, shape: shapesAtCursor && !style.skipsAllProcessing,
                                            lowercaseContinuation: outputIsEnglish && !snippetLeads)
                        dictationLog.info("paste: typed into Murmur's own field")
                        flashPasted(translationNote: translationNote)
                    } else if AXIsProcessTrusted() {
                        // Dictating into Murmur's own window (Scratchpad,
                        // Ask, Transforms' try-it box, …) is the one case
                        // where the paste target and the app posting the
                        // synthetic ⌘V are the same process. The HUD panels
                        // are deliberately non-activating so they never
                        // steal focus from *another* app mid-dictation —
                        // but the several-second gap between "recording
                        // stops" and "text is ready" is enough for Murmur
                        // itself to lose active-app status in the interim
                        // (e.g. the user's attention/pointer drifting to
                        // another window), which the other-app path never
                        // had to survive since it was never Murmur's status
                        // to lose. Reactivating right before the paste
                        // restores it without touching the window's own
                        // first responder, which AppKit preserves across an
                        // app losing and regaining active status.
                        if resolvedBundleID == Bundle.main.bundleIdentifier {
                            NSApp.activate(ignoringOtherApps: true)
                        }
                        // The text goes where the key came up. If another app took focus while Murmur was working,
                        // pasting would put it in the wrong place — leave it on the clipboard instead.
                        if resolvedBundleID != Bundle.main.bundleIdentifier, let pasteTargetPID,
                           let focused = FocusedApp.pid(), focused != pasteTargetPID {
                            dictationLog.info("paste: the app in front changed since the key came up; copied instead")
                            Self.copyToClipboardTransiently(formatted)
                            lastError = "A different app came to the front while Murmur was finishing, so the text was "
                                + "copied instead of pasted — press ⌘V where you want it."
                            flashHUD(.info("Copied — press ⌘V to paste", symbol: "doc.on.clipboard"), for: 2.6)
                        } else if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                                  RemoteSession.bundleIDs.contains(front) {
                            // Inside a remote desktop or a virtual machine ⌘V isn't paste — leave it for the user there.
                            Self.copyToClipboardTransiently(formatted)
                            lastError = "Pasting into a remote desktop or virtual machine needs its own paste "
                                + "shortcut, so the text was copied — paste it inside the session."
                            flashHUD(.info("Copied — paste inside the session", symbol: "doc.on.clipboard"), for: 2.6)
                        } else {
                            await TextInserter.waitForModifierRelease()
                            // A space after the word before the cursor, and lower case when continuing a sentence —
                            // see `InsertionShaper`. `defaults write local.murmur shapeAtCursor -bool false` turns it off.
                            let shapesAtCursor = UserDefaults.standard.object(forKey: "shapeAtCursor") as? Bool ?? true
                            let inserted = shapesAtCursor && !style.skipsAllProcessing
                                ? InsertionShaper.shape(formatted, before: CursorContext.textBeforeCaret(),
                                                        lowercaseContinuation: outputIsEnglish && !snippetLeads)
                                : formatted
                            // Where it lands, so a name the user corrects by hand afterwards is learned — see `EditLearner`.
                            let editTarget = EditLearner.watchBeforePaste()
                            // Where the paste is meant to go, to check it got there.
                            let pasteTarget = EditLearner.focusedTarget()
                            // What the recognizer wrote and what is pasted, for the local record of edits.
                            let editDraft = EditRecordStore.isEnabled ? EditRecordDraft(
                                raw: raw, pasted: inserted, app: resolvedBundleID ?? "",
                                engine: AppProfileStore.engine(forBundleID: resolvedBundleID),
                                model: AppProfileStore.model(forBundleID: resolvedBundleID)) : nil
                            TextInserter.insert(inserted) { [weak self] outcome in
                                // Either way of pasting: `.unconfirmed` only means nobody saw the app read the text, and
                                // the watcher looks for the dictation in the field itself before it learns anything.
                                if outcome == .consumed || outcome == .unconfirmed, let editTarget {
                                    EditLearner.track(editTarget, inserted: inserted, draft: editDraft)
                                }
                                // A field Murmur can't read (Codex's composer): what was sent is looked up afterwards in
                                // the agent's own session file — see `SentMessageLearner`.
                                if outcome == .consumed || outcome == .unconfirmed {
                                    SentMessageLearner.expect(
                                        inserted: inserted, bundleID: resolvedBundleID, fieldWasReadable: editTarget != nil,
                                        draft: editDraft)
                                }
                                // Did it land? Focus can move mid-dictation (another app, or an agent clicking
                                // elsewhere) and the paste goes nowhere. Unless the text is seen in the box, the
                                // dictation stays on the clipboard so ⌘V gets it — said out loud when it surely
                                // missed, quietly when the box just can't be read (Codex).
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                                    guard let self else { return }
                                    let landed = pasteTarget.flatMap { EditLearner.landed(inserted, in: $0) }
                                    guard outcome == .notObserved || landed != true else { return }
                                    Self.copyToClipboardTransiently(formatted)
                                    if outcome == .notObserved || landed == false || pasteTarget == nil {
                                        dictationLog.notice("paste: not seen in a text box — left on the clipboard")
                                        self.lastError = "Your dictation didn't land in a text box, so it's on the clipboard: "
                                            + "click where it should go and press ⌘V. It's also in History."
                                        self.flashHUD(.info("Not pasted — press ⌘V to paste", symbol: "doc.on.clipboard"),
                                                      for: 3.2)
                                    }
                                }
                            }
                            flashPasted(translationNote: translationNote)
                        }
                    } else {
                        // Can't synthesize ⌘V without Accessibility — never
                        // fail silently: leave the transcript on the clipboard.
                        Self.copyToClipboardTransiently(formatted)
                        lastError = "Accessibility isn't active for this build, " +
                            "so the text was copied to your clipboard instead — " +
                            "press ⌘V to paste it. Fix this in Settings."
                        SoundEffect.play("Basso")
                        flashHUD(.info("Copied — press ⌘V to paste", symbol: "doc.on.clipboard"), for: 2.6)
                    }
                    rebuildMenu()

                    // Contextual discovery: the first time a dictation lands
                    // in an app with no App Profile, offer to set one up
                    // right there — the strongest form of discovery, since
                    // it doesn't wait for the user to find a settings page.
                    if let targetBundleID, let targetAppName, targetBundleID != Bundle.main.bundleIdentifier,
                       AppProfileStore.profile(forBundleID: targetBundleID) == nil,
                       !Settings.promptedBundleIDs.contains(targetBundleID) {
                        promptForAppProfile(bundleID: targetBundleID, appName: targetAppName)
                    }
                } else {
                    // Previously a silent no-op: nothing pasted, nothing in
                    // History, and no indication anything had gone wrong —
                    // indistinguishable from the app being broken.
                    lastError = "Nothing was transcribed — the recording came "
                        + "through empty. Check the microphone is picking you up."
                    SoundEffect.play("Basso")
                    flashHUD(.failure("Didn’t hear anything"), for: 2.4)
                }
            } catch {
                dictationLog.error("FAILED: \(error.localizedDescription, privacy: .public)")
                lastError = "Transcription failed: \(error.localizedDescription)"
                SoundEffect.play("Basso")
                flashHUD(.failure("Couldn’t transcribe that"), for: 2.4)
            }
            uiState = .idle
            dictationLog.info("idle")
        }
    }

    /// Rewrites the selection the way the user asked, and pastes it over the selection — or, when the edit can't be
    /// trusted (`SpokenCommand.rejection`), leaves the selection exactly as it was and says why. Not saved to History:
    /// nothing was dictated.
    /// What was said over a selection, carried out as an edit when it is an instruction about it. False when it's
    /// dictation after all: nothing selected, not an instruction, or no model to edit with.
    private func editSelectionIfAsked(said raw: String, selected: (selection: CursorContext.Selection, editable: Bool?),
                                      bundleID: String?, pasteTargetPID: pid_t?) async -> Bool {
        guard rewriteEngine.isAvailable || SpokenCommand.usesGemma, selected.selection != .nothing else { return false }
        // As formatted, or as heard: the formatter turns a spoken "bullet point" into a dash of its own.
        let said = TextFormatter(dictionary: [:]).format(raw)
        var command = SpokenCommand.instruction(in: said) ?? SpokenCommand.instruction(in: raw)
        // Words the patterns don't know, over text that is certainly selected: the model that will do the edit says
        // whether it is one.
        if command == nil, case .text = selected.selection {
            command = await SpokenCommand.routed(said)
            if command != nil { dictationLog.notice("spoken command: read as an instruction by the model") }
        }
        guard let command, let selection = await spokenCommandSelection(
            selected.selection, bundleID: bundleID, pasteTargetPID: pasteTargetPID) else { return false }
        await runSpokenCommand(command, on: selection, bundleID: bundleID, pasteTargetPID: pasteTargetPID,
                               editable: selected.editable)
        return true
    }

    /// For testing an edit end to end without a microphone: `defaults write local.murmur debugHooks -bool true`, then
    /// post the distributed notification "local.murmur.debug.spokenCommand" with the instruction as its object. The
    /// app in front is treated exactly as if the words had just been dictated over its selection. Off unless the
    /// default is set.
    private func startDebugHooks() {
        guard UserDefaults.standard.bool(forKey: "debugHooks") else { return }
        // "local.murmur.debug.key" with "a", "c", "v" or "n": ⌘A, ⌘C, ⌘V or ⌘N in the app in front, to set a test up and
        // read it back.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("local.murmur.debug.key"), object: nil, queue: .main
        ) { note in
            switch note.object as? String {
            case "a": TextInserter.sendKeystroke(0, flags: .maskCommand)
            case "c": TextInserter.sendKeystroke(8, flags: .maskCommand)
            case "v": TextInserter.sendKeystroke(9, flags: .maskCommand)
            case "n": TextInserter.sendKeystroke(45, flags: .maskCommand)
            default: break
            }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("local.murmur.debug.spokenCommand"), object: nil, queue: .main
        ) { [weak self] note in
            guard let said = note.object as? String else { return }
            Task { @MainActor [weak self] in
                guard let self, self.uiState == .idle else { return }
                let front = NSWorkspace.shared.frontmostApplication
                let selected = await Task.detached(priority: .userInitiated) {
                    (selection: CursorContext.selection(), editable: CursorContext.focusedIsEditable())
                }.value
                dictationLog.notice("debug hook: instruction over \(front?.bundleIdentifier ?? "nothing", privacy: .public)")
                self.uiState = .processing
                let handled = await self.editSelectionIfAsked(
                    said: said, selected: selected, bundleID: front?.bundleIdentifier, pasteTargetPID: front?.processIdentifier)
                if !handled { dictationLog.notice("debug hook: not carried out as an edit") }
                self.uiState = .idle
            }
        }
    }

    /// The text a spoken instruction is about: what the field reported when the key went down, or — where the app
    /// doesn't report its selection — what ⌘C copies now, with the clipboard handed straight back. nil when there is
    /// nothing to edit, and the words are then dictated as usual.
    private func spokenCommandSelection(_ selected: CursorContext.Selection, bundleID: String?,
                                        pasteTargetPID: pid_t?) async -> String? {
        switch selected {
        case .text(let text):
            return text
        case .nothing:
            return nil
        case .unknown:
            guard SpokenCommand.copiesUnreadSelection(bundleID: bundleID),
                  TextInserter.mayReadClipboard(.general) else { return nil }
            // The copy goes to the app in front; it has to be the one the words were spoken over.
            if let pasteTargetPID, let focused = FocusedApp.pid(), focused != pasteTargetPID { return nil }
            await TextInserter.waitForModifierRelease()
            let saved = TextInserter.saveClipboard()
            let copied = await TextInserter.copySelection()
            TextInserter.restoreClipboard(saved)
            guard let copied, copied.count <= 8_000,
                  !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                dictationLog.notice("spoken command: the app doesn't report its selection and ⌘C copied nothing — dictating")
                return nil
            }
            dictationLog.notice("spoken command: selection read with ⌘C (\(copied.count) characters)")
            return copied
        }
    }

    /// `editable`: whether the selection can be typed over (`CursorContext.focusedIsEditable`). When it can't, the edit
    /// is copied instead of pasted; when the app doesn't say, it is pasted and left on the clipboard as well — a browser
    /// takes a paste on a page that has nowhere to put it, so "it was read" doesn't mean it landed.
    private func runSpokenCommand(_ command: SpokenCommand.Command, on selection: String, bundleID: String?,
                                  pasteTargetPID: pid_t?, editable: Bool?) async {
        dictationLog.notice(
            "spoken command: \(String(describing: command.intent), privacy: .public) on \(selection.count) characters, editable: \(editable.map { $0 ? "yes" : "no" } ?? "unknown", privacy: .public)")
        transformStatus = "Editing your selection"
        defer { transformStatus = nil }
        let destination = DestinationDetector.current(for: bundleID)
        do {
            let edited = try await SpokenCommand.perform(command, on: selection, engine: rewriteEngine,
                                                         destination: destination,
                                                         bullet: SpokenCommand.bullet(forBundleID: bundleID))
            // The selection has to still be in front to be replaced.
            if let pasteTargetPID, let focused = FocusedApp.pid(), focused != pasteTargetPID {
                Self.copyToClipboardTransiently(edited)
                lastError = "A different app came to the front while Murmur was editing, so the edit was copied "
                    + "instead of pasted — press ⌘V where you want it."
                flashHUD(.info("Copied — press ⌘V to paste", symbol: "doc.on.clipboard"), for: 2.6)
                return
            }
            // Text that can be selected but not typed over — a web page, a PDF, someone else's message: the edit is
            // copied, never thrown away.
            if editable == false {
                Self.copyToClipboardTransiently(edited)
                dictationLog.notice("spoken command: read-only selection, copied \(edited.count) characters")
                flashHUD(.info("Copied — press ⌘V to paste", symbol: "doc.on.clipboard"), for: 2.6)
                return
            }
            await TextInserter.waitForModifierRelease()
            TextInserter.insert(edited, leaveOnClipboard: editable == nil) { [weak self] outcome in
                dictationLog.notice("spoken command: paste \(String(describing: outcome), privacy: .public)")
                guard outcome == .notObserved, let self else { return }
                Self.copyToClipboardTransiently(edited)
                self.lastError = "The text you selected can't be replaced where it is, so the edit was copied "
                    + "instead — press ⌘V where you want it."
                self.flashHUD(.info("Copied — press ⌘V to paste", symbol: "doc.on.clipboard"), for: 2.6)
            }
            dictationLog.notice("spoken command: pasted \(edited.count) characters (was \(selection.count))")
            flashHUD(editable == nil ? .info("Edited · copied too", symbol: "doc.on.clipboard")
                                     : .info("Selection edited", symbol: "checkmark.circle"), for: editable == nil ? 2.6 : 1.4)
        } catch let failure as TransformManager.TransformFailure {
            dictationLog.error("spoken command: \(failure.localizedDescription, privacy: .public)")
            // A long passage is where Apple's model gives up; the bigger one is a download away.
            lastError = failure.localizedDescription + (!SpokenCommand.usesGemma && selection.count > 600
                ? " Longer edits work much better with the Gemma 4 model: download it in Settings ▸ Dictation, under Translate into."
                : "")
            if failure.isNothingToDo {
                flashHUD(.info(failure.shortMessage, symbol: "checkmark.circle"), for: 2.2)
            } else {
                SoundEffect.play("Basso")
                flashHUD(.info(failure.shortMessage, symbol: "arrow.uturn.backward"), for: 2.6)
            }
        } catch {
            dictationLog.error("spoken command failed: \(error.localizedDescription, privacy: .public)")
            lastError = "Your edit couldn't be made: \(error.localizedDescription)"
            SoundEffect.play("Basso")
            flashHUD(.failure("Couldn’t edit that"), for: 2.4)
        }
    }

    /// Offers to set up an App Profile the first time dictation lands in an
    /// app that doesn't have one. `Settings.promptedBundleIDs` is written
    /// immediately, before the (async) authorization request even resolves,
    /// so this fires at most once per app, ever, no matter what the user
    /// decides. Notification permission itself is requested lazily, right
    /// before this first real use, rather than proactively at launch — most
    /// users may go a whole session without ever hitting the condition.
    private func promptForAppProfile(bundleID: String, appName: String) {
        Settings.promptedBundleIDs.insert(bundleID)
        // Logged unconditionally, ahead of the system-notification
        // permission check below — the titlebar bell is Murmur's own
        // record, not gated on whether the user allowed system banners.
        NotificationLog.add(
            title: "Format for \(appName) automatically?",
            message: "Murmur can give \(appName) its own tone and structure — set it "
                + "up once and every dictation there uses it.",
            kind: .appProfileSuggestion)
        Task {
            let center = UNUserNotificationCenter.current()
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound]))
                ?? false
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Format for \(appName) automatically?"
            content.body = "Murmur can give \(appName) its own tone and structure — "
                + "set it up once and every dictation there uses it."
            let request = UNNotificationRequest(
                identifier: "app-profile-suggestion-\(bundleID)",
                content: content, trigger: nil)
            try? await center.add(request)
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Murmur has no Dock icon and its window is usually hidden behind
    /// whatever app you dictated into, but on the rare occasion it *is*
    /// frontmost, the discovery notification should still show as a banner
    /// rather than being silently suppressed as "app is already active".
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor [weak self] in
            self?.showMainWindow()
            self?.pendingNavigateToPage = .appProfiles
        }
        completionHandler()
    }

    // MARK: - Status item / menu

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateIcon()
        rebuildMenu()
    }

    private func updateIcon() {
        let symbol: String
        switch uiState {
        case .idle: symbol = "mic"
        case .recording: symbol = isHandsFree ? "mic.badge.plus" : "mic.fill"
        case .processing: symbol = "hourglass"
        }
        statusItem.button?.image = NSImage(
            systemSymbolName: symbol, accessibilityDescription: "Murmur")
    }

    /// "Translate into ▸" — Off, then every language but the one you speak, the one in use ticked.
    private func translateIntoMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Translate into", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let spoken = TranslateInto.code(forLocale: localeID)
        let off = NSMenuItem(title: "Off", action: #selector(pickTranslateInto(_:)), keyEquivalent: "")
        off.target = self
        off.state = translateInto == nil ? .on : .off
        submenu.addItem(off)
        submenu.addItem(.separator())
        for code in TranslateInto.languages where code != spoken {
            let language = NSMenuItem(title: TranslateInto.name(code), action: #selector(pickTranslateInto(_:)),
                                      keyEquivalent: "")
            language.target = self
            language.representedObject = code
            language.state = translateInto == code ? .on : .off
            submenu.addItem(language)
        }
        item.submenu = submenu
        return item
    }

    @objc private func pickTranslateInto(_ sender: NSMenuItem) {
        setTranslateInto(sender.representedObject as? String)
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let openItem = NSMenuItem(
            title: "Open Murmur…", action: #selector(openMainWindow),
            keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(.separator())

        let hint = NSMenuItem(
            title: "Hold \(hotkeyMonitor.hotkey.displayName) to dictate",
            action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        if let notice = secureInputNotice {
            let warning = NSMenuItem(title: "\u{26A0}\u{FE0E} " + notice, action: nil, keyEquivalent: "")
            warning.isEnabled = false
            menu.addItem(warning)
        }
        menu.addItem(translateIntoMenuItem())
        menu.addItem(.separator())

        if history.entries.isEmpty {
            let empty = NSMenuItem(title: "No transcripts yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            let header = NSMenuItem(title: "Recent (click to copy)", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for (index, entry) in history.entries.prefix(8).enumerated() {
                let preview = entry.text.count > 60
                    ? String(entry.text.prefix(57)) + "…" : entry.text
                let item = NSMenuItem(
                    title: preview.replacingOccurrences(of: "\n", with: " "),
                    action: #selector(copyHistoryItem(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: "Quit Murmur", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    // MARK: - Menu actions

    @objc private func openMainWindow() {
        showMainWindow()
    }

    @objc private func copyHistoryItem(_ sender: NSMenuItem) {
        guard sender.tag < history.entries.count else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(history.entries[sender.tag].text, forType: .string)
    }
}

/// The app's theme: follow macOS, or pin light/dark regardless of it.
enum AppearanceSetting: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// `nil` means "don't override" — the app then tracks the system
    /// setting, including automatic light/dark switching.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

enum Settings {
    private static let defaults = UserDefaults.standard

    /// One-time import of preferences saved under the app's pre-rename
    /// bundle id (local.whisperflow). Call before anything reads Settings.
    static func migrateLegacyDefaults() {
        guard defaults.object(forKey: "hotkey") == nil,
              defaults.object(forKey: "locale") == nil,
              let legacy = UserDefaults(suiteName: "local.whisperflow")
        else { return }
        for key in ["hotkey", "locale", "styleDefault", "styleOverrides"] {
            if defaults.object(forKey: key) == nil,
               let value = legacy.object(forKey: key) {
                defaults.set(value, forKey: key)
            }
        }
    }

    /// Gates first-run setup — `OnboardingRoot` vs the normal main window.
    static var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: "hasCompletedOnboarding") }
        set { defaults.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    static var hotkey: HotkeyMonitor.Hotkey {
        get {
            HotkeyMonitor.Hotkey(
                rawValue: defaults.string(forKey: "hotkey") ?? "") ?? .fn
        }
        set { defaults.set(newValue.rawValue, forKey: "hotkey") }
    }

    static var localeIdentifier: String {
        get { defaults.string(forKey: "locale") ?? "en-US" }
        set { defaults.set(newValue, forKey: "locale") }
    }

    /// The last non-English locale the user deliberately selected — kept
    /// separately from `localeIdentifier` so `reconcileLocaleWithEngine`
    /// can restore it after a temporary English fallback (forced by
    /// switching to an English-only engine/model) instead of leaving the
    /// user stuck on English once the original engine/model is reselected.
    static var lastNonEnglishLocaleIdentifier: String? {
        get { defaults.string(forKey: "lastNonEnglishLocale") }
        set { defaults.set(newValue, forKey: "lastNonEnglishLocale") }
    }

    /// Recognition engine: "apple" (instant), "whisper" or "whispercpp"
    /// (precise, Whisper-family), "parakeet" (precise, fast), or "sherpa"
    /// (sherpa-onnx/SenseVoice, CPU-only, no Neural Engine acceleration).
    static var engine: String {
        get { defaults.string(forKey: "engine") ?? "apple" }
        set { defaults.set(newValue, forKey: "engine") }
    }

    static var whisperModel: String {
        get { defaults.string(forKey: "whisperModel") ?? "small" }
        set { defaults.set(newValue, forKey: "whisperModel") }
    }

    /// Separate from `whisperModel`: WhisperKit and whisper.cpp have
    /// different, only-partially-overlapping model ID namespaces (WhisperKit
    /// has "distil-whisper_distil-large-v3_turbo", whisper.cpp doesn't; vice
    /// versa for "tiny"). Sharing one setting would carry over an invalid ID
    /// whenever the user switched between the two Whisper engines.
    static var whisperCppModel: String {
        get { defaults.string(forKey: "whisperCppModel") ?? "small" }
        set { defaults.set(newValue, forKey: "whisperCppModel") }
    }

    static var parakeetModel: String {
        get { defaults.string(forKey: "parakeetModel") ?? "v3" }
        set { defaults.set(newValue, forKey: "parakeetModel") }
    }

    /// Only one sherpa-onnx model is offered today (`SherpaOnnxEngine
    /// .availableModels`) — stored the same way as the other three engines'
    /// model settings anyway, so a second option can be added later without
    /// a migration.
    static var sherpaModel: String {
        get { defaults.string(forKey: "sherpaModel") ?? "sense-voice-small" }
        set { defaults.set(newValue, forKey: "sherpaModel") }
    }

    /// Which CTC model `ParakeetEngine` loads for vocabulary-boosting
    /// rescoring — independent of `parakeetModel` (v2/v3), which is the
    /// main transcription model. Defaults to `"ctc06b"`, the larger/more
    /// conservative of the two options FluidAudio ships, preserving
    /// existing behavior for anyone who never touches this setting.
    /// `"ctc110m"` is smaller and faster — a comparable open-source
    /// dictation app (FluidVoice) uses it for exactly this purpose — kept
    /// as an alongside option, not a replacement, since it hasn't been
    /// tested here as thoroughly against the same false-positive
    /// collisions `ctc06b`'s thresholds were tuned against.
    static var parakeetCtcVariant: String {
        get { defaults.string(forKey: "parakeetCtcVariant") ?? "ctc06b" }
        set { defaults.set(newValue, forKey: "parakeetCtcVariant") }
    }

    /// Auto-stop a hands-free recording on a detected pause, instead of
    /// requiring a second hotkey press. Defaults on; the underlying
    /// streaming VAD is FluidAudio's own "beta" feature, so this stays a
    /// real, visible toggle rather than invisible infrastructure — manual
    /// double-tap-to-stop keeps working regardless of this setting.
    static var handsFreeAutoStop: Bool {
        get { defaults.object(forKey: "handsFreeAutoStop") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "handsFreeAutoStop") }
    }

    /// Whether a finished dictation is auto-pasted at the cursor (the
    /// existing, only behavior until now) or just left on the clipboard for
    /// the user to paste themselves. A per-app `AppProfile.autoPaste`
    /// overrides this for one app; this is the fallback for everywhere else.
    /// Settings → Dictation → "Play sounds": the sounds when a dictation starts and stops, and when something can't
    /// be done (`SoundEffect`). On unless turned off.
    static var playSounds: Bool {
        get { defaults.object(forKey: "playSounds") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "playSounds") }
    }

    static var autoPasteEnabled: Bool {
        get { defaults.object(forKey: "autoPasteEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoPasteEnabled") }
    }

    /// The version the user chose "Skip This Version" for, if any — that
    /// specific release won't show the update sheet again, but a later
    /// one still will.
    static var skippedUpdateVersion: String? {
        get { defaults.string(forKey: "skippedUpdateVersion") }
        set { defaults.set(newValue, forKey: "skippedUpdateVersion") }
    }

    /// Say a template's trigger phrase ("meeting notes", "email draft", …)
    /// at the start of a dictation to reshape it automatically — no clicks.
    static var voiceTemplatesEnabled: Bool {
        get { defaults.object(forKey: "voiceTemplatesEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "voiceTemplatesEnabled") }
    }

    /// The nav rail's pinned/expanded state. Defaults to fully open on
    /// first launch — an icon-only rail with hidden groups is a reasonable
    /// compact mode for someone who already knows their way around, but a
    /// poor first impression that hides App Profiles (and everything else)
    /// behind an undiscovered toggle. Once the user sets their own
    /// preference it's respected on every later launch, not fought.
    static var railPinned: Bool {
        get { defaults.object(forKey: "railPinned") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "railPinned") }
    }

    /// Personalize (Dictionary, Voice Profile, Style, App Profiles) starts
    /// expanded — it's where the app's most differentiating, least
    /// discoverable feature lives.
    static var personaliseExpanded: Bool {
        get { defaults.object(forKey: "personaliseExpanded") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "personaliseExpanded") }
    }

    /// Tools (Snippets, Templates, Transforms) starts collapsed — more
    /// advanced, no need to front-load everything at once.
    static var toolsExpanded: Bool {
        get { defaults.object(forKey: "toolsExpanded") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "toolsExpanded") }
    }

    /// Bundle IDs already offered an App Profile via the contextual
    /// discovery notification — written once per ID so it fires at most
    /// once per app, ever, not every time you dictate into it again.
    static var promptedBundleIDs: Set<String> {
        get {
            guard let stored = defaults.string(forKey: "promptedBundleIDs"), !stored.isEmpty
            else { return [] }
            return Set(stored.split(separator: ",").map(String.init))
        }
        set {
            defaults.set(newValue.sorted().joined(separator: ","), forKey: "promptedBundleIDs")
        }
    }

    /// Feed the generated Voice Profile to rewrites and Ask, so output keeps
    /// the user's own phrasing. Opt-out because it changes every rewrite.
    static var useVoiceProfile: Bool {
        get { defaults.object(forKey: "useVoiceProfile") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "useVoiceProfile") }
    }

    /// Off by default, unlike every other meeting-detection signal —
    /// turning this on means `MeetingDetector` periodically reads the
    /// frontmost browser's own active-tab URL (via Apple Events) to check
    /// it against known meeting-link patterns, which is a meaningfully
    /// different privacy footprint from just checking a native app's
    /// bundle ID, so it needs an explicit opt-in rather than being on from
    /// first launch.
    static var browserMeetingDetectionEnabled: Bool {
        get { defaults.object(forKey: "browserMeetingDetectionEnabled") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "browserMeetingDetectionEnabled") }
    }

    /// The floating Scratchpad panel's own global hotkey — user-rebindable
    /// via `ScratchpadHotkeyEditor`, unlike Transforms' fixed ⌥1/⌥2 or the
    /// profile slots' fixed ⌃⇧1…9. Defaults to `ScratchpadHotkeyMonitor`'s
    /// own ⌃⇧Space.
    static var scratchpadHotkeyKeyCode: UInt16 {
        get {
            guard let stored = defaults.object(forKey: "scratchpadHotkeyKeyCode") as? Int else {
                return ScratchpadHotkeyMonitor.defaultKeyCode
            }
            return UInt16(stored)
        }
        set { defaults.set(Int(newValue), forKey: "scratchpadHotkeyKeyCode") }
    }
    static var scratchpadHotkeyModifiers: NSEvent.ModifierFlags {
        get {
            guard let stored = defaults.object(forKey: "scratchpadHotkeyModifiers") as? UInt else {
                return ScratchpadHotkeyMonitor.defaultModifiers
            }
            return NSEvent.ModifierFlags(rawValue: stored)
        }
        set { defaults.set(newValue.rawValue, forKey: "scratchpadHotkeyModifiers") }
    }

    /// Notetaker's own global hotkey — same rebindable mechanism as
    /// Scratchpad's, via `NotetakerHotkeyMonitor`/`NotetakerHotkeyEditor`.
    static var notetakerHotkeyKeyCode: UInt16 {
        get {
            guard let stored = defaults.object(forKey: "notetakerHotkeyKeyCode") as? Int else {
                return NotetakerHotkeyMonitor.defaultKeyCode
            }
            return UInt16(stored)
        }
        set { defaults.set(Int(newValue), forKey: "notetakerHotkeyKeyCode") }
    }
    static var notetakerHotkeyModifiers: NSEvent.ModifierFlags {
        get {
            guard let stored = defaults.object(forKey: "notetakerHotkeyModifiers") as? UInt else {
                return NotetakerHotkeyMonitor.defaultModifiers
            }
            return NSEvent.ModifierFlags(rawValue: stored)
        }
        set { defaults.set(newValue.rawValue, forKey: "notetakerHotkeyModifiers") }
    }

    /// Gates whether `NotetakerController` runs its two `LivePreviewTranscriber`
    /// instances at all during a capture — on by default (it's the reassurance
    /// feature it was built to be), off for anyone who finds a live caption
    /// distracting rather than helpful.
    static var notetakerLiveTranscriptEnabled: Bool {
        get { defaults.object(forKey: "notetakerLiveTranscriptEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "notetakerLiveTranscriptEnabled") }
    }

    /// Excludes the main window from screen recording/sharing for as long
    /// as Notetaker is capturing or processing — off by default since it's
    /// a real behavior change (anything you screen-share won't show Murmur
    /// at all while this is on, not just the Notetaker page).
    static var notetakerHideFromScreenCapture: Bool {
        get { defaults.object(forKey: "notetakerHideFromScreenCapture") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "notetakerHideFromScreenCapture") }
    }

    /// Auto-stops a capture once the app it started with has fully quit —
    /// checked against the *running* apps list, not the frontmost one, so
    /// tabbing away to check email mid-call doesn't stop a still-live
    /// meeting. On by default: a capture nobody remembered to stop is more
    /// likely a forgotten one than an intentional long one.
    static var notetakerAutoStopOnCallEnd: Bool {
        get { defaults.object(forKey: "notetakerAutoStopOnCallEnd") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "notetakerAutoStopOnCallEnd") }
    }

    /// Minutes before a capture stops itself automatically; `0` means no
    /// limit. Defaults to 120 — long enough for nearly any real meeting,
    /// short enough that an accidentally-left-running capture doesn't fill
    /// the disk with hours of silence.
    static var notetakerMaxRecordingMinutes: Int {
        get { defaults.object(forKey: "notetakerMaxRecordingMinutes") as? Int ?? 120 }
        set { defaults.set(newValue, forKey: "notetakerMaxRecordingMinutes") }
    }

    /// Light / Dark / follow the system. Stored as a raw string so an
    /// unknown value degrades to `.system` rather than crashing.
    static var appearance: AppearanceSetting {
        get { AppearanceSetting(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system }
        set { defaults.set(newValue.rawValue, forKey: "appearance") }
    }

    static var locale: Locale {
        Locale(identifier: localeIdentifier)
    }
}
