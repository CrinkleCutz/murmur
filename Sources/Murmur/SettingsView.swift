import AppKit
import ServiceManagement
import Speech
import SwiftUI
import Translation

// MARK: - Settings
//
// Tabs, the same as Insights': General (the app, and the permissions it needs), Dictation, Notetaker, and License
// in an official build. Every setting in a tab shows at once — small section labels over white cards, each row a
// name, a plain line on what it does, and its control — instead of the old closed accordion tiles, where finding a
// setting meant guessing which tile to open. A sunset dot marks a tab where something needs you, and the page opens
// there. Everything is still wired to the exact same `AppDelegate` state.
//
// The rows are built from the shared pieces in SettingsComponents.swift, so every tab — including the License tab
// an official release build adds — is made of the same parts.

struct SettingsPage: View {
    @ObservedObject var app: AppDelegate
    // Separate `@ObservedObject`s for these two, rather than reading
    // `app.notetaker.screenRecordingAuthorized`/`app.notetaker.detector
    // .calendarAuthorized` straight through `app` — neither is `@Published`
    // *on* `AppDelegate` itself, so a plain `@ObservedObject var app` alone
    // doesn't resubscribe when either changes; this page's Calendar/Screen
    // Recording rows would just go stale until some unrelated part of the
    // page happened to re-render for a different reason.
    @ObservedObject private var notetaker: NotetakerController
    @ObservedObject private var meetingDetector: MeetingDetector
    // The License tab's two sources — neither publishes through `app`.
    @ObservedObject private var license = LicenseStore.shared
    @ObservedObject private var updater = SparkleUpdater.shared
    /// A build from source: the real License tab on a pretend server, to see and try it (`LicensePreview`).
    @ObservedObject private var preview = LicensePreview.shared
    @AppStorage(LicensePreview.defaultsKey) private var showLicensePreview = false
    /// The last tab you looked at, so Settings reopens where you left it.
    @AppStorage("settingsTab") private var storedTab = SettingsTab.general.rawValue
    /// `NotchHUDController.isEnabled`'s switch.
    @AppStorage("notchHUD") private var notchHUD = true
    /// Translate into's downloads and what macOS's translator can do.
    @ObservedObject private var translationModels = TranslationModels.shared
    /// "NEW" on Translate into until it's first switched on.
    @AppStorage("translateIntoTried") private var translateIntoTried = false
    /// The worked example's translation, for the pair and translator it was made with.
    @State private var translationExample: (key: String, text: String?)?
    /// Set to have macOS download a language for its translator (it asks first).
    @State private var appleLanguageDownload: TranslationSession.Configuration?

    @State private var supportedLocaleIDs: [String] = []
    @State private var handsFreeAutoStop = Settings.handsFreeAutoStop
    @State private var autoPasteEnabled = Settings.autoPasteEnabled
    @State private var playSounds = Settings.playSounds
    /// Learning ▸ the three switches (`EditLearner`, `EditRecordStore`, `PasteLastShortcut`) and the record's size.
    @AppStorage("learnFromEdits") private var learnFromEdits = true
    @AppStorage("keepEditRecords") private var keepEditRecords = false
    @AppStorage("pasteLastShortcut") private var pasteLastShortcut = true
    @AppStorage("duckOtherAudio") private var duckOtherAudio = true
    @AppStorage("useBluetoothMicrophone") private var useBluetoothMicrophone = false
    @State private var editRecordCount = 0
    /// The Mac's input is a Bluetooth device, which Murmur prefers not to record from.
    @State private var inputIsBluetooth = false
    /// Which `AccentFieldSelect` (by its `id`) has its panel open, if any.
    /// Lifted up to the whole page rather than owned by each dropdown —
    /// see the panel-rendering `.overlayPreferenceValue` below for why.
    @State private var openDropdown: String?

    @State private var notetakerLiveTranscriptEnabled = Settings.notetakerLiveTranscriptEnabled
    @State private var notetakerHideFromScreenCapture = Settings.notetakerHideFromScreenCapture
    @State private var notetakerAutoStopOnCallEnd = Settings.notetakerAutoStopOnCallEnd
    @State private var notetakerMaxRecordingMinutes = Settings.notetakerMaxRecordingMinutes
    @State private var browserMeetingDetectionEnabled = Settings.browserMeetingDetectionEnabled
    @State private var notetakerHotkeyKeyCode = Settings.notetakerHotkeyKeyCode
    @State private var notetakerHotkeyModifiers = Settings.notetakerHotkeyModifiers
    @State private var showingNotetakerHotkeyEditor = false

    init(app: AppDelegate) {
        self.app = app
        _notetaker = ObservedObject(wrappedValue: app.notetaker)
        _meetingDetector = ObservedObject(wrappedValue: app.notetaker.detector)
    }

