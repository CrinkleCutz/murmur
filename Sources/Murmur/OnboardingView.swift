import AVFoundation
import AppKit
import Speech
import SwiftUI

/// First-run setup, built from the same parts as the rest of the app: the main window's darker titlebar band over
/// its gradient, with everything placed straight on that one background — white cards, and the app's own recording
/// pill. Welcome → permissions →
/// language and engine → dictation key → try it → done. Shown once (`Settings.hasCompletedOnboarding`), and again
/// from Settings → General → "Run setup again". Every choice applies for real the moment it's made — same as
/// `SettingsPage` — so there's nothing to save on Continue, only somewhere further to go.
///
/// Built to be effortless: the language starts as your Mac's, the engine is picked for that language (Parakeet where
/// it's strong, the Latvian Whisper for Latvian, Apple otherwise) and starts downloading while you read on, and "Try
/// it" is a real dictation into a box on the page. Pictures show rather than tell: the welcome plays the real pill
/// twice under a note and then rests; permissions show the System Settings switch to
/// turn on; the key step shows where your key is; the last step shows where Murmur lives in the menu bar.
struct OnboardingRoot: View {
    @ObservedObject var app: AppDelegate
    let onFinish: () -> Void

    @State private var step: Step = .welcome
    @State private var language = OnboardingRoot.initialLanguage()
    @State private var appleLocaleIDs: [String] = []
    @State private var tryText = ""
    @State private var tryStartedAt = Date()
    @State private var pasteFellBack = false
    /// Accessibility's "Allow" was clicked — the row switches to saying what to do in System Settings.
    @State private var accessibilityRequested = false
    @State private var notched = false
    @FocusState private var tryFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Step: Int, CaseIterable {
        case welcome, permissions, listening, key, tryIt, done
    }

    /// Keeps the permission rows, and the engine's download status, current while you're on those steps —
    /// Accessibility in particular is granted in System Settings, which tells Murmur nothing.
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private static let column: CGFloat = 520

