import AppKit
import Speech
import SwiftUI

// MARK: - App Profiles
//
// Redesigned per the "Main" canvas (AppProfiles.dc.html): same
// `GlassPanelPage` shell as the other redesigned pages, warm palette
// instead of the shared dynamic `Palette`. Functionally unchanged — one
// page answering one question: "what happens when I dictate into this
// app?" Style and Templates each used to own half the answer on separate
// pages, with an undocumented rule that the template half silently won.
// Both halves still live on one row here, and the row still spells out
// the result.

struct AppProfilesPage: View {
    @ObservedObject var app: AppDelegate
    @Binding var page: Page

    @State private var profiles: [String: AppProfile] = AppProfileStore.profiles
    @State private var templates: [NoteTemplate] = NoteTemplateStore.all()
    /// The broad, unrestricted locale list (same one Settings' own language
    /// picker falls back to for the Apple engine) — loaded once, reused as
    /// the language-override options for any profile whose effective engine
    /// doesn't narrow the list further. See `localeOptions(for:)`.
    @State private var supportedLocaleIDs: [String] = []
    @State private var addingRule = false
    @State private var addRuleMode: AddRuleMode = .app
    @State private var draftBundleID = ""
    /// A site rule's match pattern — a plain substring checked against the
    /// active browser tab's URL (e.g. "mail.google.com"), not a full URL or
    /// regex. Also doubles as the profile's own display name in the list.
    @State private var draftSitePattern = ""
    /// Snapshotted when the add row opens rather than read in `body`:
    /// `NSWorkspace.runningApplications` scans every process, and the add
    /// row reads the list three times per render.
    @State private var runningApps: [(bundleID: String, name: String)] = []
    /// Lifted out of `ProfileRow` (rather than a local `@State` there) so a
    /// hovering row can also suppress the hairline divider on *both* of its
    /// sides — see `profileList`'s own note on why.
    @State private var hoveredBundleID: String?
    /// Which profile's full editor sheet is open, if any. A small
    /// `Identifiable` wrapper around the bundle ID rather than a bare
    /// `String?` bound straight to `.sheet(isPresented:)` — `.sheet(item:)`
    /// is what lets the sheet's own content reference *which* profile
    /// without a second piece of state to keep in sync.
    @State private var editingProfile: EditingProfile?
    private struct EditingProfile: Identifiable { let id: String }