    var body: some View {
        GlassPanelPage {
            // `ThinScrollView`, not a plain `ScrollView` — see
            // ScratchpadView.swift's own note on why: a bare
            // `.scrollIndicators(.hidden)` doesn't reliably suppress
            // macOS's native scroller by itself.
            ThinScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsPageHeader(subtitle: Self.subtitle)
                    UnderlineTabBar(tabs: tabs, selected: currentTab, attention: attentionTabs,
                                    title: \.title, select: { storedTab = $0.rawValue })
                        .padding(.top, 20)
                    Group {
                        switch currentTab {
                        case .general: generalTab
                        case .dictation: dictationTab
                        case .notetaker: notetakerTab
                        case .license: licenseTab
                        }
                    }
                    .padding(.top, 24)
                }
                // Attached to the whole page, not to any individual row or
                // trigger: an `.overlay` only ever paints above its *own*
                // host view, and a later sibling declared outside that host
                // still draws on top of it — which is exactly the bug where
                // the Parakeet-model row's own white trigger rendered over
                // the still-open Recognition-engine panel behind it.
                // Anchoring here means the open panel always has every row
                // on the page as an earlier sibling, so it wins regardless
                // of which trigger opened it.
                .overlayPreferenceValue(DropdownAnchorKey.self) { anchors in
                    if let openDropdown, let anchor = anchors[openDropdown] {
                        DropdownPanel(
                            openDropdown: openDropdown,
                            anchor: anchor,
                            options: dropdownOptions(for: openDropdown),
                            label: dropdownLabel(for: openDropdown),
                            selection: dropdownSelection(for: openDropdown),
                            close: { self.openDropdown = nil })
                    }
                }
            }
        }
        .onAppear(perform: loadLocales)
        .onAppear(perform: openTabIfAsked)
        .onChange(of: app.openLicenseTile) { _, _ in openTabIfAsked() }
        .onChange(of: storedTab) { _, _ in openDropdown = nil }
        .sheet(isPresented: $showingNotetakerHotkeyEditor, onDismiss: {
            notetakerHotkeyKeyCode = Settings.notetakerHotkeyKeyCode
            notetakerHotkeyModifiers = Settings.notetakerHotkeyModifiers
        }) { NotetakerHotkeyEditor() }
    }

    static var subtitle: String {
        Notetaker.isAvailable
            ? "How Murmur listens and pastes, how Notetaker records calls, and what Murmur needs from your Mac."
            : "How Murmur listens and pastes, and what Murmur needs from your Mac."
    }

    // MARK: Tabs

    private var showsLicenseTab: Bool { license.channel == .release || showLicensePreview }

    private var tabs: [SettingsTab] {
        SettingsTab.allCases.filter {
            ($0 != .license || showsLicenseTab) && ($0 != .notetaker || Notetaker.isAvailable)
        }
    }

    private var currentTab: SettingsTab {
        let stored = SettingsTab(rawValue: storedTab) ?? .general
        return tabs.contains(stored) ? stored : .general
    }

    private func select(_ tab: SettingsTab) {
        withAnimation(.murmurEase()) { storedTab = tab.rawValue }
    }

    /// Dictation can't work without these two; Calendar and Screen Recording only add to Notetaker.
    private var dictationPermissionsMissing: Bool { !app.micAuthorized || !app.axTrusted }

    private var licensePaused: Bool {
        if license.channel == .release {
            if case .paused = license.panelState() { return true }
        } else if showLicensePreview {
            if case .paused = preview.store.panelState(buildReleaseDate: nil) { return true }
        }
        return false
    }

    private var attentionTabs: Set<SettingsTab> {
        var tabs = Set<SettingsTab>()
        if dictationPermissionsMissing { tabs.insert(.general) }
        if licensePaused { tabs.insert(.license) }
        return tabs
    }

    /// Opens on the tab that matters: License when the receipt email's activation link asked for it
    /// (`AppDelegate.openLicenseTile`) or dictation is paused — the error line sends people here, so they land on the
    /// reason and the way back — else General while dictation is missing a permission, else wherever you left it.
    private func openTabIfAsked() {
        if app.openLicenseTile {
            app.openLicenseTile = false
            if showsLicenseTab { select(.license) }
        } else if license.channel == .release, licensePaused {
            storedTab = SettingsTab.license.rawValue
        } else if dictationPermissionsMissing {
            storedTab = SettingsTab.general.rawValue
        }
    }

    // MARK: General

    private var generalTab: some View {
        let isSource = license.channel == .source
        return VStack(alignment: .leading, spacing: 0) {
            // A build from source: `app.availableUpdate` is the same published property that drives
            // `SoftwareUpdateView`'s own sheet, which shows itself the moment `checkForUpdates()` finds a newer
            // release — so this only reflects that state. An official release build: Sparkle's last answer, and a
            // newer version the license doesn't include points at the License tab, which offers the renewal.
            SettingsCard {
                SoftwareStatusRow(
                    version: appVersion, isSourceBuild: isSource, status: softwareStatus(isSource: isSource),
                    install: isSource ? nil : { SparkleUpdater.shared.checkForUpdates() },
                    showLicense: { select(.license) },
                    checkNow: { SparkleUpdater.shared.checkForUpdates() },
                    isLast: false)
                OpenAtLoginRow(isLast: false)
                SettingsFieldRow(
                    label: "Setup",
                    detail: "Walk through permissions, language, engine and your dictation key again.",
                    isLast: true
                ) {
                    Button("Run setup again") { app.showOnboarding() }
                        .buttonStyle(WarmGhostButtonStyle())
                }
            }

            SettingsSectionLabel(title: "PERMISSIONS", trailing: permissionsSummary)
                .padding(.top, 24)
            SettingsCard { permissionRows }
        }
    }

    private var permissionsSummary: String {
        switch (app.micAuthorized, app.axTrusted) {
        case (true, true): "Dictation has everything it needs"
        case (false, true): "Microphone needs your OK"
        case (true, false): "Accessibility needs your OK"
        case (false, false): "Dictation needs two permissions"
        }
    }

    @ViewBuilder private var permissionRows: some View {
        SettingsFieldRow(label: "Microphone", detail: "Hears your dictation.") {
            if app.micAuthorized {
                SettingsStatusLabel(title: "Granted")
            } else {
                openSystemSettingsButton(pane: "Privacy_Microphone")
            }
        }
        if app.axTrusted {
            SettingsFieldRow(label: "Accessibility",
                             detail: "Lets the dictation key work in every app, and pastes for you.",
                             isLast: !Notetaker.isAvailable) {
                SettingsStatusLabel(title: "Granted")
            }
        } else {
            // The fix sits right in the row, and only while it's needed: a grant left over from an older build
            // looks switched on in System Settings but doesn't count — resetting it makes macOS ask once more, and
            // the new grant sticks for all future updates.
            SettingsFieldRow(
                label: "Accessibility",
                detail: "Lets the dictation key work in every app, and pastes for you. Relaunch Murmur after "
                    + "allowing it. Already allowed but still not working? The grant belongs to an older build — "
                    + "reset it, and macOS asks once more.",
                isLast: !Notetaker.isAvailable
            ) {
                openSystemSettingsButton(pane: "Privacy_Accessibility")
            } footer: {
                HStack(spacing: 16) {
                    Button("Relaunch") { app.relaunch() }
                    Button("Reset grant & relaunch") { app.resetAccessibilityGrant() }
                }
                .buttonStyle(.plain)
                .font(.manrope(12, .semibold))
                .foregroundStyle(Palette.sunsetDeep)
                .padding(.top, 6)
            }
        }
        // Calendar and Screen Recording are asked for by Notetaker alone — nothing else in the app uses them,
        // so a build without Notetaker neither lists nor requests them.
        if Notetaker.isAvailable {
            SettingsFieldRow(
                label: "Calendar",
                detail: "Optional · Notetaker names a meeting after its calendar event and lists who was there."
            ) {
                if meetingDetector.calendarAuthorized {
                    SettingsStatusLabel(title: "Granted")
                } else {
                    Button("Connect") { Task { await meetingDetector.requestCalendarAccess() } }
                        .buttonStyle(WarmGhostButtonStyle())
                }
            }
            SettingsFieldRow(
                label: "Screen Recording",
                detail: "Lets Notetaker hear the other side of a call. It never records your screen.",
                isLast: true
            ) {
                if notetaker.screenRecordingAuthorized {
                    SettingsStatusLabel(title: "Granted")
                } else {
                    Button("Allow") { notetaker.requestScreenRecordingAccess() }
                        .buttonStyle(WarmGhostButtonStyle())
                }
            }
        }
    }

    private func openSystemSettingsButton(pane: String) -> some View {
        Button("Open System Settings") {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
            NSWorkspace.shared.open(url)
        }
        .buttonStyle(WarmGhostButtonStyle())
    }

    private func softwareStatus(isSource: Bool) -> SoftwareStatusRow.Status {
        if isSource { return app.availableUpdate == nil ? .upToDate : .updateAvailable }
        switch updater.lastCheck {
        case .available: return .updateAvailable
        case .upToDate: return updater.notIncluded == nil ? .upToDate : .newerNotIncluded
        case .unknown: return updater.notIncluded == nil ? .unknown : .newerNotIncluded
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    // MARK: Dictation

    /// Only a Mac with a notched screen has anything for the notch switch to change.
    private var hasNotchedScreen: Bool {
        NSScreen.screens.contains { NotchGeometry.placement(of: $0) != nil }
    }

    private var dictationTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionLabel(title: "DICTATING")
            SettingsCard {
                SettingsFieldRow(
                    label: "Dictation key",
                    detail: "Hold it, speak, release — the text lands at your cursor. Double-tap for hands-free."
                ) {
                    AccentFieldSelect(id: "hotkey", label: app.hotkey.displayName, openID: $openDropdown)
                }
                SettingsFieldRow(
                    label: "Stop hands-free when you pause",
                    detail: "A hands-free dictation ends by itself when you stop talking. Tapping the key still stops it."
                ) {
                    WarmToggle(isOn: $handsFreeAutoStop)
                        .onChange(of: handsFreeAutoStop) { _, newValue in
                            Settings.handsFreeAutoStop = newValue
                        }
                }
                SettingsFieldRow(
                    label: "Turn other sound down while you dictate",
                    detail: "Quieter in headphones, silent on speakers, back when you finish."
                ) {
                    WarmToggle(isOn: $duckOtherAudio)
                }
                SettingsFieldRow(
                    label: "Use your AirPods’ microphone",
                    detail: inputIsBluetooth || useBluetoothMicrophone
                        ? "Slower to start and less accurate than your Mac’s own microphone."
                        : "For AirPods or another Bluetooth headset, when one is connected."
                ) {
                    WarmToggle(isOn: $useBluetoothMicrophone)
                }
                SettingsFieldRow(
                    label: "Paste automatically",
                    detail: "Off leaves each dictation on the clipboard for you to paste. Apps can differ — set "
                        + "that in App Profiles."
                ) {
                    WarmToggle(isOn: $autoPasteEnabled)
                        .onChange(of: autoPasteEnabled) { _, newValue in
                            Settings.autoPasteEnabled = newValue
                        }
                }
                if hasNotchedScreen {
                    SettingsFieldRow(
                        label: "Show recording in the notch",
                        detail: "On your MacBook's screen, the recording pill grows out of the notch. Off keeps "
                            + "it at the bottom of the screen."
                    ) {
                        WarmToggle(isOn: $notchHUD)
                    }
                }
                SettingsFieldRow(
                    label: "Play sounds",
                    detail: "A soft sound when dictation starts and stops, and when something doesn’t work.",
                    isLast: true
                ) {
                    WarmToggle(isOn: $playSounds)
                        .onChange(of: playSounds) { _, newValue in
                            Settings.playSounds = newValue
                        }
                }
            }

            // The language you speak and the one Murmur pastes, together — see `TranslateInto`.
            SettingsSectionLabel(title: "LANGUAGE", trailing: "Everything runs on this Mac")
                .padding(.top, 24)
            SettingsCard {
                SettingsFieldRow(
                    label: "Language",
                    detail: "The language you speak. Which ones are offered depends on the engine."
                ) {
                    AccentFieldSelect(
                        id: "language",
                        label: Locale.current.localizedString(forIdentifier: app.localeID) ?? app.localeID,
                        openID: $openDropdown)
                }
                translateRows
            }
            .translationTask(appleLanguageDownload) { session in
                try? await session.prepareTranslation()
                app.refreshTranslationPair()
            }

            SettingsSectionLabel(title: "RECOGNITION")
                .padding(.top, 24)
            SettingsCard {
                SettingsFieldRow(label: "Engine", detail: engineDetail, isLast: modelRow == nil) {
                    AccentFieldSelect(id: "engine", label: engineLabel(app.engine), openID: $openDropdown)
                }
                if let modelRow {
                    SettingsFieldRow(label: "Model", status: modelRow.status, isLast: true) {
                        AccentFieldSelect(id: modelRow.dropdownID, label: modelRow.label, openID: $openDropdown)
                    }
                }
            }

            SettingsSectionLabel(title: "LEARNING", trailing: "Stays on this Mac")
                .padding(.top, 24)
            SettingsCard {
                SettingsFieldRow(
                    label: "Learn from your corrections",
                    detail: "Fix a name where it lands and Murmur writes it your way."
                ) {
                    WarmToggle(isOn: $learnFromEdits)
                }
                SettingsFieldRow(
                    label: "Keep a private record of your edits",
                    detail: "Shows which words need fixing most. Nothing is sent.",
                    isLast: editRecordCount == 0 && !keepEditRecords
                ) {
                    WarmToggle(isOn: $keepEditRecords)
                }
                if editRecordCount > 0 || keepEditRecords {
                    SettingsFieldRow(
                        label: "The record",
                        detail: "\(editRecordCount) dictation\(editRecordCount == 1 ? "" : "s") kept.",
                        isLast: true
                    ) {
                        HStack(spacing: 8) {
                            Button("Show") {
                                NSWorkspace.shared.activateFileViewerSelecting([EditRecordStore.fileURL])
                            }
                            .buttonStyle(WarmGhostButtonStyle())
                            .disabled(editRecordCount == 0)
                            Button("Delete") {
                                EditRecordStore.clear()
                                editRecordCount = 0
                            }
                            .buttonStyle(WarmGhostButtonStyle())
                            .disabled(editRecordCount == 0)
                        }
                    }
                }
            }
            SettingsCard {
                SettingsFieldRow(
                    label: "Paste last dictation",
                    detail: "Press ⌃⌥V in any app to paste your last dictation again.",
                    isLast: true
                ) {
                    WarmToggle(isOn: $pasteLastShortcut)
                }
            }
            .padding(.top, 12)
        }
        .onAppear {
            editRecordCount = EditRecordStore.load().count
            inputIsBluetooth = AudioRecorder.systemDefaultInputIsBluetooth()
        }
    }

    // MARK: Translate into

    /// The language spoken, and the one pasted when it's different.
    private var translatePair: (from: String, to: String?) {
        let from = TranslateInto.code(forLocale: app.localeID)
        return (from, app.translateInto.flatMap { $0 == from ? nil : $0 })
    }

    @ViewBuilder private var translateRows: some View {
        let (from, to) = translatePair
        // No hairline under it: the example belongs to this row; one goes in after the example instead.
        SettingsFieldRow(label: "Translate into", badge: translateIntoTried ? nil : "NEW", isLast: true) {
            AccentFieldSelect(id: "translateInto", label: to.map(TranslateInto.name) ?? "Off", openID: $openDropdown)
        } footer: {
            translateLine(from: from, to: to)
        }
        if let to, TranslateInto.languages.contains(from) {
            translateExample(from: from, to: to)
            Rectangle().fill(Palette.warmRowBorder).frame(height: 1)
            translatorRows(from: from, to: to)
        }
    }

    /// "You speak Latvian — Murmur pastes it in English." — what the setting does, with your own languages in it.
    private func translateLine(from: String, to: String?) -> some View {
        func strong(_ text: String) -> Text {
            Text(text).font(.manrope(12, .semibold)).foregroundStyle(Palette.warmInk)
        }
        let line: Text
        if let to, TranslateInto.languages.contains(from) {
            line = Text("You speak ") + strong(TranslateInto.name(from)) + Text(" — Murmur pastes it in ")
                + strong(TranslateInto.name(to)) + Text(".")
        } else if to != nil {
            line = Text("Translating from \(TranslateInto.name(from)) isn’t offered yet.")
        } else {
            line = Text("Speak one language — Murmur pastes it in another.")
        }
        return line.font(.manrope(12)).foregroundStyle(Palette.warmInkSoft)
    }

    /// The worked example, translated by the translator in use — hidden until there is one.
    @ViewBuilder private func translateExample(from: String, to: String) -> some View {
        let engine = translationModels.engine(from: from, to: to)
        let key = "\(from)-\(to)-\(engine?.rawValue ?? "none")"
        if let engine, let said = TranslateInto.examples[from] {
            TranslationExample(said: said, pasted: translationExample?.key == key ? translationExample?.text : nil)
                .padding(.bottom, 16)
                .task(id: key) {
                    guard translationExample?.key != key || translationExample?.text == nil else { return }
                    translationExample = (key, nil)
                    let outcome = await Translator.shared.translate(said, from: from, to: to, engine: engine)
                    if case .translated(let text, _) = outcome { translationExample = (key, text) }
                    else { translationExample = (key, said) }
                }
        }
    }

    private func gigabytes(_ bytes: Int64, of model: TranslationModel) -> String {
        String(format: "%.1f of %.1f GB", Double(bytes) / 1e9, Double(model.totalBytes) / 1e9)
    }

    /// Which translator is in use, and the one download that would make it better — never more than one offer.
    @ViewBuilder private func translatorRows(from: String, to: String) -> some View {
        let engine = translationModels.engine(from: from, to: to)
        let latvian = TranslateInto.involvesLatvian(from, to)
        // The model that would help most: EuroLLM wherever Latvian is involved, else Gemma 4.
        let wanted: TranslationModel = latvian ? .euroLLM : .gemma
        let state = translationModels.state(wanted)
        switch engine {
        case .gemma?, .euroLLM?:
            SettingsFieldRow(label: "Translator", status: .done("\(engine!.displayName) — translating on this Mac"),
                             isLast: true) { EmptyView() }
        case .apple?:
            modelOfferRow(label: "Translator", model: .gemma,
                          offer: "Using macOS’s translator. Gemma 4 reads more naturally — \(TranslationModel.gemma.sizeLabel).",
                          meanwhile: "macOS translates until then.")
        case nil:
            if !latvian, translationModels.appleNeedsDownload(from: from, to: to), state == .absent {
                SettingsFieldRow(label: "Translator",
                                 detail: "macOS needs to download \(TranslateInto.name(from == "en" ? to : from)) first.",
                                 isLast: true) {
                    Button("Download") {
                        if appleLanguageDownload == nil {
                            appleLanguageDownload = TranslationSession.Configuration(
                                source: Locale.Language(identifier: from), target: Locale.Language(identifier: to))
                        } else {
                            appleLanguageDownload?.invalidate()
                        }
                    }
                    .buttonStyle(WarmGhostButtonStyle())
                }
            } else {
                modelOfferRow(label: "Translator", model: wanted,
                              offer: latvian
                                ? "Latvian needs EuroLLM — \(wanted.sizeLabel), stays on this Mac."
                                : "Translating this needs Gemma 4 — \(wanted.sizeLabel), stays on this Mac.",
                              meanwhile: "It translates once it’s ready.")
            }
        }
    }

    /// One download on offer: the button, then its progress, then — if it stopped — why, and again.
    @ViewBuilder private func modelOfferRow(label: String, model: TranslationModel, offer: String,
                                            meanwhile: String) -> some View {
        switch translationModels.state(model) {
        case .downloading(let received):
            SettingsFieldRow(label: label,
                             status: .working("Downloading \(model.name) — \(gigabytes(received, of: model)). \(meanwhile)"),
                             isLast: true) {
                Button("Cancel") { translationModels.cancel(model) }.buttonStyle(WarmGhostButtonStyle())
            }
        case .failed(let reason):
            SettingsFieldRow(label: label, detail: offer, warning: "The download stopped: \(reason)", isLast: true) {
                Button("Try again") { translationModels.download(model) }.buttonStyle(WarmGhostButtonStyle())
            }
        case .ready, .absent:
            SettingsFieldRow(label: label, detail: offer, isLast: true) {
                Button("Download \(model.name)") { translationModels.download(model) }.buttonStyle(WarmGhostButtonStyle())
            }
        }
    }

    /// The selected engine's model row — nil for Apple's engine, which has no models to pick.
    private var modelRow: (dropdownID: String, label: String, status: SettingsRowStatus)? {
        func status(ready: Bool, downloaded: Bool) -> SettingsRowStatus {
            if ready { return .done("Loaded — transcribing your dictations") }
            return .working((downloaded ? "Loading" : "Downloading")
                            + " — Apple's engine covers your dictations until it's ready")
        }
        switch app.engine {
        case "whisper":
            return ("whisperModel",
                    WhisperEngine.availableModels.first { $0.id == app.whisperModel }?.label ?? app.whisperModel,
                    status(ready: app.whisperReady,
                           downloaded: app.whisperEngine.isModelDownloaded(app.whisperModel)))
        case "whispercpp":
            return ("whisperCppModel",
                    WhisperCppEngine.availableModels.first { $0.id == app.whisperCppModel }?.label
                        ?? app.whisperCppModel,
                    status(ready: app.whisperCppReady,
                           downloaded: app.whisperCppEngine.isModelDownloaded(app.whisperCppModel)))
        case "parakeet":
            return ("parakeetModel",
                    ParakeetEngine.availableModels.first { $0.id == app.parakeetModel }?.label ?? app.parakeetModel,
                    status(ready: app.parakeetReady,
                           downloaded: app.parakeetEngine.isModelDownloaded(app.parakeetModel)))
        case "sherpa":
            return ("sherpaModel",
                    SherpaOnnxEngine.availableModels.first { $0.id == app.sherpaModel }?.label ?? app.sherpaModel,
                    status(ready: app.sherpaReady,
                           downloaded: app.sherpaEngine.isModelDownloaded(app.sherpaModel)))
        default:
            return nil
        }
    }

    /// The shared panel rendered by the page-level `.overlayPreferenceValue`
    /// needs to know which options/labels/binding go with whichever
    /// `AccentFieldSelect.id` is currently open — these three dispatch on
    /// that id rather than the panel carrying a generic `Binding<T>` itself,
    /// since all four dropdowns on this page happen to be `String`-valued
    /// anyway.
    private func dropdownOptions(for id: String) -> [String] {
        switch id {
        case "hotkey": return HotkeyMonitor.Hotkey.allCases.map(\.rawValue)
        case "engine": return ["apple", "whisper", "whispercpp", "parakeet", "sherpa"]
        case "whisperModel": return WhisperEngine.availableModels.map(\.id)
        case "whisperCppModel": return WhisperCppEngine.availableModels.map(\.id)
        case "parakeetModel": return ParakeetEngine.availableModels.map(\.id)
        case "sherpaModel": return SherpaOnnxEngine.availableModels.map(\.id)
        case "language": return pickerLocaleIDs
        case "translateInto":
            return ["off"] + TranslateInto.languages.filter { $0 != TranslateInto.code(forLocale: app.localeID) }
        case "notetakerMaxLength": return ["30", "60", "120", "240", "0"]
        default: return []
        }
    }

    private func dropdownLabel(for id: String) -> (String) -> String {
        switch id {
        case "hotkey":
            return { raw in HotkeyMonitor.Hotkey(rawValue: raw)?.displayName ?? raw }
        case "engine": return engineLabel
        case "whisperModel":
            return { m in WhisperEngine.availableModels.first { $0.id == m }?.label ?? m }
        case "whisperCppModel":
            return { m in WhisperCppEngine.availableModels.first { $0.id == m }?.label ?? m }
        case "parakeetModel":
            return { m in ParakeetEngine.availableModels.first { $0.id == m }?.label ?? m }
        case "sherpaModel":
            return { m in SherpaOnnxEngine.availableModels.first { $0.id == m }?.label ?? m }
        case "language":
            return { id in Locale.current.localizedString(forIdentifier: id) ?? id }
        case "translateInto":
            return { code in code == "off" ? "Off — paste as I speak" : TranslateInto.name(code) }
        case "notetakerMaxLength":
            return { raw in
                switch raw {
                case "30": return "30 minutes"
                case "60": return "1 hour"
                case "120": return "2 hours"
                case "240": return "4 hours"
                default: return "No limit"
                }
            }
        default: return { $0 }
        }
    }

    private func dropdownSelection(for id: String) -> Binding<String> {
        switch id {
        case "hotkey":
            return Binding(
                get: { app.hotkey.rawValue },
                set: { if let hotkey = HotkeyMonitor.Hotkey(rawValue: $0) { app.setHotkey(hotkey) } })
        case "engine": return Binding(get: { app.engine }, set: { app.setEngine($0) })
        case "whisperModel": return Binding(get: { app.whisperModel }, set: { app.setWhisperModel($0) })
        case "whisperCppModel":
            return Binding(get: { app.whisperCppModel }, set: { app.setWhisperCppModel($0) })
        case "parakeetModel": return Binding(get: { app.parakeetModel }, set: { app.setParakeetModel($0) })
        case "sherpaModel": return Binding(get: { app.sherpaModel }, set: { app.setSherpaModel($0) })
        case "language": return Binding(get: { app.localeID }, set: { app.setLocale($0) })
        case "translateInto":
            return Binding(get: { app.translateInto ?? "off" }, set: { app.setTranslateInto($0 == "off" ? nil : $0) })
        case "notetakerMaxLength":
            return Binding(
                get: { String(notetakerMaxRecordingMinutes) },
                set: { raw in
                    guard let minutes = Int(raw) else { return }
                    notetakerMaxRecordingMinutes = minutes
                    Settings.notetakerMaxRecordingMinutes = minutes
                })
        default: return .constant("")
        }
    }

    private func engineLabel(_ id: String) -> String {
        switch id {
        case "whisper": return "Whisper — precise"
        // whisper.cpp runs the same Whisper models through a different,
        // Metal-accelerated engine — benchmarked ~3-4x faster than the
        // WhisperKit/Neural-Engine path above on Apple Silicon, likely
        // because it uses the GPU rather than the power-efficient Neural
        // Engine. A speed/battery tradeoff worth letting you pick, not one
        // engine replacing the other.
        case "whispercpp": return "whisper.cpp — precise, Metal"
        case "parakeet": return "Parakeet — precise, fast"
        case "sherpa": return "sherpa-onnx — experimental, CPU"
        default: return "Apple — instant"
        }
    }

    private var engineDetail: String {
        switch app.engine {
        case "whisper": "Whisper on the Neural Engine — the most accurate on accents and jargon."
        case "whispercpp": "Whisper on the graphics chip — fast and precise, a little harder on the battery."
        case "parakeet": "NVIDIA's Parakeet on the Neural Engine — very fast, and accurate."
        case "sherpa": "Experimental, on the processor only — fast, but English only for now."
        default: "Built into macOS — instant, with nothing to download."
        }
    }

    // MARK: Notetaker

    private var notetakerTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionLabel(title: "STARTING AND STOPPING")
            SettingsCard {
                SettingsFieldRow(label: "Shortcut", detail: "Starts or stops recording the current call, from any app.") {
                    Button { showingNotetakerHotkeyEditor = true } label: {
                        HStack(spacing: 3) {
                            ForEach(KeyComboLabel.symbols(for: notetakerHotkeyModifiers), id: \.self) { symbol in
                                WarmKeycap(label: symbol)
                            }
                            WarmKeycap(label: KeyComboLabel.keyName(for: notetakerHotkeyKeyCode))
                            MurmurIconView(icon: .edit)
                                .frame(width: 10, height: 10)
                                .foregroundStyle(Palette.warmInkFaint)
                                .padding(.leading, 5)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .murmurTooltip("Change shortcut")
                }
                SettingsFieldRow(
                    label: "Detect meetings in your browser",
                    detail: "Chrome, Safari, Edge, Arc and Brave. Reads only the open tab's address, never your history."
                ) {
                    WarmToggle(isOn: $browserMeetingDetectionEnabled)
                        .onChange(of: browserMeetingDetectionEnabled) { _, newValue in
                            Settings.browserMeetingDetectionEnabled = newValue
                        }
                }
                SettingsFieldRow(label: "Stop when the call ends",
                                 detail: "Recording ends by itself once the meeting app closes.") {
                    WarmToggle(isOn: $notetakerAutoStopOnCallEnd)
                        .onChange(of: notetakerAutoStopOnCallEnd) { _, newValue in
                            Settings.notetakerAutoStopOnCallEnd = newValue
                        }
                }
                SettingsFieldRow(label: "Longest recording",
                                 detail: "A forgotten recording stops by itself at this length.",
                                 isLast: true) {
                    AccentFieldSelect(
                        id: "notetakerMaxLength",
                        label: dropdownLabel(for: "notetakerMaxLength")(String(notetakerMaxRecordingMinutes)),
                        openID: $openDropdown)
                }
            }

            SettingsSectionLabel(title: "WHILE RECORDING")
                .padding(.top, 24)
            SettingsCard {
                SettingsFieldRow(
                    label: "Show live transcript",
                    detail: "Rough captions of both sides while the call runs. The full transcript is written when you stop."
                ) {
                    WarmToggle(isOn: $notetakerLiveTranscriptEnabled)
                        .onChange(of: notetakerLiveTranscriptEnabled) { _, newValue in
                            Settings.notetakerLiveTranscriptEnabled = newValue
                        }
                }
                SettingsFieldRow(
                    label: "Hide Murmur when you share your screen",
                    detail: "Keeps Murmur's window out of screen shares and screen recordings while Notetaker records.",
                    isLast: true
                ) {
                    WarmToggle(isOn: $notetakerHideFromScreenCapture)
                        .onChange(of: notetakerHideFromScreenCapture) { _, newValue in
                            Settings.notetakerHideFromScreenCapture = newValue
                        }
                }
            }
        }
    }

    // MARK: License

    /// Only an official release build has a license. A build from source shows the tab only while the preview is
    /// on (`defaults write local.murmur licensePreview -bool true`) — the very same card a buyer or trial user
    /// sees, on a pretend server that never touches this build's own dictation. Nothing on it says "preview":
    /// the developer controls (`LicensePreviewControls`) and the General switch row are not part of the page.
    @ViewBuilder private var licenseTab: some View {
        if license.channel == .release {
            SettingsCard {
                LicenseSection(store: license, notIncluded: updater.notIncluded)
            }
        } else {
            SettingsCard {
                LicenseSection(store: preview.store, notIncluded: preview.notIncluded, buildReleaseDate: nil)
            }
        }
    }

    /// The engine currently selected in Settings determines which
    /// languages are even offered — Apple's fixed on-device asset list
    /// only applies to the "apple" engine; Whisper/whisper.cpp/Parakeet
    /// each have their own trained-language set (see
    /// `AppDelegate.supportedLanguageIDs()`), which is where Parakeet v3's
    /// languages show up — only the ones accurate enough to actually
    /// offer, per `ParakeetEngine.v3WordErrorRates`.
    private var pickerLocaleIDs: [String] {
        var ids = sortedByLocalizedName(app.supportedLanguageIDs() ?? supportedLocaleIDs)
        if !ids.contains(app.localeID) { ids.insert(app.localeID, at: 0) }
        return ids
    }

    private func sortedByLocalizedName(_ ids: [String]) -> [String] {
        ids.sorted {
            (Locale.current.localizedString(forIdentifier: $0) ?? $0)
            < (Locale.current.localizedString(forIdentifier: $1) ?? $1)
        }
    }

    private func loadLocales() {
        Task {
            let locales = await SpeechTranscriber.supportedLocales
            supportedLocaleIDs = sortedByLocalizedName(locales.map { $0.identifier(.bcp47) })
        }
    }
}

