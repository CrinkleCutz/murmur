import AppKit
import SwiftUI

// MARK: - Templates
//
// The voice toggle in a white card, a card grid (each card shows what the
// template produces and its spoken phrase; selection = sunset outline, as
// on Style), and one "Try it on a transcript" card that names the template
// it will use and holds its own result. The "New template" sheet uses the
// warm sheet style App Profiles' editor has.

struct TemplatesPage: View {
    @ObservedObject var app: AppDelegate
    @Binding var page: Page
    @State private var inputText = ""
    @State private var result = ""
    /// A red line, never a result — the result has a Paste button.
    @State private var errorText: String?
    @State private var selectedTemplateID: UUID?
    @State private var running = false
    @State private var templates: [NoteTemplate] = NoteTemplateStore.all()
    @State private var showingEditor = false
    /// The template the editor sheet opens on; nil for a new one.
    @State private var editingTemplate: NoteTemplate?
    @State private var voiceTemplatesEnabled = Settings.voiceTemplatesEnabled

    /// The card grid's width, so it can drop from three columns to two
    /// before the cards get too narrow (same rule as Style's tone grid).
    @State private var gridWidth: CGFloat = 0

    /// One-line descriptions of what each built-in actually produces —
    /// the card previously showed only a name.
    private func blurb(for template: NoteTemplate) -> String {
        switch template.name {
        case "Meeting Notes": return "Attendees, key points, decisions, action items"
        case "Summary": return "One short paragraph, about a quarter the length"
        case "Email Draft": return "Subject, greeting, body, sign-off"
        case "Task List": return "Every action item as a checkbox"
        case "Blog Post": return "Opening, subheadings, closing"
        // The user's own: their description, as they wrote it.
        default: return template.isBuiltIn ? "" : String(template.instructions.prefix(90))
        }
    }