    var body: some View {
        VStack(spacing: 0) {
            // The main window's own titlebar: a 44pt band a shade darker than the gradient, with its hairline.
            Palette.homeTitlebar.frame(height: AppDelegate.titlebarHeight)
            Rectangle().fill(Palette.border).frame(height: 1)
            VStack(spacing: 0) {
                Group {
                    if step == .welcome {
                        Color.clear.frame(height: 3)
                    } else {
                        progress
                    }
                }
                VStack(alignment: .leading, spacing: 0) {
                    switch step {
                    case .welcome: welcomeStep
                    case .permissions: permissionsStep
                    case .listening: listeningStep
                    case .key: keyStep
                    case .tryIt: tryItStep
                    case .done: doneStep
                    }
                }
                .id(step)
                .transition(.opacity.combined(with: .offset(y: 6)))
                .frame(width: Self.column, alignment: .leading)
                .padding(.top, step == .welcome ? 0 : 30)
                // The welcome has no progress bar and no title row to line up with the steps after it, so it sits
                // in the middle of the window instead of leaving the bottom empty.
                .frame(maxHeight: .infinity, alignment: step == .welcome ? .center : .top)
                footer
            }
            .padding(.top, 30)
            .padding(.bottom, 30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.homeGradient)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .onReceive(tick) { _ in
            if step == .permissions || step == .listening || step == .tryIt { app.refreshPermissions() }
        }
        .onAppear {
            notched = NSScreen.main.map { NotchGeometry.placement(of: $0) != nil } ?? false
        }
        .task { await loadAppleLocales() }
    }

    // MARK: - Chrome

    /// Thin bars; the one you've just reached fills from the left.
    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(1...5, id: \.self) { index in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.warmDivider)
                    Capsule().fill(Palette.sunset)
                        .scaleEffect(x: index <= step.rawValue ? 1 : 0, anchor: .leading)
                }
                .frame(height: 3)
            }
        }
        .frame(width: Self.column)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: step)
    }

    private var footer: some View {
        HStack {
            if step != .welcome {
                Button("Back") { move(-1) }
                    .buttonStyle(.plain)
                    .font(.manrope(13, .medium))
                    .foregroundStyle(Palette.warmInkSoft)
            }
            Spacer()
            Button(action: primaryAction) {
                HStack(spacing: 8) {
                    Text(primaryLabel).font(.manrope(13, .semibold))
                    MurmurIconView(icon: .arrowRight).frame(width: 12, height: 12)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .frame(height: 38)
                .background(Palette.navActivePill, in: RoundedRectangle(cornerRadius: Radius.md))
                .contentShape(RoundedRectangle(cornerRadius: Radius.md))
            }
            .buttonStyle(PressScaleButtonStyle(scale: 0.97))
            .keyboardShortcut(.defaultAction)
        }
        .frame(width: Self.column)
    }

    private var primaryLabel: String {
        switch step {
        case .welcome: "Get started"
        case .tryIt: tryText.isEmpty ? "Skip for now" : "Continue"
        case .done: "Open Murmur"
        default: "Continue"
        }
    }

    private func primaryAction() {
        if step == .done {
            onFinish()
        } else {
            move(1)
        }
    }

    private func move(_ delta: Int) {
        guard let next = Step(rawValue: step.rawValue + delta) else { return }
        withAnimation(.murmurEase()) { step = next }
    }

    private func title(_ text: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text)
                .font(.manrope(26, .semibold))
                .tracking(-0.4)
                .foregroundStyle(Palette.warmInk)
            Text(subtitle)
                .font(.manrope(13.5))
                .foregroundStyle(Palette.warmInkSoft)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 22)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.manrope(11.5))
            .foregroundStyle(Palette.warmInkFaint)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 10)
    }

    // MARK: - Welcome

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                OnboardingBadge(size: 26)
                Text("WELCOME TO MURMUR")
                    .font(.manrope(10.5, .semibold))
                    .kerning(1.2)
                    .foregroundStyle(Palette.sunsetDeep)
            }
            .padding(.bottom, 14)
            Text("Speak, and your words appear wherever you’re typing.")
                .font(.manrope(30, .semibold))
                .tracking(-0.6)
                .lineSpacing(2)
                .foregroundStyle(Palette.warmInk)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 10)
            Text("Hold a key, talk, let go. Murmur turns your voice into clean text in any app — and none of it "
                 + "leaves this Mac.")
                .font(.manrope(13.5))
                .foregroundStyle(Palette.warmInkSoft)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 22)
            DictationDemo(reduceMotion: reduceMotion)
        }
    }

    // MARK: - Permissions

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("Two permissions, and you’re ready",
                  "macOS asks you to allow these once. Nothing you say leaves this Mac either way.")
            OnboardingCard {
                SettingsFieldRow(label: "Microphone",
                                 detail: "So Murmur can hear you — only while you hold your key.") {
                    if app.micAuthorized {
                        SettingsStatusLabel(title: "Allowed")
                            .transition(.scale(scale: 0.7).combined(with: .opacity))
                    } else {
                        Button("Allow", action: allowMicrophone).buttonStyle(WarmGhostButtonStyle())
                    }
                }
                accessibilityRow
            }
            .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.7), value: app.micAuthorized)
            .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.7), value: app.axTrusted)
            .padding(.bottom, 16)
            SystemSettingsPicture(granted: app.axTrusted)
        }
    }

    /// Before: what it's for. After "Allow": exactly what to do in System Settings, while it waits. Then: allowed.
    @ViewBuilder private var accessibilityRow: some View {
        if app.axTrusted {
            SettingsFieldRow(label: "Accessibility",
                             detail: "So your key works in every app, and Murmur can paste your words for you.",
                             isLast: true) {
                SettingsStatusLabel(title: "Allowed")
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
            }
        } else if accessibilityRequested {
            SettingsFieldRow(label: "Accessibility",
                             warning: "Click “Open System Settings”, then switch on Murmur — this updates by itself.",
                             isLast: true) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Waiting")
                        .font(.manrope(12, .medium))
                        .foregroundStyle(Palette.warmInkSoft)
                }
                .fixedSize()
            }
        } else {
            SettingsFieldRow(label: "Accessibility",
                             detail: "So your key works in every app, and Murmur can paste your words for you.",
                             isLast: true) {
                Button("Allow") {
                    accessibilityRequested = true
                    app.refreshPermissions(promptAccessibility: true)
                }
                .buttonStyle(WarmGhostButtonStyle())
            }
        }
    }

    /// Asks the first time; once someone has said no, macOS won't ask again, so this opens the setting instead.
    private func allowMicrophone() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .denied {
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        } else {
            Task { app.micAuthorized = await AudioRecorder.requestMicrophoneAccess() }
        }
    }

    // MARK: - Language and engine

    private enum EngineChoice: CaseIterable {
        case parakeet, apple, whisper
    }

    private var listeningStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("How should Murmur listen?",
                  "Everything runs on this Mac. You can switch any time in Settings.")
            HStack {
                Text("You speak")
                    .font(.manrope(13, .semibold))
                    .foregroundStyle(Palette.warmInk)
                Spacer()
                languageMenu
            }
            .padding(.bottom, 10)
            // Optional, and off unless picked: Murmur can paste what you say in another language — see `TranslateInto`.
            HStack {
                Text("Paste it in another language?")
                    .font(.manrope(13))
                    .foregroundStyle(Palette.warmInkSoft)
                Spacer()
                translateMenu
            }
            .padding(.bottom, 16)
            VStack(spacing: 10) {
                ForEach(EngineChoice.allCases, id: \.self) { choice in
                    engineCard(choice)
                }
            }
            engineStatus
                .padding(.top, 14)
        }
        .onAppear {
            // A first run starts on the engine picked for this language (Parakeet, for most), downloading while
            // you read on. Running setup again keeps whatever you'd already chosen.
            if UserDefaults.standard.object(forKey: "engine") == nil {
                apply(recommended(for: language))
            }
        }
    }

    private var languageMenu: some View {
        Menu {
            ForEach(languageCodes, id: \.self) { code in
                Button(Self.name(of: code)) { chooseLanguage(code) }
            }
        } label: {
            HStack(spacing: 6) {
                Text(Self.name(of: language))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(.manrope(12, .medium))
            .foregroundStyle(Palette.warmInk)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: Radius.sm))
            .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Palette.warmRowBorder, lineWidth: 1))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var translateMenu: some View {
        let spoken = TranslateInto.code(forLocale: language)
        let target = app.translateInto.flatMap { $0 == spoken ? nil : $0 }
        return Menu {
            Button("Off — paste as I speak") { app.setTranslateInto(nil) }
            Divider()
            ForEach(TranslateInto.languages.filter { $0 != spoken }, id: \.self) { code in
                Button(TranslateInto.name(code)) { app.setTranslateInto(code) }
            }
        } label: {
            HStack(spacing: 6) {
                Text(target.map(TranslateInto.name) ?? "Off")
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(.manrope(12, .medium))
            .foregroundStyle(Palette.warmInk)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: Radius.sm))
            .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Palette.warmRowBorder, lineWidth: 1))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func engineCard(_ choice: EngineChoice) -> some View {
        let supported = supports(choice, language)
        let selected = currentChoice == choice
        return Button { apply(choice) } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(engineName(choice))
                            .font(.manrope(13, .semibold))
                            .foregroundStyle(Palette.warmInk)
                        if supported, recommended(for: language) == choice {
                            Text("Recommended")
                                .font(.manrope(10.5, .semibold))
                                .foregroundStyle(Palette.sunsetDeep)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Palette.sunsetSoft, in: Capsule())
                        }
                    }
                    Text(supported ? engineDetail(choice) : "Doesn’t understand \(Self.name(of: language)) yet.")
                        .font(.manrope(12))
                        .foregroundStyle(Palette.warmInkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if selected {
                    CheckBadge()
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(selected ? Palette.sunset : Palette.warmRowBorder, lineWidth: selected ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressScaleButtonStyle(scale: 0.98))
        .disabled(!supported)
        .opacity(supported ? 1 : 0.5)
        .animation(.murmurEase(0.15), value: selected)
    }

    private func engineName(_ choice: EngineChoice) -> String {
        switch choice {
        case .parakeet: "Parakeet"
        case .apple: "Apple"
        case .whisper: "Whisper"
        }
    }

    private func engineDetail(_ choice: EngineChoice) -> String {
        switch choice {
        case .parakeet: "Fast and accurate. A one-time download, about 600 MB."
        case .apple: "Instant, with nothing to download."
        case .whisper:
            if language == "lv" {
                "Whisper Large v3, trained further on Latvian. A one-time download, about 1.7 GB."
            } else if app.engine == "whispercpp" {
                // Setup run again by someone already on whisper.cpp: say what they have, not the default.
                "Whisper on the graphics chip, the way you have it set up now."
            } else {
                "Strongest on accents and specialist words. A one-time download, about 500 MB."
            }
        }
    }

    @ViewBuilder private var engineStatus: some View {
        if let status = engineReadiness {
            HStack(spacing: 6) {
                if status.ready {
                    MurmurIconView(icon: .check).frame(width: 11, height: 11)
                } else {
                    ProgressView().controlSize(.mini)
                }
                Text(status.text)
            }
            .font(.manrope(11.5))
            .foregroundStyle(Palette.warmInkSoft)
        } else {
            Text("Nothing to download — Apple’s engine is already on your Mac.")
                .font(.manrope(11.5))
                .foregroundStyle(Palette.warmInkSoft)
        }
    }

    /// The chosen engine's model: ready, loading, or downloading — nil for Apple's, which has nothing to fetch.
    private var engineReadiness: (ready: Bool, text: String)? {
        let name: String
        let ready: Bool
        let downloaded: Bool
        switch app.engine {
        case "parakeet":
            (name, ready, downloaded) = ("Parakeet", app.parakeetReady,
                                         app.parakeetEngine.isModelDownloaded(app.parakeetModel))
        case "whisper":
            (name, ready, downloaded) = ("Whisper", app.whisperReady,
                                         app.whisperEngine.isModelDownloaded(app.whisperModel))
        case "whispercpp":
            (name, ready, downloaded) = ("Whisper", app.whisperCppReady,
                                         app.whisperCppEngine.isModelDownloaded(app.whisperCppModel))
        case "sherpa":
            (name, ready, downloaded) = ("sherpa-onnx", app.sherpaReady,
                                         app.sherpaEngine.isModelDownloaded(app.sherpaModel))
        default:
            return nil
        }
        if ready { return (true, "\(name) is ready.") }
        return (false, "\(downloaded ? "Loading" : "Downloading") \(name) — Apple’s engine covers you until it’s ready.")
    }

    private var currentChoice: EngineChoice? {
        switch app.engine {
        case "parakeet": .parakeet
        case "apple": .apple
        case "whisper", "whispercpp": .whisper
        default: nil
        }
    }

    /// Languages offered here: the ones an engine handles well — Parakeet's, Apple's, and Latvian (the Latvian
    /// Whisper). Whisper's long tail stays in Settings.
    private var languageCodes: [String] {
        var codes = Set(ParakeetEngine.supportedLanguageCodes(for: "v3"))
        codes.formUnion(appleLocaleIDs.map(Self.code(of:)))
        codes.insert("lv")
        codes.insert(language)
        return codes.sorted { Self.name(of: $0) < Self.name(of: $1) }
    }

    private func supports(_ choice: EngineChoice, _ code: String) -> Bool {
        switch choice {
        case .parakeet: ParakeetEngine.supportedLanguageCodes(for: "v3").contains(code)
        case .apple: appleLocaleIDs.contains { Self.code(of: $0) == code }
        case .whisper: code == "lv" || WhisperEngine.supportedLanguageCodes.contains(code)
        }
    }

    /// Parakeet where it's strong, the Latvian Whisper for Latvian, else Apple's engine, else Whisper.
    private func recommended(for code: String) -> EngineChoice {
        if supports(.parakeet, code) { return .parakeet }
        if code == "lv" { return .whisper }
        if supports(.apple, code) { return .apple }
        return .whisper
    }

    /// Keeps the engine you picked if it handles the new language (for Whisper: if it's the right one of the two,
    /// since Latvian has its own); otherwise moves to the one recommended for it.
    private func chooseLanguage(_ code: String) {
        language = code
        let keepsEngine: Bool
        switch currentChoice {
        case .whisper?:
            let onLatvianWhisper = app.engine == "whispercpp" && app.whisperCppModel == "large-v3-lv"
            keepsEngine = supports(.whisper, code) && (code == "lv") == onLatvianWhisper
        case .parakeet?:
            // Staying on Parakeet still goes through `apply`, which picks v2 for English and v3 for the others.
            if supports(.parakeet, code) { apply(.parakeet); return }
            keepsEngine = false
        case let current?:
            keepsEngine = supports(current, code)
        case nil:
            keepsEngine = false
        }
        if keepsEngine { applyLanguage() } else { apply(recommended(for: code)) }
    }

    /// Switches engine (and, where the language needs one, its model), then sets the language — in that order,
    /// since switching engine resets a language the new engine can't handle.
    private func apply(_ choice: EngineChoice) {
        switch choice {
        case .parakeet:
            // English gets v2: measured on accented English it makes about half v3's errors (6.1% vs 11.4%,
            // 2026-09-28); v3 is for the other languages it covers.
            let model = language == "en" ? "v2" : "v3"
            if app.parakeetModel != model { app.setParakeetModel(model) }
            app.setEngine("parakeet")
        case .apple:
            app.setEngine("apple")
        case .whisper:
            if language == "lv" {
                app.setWhisperCppModel("large-v3-lv")
                app.setEngine("whispercpp")
            } else {
                if WhisperEngine.isEnglishOnly(app.whisperModel), language != "en" { app.setWhisperModel("small") }
                app.setEngine("whisper")
            }
        }
        applyLanguage()
    }

    private func applyLanguage() {
        if app.engine == "apple" {
            let region = Locale.current.region?.identifier
            let matches = appleLocaleIDs.filter { Self.code(of: $0) == language }
            let id = matches.first { region != nil && $0.hasSuffix("-\(region!)") } ?? matches.first ?? language
            app.setLocale(id)
        } else {
            app.setLocale(language)
        }
    }

    private func loadAppleLocales() async {
        let locales = await SpeechTranscriber.supportedLocales
        appleLocaleIDs = locales.map { $0.identifier(.bcp47) }
    }

    /// Your Mac's own language if an engine here handles it, the language you'd already chosen if setup ran before,
    /// else English.
    private static func initialLanguage() -> String {
        if UserDefaults.standard.object(forKey: "locale") != nil {
            return code(of: Settings.localeIdentifier)
        }
        let preferred = code(of: Locale.preferredLanguages.first ?? "en")
        let offered = Set(ParakeetEngine.supportedLanguageCodes(for: "v3")).union(["lv", "en"])
        return offered.contains(preferred) ? preferred : "en"
    }

    private static func code(of identifier: String) -> String {
        String(identifier.prefix { $0 != "-" && $0 != "_" }).lowercased()
    }

    private static func name(of code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code)?.capitalized(with: Locale.current) ?? code
    }

    // MARK: - Dictation key

    private var keyStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("Pick your dictation key",
                  "Hold it to talk, let go to paste. Double-tap it to keep talking hands-free.")
            KeyboardPicture(key: app.hotkey)
                .padding(.bottom, 14)
            OnboardingCard {
                ForEach(Array(HotkeyMonitor.Hotkey.allCases.enumerated()), id: \.element) { index, key in
                    Button { app.setHotkey(key) } label: {
                        VStack(spacing: 0) {
                            HStack(spacing: 14) {
                                WarmKeycap(label: key.shortSymbol)
                                    .frame(width: 30, alignment: .leading)
                                Text(Self.keyName(key))
                                    .font(.manrope(13, .semibold))
                                    .foregroundStyle(Palette.warmInk)
                                Spacer()
                                if app.hotkey == key {
                                    CheckBadge()
                                        .transition(.scale.combined(with: .opacity))
                                }
                            }
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                            if index < HotkeyMonitor.Hotkey.allCases.count - 1 {
                                Rectangle().fill(Palette.warmRowBorder).frame(height: 1)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .animation(.murmurEase(0.15), value: app.hotkey)
            if app.hotkey == .fn {
                note("If fn opens the emoji picker: System Settings → Keyboard → \u{201c}Press 🌐 key to\u{201d} → "
                     + "Do Nothing.")
            }
        }
    }

    /// "Globe (fn)" — the fn key is labelled with the globe on current Macs — and "Right Option" rather than
    /// "Right Option (⌥)", since the keycap beside it already shows the symbol.
    static func keyName(_ key: HotkeyMonitor.Hotkey) -> String {
        if key == .fn { return "Globe (fn)" }
        return key.displayName.replacingOccurrences(of: #" \(.*\)$"#, with: "", options: .regularExpression)
    }

    /// How the key is named inside a sentence ("Hold fn, say a sentence…").
    private static func spokenKey(_ key: HotkeyMonitor.Hotkey) -> String {
        key == .fn ? "fn" : keyName(key)
    }

    // MARK: - Try it

    private var tryItStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("Try it",
                  "Hold \(Self.spokenKey(app.hotkey)), say a sentence, and let go. Your words land right here.")
            VStack(alignment: .leading, spacing: 0) {
                TextEditor(text: $tryText)
                    .font(.manrope(14))
                    .foregroundStyle(Palette.warmInk)
                    .scrollContentBackground(.hidden)
                    .focused($tryFocused)
                    .padding(8)
                    .frame(height: 100)
                    .overlay(alignment: .topLeading) {
                        if tryText.isEmpty {
                            Text("Hold \(Self.spokenKey(app.hotkey)) and start talking…")
                                .font(.manrope(14))
                                .italic()
                                .foregroundStyle(Palette.warmInkFaint)
                                .padding(.top, 8)
                                .padding(.leading, 13)
                                .allowsHitTesting(false)
                        }
                    }
                    .background(Palette.warmRowBorder, in: RoundedRectangle(cornerRadius: Radius.sm))
                    .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Palette.warmDivider, lineWidth: 1))
                HStack(spacing: 6) {
                    MurmurIconView(icon: .mic).frame(width: 12, height: 12)
                    Text(tryStatusLine)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.manrope(11.5))
                .foregroundStyle(Palette.warmInkSoft)
                .padding(.top, 12)
            }
            .padding(20)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            if !tryText.isEmpty {
                HStack(spacing: 8) {
                    CheckBadge(size: 20)
                    Text("It works — the same in every app.")
                        .font(.manrope(13, .semibold))
                        .foregroundStyle(Palette.warmInk)
                }
                .padding(.top, 14)
                .transition(reduceMotion ? .opacity : .scale(scale: 0.85, anchor: .leading).combined(with: .opacity))
            }
            if pasteFellBack, !app.axTrusted {
                HStack(spacing: 10) {
                    Text("Allow Accessibility too, so Murmur can paste into your other apps.")
                        .font(.manrope(12))
                        .foregroundStyle(Palette.warmInkSoft)
                    Button("Allow") { app.refreshPermissions(promptAccessibility: true) }
                        .buttonStyle(WarmGhostButtonStyle())
                }
                .padding(.top, 10)
            } else if tryText.isEmpty {
                PillPicture(notched: notched)
                    .padding(.top, 16)
            }
        }
        .onAppear {
            tryStartedAt = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { tryFocused = true }
        }
        // Normally the dictation pastes itself into the box. Without Accessibility the paste can't happen, so the
        // words would only be on the clipboard — show them anyway, from History, and say what's missing.
        .onChange(of: app.entries.first?.id) { _, _ in
            guard let entry = app.entries.first, entry.date >= tryStartedAt else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                if tryText.isEmpty {
                    withAnimation(.murmurEase()) { tryText = entry.text }
                    pasteFellBack = true
                }
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.35, dampingFraction: 0.7),
                   value: tryText.isEmpty)
    }

    private var tryStatusLine: String {
        let microphone = AVCaptureDevice.default(for: .audio)?.localizedName ?? "your Mac’s microphone"
        if let status = engineReadiness, !status.ready {
            let name = app.engine == "parakeet" ? "Parakeet" : "Whisper"
            return "Listening with \(microphone). \(name) is still downloading, so this uses Apple’s engine for now."
        }
        return "Listening with \(microphone)"
    }

    // MARK: - Done

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("You’re all set",
                  "Murmur lives in your menu bar. Hold \(Self.spokenKey(app.hotkey)) in any app to dictate.")
            MenuBarPicture(reduceMotion: reduceMotion)
                .padding(.bottom, 16)
            OnboardingCard {
                CardRow(title: "Teach it your words", detail: "Names and terms it should always get right.",
                        action: { finish(opening: .dictionary) }) {
                    RowDestinationLabel(title: "Dictionary")
                }
                CardRow(title: "Choose how it sounds", detail: "As spoken, casual, formal — per app if you like.",
                        action: { finish(opening: .style) }) {
                    RowDestinationLabel(title: "Style")
                }
                CardRow(title: "Every shortcut and tip", detail: Notetaker.isAvailable ? "Hands-free, voice commands, Notetaker and more." : "Hands-free, voice commands and more.",
                        isLast: true, action: { finish(opening: .help) }) {
                    RowDestinationLabel(title: "Help")
                }
            }
        }
    }

    /// Finishes setup and opens the main window on that page.
    private func finish(opening page: Page) {
        onFinish()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { app.pendingNavigateToPage = page }
    }
}