/// Starts Murmur when you log in (`SMAppService.mainApp`). If macOS wants the OK in System Settings first, the row
/// says so and opens Login Items instead of showing a switch that looks on but isn't.
private struct OpenAtLoginRow: View {
    var isLast: Bool
    @State private var status = SMAppService.mainApp.status
    @State private var error: String?

    var body: some View {
        SettingsFieldRow(
            label: "Open at login",
            detail: status == .requiresApproval
                ? "Waiting for your OK in System Settings → General → Login Items."
                : "Starts Murmur when you log in, so the dictation key works right away.",
            warning: error,
            isLast: isLast
        ) {
            if status == .requiresApproval {
                Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    .buttonStyle(WarmGhostButtonStyle())
            } else {
                WarmToggle(isOn: Binding(get: { status == .enabled }, set: setEnabled))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            status = SMAppService.mainApp.status
        }
    }

    private func setEnabled(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            self.error = "Couldn't change that: \(error.localizedDescription)"
        }
        status = SMAppService.mainApp.status
    }
}

/// `.switch` reskinned in warm tokens — see VoiceProfileView's own
/// `warmToggle` for the twin of this; kept as a separate local type here
/// (rather than shared) since `private` there scopes it to that file.
private struct WarmToggle: View {
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

/// Reports each `AccentFieldSelect` trigger's on-screen bounds, keyed by
/// its `id`, up to the page-level `.overlayPreferenceValue` that actually
/// draws the open panel — see that call site for why the panel can't just
/// be a plain `.overlay` on the trigger itself.
private struct DropdownAnchorKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Positions and sizes the floating options panel for whichever dropdown
/// is open. Deliberately its own `View` rather than an inline closure in
/// `SettingsPage.body`: `@Environment` is resolved by a view's position in
/// the *rendered tree*, not by where a line of code textually sits, so
/// reading `\.tooltipClipBounds` from a property on `SettingsPage` itself
/// silently returned nil — `SettingsPage` sits *above* `ThinScrollView` in
/// the hierarchy, and `ThinScrollView` is what actually sets that value,
/// only for views nested inside it. This struct is constructed from
/// inside `.overlayPreferenceValue`, which *is* nested inside
/// `ThinScrollView`'s content, so its own `@Environment` read here
/// resolves correctly. Concretely, that bug meant the panel always
/// believed it had infinite room below the trigger, so it opened
/// downward unconditionally and simply ran off the bottom of the window
/// whenever real content was too tall to fit.
private struct DropdownPanel: View {
    let openDropdown: String
    let anchor: Anchor<CGRect>
    let options: [String]
    let label: (String) -> String
    let selection: Binding<String>
    let close: () -> Void

