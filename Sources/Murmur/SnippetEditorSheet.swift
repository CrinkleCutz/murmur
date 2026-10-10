import AppKit
import SwiftUI

/// New snippet / Edit snippet: "When I say ___, paste this."
///
/// Built 2026-10-01 from the approved mockup `build/mockups/snippets-v2.html`. It replaced an inline row — a "Say
/// this…" field, an unlabelled box and two tiny ✓/✕ buttons — that never showed what would actually be pasted. Same
/// shape as New template (`SheetParts`): the phrase, the text, buttons that put in today's date / the time / what was
/// copied, a live preview worked out by the real `SnippetStore` (not an imitation of it), and a warning when the
/// phrase is a word the user would say anyway.
struct SnippetEditorSheet: View {
    /// The snippet being edited, or nil for a new one.
    let existing: Snippet?
    /// A starter's phrase and text, already filled in.
    var starter: (trigger: String, expansion: String)?
    let onDone: () -> Void
    /// The sheet's height: what it needs, within the window.
    var height: CGFloat = SheetMetrics.height(fitting: 660)

    @State private var phrase = ""
    @State private var expansion = ""
    @FocusState private var phraseFocused: Bool

    private var trimmedPhrase: String { phrase.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasText: Bool { !expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Another snippet already started by this phrase.
    private var snippetClash: Snippet? {
        let key = Self.key(trimmedPhrase)
        guard !key.isEmpty else { return nil }
        return SnippetStore.load().first { $0.id != existing?.id && Self.key($0.trigger) == key }
    }
    /// A template already started by this phrase — saying it would do both.
    private var templateClash: NoteTemplate? {
        let key = Self.key(trimmedPhrase)
        guard !key.isEmpty else { return nil }
        return NoteTemplateStore.all().first { template in template.triggers.contains { Self.key($0) == key } }
    }
    private var warning: String? { SnippetStore.accidentalTriggerWarning(for: trimmedPhrase) }
    private var canSave: Bool { !trimmedPhrase.isEmpty && hasText && snippetClash == nil && templateClash == nil }

    /// A phrase as matching sees it: lower case, words only.
    private static func key(_ phrase: String) -> String {
        phrase.lowercased().split { !($0.isLetter || $0.isNumber) }.joined(separator: " ")
    }

    var body: some View {
        VStack(spacing: 0) {
            ThinScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SheetHeader(
                        title: existing == nil ? "New snippet" : "Edit snippet",
                        lede: "Say a short phrase anywhere in a dictation, and Murmur pastes your saved text in its "
                            + "place, exactly as you wrote it.")

                    VStack(alignment: .leading, spacing: 0) {
                        SheetQuestion(title: "When I say…")
                        SheetPhraseField(text: $phrase, placeholder: "e.g. my calendar link",
                                         hint: "anywhere in a sentence", focused: $phraseFocused)
                        if let warning {
                            SheetNote(text: warning, warn: true)
                        } else {
                            SheetNote(text: "Pick words you wouldn’t say by accident: \u{201c}my calendar link\u{201d}, "
                                      + "not \u{201c}calendar\u{201d}.")
                        }
                    }
                    .padding(.top, SheetMetrics.sectionGap)

                    VStack(alignment: .leading, spacing: 0) {
                        SheetQuestion(title: "…paste this", trailingAside: "exactly as written")
                        SheetTextEditor(text: $expansion, placeholder: "A link, an address, a sign-off…", minHeight: 84)
                        HStack(spacing: SheetMetrics.chipGap) {
                            Text("Insert").font(.manrope(12)).foregroundStyle(Palette.warmInkFaint).padding(.trailing, 2)
                            ForEach(SnippetStore.Value.allCases, id: \.token) { value in
                                SheetChip(label: value.label, leadingPlus: true) { insert(value) }
                            }
                        }
                        .padding(.top, SheetMetrics.helperGap)
                    }
                    .padding(.top, SheetMetrics.sectionGap)

                    VStack(alignment: .leading, spacing: 0) {
                        SheetQuestion(title: "Preview")
                        preview
                    }
                    .padding(.top, SheetMetrics.sectionGap)
                }
                .padding(SheetMetrics.margin)
            }
            SheetFooter(saveTitle: "Save", canSave: canSave, onCancel: onDone, onSave: save) { status }
        }
        .frame(width: SheetMetrics.width, height: height)
        .background(Palette.panel)
        .onAppear {
            phrase = existing?.trigger ?? starter?.trigger ?? ""
            expansion = existing?.expansion ?? starter?.expansion ?? ""
            phraseFocused = true
        }
    }

