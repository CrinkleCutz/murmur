import AppKit
import AVFoundation
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
    @Published var uiState: UIState = .idle { didSet { updateIcon(); updateHUD() } }
    @Published var isHandsFree = false { didSet { updateHUD() } }
    @Published var entries: [HistoryEntry] = []
    @Published var micAuthorized = false
    @Published var axTrusted = false
    @Published var hotkey: HotkeyMonitor.Hotkey = Settings.hotkey
    @Published var localeID: String = Settings.locale.identifier
    @Published var lastError: String?

    /// Height of the custom titlebar strip drawn in SwiftUI; the traffic
    /// lights are aligned to its vertical center.
    static let titlebarHeight: CGFloat = 44
    /// AppKit's own y for the traffic lights, captured before any change.
    private var trafficLightBaselineY: CGFloat?

    private var statusItem: NSStatusItem!
    private var window: NSWindow?
    private var onboardingWindow: NSWindow?
    private let navBarHUD = NavBarHUDController()
    private let recorder = AudioRecorder()
    private let history = HistoryStore()
    let pipelineStats = PipelineStatsStore()
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
    private func updateHUD() {
        let state: HUDState
        switch uiState {
        case .recording:
            state = .recording(handsFree: isHandsFree)
        case .processing:
            state = .processing(transformStatus ?? "Transcribing")
        case .idle:
            // A transform (⌥1/⌥2) runs with no recording in flight, so idle
            // plus a status line still means work is happening.
            state = transformStatus.map { .processing($0) } ?? .hidden
        }
        // Deferred, never inline. These observers fire during a @Published
        // change — i.e. in the middle of SwiftUI's own update pass — and
        // building an NSHostingView/NSPanel there would start a nested
        // SwiftUI update on the same actor. Hopping to the next main-actor
        // turn keeps all window work out of that cycle.
        Task { @MainActor [statusHUD, navBarHUD, weak self] in
            statusHUD.update(state)
            // The nav bar only exists while the status HUD doesn't — same
            // `state == .hidden` check that decides the pill, not a raw
            // idle read, so a transform running with no recording in
            // flight (⌥1/⌥2) correctly hides the nav bar too.
            if let self { navBarHUD.setActive(state == .hidden, app: self) }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        FontLoader.registerManrope()
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
            self?.transformStatus = status
        }
        transformManager.onError = { [weak self] message in
            self?.lastError = message
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
        refreshVoiceProfileIfDue()
        checkForUpdates()

        // Same engine-selection/fallback path every normal dictation
        // already goes through — a meeting clip isn't a second,
        // differently-behaved transcription pipeline.
        notetaker.transcribeFile = { [weak self] url in
            try await self?.recognize(fileAt: url, bundleID: nil) ?? ""
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
    }

    /// Checks GitHub's own Releases API for this repo — no appcast, no
    /// Sparkle. Silent on any failure (offline, rate-limited): a missed
    /// check just means no sheet this launch, never an error surfaced to
    /// the user. Skips a release the user already dismissed via "Skip
    /// This Version", but a newer one past that still shows.
    private func checkForUpdates() {
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
        let totalWords = entries.reduce(0) { $0 + $1.wordCount }
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

    func showOnboarding() {
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
        onboarding.setContentSize(NSSize(width: 600, height: 780))
        onboarding.isReleasedWhenClosed = false
        onboarding.center()
        onboardingWindow = onboarding
        NSApp.activate(ignoringOtherApps: true)
        onboarding.makeKeyAndOrderFront(nil)
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
        guard let window else { return }
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
        guard let reference = buttons.first else { return }

        // Capture AppKit's unmodified layout the first time only.
        if trafficLightBaselineY == nil {
            trafficLightBaselineY = reference.frame.origin.y
        }
        guard let baseline = trafficLightBaselineY else { return }

        // Titlebar content centers at 22pt; AppKit centers buttons at 16pt.
        // NSView is bottom-up, so subtracting moves them down.
        let target = baseline - (Self.titlebarHeight / 2 - 16)
        for button in buttons where abs(button.frame.origin.y - target) > 0.5 {
            button.frame.origin.y = target
        }
    }

    // AppKit re-lays out the titlebar on these, undoing the alignment.
    func windowDidResize(_ notification: Notification) { alignTrafficLights() }
    func windowDidExitFullScreen(_ notification: Notification) { alignTrafficLights() }
    func windowDidBecomeKey(_ notification: Notification) { alignTrafficLights() }

    // MARK: - Permissions

    func refreshPermissions(promptAccessibility: Bool = false) {
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
        let learnedCount = LearnedStore.learn(original: entry.text, corrected: newText)
        history.update(id: id, text: newText)
        entries = history.entries
        rebuildMenu()
        return learnedCount
    }

    /// Raw transcription without biasing or cleanup — used by Voice Training
    /// to see what the model naturally hears.
    func transcribeRaw(fileAt url: URL) async throws -> String {
        try await transcriber.transcribe(fileAt: url)
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
    private func recognize(fileAt url: URL, bundleID: String?) async throws -> String {
        let developerVocabulary = AppProfileStore.developerVocabularyEnabled(forBundleID: bundleID)
        let biasTerms = LearnedStore.biasTerms(includeDeveloperVocabulary: developerVocabulary)
        let effectiveEngine = AppProfileStore.engine(forBundleID: bundleID)
        let effectiveModel = AppProfileStore.model(forBundleID: bundleID)
        let effectiveLocale = AppProfileStore.localeIdentifier(forBundleID: bundleID)
        dictationLog.info(
            "recognize: engine=\(effectiveEngine, privacy: .public) model=\(effectiveModel, privacy: .public) locale=\(effectiveLocale, privacy: .public) developerVocabulary=\(developerVocabulary) parakeetReady=\(self.parakeetEngine.isReady(model: Settings.parakeetModel)) whisperReady=\(self.whisperEngine.isReady(model: Settings.whisperModel)) whisperCppReady=\(self.whisperCppEngine.isReady(model: Settings.whisperCppModel)) sherpaReady=\(self.sherpaEngine.isReady(model: Settings.sherpaModel))")
        if effectiveEngine == "whisper" {
            if whisperEngine.isReady(model: effectiveModel) {
                do {
                    return try await whisperEngine.transcribe(
                        fileAt: url, model: effectiveModel,
                        localeID: effectiveLocale, biasTerms: biasTerms)
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
            if whisperCppEngine.isReady(model: effectiveModel) {
                do {
                    return try await whisperCppEngine.transcribe(
                        fileAt: url, model: effectiveModel,
                        localeID: effectiveLocale, biasTerms: biasTerms)
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
                    return try await parakeetEngine.transcribe(
                        fileAt: url, model: effectiveModel,
                        localeID: effectiveLocale, biasTerms: biasTerms,
                        boostVocabulary: developerVocabulary)
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
                    return try await sherpaEngine.transcribe(
                        fileAt: url, model: effectiveModel,
                        localeID: effectiveLocale, biasTerms: biasTerms)
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
                self?.recorder.cancel()
                self?.uiState = .idle
                self?.activeProfileHotkeySlot = nil
            }
        }
        hotkeyMonitor.onHandsFreeChange = { [weak self] active in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isHandsFree = active
                self.updateIcon()
                if active {
                    NSSound(named: "Pop")?.play()
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
    /// Which profile-hotkey slot (if any) started the current recording, so
    /// a *different* slot pressed mid-recording is a no-op instead of
    /// stopping a dictation some other slot started.
    private var activeProfileHotkeySlot: ProfileHotkeySlot?

    private func startRecording(forcedBundleID: String? = nil) {
        guard uiState != .recording else { return }
        do {
            try recorder.start()
            recordingStartedAt = Date()
            let frontmost = NSWorkspace.shared.frontmostApplication
            recordingTargetBundleID = frontmost?.bundleIdentifier
            recordingTargetAppName = frontmost?.localizedName
            statusHUD.setTargetAppIcon(frontmost?.icon)
            recordingForcedBundleID = forcedBundleID
            uiState = .recording
            lastError = nil
            NSSound(named: "Pop")?.play()
        } catch {
            lastError = "Could not start recording: \(error.localizedDescription)"
            NSSound(named: "Basso")?.play()
        }
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

    private func stopAndTranscribe() {
        isHandsFree = false
        guard let url = recorder.stop() else {
            uiState = .idle
            return
        }
        NSSound(named: "Tink")?.play()
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
            lastError = "No audio was captured — the microphone delivered "
                + "nothing. If you're on Bluetooth headphones, try switching "
                + "input to the built-in microphone."
            NSSound(named: "Basso")?.play()
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
            uiState = .idle
            try? FileManager.default.removeItem(at: url)
            return
        }

        Task { [history, rewriteEngine, pipelineStats] in
            defer { try? FileManager.default.removeItem(at: url) }
            // A second, sharper opinion on top of the RMS-based `hasSignal`
            // gate just above — catches what raw amplitude can't, like a
            // loud non-speech sound clearing the floor. Independent of
            // whichever recognition engine is selected below.
            if await vadEngine.hasNoDetectedSpeech(fileAt: url) {
                dictationLog.info("recognize: VAD found no speech, skipping recognition")
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
                let raw = try await recognize(fileAt: url, bundleID: resolvedBundleID)
                dictationLog.info("recognize: done, \(raw.count) chars")
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
                    uiState = .idle
                    return
                }

                let style = AppProfileStore.style(forBundleID: resolvedBundleID)
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
                dictationLog.info(
                    "locale gate: Settings.localeIdentifier=\(Settings.localeIdentifier, privacy: .public) engine=\(Settings.engine, privacy: .public) parakeetModel=\(Settings.parakeetModel, privacy: .public) isEnglishDictation=\(isEnglishDictation)")

                // Tallied for Insights' "Fixes made by Murmur" card only —
                // each count comes from a plain before/after read of
                // `formatted` around a call already made below, never from
                // changing what that call does or re-deriving its result.
                var harperFixCount = 0
                var dictionaryFixCount = 0
                var snippetExpansionCount = 0

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
                    }
                    snippetExpansionCount += PipelineDiff.snippetMatchCount(
                        in: formatted, snippets: SnippetStore.load())
                    formatted = SnippetStore.expand(in: formatted)
                } else {
                    formatted = TextFormatter(
                        dictionary: isEnglishDictation ? TextFormatter.loadDictionary() : [:]
                    ).format(raw)
                    if isEnglishDictation {
                        let beforeDictionary = formatted
                        formatted = LearnedStore.apply(
                            in: formatted, includeDeveloperVocabulary: developerVocabulary)
                        dictionaryFixCount += PipelineDiff.wordChangeCount(
                            from: beforeDictionary, to: formatted)
                    }
                    snippetExpansionCount += PipelineDiff.snippetMatchCount(
                        in: formatted, snippets: SnippetStore.load())
                    formatted = SnippetStore.expand(in: formatted)

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
                    if !formatted.isEmpty, rewriteEngine.isAvailable, isEnglishDictation {
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

                        // Structure and tone go in together. Running them as
                        // separate passes meant a template silently threw the
                        // app's style away; composing them keeps both for the
                        // price of one round-trip.
                        if let instructions = RewritePlan.instructions(
                            template: template, style: style,
                            cleanupLevel: StyleSettings.defaultCleanupLevel,
                            voice: Settings.useVoiceProfile ? voiceProfile : nil),
                           !body.isEmpty {
                            // "Applying As spoken style…" read oddly once
                            // this became the always-on default cleanup pass
                            // rather than something the user explicitly set.
                            transformStatus = template.map { "Formatting as \($0.name)" }
                                ?? (style == .none
                                    ? "Cleaning up"
                                    : "Applying \(style.displayName) style")
                            if let rewritten = try? await rewriteEngine.edit(
                                body, instructions: instructions), !rewritten.isEmpty {
                                // The rewrite prompt is hardened against this, but
                                // model output isn't deterministic — a real incident
                                // produced a fabricated paragraph from a 3-word
                                // dictation ("In this section." → 300+ characters
                                // describing "the author"'s writing style, lifted
                                // from the Voice Profile context). Templates
                                // legitimately restructure and can grow the text by
                                // design, so this only guards the no-template case,
                                // where a cleanup/style pass has no reason to
                                // multiply the input's length.
                                let plausibleLimit = max(body.count * 3, body.count + 80)
                                if template != nil || rewritten.count <= plausibleLimit {
                                    formatted = rewritten
                                } else {
                                    dictationLog.error(
                                        "rewrite rejected: \(body.count) chars in, \(rewritten.count) chars out — keeping unrewritten text")
                                }
                            }
                            transformStatus = nil
                        }
                    }

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
                    if !formatted.isEmpty, isEnglishDictation {
                        let beforeHarper = formatted
                        formatted = HarperChecker.fix(
                            formatted,
                            vocabulary: LearnedStore.biasTerms(
                                includeDeveloperVocabulary: developerVocabulary))
                        harperFixCount += PipelineDiff.wordChangeCount(from: beforeHarper, to: formatted)
                    }
                }
                dictationLog.info("pipeline done: \(formatted.count) chars")
                if !formatted.isEmpty {
                    history.add(formatted, duration: duration, targetBundleID: resolvedBundleID)
                    pipelineStats.record(
                        harperFixes: harperFixCount, dictionaryFixes: dictionaryFixCount,
                        snippetExpansions: snippetExpansionCount)
                    entries = history.entries
                    dictationLog.info("history: added, inserting text")
                    refreshVoiceProfileIfDue()
                    if !AppProfileStore.autoPasteEnabled(forBundleID: resolvedBundleID) {
                        // A deliberate choice, not a failure — no error, no
                        // sound, just leave it where the user asked for it.
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(formatted, forType: .string)
                        dictationLog.info("auto-paste disabled for this app — left on clipboard")
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
                        TextInserter.insert(formatted)
                    } else {
                        // Can't synthesize ⌘V without Accessibility — never
                        // fail silently: leave the transcript on the clipboard.
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(formatted, forType: .string)
                        lastError = "Accessibility isn't active for this build, " +
                            "so the text was copied to your clipboard instead — " +
                            "press ⌘V to paste it. Fix this in Settings."
                        NSSound(named: "Basso")?.play()
                    }
                    rebuildMenu()

                    // Contextual discovery: the first time a dictation lands
                    // in an app with no App Profile, offer to set one up
                    // right there — the strongest form of discovery, since
                    // it doesn't wait for the user to find a settings page.
                    if let targetBundleID, let targetAppName,
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
                    NSSound(named: "Basso")?.play()
                }
            } catch {
                dictationLog.error("FAILED: \(error.localizedDescription, privacy: .public)")
                lastError = "Transcription failed: \(error.localizedDescription)"
                NSSound(named: "Basso")?.play()
            }
            uiState = .idle
            dictationLog.info("idle")
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