// MARK: - Pieces

/// The white card the steps' rows sit in — the same fill and radius as the app's cards, no border, no shadow.
private struct OnboardingCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// The app's selection mark: a sunset disc with a white check.
private struct CheckBadge: View {
    var size: CGFloat = 18

    var body: some View {
        ZStack {
            Circle().fill(Palette.sunset)
            MurmurIconView(icon: .check)
                .frame(width: size / 2, height: size / 2)
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

/// Murmur's mark — the sidebar's sunset badge with its five white waveform bars — at any size, with no shadow. It
/// replaces the retired mascot.
private struct OnboardingBadge: View {
    let size: CGFloat
    private static let barHeights: [CGFloat] = [6, 12, 18, 12, 6]

    var body: some View {
        let unit = size / 34 * 15 / 24
        HStack(alignment: .center, spacing: 2 * unit) {
            ForEach(Array(Self.barHeights.enumerated()), id: \.offset) { _, height in
                Rectangle()
                    .fill(.white)
                    .frame(width: 3 * unit, height: height * unit)
            }
        }
        .frame(width: size, height: size)
        .background(Palette.sunset, in: RoundedRectangle(cornerRadius: size * 10 / 34, style: .continuous))
    }
}

private let notesIcon = NSWorkspace.shared.icon(forFile: "/System/Applications/Notes.app")

/// Welcome's demo, on the window's own background: a note, your key, and Murmur's real recording pill appearing
/// under the note while the key is held. Plays twice, then rests on the finished note; with Reduce Motion it just
/// shows that finished note.
private struct DictationDemo: View {
    let reduceMotion: Bool

    @StateObject private var hud = HUDModel()
    @State private var holding = false
    @State private var released = false
    @State private var typed = 0

    private static let heading = "Friday launch"
    private static let sentence = "Move the launch to Thursday, and send Anna the draft by noon."

    var body: some View {
        VStack(spacing: 12) {
            noteCard
            ZStack {
                keyHint
                    .frame(maxWidth: .infinity, alignment: .leading)
                if hud.state != .hidden {
                    StatusHUDView(model: hud)
                        .frame(width: 300, height: 56)
                        .transition(.opacity.combined(with: .offset(y: 8)))
                }
            }
            .frame(height: 56)
        }
        .onAppear {
            hud.targetAppIcon = notesIcon
            hud.expanded = true
        }
        .task { await play() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("A short animation: holding the fn key brings up Murmur’s listening pill, and when you "
                            + "let go, what you said appears in a note.")
    }

    private var noteCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Self.heading)
                .font(.manrope(14, .bold))
                .foregroundStyle(Palette.warmInk)
            TimelineView(.periodic(from: .now, by: 0.53)) { context in
                let caretOn = reduceMotion || Int(context.date.timeIntervalSinceReferenceDate / 0.53) % 2 == 0
                (Text(String(Self.sentence.prefix(typed))).foregroundColor(Palette.warmInk)
                    + Text("|").foregroundColor(caretOn ? Palette.sunset : .clear))
                    .font(.manrope(13))
                    .lineSpacing(3)
            }
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .topLeading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var keyHint: some View {
        HStack(spacing: 8) {
            PictureKey(top: "fn", symbol: "globe", width: 44, highlighted: holding)
                .offset(y: holding ? 1 : 0)
            Text(holding ? "Holding" : (released ? "Let go" : "Hold fn"))
                .font(.manrope(11, .semibold))
                .foregroundStyle(holding ? Palette.sunsetDeep : Palette.warmInkFaint)
                .frame(width: 46, alignment: .leading)
        }
        .animation(.easeOut(duration: 0.12), value: holding)
    }

    private func play() async {
        guard !reduceMotion else {
            typed = Self.sentence.count
            return
        }
        for round in 0..<2 {
            typed = 0
            released = false
            guard await pause(0.9) else { return }
            withAnimation(.murmurEase(0.2)) {
                holding = true
                hud.state = .recording(handsFree: false)
            }
            // A voice's rise and fall for the bars to follow, ten times a second like the real microphone.
            for step in 0..<20 {
                let time = Double(step) / 10
                hud.level = 0.45 + 0.35 * abs(sin(time * 2.9)) + 0.15 * sin(time * 7.1)
                guard await pause(0.1) else { return }
            }
            hud.level = 0
            holding = false
            released = true
            hud.state = .processing("Transcribing")
            guard await pause(0.8) else { return }
            withAnimation(.murmurEase(0.2)) { hud.state = .hidden }
            released = false
            for count in 1...Self.sentence.count {
                typed = count
                guard await pause(0.022) else { return }
            }
            if round == 0 { guard await pause(1.8) else { return } }
        }
    }

    /// Sleeps; false once the step has gone away, so the loop stops with it.
    private func pause(_ seconds: Double) async -> Bool {
        try? await Task.sleep(for: .seconds(seconds))
        return !Task.isCancelled
    }
}

/// One key of a Mac keyboard, for the pictures: white with a hairline, or sunset-lit when it's the one that matters.
private struct PictureKey: View {
    var top: String? = nil
    var bottom: String? = nil
    var symbol: String? = nil
    var width: CGFloat = 38
    var highlighted = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(highlighted ? Palette.sunsetSoft : Palette.panel)
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(highlighted ? Palette.sunset : Palette.warmDivider, lineWidth: highlighted ? 1.5 : 1)
            VStack(alignment: .trailing, spacing: 0) {
                if let top { Text(top).font(.manrope(9.5, .semibold)) }
                Spacer(minLength: 0)
                HStack(spacing: 2) {
                    if let symbol { Image(systemName: symbol).font(.system(size: 9.5, weight: .medium)) }
                    if let bottom { Text(bottom).font(.manrope(9, .medium)).lineLimit(1) }
                    Spacer(minLength: 0)
                }
            }
            .foregroundStyle(highlighted ? Palette.sunsetDeep : Palette.warmInkSoft)
            .padding(5)
        }
        .frame(width: width, height: 34)
    }
}

/// Where your key is: the left corner of a Mac keyboard for fn, the right corner for the right-hand keys — the
/// chosen one lit. Fades out towards the middle of the keyboard.
private struct KeyboardPicture: View {
    let key: HotkeyMonitor.Hotkey