    var body: some View {
        GlassPanelPage {
            // `ThinScrollView`, not a plain `ScrollView` — see
            // ScratchpadView.swift's own note on why: a bare
            // `.scrollIndicators(.hidden)` doesn't reliably suppress
            // macOS's native scroller by itself.
            ThinScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header

                    if let note = app.rewriteEngine.availabilityNote {
                        tipBanner(note).padding(.top, 18)
                    }

                    if addingRule {
                        addRow.padding(.top, 24)
                    }

                    profileList
                        .padding(.top, addingRule ? 12 : 24)

                    if !suggestedApps.isEmpty {
                        suggestedCard
                            .padding(.top, 24)
                    }

                    relatedLink
                        .padding(.top, 16)
                }
            }
        }
        .onAppear {
            templates = NoteTemplateStore.all()
            loadLocales()
        }
        // A profile added from a suggestion or the add row starts empty and
        // lives only here until something's set (the store drops empties);
        // closing its editor untouched just lets it go again.
        .sheet(item: $editingProfile, onDismiss: {
            profiles = profiles.filter { !$0.value.isEmpty }
        }) { editing in
            if let profile = profiles[editing.id] {
                ProfileEditorSheet(
                    bundleID: editing.id,
                    profile: profile,
                    templates: templates,
                    globalEngine: app.engine,
                    globalModel: globalModel(forEngine:),
                    globalLocaleID: app.localeID,
                    localeOptions: localeOptions(for: profile),
                    onChange: { updated in applyChange(bundleID: editing.id, updated) },
                    onDelete: { deleteProfile(bundleID: editing.id) })
            }
        }
    }

    /// Shared by both the sheet and (for the hotkey-conflict check) nowhere
    /// else now that the row itself no longer edits fields directly — kept
    /// as its own function anyway since `.sheet(item:)`'s closure re-reads
    /// `profiles[editing.id]` fresh on every change, and needs a single
    /// place to write back to both the local `@State` mirror and the store.
    private func applyChange(bundleID: String, _ updated: AppProfile) {
        // Single-owner: assigning a hotkey slot already held by a different
        // profile silently takes it from that profile — matches the
        // store's own house style of silent conflict handling (e.g.
        // pruning empties below) rather than a blocking-validation UI.
        if let slot = updated.hotkeySlot {
            for key in profiles.keys where key != bundleID {
                if profiles[key]?.hotkeySlot == slot {
                    profiles[key]?.hotkeySlot = nil
                }
            }
        }
        profiles[bundleID] = updated
        AppProfileStore.profiles = profiles
    }

    private func deleteProfile(bundleID: String) {
        profiles.removeValue(forKey: bundleID)
        AppProfileStore.profiles = profiles
    }

    private func loadLocales() {
        Task {
            let locales = await SpeechTranscriber.supportedLocales
            supportedLocaleIDs = sortedByLocalizedName(locales.map { $0.identifier(.bcp47) })
        }
    }

    private func sortedByLocalizedName(_ ids: [String]) -> [String] {
        ids.sorted {
            (Locale.current.localizedString(forIdentifier: $0) ?? $0)
            < (Locale.current.localizedString(forIdentifier: $1) ?? $1)
        }
    }

    /// The languages to offer a profile's language-override picker — those
    /// supported by whichever engine this profile would actually use (its
    /// own override, or else the global default), same rule Settings' own
    /// language picker follows for the global case. Falls back to the
    /// broad Apple-engine list when the effective engine doesn't narrow it
    /// (Apple itself, or an engine/model combo `supportedLanguageIDs`
    /// doesn't restrict).
    private func localeOptions(for profile: AppProfile) -> [String] {
        let effectiveEngine = profile.engine ?? app.engine
        // Each `xModel` param only actually matters when `effectiveEngine`
        // is that engine — but a profile's own `model` override should
        // still narrow the language list correctly in that case, not just
        // whatever the *global* model for that engine happens to be.
        let effectiveModel = profile.model ?? globalModel(forEngine: effectiveEngine)
        let restricted = AppDelegate.supportedLanguageIDs(
            engine: effectiveEngine,
            whisperModel: effectiveEngine == "whisper" ? effectiveModel : app.whisperModel,
            whisperCppModel: effectiveEngine == "whispercpp" ? effectiveModel : app.whisperCppModel,
            parakeetModel: effectiveEngine == "parakeet" ? effectiveModel : app.parakeetModel,
            sherpaModel: effectiveEngine == "sherpa" ? effectiveModel : app.sherpaModel)
        return sortedByLocalizedName(restricted ?? supportedLocaleIDs)
    }

    /// The globally-configured model for a given engine — `Settings
    /// .whisperModel`/`.whisperCppModel`/`.parakeetModel`/`.sherpaModel`
    /// depending on which, empty for Apple (no model concept). Mirrors
    /// `AppProfileStore.model(forBundleID:)`'s own per-engine switch.
    private func globalModel(forEngine engine: String) -> String {
        switch engine {
        case "whisper": return app.whisperModel
        case "whispercpp": return app.whisperCppModel
        case "parakeet": return app.parakeetModel
        case "sherpa": return app.sherpaModel
        default: return ""
        }
    }

    /// Title and subtitle on the left, the two add actions on the right —
    /// side by side (not overlaid), so a narrow window wraps the subtitle
    /// instead of running it under the buttons.
    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("App Profiles")
                    .font(.manrope(22, .medium))
                    .tracking(-0.33)
                    .foregroundStyle(Palette.warmInk)
                // The old tip card ("Everything without a profile uses your
                // default tone…") folded into the subtitle.
                Text("What Murmur does in a particular app or website. Everything else uses your defaults.")
                    .font(.manrope(12.5))
                    .foregroundStyle(Palette.warmInkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 14) {
                Button { startAdding(.site) } label: {
                    Text("Add website")
                        .font(.manrope(13, .medium))
                        .foregroundStyle(Palette.warmInkSoft)
                }
                .buttonStyle(.plain)
                Button { startAdding(.app) } label: {
                    PrimaryActionLabel(title: "Add app")
                }
                .buttonStyle(PressScaleButtonStyle(scale: 0.97))
            }
            .fixedSize()
        }
    }

    private func tipBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            MurmurIconView(icon: .help)
                .frame(width: 13, height: 13)
                .foregroundStyle(Palette.warmInkSoft)
                .padding(.top, 1)
            Text(text)
                .font(.manrope(12.5))
                .lineSpacing(3)
                .foregroundStyle(Palette.warmInkSoft)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var profileList: some View {
        if profiles.isEmpty && !addingRule {
            Text("No profiles yet — every app and website uses your defaults.")
                .font(.manrope(12.5))
                .italic()
                .foregroundStyle(Palette.warmInkFaint)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .background(Palette.panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        } else {
            let sorted = profiles.sorted { $0.value.appName < $1.value.appName }
            VStack(spacing: 0) {
                ForEach(Array(sorted.enumerated()), id: \.element.key) { index, item in
                    profileRow(bundleID: item.key, profile: item.value)
                    // A divider sits on the boundary between two different
                    // row backgrounds, so it can never be color-matched
                    // away on both sides at once once either neighbor is
                    // hover-tinted — omitting it there (rather than always
                    // showing it) is the only fully seamless option; it
                    // stays everywhere else, between two plain rows.
                    if index != sorted.count - 1 {
                        let nextKey = sorted[index + 1].key
                        if hoveredBundleID != item.key && hoveredBundleID != nextKey {
                            Rectangle().fill(Palette.warmRowBorder).frame(height: 1)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    // MARK: Rows

    private func profileRow(bundleID: String, profile: AppProfile) -> some View {
        CompactProfileRow(
            bundleID: bundleID,
            profile: profile,
            chips: chips(for: bundleID, profile: profile),
            isHovering: hoveredBundleID == bundleID,
            onHoverChange: { inside in
                hoveredBundleID = inside
                    ? bundleID
                    : (hoveredBundleID == bundleID ? nil : hoveredBundleID)
            },
            onOpen: { editingProfile = EditingProfile(id: bundleID) })
    }

    /// A profile normally binds to an app (bundle ID); a site rule instead
    /// binds to a plain substring match against the frontmost browser's
    /// active tab URL, checked only when a supported browser (the same
    /// five `MeetingDetector` already knows: Chrome/Safari/Edge/Arc/Brave)
    /// is actually frontmost and at least one site rule exists — see
    /// `AppProfileStore.siteProfileKey(forURL:)`.
    private enum AddRuleMode { case app, site }

    private func startAdding(_ mode: AddRuleMode) {
        draftBundleID = ""
        draftSitePattern = ""
        addRuleMode = mode
        runningApps = RunningApps.list
        addingRule = true
    }

    /// Creates an empty profile for this app or site and opens its editor
    /// straight away. Empty on purpose — it used to start with the default
    /// tone written in "so the new row does something visible", which
    /// made a profile that changed nothing look as if it did.
    private func createProfile(key: String, name: String) {
        if profiles[key] == nil {
            profiles[key] = AppProfile(appName: name, style: nil, templateID: nil)
        }
        addingRule = false
        draftBundleID = ""
        draftSitePattern = ""
        editingProfile = EditingProfile(id: key)
    }

    /// Inline, above the list. Which kind it adds is decided by the button
    /// that opened it ("Add app" / "Add website"), so no mode switch. The
    /// app choices list your most-dictated apps first, then whatever's
    /// running.
    private var addRow: some View {
        HStack(spacing: 10) {
            if addRuleMode == .app {
                let suggested = suggestedApps.map { (bundleID: $0.bundleID, name: $0.name) }
                let running = runningApps.filter { app in
                    profiles[app.bundleID] == nil && !suggested.contains { $0.bundleID == app.bundleID }
                }
                let choices = suggested + running
                WarmFieldSelect(
                    options: [""] + choices.map(\.bundleID),
                    label: { id in
                        id.isEmpty ? "Choose an app…" : (choices.first { $0.bundleID == id }?.name ?? id)
                    },
                    selection: $draftBundleID)
            } else {
                TextField("Website, e.g. mail.google.com", text: $draftSitePattern)
                    .textFieldStyle(.plain)
                    .font(.manrope(13))
                    .foregroundStyle(Palette.warmInk)
                    .padding(.horizontal, 12)
                    .frame(width: 260, height: 32)
                    .background(Palette.panel, in: RoundedRectangle(cornerRadius: Radius.sm))
                    .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Palette.warmRowBorder, lineWidth: 1))
                    .onSubmit(commitAdd)
            }
            IconButton(icon: .check, hoverFill: Palette.hoverWash, help: "Add", action: commitAdd)
                .disabled(addRuleMode == .app
                    ? draftBundleID.isEmpty
                    : draftSitePattern.trimmingCharacters(in: .whitespaces).isEmpty)
            IconButton(icon: .plus, rotated: true, hoverFill: Palette.hoverWash, help: "Cancel") {
                addingRule = false
                draftBundleID = ""
                draftSitePattern = ""
            }
            Spacer()
        }
        .onExitCommand { addingRule = false }
    }

    private func commitAdd() {
        switch addRuleMode {
        case .app:
            guard !draftBundleID.isEmpty else { return }
            createProfile(key: draftBundleID, name: Self.resolveApp(bundleID: draftBundleID).name)
        case .site:
            let pattern = draftSitePattern.trimmingCharacters(in: .whitespaces)
            guard !pattern.isEmpty else { return }
            createProfile(key: AppProfileStore.siteKey(forPattern: pattern), name: pattern)
        }
    }

    // MARK: Suggested

    /// The apps you dictated into most over the last 7 days that don't have
    /// a profile yet and are installed — from `UsageStatsStore`'s per-app
    /// words, so the page brings you the apps worth setting up instead of
    /// making you hunt for them. Murmur itself is never suggested.
    private var suggestedApps: [(bundleID: String, name: String, icon: NSImage?, words: Int)] {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: Date()))!
        var words: [String: Int] = [:]
        for day in app.usageStats.days(from: start) {
            words.merge(day.appWords ?? [:], uniquingKeysWith: +)
        }
        return words
            .filter { profiles[$0.key] == nil && $0.key != Bundle.main.bundleIdentifier }
            .sorted { $0.value > $1.value }
            .compactMap { bundleID, count in
                guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil else { return nil }
                let resolved = Self.resolveApp(bundleID: bundleID)
                return (bundleID, resolved.name, resolved.icon, count)
            }
            .prefix(3)
            .map { $0 }
    }

    private var suggestedCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .lastTextBaseline) {
                Text("Suggested")
                    .font(.manrope(13, .semibold))
                    .foregroundStyle(Palette.warmInk)
                Spacer()
                Text("apps you dictate into most, without a profile")
                    .font(.manrope(11.5))
                    .foregroundStyle(Palette.warmInkFaint)
            }
            VStack(spacing: 0) {
                ForEach(Array(suggestedApps.enumerated()), id: \.element.bundleID) { index, suggestion in
                    if index > 0 {
                        Rectangle().fill(Palette.warmRowBorder).frame(height: 1)
                    }
                    HStack(spacing: 12) {
                        AppIconTile(icon: suggestion.icon)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.name)
                                .font(.manrope(13, .semibold))
                                .foregroundStyle(Palette.warmInk)
                            Text("\(suggestion.words.formatted()) words this week")
                                .font(.manrope(12))
                                .foregroundStyle(Palette.warmInkSoft)
                        }
                        Spacer()
                        Button {
                            createProfile(key: suggestion.bundleID, name: suggestion.name)
                        } label: {
                            HStack(spacing: 6) {
                                MurmurIconView(icon: .plus).frame(width: 11, height: 11)
                                Text("Add").font(.manrope(12.5, .semibold))
                            }
                            .foregroundStyle(Palette.warmInk)
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .background(Palette.panel, in: RoundedRectangle(cornerRadius: Radius.sm))
                            .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Palette.warmDivider, lineWidth: 1))
                        }
                        .buttonStyle(PressScaleButtonStyle(scale: 0.96))
                    }
                    .padding(.vertical, 10)
                }
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// Resolves via the *installed* app — its current name and icon — not
    /// the name saved when a profile was created, which can go stale (a
    /// profile saved as "ChatGPT" was really bound to the Codex app).
    static func resolveApp(bundleID: String) -> (name: String, icon: NSImage?) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return (bundleID, nil)
        }
        return (FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""),
                NSWorkspace.shared.icon(forFile: url.path))
    }

    private var relatedLink: some View {
        HStack(spacing: 4) {
            Text("Want to reshape text on demand instead of automatically?")
                .font(.manrope(12))
                .foregroundStyle(Palette.warmInkSoft)
            Button { page = .transforms } label: {
                Text("Transforms")
                    .font(.manrope(12, .medium))
                    .foregroundStyle(Palette.sunsetDeep)
            }
            .buttonStyle(.plain)
            Text("run when you trigger them.")
                .font(.manrope(12))
                .foregroundStyle(Palette.warmInkSoft)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// This profile's active overrides as chips — every one that actually
    /// does something, including developer vocabulary (which the old
    /// middot summary never showed). A setting equal to the current default
    /// says so ("— your default", faint), so a profile that changes nothing
    /// no longer reads as if it does.
    private func chips(for bundleID: String, profile: AppProfile) -> [(text: String, isDefault: Bool)] {
        var chips: [(String, Bool)] = []
        if let tone = profile.style {
            chips.append(tone == StyleSettings.defaultStyle
                         ? ("\(tone.displayName) — your default", true)
                         : (tone.displayName, false))
        }
        if let templateID = profile.templateID,
           let name = templates.first(where: { $0.id == templateID })?.name {
            chips.append((name, false))
        }
        if let engine = profile.engine { chips.append((AppProfilesPage.engineDisplayName(engine), false)) }
        if let model = profile.model {
            chips.append((AppProfilesPage.modelDisplayName(model, engine: profile.engine ?? app.engine), false))
        }
        if let localeID = profile.localeIdentifier {
            chips.append((Locale.current.localizedString(forIdentifier: localeID) ?? localeID, false))
        }
        if let translate = profile.translateInto {
            chips.append((translate.isEmpty ? "No translation" : "Into \(TranslateInto.name(translate))", false))
        }
        if let autoPaste = profile.autoPaste { chips.append((autoPaste ? "Auto-paste" : "No auto-paste", false)) }
        if let developer = profile.developerVocabulary {
            chips.append((developer ? "Developer words on" : "Developer words off", false))
        }
        if let hotkey = profile.hotkeySlot { chips.append((hotkey.label, false)) }
        return chips.isEmpty ? [("Uses your defaults", true)] : chips
    }

    /// Shared by the row summary above and `ProfileEditorSheet`'s own
    /// engine picker, so the same engine id always reads the same way.
    static func engineDisplayName(_ id: String) -> String {
        switch id {
        case "whisper": return "Whisper"
        case "whispercpp": return "whisper.cpp"
        case "parakeet": return "Parakeet"
        case "sherpa": return "sherpa-onnx"
        default: return "Apple"
        }
    }

    /// The model choices for a given engine — empty for Apple, which has
    /// no model concept. Shared by `ProfileEditorSheet`'s model picker so
    /// it never has to know each engine's own `availableModels` type.
    static func modelOptions(forEngine engine: String) -> [(id: String, label: String)] {
        switch engine {
        case "whisper": return WhisperEngine.availableModels
        case "whispercpp": return WhisperCppEngine.availableModels
        case "parakeet": return ParakeetEngine.availableModels
        case "sherpa": return SherpaOnnxEngine.availableModels
        default: return []
        }
    }

    /// A model's own short name within a given engine — just the name,
    /// dropping the " — size/description" suffix every engine's own
    /// `availableModels` label carries (e.g. "FunASR Nano — LLM-backed,
    /// English only, ~1 GB" → "FunASR Nano"). Those full labels were
    /// written for Settings' own dedicated, full-width picker row; reused
    /// as-is here they made the picker trigger wide enough to squeeze this
    /// sheet's fixed-width row layout into wrapping its *own* label
    /// character-by-character — a real, reproduced layout bug, not a
    /// hypothetical one. Falls back to the raw id if the engine's
    /// `availableModels` doesn't list it (e.g. a hidden model like
    /// Zipformer/Moonshine, still reachable by id even though it's not
    /// offered in the picker — see `SherpaOnnxEngine`'s own doc comment on
    /// why those stay hidden, not deleted).
    static func modelDisplayName(_ id: String, engine: String) -> String {
        let fullLabel = modelOptions(forEngine: engine).first { $0.id == id }?.label ?? id
        return fullLabel.components(separatedBy: " — ").first ?? fullLabel
    }
}

// MARK: - Row

/// The always-visible row: name, a middot-joined summary of whatever's
/// actually overridden, and nothing else — tapping anywhere on the row
/// opens `ProfileEditorSheet`, which is where every setting actually lives
/// now. Replaces the old row that tried to fit up to seven pickers inline
/// (four visible, three behind a chevron) — engine specifically was one of
/// the three behind it, easy to set and then never see confirmed anywhere.
private struct CompactProfileRow: View {
    let bundleID: String
    let profile: AppProfile
    let chips: [(text: String, isDefault: Bool)]
    let isHovering: Bool
    let onHoverChange: (Bool) -> Void
    let onOpen: () -> Void

    private var isSite: Bool { AppProfileStore.isSiteKey(bundleID) }

    var body: some View {
        let resolved = isSite ? (name: profile.appName, icon: nil) : AppProfilesPage.resolveApp(bundleID: bundleID)
        // A profile whose app isn't installed any more keeps its saved name.
        let name = !isSite && resolved.icon == nil ? profile.appName : resolved.name
        Button(action: onOpen) {
            HStack(spacing: 12) {
                AppIconTile(icon: resolved.icon, symbol: isSite ? .search : .apps)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(name)
                            .font(.manrope(13, .semibold))
                            .foregroundStyle(Palette.warmInk)
                        if isSite {
                            Text("Website")
                                .font(.manrope(9.5, .semibold))
                                .foregroundStyle(Palette.warmInkFaint)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Palette.warmRowBorder, in: Capsule())
                        }
                    }
                    HStack(spacing: 6) {
                        ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                            Text(chip.text)
                                .font(.manrope(11.5, .medium))
                                .foregroundStyle(chip.isDefault ? Palette.warmInkFaint : Palette.warmInkSoft)
                                .padding(.horizontal, 8)
                                .frame(height: 22)
                                .background(Palette.warmRowBorder, in: Capsule())
                                .fixedSize()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                MurmurIconView(icon: .caret)
                    .frame(width: 9, height: 9)
                    .foregroundStyle(Palette.warmInkFainter)
                    .opacity(isHovering ? 1 : 0.5)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: Radius.sm)
                .fill(isHovering ? Palette.hoverWash : Color.clear))
        // See HomeView.swift's historyRow for why this is needed: a .clear
        // background makes SwiftUI treat the row's empty space as outside
        // the hoverable region until this forces the whole padded frame to
        // count, regardless of what's actually drawn there.
        .contentShape(Rectangle())
        .onHover(perform: onHoverChange)
        .animation(.easeOut(duration: 0.1), value: isHovering)
    }
}