    /// The phrase to show on a card: the one for the language being dictated (a built-in's Latvian phrase).
    private func shownTrigger(for template: NoteTemplate) -> String {
        if TemplateLanguage.from(localeIdentifier: Settings.localeIdentifier) == .latvian,
           let latvian = NoteTemplate.latvianTriggers[template.name]?.first, template.isBuiltIn {
            return latvian
        }
        return template.voiceTrigger
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

                    applyByVoiceCard
                        .padding(.top, 24)

                    if let note = app.rewriteEngine.availabilityNote {
                        tipBanner(note).padding(.top, 12)
                    }

                    Text("YOUR TEMPLATES")
                        .font(.manrope(10, .semibold))
                        .kerning(0.9)
                        .foregroundStyle(Palette.warmInkSoft)
                        .padding(.top, 24)
                        .padding(.bottom, 10)
                    templateGrid

                    tryItCard
                        .padding(.top, 24)

                    relatedLink
                        .padding(.top, 16)
                }
            }
        }
        .onAppear(perform: consumePendingText)
        .onChange(of: app.pendingTemplateText) { _, _ in consumePendingText() }
        .sheet(isPresented: $showingEditor) {
            TemplateEditorSheet(
                app: app, existing: editingTemplate, voiceEnabled: voiceTemplatesEnabled,
                onTurnOnVoice: { voiceTemplatesEnabled = true },
                onDone: {
                    showingEditor = false
                    templates = NoteTemplateStore.all()
                })
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Templates")
                .font(.manrope(22, .medium))
                .tracking(-0.33)
                .foregroundStyle(Palette.warmInk)
            // The old tip card folded into the subtitle.
            Text("Reshape a dictation into a set structure. Say a template's phrase first, then keep "
                 + "talking — Murmur removes the phrase and reshapes what follows.")
                .font(.manrope(12.5))
                .foregroundStyle(Palette.warmInkFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    /// A white card like every other setting on these pages (it used to
    /// float unboxed on the glass).
    private var applyByVoiceCard: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Apply by voice")
                    .font(.manrope(13, .semibold))
                    .foregroundStyle(Palette.warmInk)
                Text("Saying a template's phrase at the start of a dictation reshapes it automatically.")
                    .font(.manrope(12.5))
                    .foregroundStyle(Palette.warmInkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            WarmToggle(isOn: $voiceTemplatesEnabled)
                .onChange(of: voiceTemplatesEnabled) { _, newValue in
                    Settings.voiceTemplatesEnabled = newValue
                }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// Three columns (two below 660pt), rows of equal height — the same
    /// grid as Style's tones, with the "New template" tile last.
    private var templateGrid: some View {
        let columns = gridWidth > 0 && gridWidth < 660 ? 2 : 3
        let items: [NoteTemplate?] = templates.map { Optional($0) } + [nil]
        let rows = stride(from: 0, to: items.count, by: columns).map {
            Array(items[$0..<min($0 + columns, items.count)])
        }
        return VStack(spacing: 12) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 12) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, item in
                        if let template = item {
                            templateCard(template)
                        } else {
                            newTemplateCard
                        }
                    }
                    ForEach(0..<(columns - row.count), id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
    }

    private func templateCard(_ template: NoteTemplate) -> some View {
        TemplateCard(
            template: template,
            blurb: blurb(for: template),
            trigger: shownTrigger(for: template),
            selected: selectedTemplateID == template.id,
            voiceEnabled: voiceTemplatesEnabled,
            onSelect: { withAnimation(.murmurEase(0.15)) { selectedTemplateID = template.id } },
            onEdit: template.isBuiltIn ? nil : {
                editingTemplate = template
                showingEditor = true
            },
            onDelete: template.isBuiltIn ? nil : { deleteCustomTemplate(template) })
    }

    /// A quiet tile with a hairline border, not the old dashed outline.
    private var newTemplateCard: some View {
        NewTemplateTile {
            editingTemplate = nil
            showingEditor = true
        }
    }

    private var selectedTemplate: NoteTemplate? {
        templates.first { $0.id == selectedTemplateID }
    }

    /// The manual tool, in one card: the header says which template it will
    /// use, the button shows its real state (grey until there's a
    /// transcript and a template, sunset when it can run), and the result
    /// lands inside the same card — not under separate floating
    /// "Transcript"/"Result" headings.
    private var tryItCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .lastTextBaseline) {
                Text("Try it on a transcript")
                    .font(.manrope(13, .semibold))
                    .foregroundStyle(Palette.warmInk)
                Spacer()
                Text(selectedTemplate.map { "reshapes with \($0.name)" } ?? "pick a template above")
                    .font(.manrope(11.5))
                    .foregroundStyle(Palette.warmInkFaint)
            }
            TextEditor(text: $inputText)
                .font(.manrope(13))
                .foregroundStyle(Palette.warmInk)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 90)
                .background(Palette.warmRowBorder, in: RoundedRectangle(cornerRadius: Radius.sm))
                .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Palette.warmDivider, lineWidth: 1))
                .overlay(alignment: .topLeading) {
                    if inputText.isEmpty {
                        Text("Paste or dictate a transcript, or send one in from History…")
                            .font(.manrope(13))
                            .italic()
                            .foregroundStyle(Palette.warmInkFaint)
                            .padding(.top, 8)
                            .padding(.leading, 13)
                            .allowsHitTesting(false)
                    }
                }
                .padding(.top, 12)
            HStack(spacing: 12) {
                Button(action: generate) {
                    HStack(spacing: 7) {
                        if running {
                            ProgressView().controlSize(.small)
                        } else {
                            MurmurIconView(icon: .trans).frame(width: 13, height: 13)
                        }
                        Text(running ? "Reshaping…" : "Reshape")
                            .font(.manrope(13, .semibold))
                    }
                    .foregroundStyle(canGenerate ? .white : Palette.warmInkFainter)
                    .padding(.horizontal, 16)
                    .frame(height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.md)
                            .fill(canGenerate ? Palette.sunset : Palette.warmRowBorder))
                    .animation(.murmurEase(0.15), value: canGenerate)
                }
                .buttonStyle(PressScaleButtonStyle(scale: 0.97))
                .disabled(!canGenerate)
                Spacer()
                if !inputText.isEmpty {
                    Button("Clear") { inputText = ""; result = ""; errorText = nil }
                        .buttonStyle(.plain)
                        .font(.manrope(12.5, .medium))
                        .foregroundStyle(Palette.warmInkSoft)
                }
            }
            .padding(.top, 12)
            if let errorText {
                Text(errorText)
                    .font(.manrope(12))
                    .foregroundStyle(Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
            if !result.isEmpty {
                Rectangle().fill(Palette.warmRowBorder).frame(height: 1).padding(.top, 18)
                HStack(alignment: .lastTextBaseline) {
                    Text("RESULT")
                        .font(.manrope(10, .semibold))
                        .kerning(0.9)
                        .foregroundStyle(Palette.warmInkSoft)
                    Spacer()
                    IconButton(icon: .copy, hoverFill: Palette.hoverWash, help: "Copy") {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(result, forType: .string)
                    }
                    IconButton(icon: .arrowRight, hoverFill: Palette.hoverWash,
                               help: "Paste at cursor in the app behind Murmur") {
                        TextInserter.insert(result)
                    }
                }
                .padding(.top, 12)
                Text(result)
                    .font(.manrope(13.5))
                    .lineSpacing(3)
                    .foregroundStyle(Palette.warmInk)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var relatedLink: some View {
        HStack(spacing: 4) {
            Text("Want a template applied automatically in one app?")
                .font(.manrope(12))
                .foregroundStyle(Palette.warmInkSoft)
            Button { page = .appProfiles } label: {
                Text("App Profiles")
                    .font(.manrope(12, .medium))
                    .foregroundStyle(Palette.sunsetDeep)
            }
            .buttonStyle(.plain)
            Text("set it there, no trigger phrase needed.")
                .font(.manrope(12))
                .foregroundStyle(Palette.warmInkSoft)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var canGenerate: Bool {
        !running && !inputText.isEmpty && selectedTemplateID != nil
            && app.rewriteEngine.isAvailable
    }

    private func consumePendingText() {
        guard let pending = app.pendingTemplateText else { return }
        inputText = pending
        result = ""
        errorText = nil
        app.pendingTemplateText = nil
    }

    private func deleteCustomTemplate(_ template: NoteTemplate) {
        var custom = NoteTemplateStore.loadCustom()
        custom.removeAll { $0.id == template.id }
        NoteTemplateStore.saveCustom(custom)
        templates = NoteTemplateStore.all()
        if selectedTemplateID == template.id { selectedTemplateID = nil }
    }

    private func generate() {
        guard let template = templates.first(where: { $0.id == selectedTemplateID }) else { return }
        running = true
        result = ""
        errorText = nil
        Task {
            defer { running = false }
            // The same path as a dictation (`TemplateEngine`), so what this box shows is what a dictation gets.
            do {
                result = try await TemplateEngine.apply(template, to: inputText, extraInstructions: nil)
            } catch let failure as TemplateEngine.Failure {
                errorText = failure.localizedDescription
            } catch {
                errorText = "\(template.name) failed: \(error.localizedDescription)"
            }
        }
    }

}

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

/// White, like Style's tone cards: selected = sunset outline + check (the
/// old solid-black selection was a second selection style in the app).
/// The spoken phrase sits at the bottom with a mic, faded while Apply by
/// voice is off.
private struct TemplateCard: View {
    let template: NoteTemplate
    let blurb: String
    let trigger: String
    let selected: Bool
    let voiceEnabled: Bool
    let onSelect: () -> Void
    let onEdit: (() -> Void)?
    let onDelete: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text(template.name)
                        .font(.manrope(13, .semibold))
                        .foregroundStyle(Palette.warmInk)
                    Spacer(minLength: 4)
                    if let onEdit, hovering {
                        IconButton(icon: .edit, size: 22, iconSize: 11, hoverFill: Palette.hoverWash,
                                   help: "Edit", action: onEdit)
                    }
                    if let onDelete, hovering {
                        IconButton(icon: .trash, size: 22, iconSize: 11, hoverFill: Palette.hoverWash,
                                   help: "Delete", action: onDelete)
                    }
                    if selected {
                        ZStack {
                            Circle().fill(Palette.sunset)
                            MurmurIconView(icon: .check)
                                .frame(width: 9, height: 9)
                                .foregroundStyle(.white)
                        }
                        .frame(width: 18, height: 18)
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(minHeight: 22)
                if !blurb.isEmpty {
                    Text(blurb)
                        .font(.manrope(12))
                        .foregroundStyle(Palette.warmInkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 3)
                }
                Spacer(minLength: 10)
                if !trigger.isEmpty {
                    HStack(spacing: 5) {
                        MurmurIconView(icon: .mic).frame(width: 11, height: 11)
                        Text("\u{201c}\(trigger)\u{201d}")
                            .font(.manrope(11.5, .medium))
                    }
                    .foregroundStyle(Palette.sunsetDeep)
                    .opacity(voiceEnabled ? 1 : 0.35)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .frame(minHeight: 104)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(selected ? Palette.sunset
                                  : (hovering ? Palette.warmDivider : Palette.warmRowBorder),
                                  lineWidth: selected ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressScaleButtonStyle(scale: 0.98))
        .onHover { hovering = $0 }
        .animation(.murmurEase(0.12), value: hovering)
    }
}

private struct NewTemplateTile: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                MurmurIconView(icon: .plus).frame(width: 13, height: 13)
                Text("New template").font(.manrope(13, .semibold))
            }
            .foregroundStyle(hovering ? Palette.warmInk : Palette.warmInkSoft)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(minHeight: 104)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(hovering ? Palette.warmDivider : Palette.warmRowBorder, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressScaleButtonStyle(scale: 0.98))
        .onHover { hovering = $0 }
        .animation(.murmurEase(0.12), value: hovering)
    }
}