    var body: some View {
        let onRight = key != .fn
        VStack(alignment: onRight ? .trailing : .leading, spacing: 6) {
            HStack(spacing: 6) {
                if onRight {
                    ForEach(["B", "N", "M", ",", ".", "/"], id: \.self) { PictureKey(bottom: $0) }
                    PictureKey(top: "⇧", bottom: "shift", width: 96, highlighted: key == .rightShift)
                } else {
                    PictureKey(top: "⇧", bottom: "shift", width: 88)
                    ForEach(["Z", "X", "C", "V", "B", "N"], id: \.self) { PictureKey(bottom: $0) }
                }
            }
            HStack(spacing: 6) {
                if onRight {
                    PictureKey(width: 150)
                    PictureKey(top: "⌘", bottom: "command", width: 58, highlighted: key == .rightCommand)
                    PictureKey(top: "⌥", bottom: "option", width: 50, highlighted: key == .rightOption)
                    // Apple's keyboards have the arrows here, not a right Control — that's on other keyboards.
                    if key == .rightControl {
                        PictureKey(top: "⌃", bottom: "control", width: 52, highlighted: true)
                    } else {
                        PictureKey(symbol: "arrowtriangle.left.fill")
                        PictureKey(symbol: "arrowtriangle.right.fill")
                    }
                } else {
                    PictureKey(top: "fn", symbol: "globe", width: 40, highlighted: true)
                    PictureKey(top: "⌃", bottom: "control", width: 52)
                    PictureKey(top: "⌥", bottom: "option", width: 50)
                    PictureKey(top: "⌘", bottom: "command", width: 58)
                    PictureKey(width: 150)
                }
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: onRight ? .trailing : .leading)
        .mask(LinearGradient(colors: onRight ? [.clear, .black, .black] : [.black, .black, .clear],
                             startPoint: .leading, endPoint: .trailing))
        .animation(.murmurEase(0.2), value: key)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Keyboard with the \(OnboardingRoot.keyName(key)) key highlighted")
    }
}

/// System Settings → Privacy & Security → Accessibility, in miniature: the switch to turn on, which flips on by
/// itself once macOS reports the grant.
private struct SystemSettingsPicture: View {
    let granted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.warmInkFaint)
                Text("Accessibility")
                    .font(.manrope(13, .bold))
                    .foregroundStyle(Palette.warmInk)
                Spacer()
                Text("System Settings")
                    .font(.manrope(10.5, .medium))
                    .foregroundStyle(Palette.warmInkFaint)
            }
            .padding(.bottom, 8)
            placeholderRow(on: true)
            Rectangle().fill(Palette.warmRowBorder).frame(height: 1)
            HStack(spacing: 10) {
                OnboardingBadge(size: 20)
                Text("Murmur")
                    .font(.manrope(12.5, .semibold))
                    .foregroundStyle(Palette.warmInk)
                Spacer()
                if !granted {
                    HStack(spacing: 4) {
                        Text("Switch this on")
                        Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold))
                    }
                    .font(.manrope(11, .semibold))
                    .foregroundStyle(Palette.sunsetDeep)
                    .transition(.opacity)
                }
                PictureSwitch(on: granted, highlighted: !granted)
            }
            .padding(.vertical, 8)
            Rectangle().fill(Palette.warmRowBorder).frame(height: 1)
            placeholderRow(on: false)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: granted)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(granted ? "Murmur is switched on in System Settings, Accessibility."
                                    : "In System Settings, Accessibility, switch on Murmur.")
    }

    private func placeholderRow(on: Bool) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Palette.warmRowBorder)
                .frame(width: 20, height: 20)
            Capsule().fill(Palette.warmRowBorder).frame(width: 92, height: 7)
            Spacer()
            PictureSwitch(on: on, highlighted: false)
        }
        .padding(.vertical, 8)
        .opacity(0.8)
    }
}