    // MARK: - Preview

    /// What a dictation with the phrase in it says, and what gets pasted — worked out by `SnippetStore` itself.
    private var preview: some View {
        let sample = previewSample
        return VStack(spacing: 0) {
            previewRow("YOU SAY", sample.said, fill: Palette.warmRowBorder)
            Rectangle().fill(Palette.warmDivider).frame(height: 1)
            previewRow("PASTED", sample.pasted, fill: Palette.panel)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.warmDivider, lineWidth: 1))
    }

    private func previewRow(_ label: String, _ text: AttributedString, fill: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.manrope(10.5, .bold))
                .kerning(0.5)
                .foregroundStyle(Palette.warmInkFaint)
                .frame(width: 64, alignment: .leading)
            Text(text)
                .font(.manrope(13))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(fill)
    }

    private var previewSample: (said: AttributedString, pasted: AttributedString) {
        func plain(_ text: String, _ color: Color = Palette.warmInk) -> AttributedString {
            var part = AttributedString(text)
            part.foregroundColor = color
            return part
        }
        guard !trimmedPhrase.isEmpty else {
            return (plain("Type a phrase to see it in a sentence.", Palette.warmInkFainter),
                    plain("Then the text that goes in its place.", Palette.warmInkFainter))
        }
        // A signature reads naturally after a sentence (capitalised, as the formatter would); anything else in the
        // middle of one.
        let multiline = expansion.contains("\n")
        let (before, after) = multiline ? ("Thanks again. ", ".") : ("Here’s ", ", as promised.")
        let spoken = multiline ? trimmedPhrase.prefix(1).uppercased() + trimmedPhrase.dropFirst() : trimmedPhrase
        var said = plain(before)
        var phrasePart = AttributedString(spoken)
        phrasePart.foregroundColor = Palette.sunset
        phrasePart.font = .manrope(13, .semibold)
        said += phrasePart + plain(after)
        guard hasText else { return (said, plain("Type the text to paste to see it here.", Palette.warmInkFainter)) }

        let draft = Snippet(trigger: trimmedPhrase, expansion: expansion)
        let held = SnippetStore.hold(in: before + spoken + after, snippets: [draft],
                                     clipboard: { "(what you copied)" }, recordUse: false)
        let result = held.restore(held.text).text
        let filled = held.slots.first?.text ?? ""
        guard !filled.isEmpty, let range = result.range(of: filled) else { return (said, plain(result)) }
        var inserted = AttributedString(filled)
        inserted.foregroundColor = Palette.trendUp
        inserted.backgroundColor = Palette.trendUp.opacity(0.10)
        return (said, plain(String(result[..<range.lowerBound])) + inserted + plain(String(result[range.upperBound...])))
    }

    // MARK: - Footer

    @ViewBuilder private var status: some View {
        if let clash = snippetClash {
            SheetStatus(text: "\u{201c}\(clash.trigger)\u{201d} is already a snippet.", warn: true)
        } else if let template = templateClash {
            SheetStatus(text: "\u{201c}\(trimmedPhrase)\u{201d} already starts the \(template.name) template.", warn: true)
        } else if trimmedPhrase.isEmpty || !hasText {
            SheetStatus(text: "Add the phrase and the text to paste.", warn: true)
        } else {
            SheetStatus(text: "Works in every app and every language.")
        }
    }

    // MARK: - Actions

    /// Puts a value's words at the end of the text, on the same line, with a space before it.
    private func insert(_ value: SnippetStore.Value) {
        if expansion.isEmpty || expansion.last?.isWhitespace == true {
            expansion += value.token
        } else {
            expansion += " " + value.token
        }
    }

    private func save() {
        guard canSave else { return }
        // Spaces or a blank line left at either end would be pasted too.
        let text = expansion.trimmingCharacters(in: .whitespacesAndNewlines)
        var all = SnippetStore.load()
        if let existing, let index = all.firstIndex(where: { $0.id == existing.id }) {
            all[index].trigger = trimmedPhrase
            all[index].expansion = text
        } else {
            all.append(Snippet(trigger: trimmedPhrase, expansion: text))
        }
        SnippetStore.save(all)
        onDone()
    }
}
