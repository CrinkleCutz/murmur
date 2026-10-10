import AppKit
import SwiftUI

/// New template / Edit template — one sentence to fill in: "When I start with ___, turn what I say into ___."
///
/// Redesigned 2026-10-01 (approved mockup `build/mockups/new-template-v2.html`). The old sheet was a name, a blank
/// "What it should do" box and a phrase; the user couldn't tell what to write or what would happen. Other dictation
/// apps (VoiceInk, OpenWhispr, Monologue, MacWhisper, Superwhisper) all reduce it to a trigger plus plain words, with
/// ready-made starters; nobody asks the user to design a structure. Here: starter buttons write the description, a
/// live Try it runs the real engine (`TemplateEngine`) before anything is saved, and the rest — name, apps it's always
/// used in, a worked example — waits under More options. When the description names parts ("what I did yesterday,
/// what I'm doing today…"), Murmur works the headings out itself (`TemplateEngine.planSections`).
struct TemplateEditorSheet: View {
    @ObservedObject var app: AppDelegate
    /// The template being edited, or nil for a new one.
    let existing: NoteTemplate?
    let voiceEnabled: Bool
    let onTurnOnVoice: () -> Void
    let onDone: () -> Void
    /// The sheet's height: what it needs, within the window (set only for the command line's off-screen picture).
    var height: CGFloat = SheetMetrics.height(fitting: 712)

    @State private var phrase = ""
    @State private var describe = ""
    @State private var name = ""
    @State private var nameEdited = false
    @State private var exampleIn = ""
    @State private var exampleOut = ""
    @State private var apps: [(bundleID: String, name: String)] = []
    @State private var showMore = false
    @State private var sample = ""
    @State private var result: String?
    @State private var resultNote: String?
    @State private var trying = false
    @State private var saving = false
    /// The parts worked out for `plannedFor`, so Try it and Save don't ask twice for the same description.
    @State private var planned: [TemplateSectionSpec] = []
    @State private var plannedFor: String?
    @FocusState private var phraseFocused: Bool

    private var firstName: String { NSFullUserName().split(separator: " ").first.map(String.init) ?? "" }

    /// The starter buttons and the description each one writes — worded for Apple's small on-device model, which
    /// follows a concrete example far better than an abstract rule (a vague "friendly message" was handed back as is).
    private var starters: [(label: String, text: String)] {
        [("Bullet points", "Bullet points, one for each thing I mention, in my own words."),
         ("An email", "An email: a short subject line, a greeting, the message written to the person I mention, and a "
            + "sign-off with my name" + (firstName.isEmpty ? "." : ", \(firstName).")),
         ("A checklist", "A checklist with one \"- [ ] \" line for each thing to do, adding who and when if I say it."),
         ("Notes with headings", "Notes with a short heading for each topic I talk about, and bullet points under it."),
         ("A short message", "A short, friendly chat message written straight to the person I mention: \"tell mum we "
            + "land at six\" becomes \"We land at six\", and \"ask Tom if he can come\" becomes \"Can you come?\"."),
         ("A LinkedIn post", "A LinkedIn post: a strong first line, two or three short paragraphs, and no hashtags or "
            + "emojis I didn't say."),
         ("Translate to…", "Translate it into English, keeping my meaning and tone.")]
    }