/// A switch, drawn — sunset when on, like the app's own toggles.
private struct PictureSwitch: View {
    let on: Bool
    let highlighted: Bool

    var body: some View {
        ZStack(alignment: on ? .trailing : .leading) {
            Capsule().fill(on ? Palette.sunset : Palette.warmDivider).frame(width: 30, height: 18)
            Circle().fill(.white).frame(width: 14, height: 14).padding(.horizontal, 2)
        }
        .frame(width: 30, height: 18)
        .padding(3)
        .overlay(Capsule().strokeBorder(Palette.sunset.opacity(highlighted ? 0.45 : 0), lineWidth: 2))
    }
}

/// Try it's heads-up: the pill you'll see while you talk — the real one. On a Mac with a notch it says where it goes
/// on the MacBook's own screen.
private struct PillPicture: View {
    let notched: Bool
    @StateObject private var hud = HUDModel()

    var body: some View {
        VStack(spacing: 10) {
            StatusHUDView(model: hud)
                .frame(width: 300, height: 56)
            Text(notched ? "While you talk, this shows at the bottom of your screen — on a MacBook, it grows out of the notch."
                         : "While you talk, this shows at the bottom of your screen.")
                .font(.manrope(11.5))
                .foregroundStyle(Palette.warmInkSoft)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            hud.targetAppIcon = notesIcon
            hud.state = .recording(handsFree: false)
            hud.level = 0.65
            hud.expanded = true
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("While you talk, Murmur’s listening pill shows on your screen.")
    }
}

/// Where Murmur lives: the right-hand end of the menu bar, Murmur's microphone circled, pulsing once.
private struct MenuBarPicture: View {
    let reduceMotion: Bool
    @State private var pulsed = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                Spacer()
                Image(systemName: "magnifyingglass")
                Image(systemName: "wifi")
                Image(systemName: "battery.75percent")
                ZStack {
                    Circle().fill(Palette.sunset).frame(width: 26, height: 26)
                    Image(systemName: "mic").foregroundStyle(.white)
                }
                .scaleEffect(pulsed ? 1.12 : 1)
                .overlay(alignment: .top) {
                    VStack(spacing: 2) {
                        Image(systemName: "arrow.up").font(.system(size: 9, weight: .bold))
                        Text("Murmur").font(.manrope(11, .semibold))
                    }
                    .foregroundStyle(Palette.sunsetDeep)
                    .fixedSize()
                    .offset(y: 34)
                }
                Image(systemName: "switch.2")
                Text(Date.now.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) + "  "
                     + Date.now.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 12.5, weight: .medium))
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Palette.warmInk)
            .padding(.horizontal, 18)
            .frame(height: 36)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Color.clear.frame(height: 34)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.28).delay(0.35)) { pulsed = true }
            withAnimation(.easeInOut(duration: 0.28).delay(0.63)) { pulsed = false }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Murmur’s microphone icon in the menu bar")
    }
}