/// An app's real icon at 28pt, or — for a website, or an app that's no
/// longer installed — a warm tile with a glyph, the same tile Insights'
/// category rows use.
private struct AppIconTile: View {
    let icon: NSImage?
    var symbol: MurmurIcon = .apps

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon).resizable()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 7).fill(Palette.warmRowBorder)
                    MurmurIconView(icon: symbol)
                        .frame(width: 13, height: 13)
                        .foregroundStyle(Palette.sunsetDeep)
                }
            }
        }
        .frame(width: 28, height: 28)
    }
}

// MARK: - Editor sheet

/// Everything one profile can set, in three labeled sections — Style,
/// Recognition, Behavior — each row at equal visual weight. Nothing here
/// is progressively disclosed: the whole point of replacing the old inline
/// row is that a setting you can't see isn't a setting you remember you
/// set. Each field writes through `onChange` immediately on selection, the
/// same instant-apply behavior the old row had — "Done" just closes the
/// sheet, it isn't a separate save step.
private struct ProfileEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let bundleID: String
    let profile: AppProfile
    let templates: [NoteTemplate]
    let globalEngine: String
    /// The globally-configured model for a given engine id — mirrors
    /// `AppProfilesPage.globalModel(forEngine:)`. A closure rather than one
    /// flat value: the model picker's own "Default" label needs whichever
    /// engine is actually in effect (this profile's own override, or else
    /// `globalEngine`), not always `globalEngine`'s.
    let globalModel: (String) -> String
    let globalLocaleID: String
    /// Languages to offer in the language-override picker — already
    /// narrowed to whichever engine this profile would actually use; see
    /// `AppProfilesPage.localeOptions(for:)`.
    let localeOptions: [String]
    let onChange: (AppProfile) -> Void
    let onDelete: () -> Void

    @State private var showingDeleteConfirm = false

    private func set<T>(_ keyPath: WritableKeyPath<AppProfile, T>, _ value: T) {
        var updated = profile
        updated[keyPath: keyPath] = value
        onChange(updated)
    }

    /// `nil` first so "inherit the default" is the top choice rather than
    /// something buried under five concrete tones.
    private var styleOptions: [WritingStyle?] {
        [nil] + WritingStyle.allCases.map { Optional($0) }
    }

    /// What "Default tone" actually resolves to for this app — plain
    /// global default everywhere, except a recognized terminal, which
    /// `AppProfileStore.style(forBundleID:)` auto-defaults to Raw. Stated
    /// rather than left to look up, same as developer vocabulary below.
    private var defaultStyleLabel: String {
        DeveloperVocabulary.terminalBundleIDs.contains(bundleID)
            ? "Default (Raw)" : "Default (\(StyleSettings.defaultStyle.displayName))"
    }

    private var templateOptions: [UUID?] { [nil] + templates.map { Optional($0.id) } }

    private var engineOptions: [String?] { [nil, "apple", "whisper", "whispercpp", "parakeet", "sherpa"] }

    private func engineLabel(_ id: String?) -> String {
        guard let id else { return "Default (\(AppProfilesPage.engineDisplayName(globalEngine)))" }
        return AppProfilesPage.engineDisplayName(id)
    }

    /// Whichever engine this profile would actually use — its own
    /// override if set, else the global default. The model picker below
    /// is keyed to this, not always `globalEngine`, so switching the
    /// engine picker immediately offers that engine's own models.
    private var effectiveEngine: String { profile.engine ?? globalEngine }

    private var modelOptions: [String?] {
        [nil] + AppProfilesPage.modelOptions(forEngine: effectiveEngine).map { Optional($0.id) }
    }

    private func modelLabel(_ id: String?) -> String {
        guard let id else { return "Default (\(AppProfilesPage.modelDisplayName(globalModel(effectiveEngine), engine: effectiveEngine)))" }
        return AppProfilesPage.modelDisplayName(id, engine: effectiveEngine)
    }

    private var localeSelectOptions: [String?] { [nil] + localeOptions }

    private func localeLabel(_ id: String?) -> String {
        guard let id else {
            return "Default (\(Locale.current.localizedString(forIdentifier: globalLocaleID) ?? globalLocaleID))"
        }
        return Locale.current.localizedString(forIdentifier: id) ?? id
    }

    /// nil follows Settings, "" is off in this app, else the language — see `TranslateInto`.
    private var translateOptions: [String?] { [nil, ""] + TranslateInto.languages.map { Optional($0) } }

    private func translateLabel(_ value: String?) -> String {
        switch value {
        case nil: return "Default (\(TranslateInto.target.map(TranslateInto.name) ?? "Off"))"
        case ""?: return "Off"
        case let code?: return TranslateInto.name(code)
        }
    }

    private var autoPasteOptions: [Bool?] { [nil, true, false] }

    private func autoPasteLabel(_ value: Bool?) -> String {
        switch value {
        case nil: return "Default (\(Settings.autoPasteEnabled ? "On" : "Off"))"
        case true?: return "On"
        case false?: return "Off"
        }
    }

    private var developerVocabularyOptions: [Bool?] { [nil, true, false] }

    private var autoDefaultLabel: String {
        DeveloperVocabulary.developerContextBundleIDs.contains(bundleID)
            ? "Auto (on for this app)" : "Auto (off for this app)"
    }

    private func developerVocabularyLabel(_ value: Bool?) -> String {
        switch value {
        case nil: return autoDefaultLabel
        case true?: return "On"
        case false?: return "Off"
        }
    }

    private var hotkeyOptions: [ProfileHotkeySlot?] { [nil] + ProfileHotkeySlot.allCases.map { Optional($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 6) {
                    Text(profile.appName)
                        .font(.manrope(16, .semibold))
                        .foregroundStyle(Palette.warmInk)
                    if AppProfileStore.isSiteKey(bundleID) {
                        Text("Website")
                            .font(.manrope(9.5, .semibold))
                            .foregroundStyle(Palette.warmInkFaint)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Palette.warmRowBorder, in: Capsule())
                    }
                }
                Spacer()
                // Not `GhostButtonStyle()` — it pulls from `Palette.accent`,
                // the pre-warm-redesign accent color (a pale lime-green),
                // not this page's actual warm palette. Matches
                // `NotetakerHotkeyEditor`'s own "Done" button instead: a
                // solid dark pill, the established warm-sheet convention.
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
            .padding(.bottom, 18)

            sectionHeader("Style")
            sheetRow(label: "Tone") {
                WarmFieldSelect(
                    options: styleOptions, label: { $0?.displayName ?? defaultStyleLabel },
                    selection: Binding(get: { profile.style }, set: { set(\.style, $0) }))
            }
            sheetRow(label: "Template", isLast: true) {
                WarmFieldSelect(
                    options: templateOptions,
                    label: { id in
                        guard let id else { return "No template" }
                        return templates.first { $0.id == id }?.name ?? "No template"
                    },
                    selection: Binding(get: { profile.templateID }, set: { set(\.templateID, $0) }))
            }

            sectionHeader("Recognition").padding(.top, 20)
            sheetRow(label: "Engine") {
                WarmFieldSelect(
                    options: engineOptions, label: engineLabel,
                    selection: Binding(
                        get: { profile.engine },
                        set: { newValue in
                            // A model id only means something within the
                            // engine it belongs to — clear a stale one
                            // rather than carry, say, a Whisper model id
                            // into a freshly-switched-to Parakeet override.
                            var updated = profile
                            updated.engine = newValue
                            updated.model = nil
                            onChange(updated)
                        }))
            }
            // Apple has no model concept — nothing to pick.
            if effectiveEngine != "apple" {
                sheetRow(label: "Model") {
                    WarmFieldSelect(
                        options: modelOptions, label: modelLabel,
                        selection: Binding(get: { profile.model }, set: { set(\.model, $0) }))
                }
            }
            sheetRow(label: "Language") {
                WarmFieldSelect(
                    options: localeSelectOptions, label: localeLabel,
                    selection: Binding(get: { profile.localeIdentifier }, set: { set(\.localeIdentifier, $0) }))
            }
            sheetRow(label: "Translate into", isLast: true) {
                WarmFieldSelect(
                    options: translateOptions, label: translateLabel,
                    selection: Binding(get: { profile.translateInto }, set: { set(\.translateInto, $0) }))
            }

            sectionHeader("Behavior").padding(.top, 20)
            sheetRow(label: "Auto-paste") {
                WarmFieldSelect(
                    options: autoPasteOptions, label: autoPasteLabel,
                    selection: Binding(get: { profile.autoPaste }, set: { set(\.autoPaste, $0) }))
            }
            sheetRow(label: "Developer vocabulary") {
                WarmFieldSelect(
                    options: developerVocabularyOptions, label: developerVocabularyLabel,
                    selection: Binding(get: { profile.developerVocabulary }, set: { set(\.developerVocabulary, $0) }))
            }
            sheetRow(label: "Hotkey", isLast: true) {
                WarmFieldSelect(
                    options: hotkeyOptions, label: { $0?.label ?? "No hotkey" },
                    selection: Binding(get: { profile.hotkeySlot }, set: { set(\.hotkeySlot, $0) }))
            }

            Button {
                showingDeleteConfirm = true
            } label: {
                Text("Delete profile")
                    .font(.manrope(12, .medium))
                    .foregroundStyle(Palette.warmInkFaint)
            }
            .buttonStyle(.plain)
            .padding(.top, 22)
        }
        .padding(22)
        .frame(width: 420)
        .confirmationDialog(
            "Delete this profile?", isPresented: $showingDeleteConfirm, titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                onDelete()
                dismiss()
            }
        } message: {
            Text("\(profile.appName) goes back to using your defaults.")
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.manrope(10.5, .semibold))
            .tracking(0.6)
            .foregroundStyle(Palette.sunsetDeep)
            .padding(.bottom, 8)
    }

    private func sheetRow<Content: View>(
        label: String, isLast: Bool = false, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            HStack {
                // `.lineLimit(1)` is the actual fix, not just tidiness: an
                // over-wide sibling (the picker trigger button next to
                // this, `.fixedSize()`'d to whatever its label text needs)
                // can squeeze this row's own remaining width toward zero —
                // reproduced for real with a long model label ("Model"
                // wrapped one letter per line). Capped at one line, an
                // over-squeeze truncates with an ellipsis instead, which
                // is recoverable-looking rather than broken-looking.
                Text(label)
                    .font(.manrope(12.5))
                    .foregroundStyle(Palette.warmInkSoft)
                    .lineLimit(1)
                Spacer()
                content()
            }
            .padding(.vertical, 9)
            if !isLast {
                Rectangle().fill(Palette.warmRowBorder).frame(height: 1)
            }
        }
    }
}

