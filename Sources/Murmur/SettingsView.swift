import AppKit
import Speech
import SwiftUI

// MARK: - Settings
//
// Redesigned per the "Main" canvas (Settings.dc.html): same `GlassPanelPage`
// shell as the other redesigned pages, warm palette instead of the shared
// dynamic `Palette`. Functionally unchanged — appearance, permissions,
// dictation key, and recognition engine, all still wired to the exact same
// `AppDelegate` state.
//
// The mockup's own "Software" section shows a version number plus an
// "Update available" pill — this app has no update-checking mechanism at
// all (no Sparkle, no appcast, nothing to compare against), so that pill
// would have to be invented from nothing rather than translated. Only the
// real, honest half — the actual running version, read from the bundle —
// is implemented here; the update-check itself is a real feature, not a
// restyle, and hasn't been asked for.

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

    @State private var supportedLocaleIDs: [String] = []
    @State private var handsFreeAutoStop = Settings.handsFreeAutoStop
    @State private var autoPasteEnabled = Settings.autoPasteEnabled
    /// Which `AccentFieldSelect` (by its `id`) has its panel open, if any.
    /// Lifted up to the whole page rather than owned by each dropdown —
    /// see the panel-rendering `.overlayPreferenceValue` below for why.
    @State private var openDropdown: String?
    /// Which tile (by its `tile(id:...)` index) is expanded — mutually
    /// exclusive, same mechanism as `HelpPage.openTile`. All closed by
    /// default, same as Help's own tiles.
    @State private var openTile: Int?

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
                    header
                    tiles.padding(.top, 18)
                }
                // Attached to the whole page, not to any individual tile or
                // trigger: an `.overlay` only ever paints above its *own*
                // host view, and a later sibling declared outside that host
                // still draws on top of it — which is exactly the bug where
                // the Parakeet-model row's own white trigger rendered over
                // the still-open Recognition-engine panel behind it.
                // Anchoring here means the open panel always has every row
                // on the page as an earlier sibling, so it wins regardless
                // of which trigger (in whichever tile) opened it.
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
        .sheet(isPresented: $showingNotetakerHotkeyEditor, onDismiss: {
            notetakerHotkeyKeyCode = Settings.notetakerHotkeyKeyCode
            notetakerHotkeyModifiers = Settings.notetakerHotkeyModifiers
        }) { NotetakerHotkeyEditor() }
    }

    // MARK: Tiles (category-level disclosure, mirrors HelpPage's own)

    private var tiles: some View {
        VStack(spacing: 12) {
            tile(id: 0, icon: .settings, title: "General", summary: "Version \(appVersion)") {
                softwareSection
            }
            tile(
                id: 1, icon: .mic, title: "Dictation",
                summary: "Dictation key · Language · Recognition engine"
            ) {
                dictationSection
            }
            tile(
                id: 2, icon: .notetaker, title: "Notetaker",
                summary: "Live transcript · Auto-stop · Shortcut"
            ) {
                notetakerSection
            }
            tile(
                id: 3, icon: .lock, title: "Privacy & Permissions",
                summary: "Microphone · Accessibility · Calendar · Screen Recording"
            ) {
                privacyPermissionsSection
            }
        }
    }

    /// Hand-rolled rather than a `DisclosureGroup`, for the same reason
    /// `HelpPage.tile` is — the label and body need different horizontal
    /// padding, and a divider only once expanded, which `DisclosureGroup`'s
    /// single content/label layout doesn't cleanly support.
    private func tile<Content: View>(
        id: Int, icon: MurmurIcon, title: String, summary: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isOpen = openTile == id
        return VStack(spacing: 0) {
            Button {
                withAnimation(.murmurEase()) { openTile = isOpen ? nil : id }
            } label: {
                HStack(spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .fill(Palette.sunsetSoft)
                        MurmurIconView(icon: icon)
                            .frame(width: 24, height: 24)
                            .foregroundStyle(Palette.sunsetDeep)
                    }
                    .frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.manrope(17, .bold))
                            .foregroundStyle(Palette.warmInk)
                        Text(summary)
                            .font(.manrope(12))
                            .foregroundStyle(Palette.warmInkFaint)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 8)
                    MurmurIconView(icon: .caret)
                        .frame(width: 13, height: 13)
                        .foregroundStyle(Palette.warmInkFainter)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                VStack(spacing: 0) { content() }
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 4)
                    .overlay(alignment: .top) {
                        Rectangle().fill(Palette.warmRowBorder).frame(height: 1)
                    }
            }
        }
        .background(Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Palette.warmRowBorder, lineWidth: 1))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Settings")
                .font(.manrope(22, .medium))
                .tracking(-0.33)
                .foregroundStyle(Palette.warmInk)
            Text("Tap a category to open it — appearance, dictation, Notetaker, and privacy.")
                .font(.manrope(12.5))
                .foregroundStyle(Palette.warmInkFaint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// `.field-row` reskinned in warm tokens: a label/detail on the left, a
    /// control on the right, a hairline below unless it's the section's
    /// last row. Reused for every row on this page rather than shared —
    /// same call as every other bespoke warm view this redesign has added.
    private func fieldRow<Control: View>(
        label: String, detail: String? = nil, isLast: Bool = false,
        @ViewBuilder control: () -> Control
    ) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.manrope(12.5, .semibold))
                        .foregroundStyle(Palette.warmInk)
                    if let detail {
                        Text(detail)
                            .font(.manrope(11))
                            .foregroundStyle(Palette.warmInkSoft)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 16)
                control()
            }
            .padding(.vertical, 12)
            if !isLast {
                Rectangle().fill(Palette.warmRowBorder).frame(height: 1)
            }
        }
    }

    // MARK: Privacy & Permissions

    private var privacyPermissionsSection: some View {
        VStack(spacing: 0) {
            permissionRow(
                granted: app.micAuthorized,
                title: "Microphone",
                detail: "Required to hear your dictation.",
                pane: "Privacy_Microphone",
                isLast: false)
            permissionRow(
                granted: app.axTrusted,
                title: "Accessibility",
                detail: "Required for the global hotkey and pasting. "
                    + "Relaunch Murmur after granting.",
                pane: "Privacy_Accessibility",
                isLast: false)
            if !app.axTrusted {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Toggle on in System Settings but still red here? The saved grant "
                         + "belongs to an older build. Click Reset Grant — the app relaunches, "
                         + "macOS asks once more, and the new grant sticks for all future updates.")
                        .font(.manrope(11.5))
                        .foregroundStyle(Palette.warmInkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("Reset Grant & Relaunch") { app.resetAccessibilityGrant() }
                            .buttonStyle(WarmGhostButtonStyle())
                        Button("Relaunch") { app.relaunch() }
                            .buttonStyle(WarmGhostButtonStyle())
                    }
                }
                .padding(.top, 10)
                .padding(.bottom, 12)
                Rectangle().fill(Palette.warmRowBorder).frame(height: 1)
            }
            requestPermissionRow(
                granted: meetingDetector.calendarAuthorized,
                title: "Calendar",
                detail: "Gives Notetaker a meeting's real title and its attendees' names, "
                    + "instead of \u{201c}Zoom, 2:14 PM.\u{201d}",
                isLast: false
            ) {
                Task { await meetingDetector.requestCalendarAccess() }
            }
            requestPermissionRow(
                granted: notetaker.screenRecordingAuthorized,
                title: "Screen Recording",
                detail: "Lets Notetaker hear the other side of a call through the meeting "
                    + "app's own audio — it never records your screen.",
                isLast: true
            ) {
                notetaker.requestScreenRecordingAccess()
            }
        }
    }

    private func permissionRow(
        granted: Bool, title: String, detail: String, pane: String, isLast: Bool
    ) -> some View {
        fieldRow(label: title, detail: detail, isLast: isLast) {
            if granted {
                HStack(spacing: 6) {
                    MurmurIconView(icon: .check).frame(width: 13, height: 13)
                    Text("Granted").font(.manrope(12, .semibold))
                }
                .foregroundStyle(Palette.sunsetDeep)
            } else {
                Button("Open Settings") {
                    let url = URL(string:
                        "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(WarmGhostButtonStyle())
            }
        }
    }

    /// Same shape as `permissionRow`, but the grant flow is an in-app
    /// request (`EKEventStore`/`CGRequestScreenCaptureAccess`) rather than
    /// a System Settings deep link — Calendar and Screen Recording are both
    /// requested in-app elsewhere already (Notetaker's own page), so this
    /// reuses that same flow instead of sending the user to System Settings
    /// for something Murmur can just ask for directly.
    private func requestPermissionRow(
        granted: Bool, title: String, detail: String, isLast: Bool, action: @escaping () -> Void
    ) -> some View {
        fieldRow(label: title, detail: detail, isLast: isLast) {
            if granted {
                HStack(spacing: 6) {
                    MurmurIconView(icon: .check).frame(width: 13, height: 13)
                    Text("Granted").font(.manrope(12, .semibold))
                }
                .foregroundStyle(Palette.sunsetDeep)
            } else {
                Button("Connect", action: action)
                    .buttonStyle(WarmGhostButtonStyle())
            }
        }
    }

    // MARK: Dictation

    private var dictationSection: some View {
        VStack(spacing: 0) {
            fieldRow(label: "Dictation key") {
                AccentFieldSelect(
                    id: "hotkey", label: app.hotkey.displayName, openID: $openDropdown)
            }
            fieldRow(
                label: "Hands-free auto-stop",
                detail: "Double-tap to start, then stop automatically on a real pause "
                    + "instead of tapping again. Manual stop always still works.",
                isLast: false
            ) {
                WarmToggle(isOn: $handsFreeAutoStop)
                    .onChange(of: handsFreeAutoStop) { _, newValue in
                        Settings.handsFreeAutoStop = newValue
                    }
            }
            fieldRow(
                label: "Auto-paste",
                detail: "Paste a finished dictation at your cursor automatically. Off "
                    + "leaves it on the clipboard to paste yourself — useful for a field "
                    + "you'd rather review first. Overridable per app in App Profiles.",
                isLast: false
            ) {
                WarmToggle(isOn: $autoPasteEnabled)
                    .onChange(of: autoPasteEnabled) { _, newValue in
                        Settings.autoPasteEnabled = newValue
                    }
            }
            fieldRow(label: "Language") {
                AccentFieldSelect(
                    id: "language",
                    label: Locale.current.localizedString(forIdentifier: app.localeID) ?? app.localeID,
                    openID: $openDropdown)
            }
            fieldRow(
                label: "Recognition engine",
                detail: engineDetail,
                isLast: app.engine != "whisper" && app.engine != "whispercpp"
                    && app.engine != "parakeet" && app.engine != "sherpa"
            ) {
                AccentFieldSelect(id: "engine", label: engineLabel(app.engine), openID: $openDropdown)
            }
            if app.engine == "whisper" {
                fieldRow(
                    label: "Whisper model",
                    detail: whisperModelDetail,
                    isLast: true
                ) {
                    AccentFieldSelect(
                        id: "whisperModel",
                        label: WhisperEngine.availableModels.first { $0.id == app.whisperModel }?.label
                            ?? app.whisperModel,
                        openID: $openDropdown)
                }
            }
            if app.engine == "whispercpp" {
                fieldRow(
                    label: "whisper.cpp model",
                    detail: whisperCppModelDetail,
                    isLast: true
                ) {
                    AccentFieldSelect(
                        id: "whisperCppModel",
                        label: WhisperCppEngine.availableModels.first { $0.id == app.whisperCppModel }?.label
                            ?? app.whisperCppModel,
                        openID: $openDropdown)
                }
            }
            if app.engine == "parakeet" {
                fieldRow(
                    label: "Parakeet model",
                    detail: parakeetModelDetail,
                    isLast: true
                ) {
                    AccentFieldSelect(
                        id: "parakeetModel",
                        label: ParakeetEngine.availableModels.first { $0.id == app.parakeetModel }?.label
                            ?? app.parakeetModel,
                        openID: $openDropdown)
                }
            }
            if app.engine == "sherpa" {
                fieldRow(
                    label: "sherpa-onnx model",
                    detail: sherpaModelDetail,
                    isLast: true
                ) {
                    AccentFieldSelect(
                        id: "sherpaModel",
                        label: SherpaOnnxEngine.availableModels.first { $0.id == app.sherpaModel }?.label
                            ?? app.sherpaModel,
                        openID: $openDropdown)
                }
            }
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
        case "whisper":
            return "Whisper: best accuracy on accents and jargon; your vocabulary is fed "
                + "to the model. Runs locally."
        case "whispercpp":
            return "whisper.cpp: the same Whisper models, run on the GPU via Metal instead "
                + "of the Neural Engine — faster, at some cost to battery life. Runs locally."
        case "parakeet":
            return "Parakeet: NVIDIA's model, run on the Neural Engine — notably fast, "
                + "strong accuracy. Your dictionary isn't fed to it yet, unlike the "
                + "Whisper engines above. Runs locally."
        case "sherpa":
            return "sherpa-onnx: a newer, CPU-only engine (SenseVoice) — no Neural Engine "
                + "acceleration, but very fast even so. English only for now, and less "
                + "tested here than the engines above. Your dictionary isn't fed to it "
                + "yet either. Runs locally."
        default:
            return "Apple: instant, built into macOS. Runs locally."
        }
    }

    private var whisperModelDetail: String {
        if app.whisperReady {
            return "Model loaded — Whisper is transcribing your dictations."
        }
        if app.whisperEngine.isModelDownloaded(app.whisperModel) {
            return "Model downloaded — loading. Apple engine covers dictations until it's ready."
        }
        return "Downloading in the background. Apple engine covers dictations until it's ready."
    }

    private var whisperCppModelDetail: String {
        if app.whisperCppReady {
            return "Model loaded — whisper.cpp is transcribing your dictations."
        }
        if app.whisperCppEngine.isModelDownloaded(app.whisperCppModel) {
            return "Model downloaded — loading. Apple engine covers dictations until it's ready."
        }
        return "Downloading in the background. Apple engine covers dictations until it's ready."
    }

    private var parakeetModelDetail: String {
        if app.parakeetReady {
            return "Model loaded — Parakeet is transcribing your dictations."
        }
        if app.parakeetEngine.isModelDownloaded(app.parakeetModel) {
            return "Model downloaded — loading. Apple engine covers dictations until it's ready."
        }
        return "Downloading in the background. Apple engine covers dictations until it's ready."
    }

    private var sherpaModelDetail: String {
        if app.sherpaReady {
            return "Model loaded — sherpa-onnx is transcribing your dictations."
        }
        if app.sherpaEngine.isModelDownloaded(app.sherpaModel) {
            return "Model downloaded — loading. Apple engine covers dictations until it's ready."
        }
        return "Downloading in the background. Apple engine covers dictations until it's ready."
    }

    // MARK: Notetaker

    private var notetakerSection: some View {
        VStack(spacing: 0) {
            fieldRow(
                label: "Show live transcript",
                detail: "Rough captions from both sides of the call while it's still running "
                    + "— the real, diarized transcript is only written once you stop."
            ) {
                WarmToggle(isOn: $notetakerLiveTranscriptEnabled)
                    .onChange(of: notetakerLiveTranscriptEnabled) { _, newValue in
                        Settings.notetakerLiveTranscriptEnabled = newValue
                    }
            }
            fieldRow(
                label: "Don't show Notetaker in screen capture",
                detail: "Keeps Murmur's own window out of anything you screen-record or "
                    + "share while capturing a meeting."
            ) {
                WarmToggle(isOn: $notetakerHideFromScreenCapture)
                    .onChange(of: notetakerHideFromScreenCapture) { _, newValue in
                        Settings.notetakerHideFromScreenCapture = newValue
                    }
            }
            fieldRow(
                label: "Stop automatically when the call ends",
                detail: "Ends the capture on its own once the meeting app closes."
            ) {
                WarmToggle(isOn: $notetakerAutoStopOnCallEnd)
                    .onChange(of: notetakerAutoStopOnCallEnd) { _, newValue in
                        Settings.notetakerAutoStopOnCallEnd = newValue
                    }
            }
            fieldRow(
                label: "Maximum recording length",
                detail: "Stops automatically at this length."
            ) {
                AccentFieldSelect(
                    id: "notetakerMaxLength",
                    label: dropdownLabel(for: "notetakerMaxLength")(String(notetakerMaxRecordingMinutes)),
                    openID: $openDropdown)
            }
            fieldRow(
                label: "Also detect meetings in your browser",
                detail: "Chrome, Safari, Edge, Arc, Brave. Reads only the active tab's URL "
                    + "to check for a meeting link — never your browsing history."
            ) {
                WarmToggle(isOn: $browserMeetingDetectionEnabled)
                    .onChange(of: browserMeetingDetectionEnabled) { _, newValue in
                        Settings.browserMeetingDetectionEnabled = newValue
                    }
            }
            fieldRow(
                label: "Keyboard shortcut",
                detail: "Starts or stops capturing the current call, from anywhere.",
                isLast: true
            ) {
                Button { showingNotetakerHotkeyEditor = true } label: {
                    HStack(spacing: 6) {
                        ForEach(KeyComboLabel.symbols(for: notetakerHotkeyModifiers), id: \.self) { symbol in
                            notetakerKeycap(symbol)
                        }
                        notetakerKeycap(KeyComboLabel.keyName(for: notetakerHotkeyKeyCode))
                        MurmurIconView(icon: .edit)
                            .frame(width: 10, height: 10)
                            .foregroundStyle(Palette.warmInkFaint)
                            .padding(.leading, 2)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func notetakerKeycap(_ label: String) -> some View {
        Text(label)
            .font(.manrope(11, .semibold))
            .foregroundStyle(Palette.warmInk)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Palette.warmRowBorder, in: RoundedRectangle(cornerRadius: 5))
    }

    // MARK: Software

    /// Real status, not decoration — `app.availableUpdate` is the same
    /// published property that drives `SoftwareUpdateView`'s own sheet
    /// (`AppShellRoot`'s `.sheet(item: $app.availableUpdate)`), which
    /// already shows itself automatically the moment `checkForUpdates()`
    /// finds a newer release. By the time anyone is looking at this row,
    /// that's almost always already resolved one way or the other, so this
    /// just reflects the same state rather than checking again.
    private var softwareSection: some View {
        fieldRow(label: "Murmur", detail: "Version \(appVersion)", isLast: true) {
            if app.availableUpdate == nil {
                // Quiet, not a badge — the normal state deserves no more
                // visual weight than a permission that's already
                // `Granted` gets (`permissionRow`'s own identical
                // treatment just below, in the Privacy tile): a check and
                // some text, no fill. Reserving the filled orange pill for
                // "Update available" is what actually makes that state
                // read as worth noticing.
                HStack(spacing: 6) {
                    MurmurIconView(icon: .check).frame(width: 13, height: 13)
                    Text("Up to date").font(.manrope(12, .semibold))
                }
                .foregroundStyle(Palette.sunsetDeep)
            } else {
                // Same outer-capsule treatment as the Theme picker just
                // above — a white capsule with a `warmRowBorder` stroke
                // and 2pt inset around the filled inner pill — so this
                // reads as belonging to the same control family, not a
                // one-off badge, precisely because it's the state that
                // should draw the eye the way a selected theme option does.
                HStack(spacing: 0) {
                    Text("Update available")
                        .font(.manrope(12, .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Palette.sunset))
                }
                .padding(2)
                .background(Color.white, in: Capsule())
                .overlay(Capsule().stroke(Palette.warmRowBorder, lineWidth: 1))
                .fixedSize()
            }
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
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

/// `GhostButtonStyle` reskinned in warm tokens — same soft-accent pairing
/// the mockup itself uses for its "Update available" pill.
private struct WarmGhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.manrope(11.5, .semibold))
            .foregroundStyle(Palette.sunsetDeep)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(Palette.sunsetSoft, in: RoundedRectangle(cornerRadius: Radius.sm))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
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
            .background(Color.white, in: RoundedRectangle(cornerRadius: Radius.sm))
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
        .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
        .environment(\.colorScheme, .light)
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