    @Environment(\.tooltipClipBounds) private var clipBounds

    var body: some View {
        GeometryReader { proxy in
            let rect = proxy[anchor]
            // The visible viewport's bottom edge, converted from
            // `clipBounds`' global space into this GeometryReader's own
            // local space, so it's directly comparable to `rect`.
            let viewportMaxY = (clipBounds?.maxY ?? .infinity)
                - proxy.frame(in: .global).minY
            let viewportHeight = clipBounds?.height ?? .greatestFiniteMagnitude
            let searchFieldHeight: CGFloat = openDropdown == "language" ? 50 : 0
            // The list's own ideal height, from its *actual* option count
            // — Language used to hardcode 396 here regardless of how many
            // locales were really on offer, which broke the moment
            // Parakeet v2 (English-only) narrowed it down to 2 options:
            // the estimate stayed at "whole page's worth," so the card
            // rendered huge with almost nothing in it. Per-row, not a flat
            // multiply: at this card's width (max 320pt, minus padding),
            // a label past ~38 characters wraps to two lines — measured
            // against "Parakeet v3 — multilingual (10 languages), ~600 MB"
            // (52 chars) actually clipping its second line at 36pt/row.
            // Model/engine labels routinely run this long; locale names
            // never do, so this only ever affects the non-Language lists.
            let rowHeight: (String) -> CGFloat = { label($0).count > 38 ? 56 : 36 }
            let idealContentHeight = options.reduce(0) { $0 + rowHeight($1) } + 12 + searchFieldHeight
            let availableBelow = max(0, viewportMaxY - rect.maxY - 6)
            let availableAbove = max(0, rect.minY - 6)
            let opensUpward = availableBelow < idealContentHeight
                && availableAbove > availableBelow
            // A *sensible* size, not just whatever happens to be free —
            // capped at half the visible viewport regardless of how much
            // *more* room a direction has: a short list opening upward
            // from low on a tall page had the whole page above it to use,
            // which is exactly why it rendered as a mostly-empty card
            // stretching nearly to the top. This only ever shrinks
            // `idealContentHeight` down for the *card's own size*
            // (`listHeight` below) — it must stay completely separate
            // from the positioning math right below, which needs the
            // real, uncapped distance to the trigger to line up against
            // it; conflating the two once already sent every panel
            // floating off to some fixed spot unrelated to its trigger.
            let sizeCap = max(160, min(
                opensUpward ? availableAbove : availableBelow, viewportHeight / 2))
            let listHeight = max(100, min(idealContentHeight, sizeCap) - searchFieldHeight)

            ZStack(alignment: .topLeading) {
                // Click-outside-to-dismiss: far bigger than any real
                // screen so it covers the window regardless of where the
                // trigger sits, invisible but still hit-testable via
                // `contentShape`. Declared first so the panel below —
                // drawn after, i.e. on top — intercepts its own clicks
                // instead of this catcher swallowing them.
                Color.clear
                    .frame(width: 6000, height: 6000)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: close)
                    .offset(x: -3000, y: -3000)
                // Trailing-aligned to the trigger's own right edge without
                // needing to know the panel's width up front: proposing a
                // container exactly `rect.maxX` wide (from the content
                // area's left edge to the trigger's right edge) and
                // right-aligning within it puts the panel's own right
                // edge flush with the trigger's, however wide the panel
                // ends up being — a fixed guessed offset undershot for a
                // long label like "Parakeet v2 — English, highest recall,
                // ~600 MB" and ran the panel past the window's edge. The
                // vertical side uses the same trick: rather than subtract
                // an estimated panel height to position it (compounding
                // that estimate's own error), bottom-aligning within a
                // frame that ends exactly at the trigger's top edge lets
                // the panel's *real* height determine how far upward it
                // grows.
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    AccentFieldSelectList(
                        options: options,
                        label: label,
                        selection: selection,
                        close: close,
                        showsSearch: openDropdown == "language",
                        listHeight: listHeight)
                        .frame(height: opensUpward ? max(0, rect.minY - 6) : nil,
                               alignment: .bottom)
                }
                .frame(width: max(1, rect.maxX))
                .offset(y: opensUpward ? 0 : rect.maxY + 6)
            }
        }
    }
}