    private var trimmedPhrase: String { phrase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    private var trimmedDescribe: String { describe.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var effectiveName: String {
        let typed = name.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? TemplateLayout.capitalized(trimmedPhrase) : typed
    }
    /// Another template already started by this phrase.
    private var phraseClash: NoteTemplate? {
        guard !trimmedPhrase.isEmpty else { return nil }
        return NoteTemplateStore.all().first { other in
            other.id != existing?.id && other.triggers.contains { $0.lowercased() == trimmedPhrase }
        }
    }
    private var canSave: Bool {
        !trimmedDescribe.isEmpty && !effectiveName.isEmpty && (!trimmedPhrase.isEmpty || !apps.isEmpty)
            && phraseClash == nil && !saving
    }

    var body: some View {
        VStack(spacing: 0) {
            ThinScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SheetHeader(
                        title: existing == nil ? "New template" : "Edit template",
                        lede: "Start a dictation with your phrase, then talk as usual. Murmur turns what you said "
                            + "into the format you describe here.")

                    VStack(alignment: .leading, spacing: 0) {
                        SheetQuestion(title: "When I start with…")
                        SheetPhraseField(text: $phrase, placeholder: "e.g. standup update", hint: "then keep talking",
                                         focused: $phraseFocused)
                            .onChange(of: phrase) { _, _ in if !nameEdited { name = "" } }
                    }
                    .padding(.top, SheetMetrics.sectionGap)

                    VStack(alignment: .leading, spacing: 0) {
                        SheetQuestion(title: "…turn what I say into")
                        SheetTextEditor(text: $describe,
                                        placeholder: "Describe the result in your own words, or pick a starter below.",
                                        minHeight: 84)
                        ChipFlow(spacing: SheetMetrics.chipGap) {
                            ForEach(starters, id: \.label) { starter in
                                SheetChip(label: starter.label, selected: trimmedDescribe == starter.text) {
                                    describe = starter.text
                                }
                            }
                        }
                        .padding(.top, SheetMetrics.helperGap)
                    }
                    .padding(.top, SheetMetrics.sectionGap)

                    tryIt.padding(.top, SheetMetrics.sectionGap)
                    moreOptions.padding(.top, SheetMetrics.sectionGap)
                }
                .padding(SheetMetrics.margin)
            }
            SheetFooter(saveTitle: saving ? "Saving…" : "Save", canSave: canSave, onCancel: onDone, onSave: save) {
                status
            }
        }
        .frame(width: SheetMetrics.width, height: height)
        .background(Palette.panel)
        .onAppear {
            load()
            if existing == nil { phraseFocused = true }
        }
    }

    // MARK: - Parts