// MARK: - Warm field select
//
// Same `Button` + `.popover` mechanics as the shared `FieldSelect` (Menu
// combined with `.menuStyle(.borderlessButton)` silently drops the custom
// background/border on this build — see that type's own note), reskinned
// in warm tokens throughout, including the popover's own list — the
// shared version bakes `Palette.ink`/`.cardHover` into that list with no
// override, so restyling only the trigger would leave a mismatched popover.

private struct WarmFieldSelect<T: Hashable>: View {
    let options: [T]
    let label: (T) -> String
    @Binding var selection: T
    @State private var isOpen = false

    var body: some View {
        Button {
            isOpen = true
        } label: {
            HStack(spacing: 6) {
                Text(label(selection))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .font(.manrope(12, .medium))
            .foregroundStyle(Palette.warmInkSoft)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: Radius.sm))
            .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Palette.warmRowBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            WarmFieldSelectList(options: options, label: label, selection: $selection, isOpen: $isOpen)
        }
    }
}

private struct WarmFieldSelectList<T: Hashable>: View {
    let options: [T]
    let label: (T) -> String
    @Binding var selection: T
    @Binding var isOpen: Bool
    @State private var hovered: T?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                    isOpen = false
                } label: {
                    Text(label(option))
                        .font(.manrope(12, .medium))
                        .foregroundStyle(option == selection ? Palette.warmInk : Palette.warmInkSoft)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(hovered == option ? Palette.warmRowBorder : Color.clear)
                }
                .buttonStyle(.plain)
                .onHover { inside in hovered = inside ? option : nil }
            }
        }
        .padding(.vertical, 4)
        .frame(minWidth: 160)
    }
}

// MARK: - Shared

/// The user-facing apps currently running, for picking one to profile.
enum RunningApps {
    static var list: [(bundleID: String, name: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { application in
                guard let bundleID = application.bundleIdentifier,
                      let name = application.localizedName else { return nil }
                return (bundleID, name)
            }
            .sorted { $0.name < $1.name }
    }
}