/// The canvas's dedicated `Dropdown` component. Originally reserved for
/// just the two choices the mockup itself gives the treatment
/// (recognition engine, model) — Dictation key and Language used a
/// plainer, now-deleted `WarmFieldSelect` instead — but that inconsistency
/// read as leftover old UI once the rest of the page moved to this one, so
/// every dropdown on the page now shares it.
///
/// Deliberately not `.popover` — a native macOS popover always draws its
/// own arrow/caret pointing back at the trigger, which read as "old
/// system style" next to the mockup's plain floating card with no arrow
/// at all. Deliberately not a plain `.overlay` on the trigger either —
/// that only ever paints above its own host view, so a later sibling row
/// (e.g. the Parakeet-model trigger sitting right below the open
/// Recognition-engine panel) still drew on top of it. This only reports
/// *where* the trigger is via `.anchorPreference`; the panel itself is
/// drawn once, at the whole-page level, by `SettingsPage.body`'s own
/// `.overlayPreferenceValue` — see that for the actual positioning.
///
/// Also differs from `WarmFieldSelect` in that the trigger's accent
/// border and chevron color only appear while open — both mockup
/// illustrations of this only ever show the accent state *together with*
/// the panel already open, never at rest, and the closed/idle look
/// should match every other trigger on the page — and the selected row
/// in the panel carries a permanent tinted background plus a checkmark
/// instead of relying on hover alone to show which option is current.
/// No drop shadow on the panel, by request — overriding the mockup's own
/// (which does specify one), same no-shadow call as every other
/// floating/card element in this redesign. The mockup's own
/// `Dropdown.dc.html` also adds a search field, but only for its
/// Language illustration — a handful of engine/model options doesn't
/// need one, and the screenshot this was requested from shows none.
private struct AccentFieldSelect: View {
    let id: String
    let label: String
    @Binding var openID: String?