    /// The text box and its Try it button in one container: the button in a bar under the box (it used to float at
    /// the far right of the heading, saying "Try it" a second time), the result under that.
    private var tryIt: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetQuestion(title: "Try it", aside: "say or type something to see the result")
            VStack(alignment: .leading, spacing: 0) {
                SheetTextEditor(text: $sample, placeholder: "Hold \(app.hotkey.displayName) and talk here, or type what "
                                + "you’d say…", minHeight: 60, corners: 0, bordered: false)
                Rectangle().fill(Palette.warmDivider).frame(height: 1)
                HStack(spacing: 12) {
                    Text("Nothing is pasted or saved while you try.")
                        .font(.manrope(11.5))
                        .foregroundStyle(Palette.warmInkFaint)
                    Spacer(minLength: 8)
                    Button(action: runTry) {
                        Text(trying ? "Trying…" : "Try it")
                            .font(.manrope(12, .semibold))
                            .foregroundStyle(canTry ? .white : Palette.warmInkFainter)
                            .padding(.horizontal, 14)
                            .frame(height: SheetMetrics.smallButtonHeight)
                            .background(canTry ? Palette.navActivePill : Palette.panel,
                                        in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                                .strokeBorder(canTry ? Color.clear : Palette.warmDivider, lineWidth: 1))
                    }
                    .buttonStyle(PressScaleButtonStyle(scale: 0.97))
                    .disabled(!canTry)
                }
                .padding(.leading, 12)
                .padding(.trailing, 8)
                .padding(.vertical, 8)
                .background(Palette.warmRowBorder)
                if let result {
                    Rectangle().fill(Palette.warmDivider).frame(height: 1)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("RESULT").font(.manrope(10.5, .bold)).kerning(0.5).foregroundStyle(Palette.trendUp)
                        Text(result)
                            .font(.manrope(13))
                            .lineSpacing(2)
                            .foregroundStyle(Palette.warmInk)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Palette.panel)
                }
                if let resultNote {
                    Rectangle().fill(Palette.warmDivider).frame(height: 1)
                    Text(resultNote)
                        .font(.manrope(12))
                        .foregroundStyle(Palette.warmInkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Palette.panel)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.warmDivider, lineWidth: 1))
        }
    }

    private var canTry: Bool {
        !trying && !trimmedDescribe.isEmpty && !sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && app.rewriteEngine.isAvailable
    }

    private var moreOptions: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Palette.warmDivider).frame(height: 1)
            Button { withAnimation(.murmurEase(0.18)) { showMore.toggle() } } label: {
                HStack(spacing: 8) {
                    MurmurIconView(icon: .caret)
                        .frame(width: 9, height: 9)
                        .rotationEffect(.degrees(showMore ? 90 : 0))
                    Text("More options").font(.manrope(13, .semibold))
                }
                .foregroundStyle(Palette.warmInkSoft)
                .frame(height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showMore {
                VStack(alignment: .leading, spacing: 20) {
                    // Each label is centred on its field's first line: the 36 pt name field, the 28 pt app buttons.
                    optionRow("Name", lineHeight: SheetMetrics.fieldHeight,
                              note: nameEdited ? nil : "Filled in from your phrase. Change it if you like.") {
                        // Shows the name it will save under, in full ink — the one from the phrase until it's changed.
                        SheetTextField(
                            text: Binding(get: { effectiveName }, set: { typed in
                                let auto = TemplateLayout.capitalized(trimmedPhrase)
                                nameEdited = !typed.isEmpty && typed != auto
                                name = nameEdited ? typed : ""
                            }),
                            placeholder: "Standup update")
                    }
                    optionRow("Always use in", lineHeight: SheetMetrics.smallButtonHeight,
                              note: "In these apps it’s used on every dictation, no phrase needed.") {
                        appPicker
                    }
                    exampleRow
                }
                .padding(.top, 4)
            }
        }
    }

    private func optionRow<Content: View>(_ label: String, lineHeight: CGFloat, note: String?,
                                          @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(label)
                .font(.manrope(13))
                .foregroundStyle(Palette.warmInkSoft)
                .frame(width: 112, height: lineHeight, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                content()
                if let note { SheetNote(text: note) }
            }
        }
    }

    /// The worked example: two boxes of the same size side by side, the arrow centred between them, the label on the
    /// captions' line.
    private var exampleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Example").font(.manrope(13)).foregroundStyle(Palette.warmInkSoft)
                Text("optional").font(.manrope(11.5)).foregroundStyle(Palette.warmInkFainter)
            }
            .frame(width: 112, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 0) {
                        exampleCaption("YOU SAY")
                        Color.clear.frame(width: 24, height: 1)
                        exampleCaption("YOU WANT")
                    }
                    HStack(spacing: 0) {
                        SheetTextEditor(text: $exampleIn, height: 172)
                        Text("→")
                            .font(.manrope(13))
                            .foregroundStyle(Palette.warmInkFainter)
                            .frame(width: 24)
                        SheetTextEditor(text: $exampleOut, height: 172, fill: Palette.panel)
                    }
                }
                SheetNote(text: "The surest way to get exactly the layout you want.")
            }
        }
    }

    private func exampleCaption(_ text: String) -> some View {
        Text(text)
            .font(.manrope(10.5, .bold))
            .kerning(0.5)
            .foregroundStyle(Palette.warmInkFaint)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var appPicker: some View {
        ChipFlow(spacing: SheetMetrics.chipGap) {
            ForEach(apps, id: \.bundleID) { chosen in
                HStack(spacing: 7) {
                    if let icon = appIcon(chosen.bundleID) {
                        Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                    }
                    Text(chosen.name).font(.manrope(12.5))
                    Button { apps.removeAll { $0.bundleID == chosen.bundleID } } label: {
                        Text("×").font(.manrope(13)).foregroundStyle(Palette.warmInkFaint)
                    }
                    .buttonStyle(.plain)
                    .help("Remove \(chosen.name)")
                }
                .foregroundStyle(Palette.warmInk)
                .padding(.leading, 8)
                .padding(.trailing, 10)
                .frame(height: SheetMetrics.smallButtonHeight)
                .background(Palette.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.warmDivider, lineWidth: 1))
            }
            Menu {
                let chosen = Set(apps.map(\.bundleID))
                ForEach(RunningApps.list.filter { !chosen.contains($0.bundleID) && $0.bundleID != Bundle.main.bundleIdentifier },
                        id: \.bundleID) { candidate in
                    Button(candidate.name) { apps.append(candidate) }
                }
            } label: {
                Text("+ Add app")
                    .font(.manrope(12.5, .semibold))
                    .foregroundStyle(Palette.sunset)
                    .padding(.horizontal, 12)
                    .frame(height: SheetMetrics.smallButtonHeight)
                    .background(Palette.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.warmDivider, lineWidth: 1))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private func appIcon(_ bundleID: String) -> NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    /// What the template still needs to work, or how it works — one line, so it never squeezes in next to Cancel.
    @ViewBuilder private var status: some View {
        if let clash = phraseClash {
            SheetStatus(text: "\u{201c}\(trimmedPhrase)\u{201d} already starts \(clash.name).", warn: true)
        } else if !trimmedPhrase.isEmpty, !voiceEnabled {
            HStack(spacing: 8) {
                SheetStatus(text: "Saying a phrase is off.", warn: true)
                Button("Turn on", action: onTurnOnVoice)
                    .buttonStyle(.plain)
                    .font(.manrope(12, .semibold))
                    .foregroundStyle(Palette.sunset)
            }
        } else if trimmedPhrase.isEmpty, apps.isEmpty {
            SheetStatus(text: "Add a phrase or an app so it can start.", warn: true)
        } else {
            SheetStatus(text: "Works when you dictate in English or Latvian.")
        }
    }

    // MARK: - Actions

    private func load() {
        guard let existing else { return }
        phrase = existing.voiceTrigger
        describe = existing.instructions
        name = existing.name
        nameEdited = TemplateLayout.capitalized(existing.voiceTrigger) != existing.name
        exampleIn = existing.exampleInput ?? ""
        exampleOut = existing.exampleOutput ?? ""
        if let sections = existing.sections { planned = sections; plannedFor = existing.instructions }
        apps = AppProfileStore.profiles.compactMap { bundleID, profile in
            profile.templateID == existing.id ? (bundleID, profile.appName) : nil
        }.sorted { $0.name < $1.name }
        showMore = !apps.isEmpty || existing.exampleInput != nil
    }

    /// The template as the sheet stands, with the parts its description names.
    private func draft() async -> NoteTemplate {
        if plannedFor != trimmedDescribe {
            planned = await TemplateEngine.planSections(for: trimmedDescribe)
            plannedFor = trimmedDescribe
        }
        let exampleInput = exampleIn.trimmingCharacters(in: .whitespacesAndNewlines)
        let exampleOutput = exampleOut.trimmingCharacters(in: .whitespacesAndNewlines)
        return NoteTemplate(
            id: existing?.id ?? UUID(), name: effectiveName, icon: "doc.text", instructions: trimmedDescribe,
            voiceTrigger: trimmedPhrase,
            exampleInput: exampleInput.isEmpty ? nil : exampleInput,
            exampleOutput: exampleOutput.isEmpty ? nil : exampleOutput,
            sections: planned.isEmpty ? nil : planned)
    }

    private func runTry() {
        trying = true
        result = nil
        resultNote = nil
        let text = sample.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { trying = false }
            let template = await draft()
            let language = TemplateLanguage.from(localeIdentifier: Settings.localeIdentifier) ?? .english
            do {
                result = try await TemplateEngine.apply(template, to: text, extraInstructions: nil, language: language)
            } catch let failure as TemplateEngine.Failure {
                resultNote = failure.localizedDescription + " Your words would go in as you said them."
            } catch {
                resultNote = "It couldn't be tried: \(error.localizedDescription)"
            }
        }
    }

    private func save() {
        saving = true
        Task {
            let template = await draft()
            var custom = NoteTemplateStore.loadCustom()
            if let index = custom.firstIndex(where: { $0.id == template.id }) {
                custom[index] = template
            } else {
                custom.append(template)
            }
            NoteTemplateStore.saveCustom(custom)
            // "Always use in": the same setting as App Profiles' template, kept in step both ways.
            var profiles = AppProfileStore.profiles
            let chosen = Set(apps.map(\.bundleID))
            for (bundleID, profile) in profiles where profile.templateID == template.id && !chosen.contains(bundleID) {
                profiles[bundleID]?.templateID = nil
            }
            for chosenApp in apps {
                var profile = profiles[chosenApp.bundleID] ?? AppProfile(appName: chosenApp.name)
                profile.templateID = template.id
                profiles[chosenApp.bundleID] = profile
            }
            AppProfileStore.profiles = profiles
            saving = false
            onDone()
        }
    }
}

/// Lays its children out left to right, wrapping onto new lines — the starter buttons and the chosen apps.
struct ChipFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews, width: width)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        var current: (indices: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = ([index], size.width, size.height)
            } else {
                current = (current.indices + [index], needed, max(current.height, size.height))
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