    private var isOpen: Bool { openID == id }

    var body: some View {
        Button {
            withAnimation(.murmurEase(0.12)) { openID = isOpen ? nil : id }
        } label: {
            HStack(spacing: 6) {
                Text(label)
                Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .font(.manrope(12, .medium))
            .foregroundStyle(isOpen ? Palette.sunsetDeep : Palette.warmInk)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: Radius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.sm)
                    .stroke(isOpen ? Palette.sunset : Palette.warmRowBorder, lineWidth: isOpen ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .anchorPreference(key: DropdownAnchorKey.self, value: .bounds) { [id: $0] }
    }
}

private struct AccentFieldSelectList: View {
    let options: [String]
    let label: (String) -> String
    @Binding var selection: String
    let close: () -> Void
    /// Only Language needs this — a couple dozen locales is the one list
    /// on this page long enough to warrant filtering, matching the
    /// mockup's own `Dropdown.dc.html`, which only ever illustrates the
    /// search field on its Language example, not a generic dropdown
    /// feature every instance gets.
    var showsSearch = false
    /// The options list's *exact* rendered height, computed by the caller
    /// (`DropdownPanel`) from the option count and available space —
    /// applied directly rather than as a maximum. A plain `ScrollView`
    /// fills whatever height it's offered instead of shrinking to fit
    /// short content, so a bare max-height cap alone left a 2-option list
    /// rendering as a mostly-empty card the full size of the cap.
    var listHeight: CGFloat = 336
    @State private var hovered: String?
    @State private var searchText = ""

    private var filteredOptions: [String] {
        guard showsSearch, !searchText.isEmpty else { return options }
        return options.filter { label($0).localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsSearch {
                searchField
                Rectangle().fill(Palette.warmRowBorder).frame(height: 1)
            }
            // `ThinScrollView`, not a plain `ScrollView` — see
            // ScratchpadView.swift's own note on why: a bare
            // `.scrollIndicators(.hidden)` doesn't reliably suppress
            // macOS's native scroller by itself. Applied unconditionally
            // now, not just for Language.
            ThinScrollView {
                optionsList.padding(6)
            }
            .frame(height: listHeight)
        }
        // `maxWidth`, not just `minWidth` — without a cap, the `Spacer`
        // pushing each row's checkmark to the trailing edge had unlimited
        // room to expand into and stretched the whole panel across most
        // of the page instead of hugging its content.
        .frame(minWidth: 220, maxWidth: 320)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        // Every other white card on this page (the tiles themselves) gets
        // a border — this floating panel didn't, which was invisible on
        // its own but broke down the moment Settings grew tall enough for
        // a panel to open directly over another white tile card behind
        // it: same fill, no shadow (kept — see this type's own header),
        // and now no border either meant literally nothing drawn marked
        // where one surface ended and the other began. `warmDivider`, not
        // `warmRowBorder` — the latter is tuned to nearly vanish against
        // white by design (it's a *fill* for chips sitting on the glass
        // panel elsewhere), which is exactly the problem here; this needs
        // to actually read as an edge.
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Palette.warmDivider, lineWidth: 1))
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            MurmurIconView(icon: .search)
                .frame(width: 13, height: 13)
                .foregroundStyle(Palette.warmInkFaint)
            TextField("Search languages…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.manrope(12.5))
                .foregroundStyle(Palette.warmInk)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        // `#F7F5F0` in the mockup — happens to be the exact same value as
        // `homeGradientBottom`, reused here rather than adding a new
        // one-off token for a single search field.
        .background(Palette.homeGradientBottom, in: RoundedRectangle(cornerRadius: Radius.sm))
        .padding(10)
    }

    private var optionsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(filteredOptions, id: \.self) { option in
                let isSelected = option == selection
                Button {
                    selection = option
                    close()
                } label: {
                    HStack {
                        Text(label(option))
                            .font(.manrope(13, isSelected ? .medium : .regular))
                            .foregroundStyle(Palette.warmInk)
                        Spacer(minLength: 12)
                        if isSelected {
                            MurmurIconView(icon: .check)
                                .frame(width: 13, height: 13)
                                .foregroundStyle(Palette.sunset)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .background(
                        isSelected ? Palette.sunsetSoft
                            : (hovered == option ? Palette.warmRowBorder : Color.clear),
                        in: RoundedRectangle(cornerRadius: Radius.sm))
                }
                .buttonStyle(.plain)
                .onHover { inside in hovered = inside ? option : nil }
            }
        }
    }
}
