import SwiftUI

// MARK: - Snippets
//
// Same structure as the Dictionary (it's the same shape of page — you say
// one thing, Murmur writes another): an intro card whose examples are real
// starting points when empty; otherwise search + "Add snippet" and a list
// with "YOU SAY / MURMUR PASTES" columns and use counts. Adding and editing
// open the New snippet sheet (`SnippetEditorSheet`), which replaced the
// inline row on 2026-10-01. White cards only — the orange hero card is
// Home's alone.

struct SnippetsPage: View {
    @Binding var page: Page
    @State private var snippets: [Snippet] = []
    @State private var searchText = ""
    @State private var editor: EditorTarget?

    /// What the sheet opens on: a saved snippet, a starter, or a blank one.
    private struct EditorTarget: Identifiable {
        let id = UUID()
        var existing: Snippet?
        var starter: (trigger: String, expansion: String)?
    }

    /// The starters on the empty page: things typed the same way every time. Plain words a recognizer hears
    /// reliably ("my calendar link", not a brand like "calendly", which came back as "calendar day"). The old
    /// "tighten this up" (an instruction) and "standup update" (blanks to fill in) went: an instruction is what the
    /// clean-up used to delete, and blanks are what Templates are for.
    private static var starters: [(trigger: String, expansion: String)] {
        let firstName = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        return [
            ("my calendar link", "https://cal.com/yourname/30min"),
            ("my address", "14 Elm Road\nLondon N1 7GU"),
            ("my sign-off", "Best regards," + (firstName.isEmpty ? "" : "\n\(firstName)")),
            ("today’s date", SnippetStore.Value.date.token),
        ]
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
                    if snippets.isEmpty {
                        introCard
                            .padding(.top, 24)
                    } else {
                        toolbar
                            .padding(.top, 24)
                        listCard
                            .padding(.top, 16)
                    }
                    relatedLink
                        .padding(.top, 16)
                }
            }
        }
        .onAppear { snippets = SnippetStore.load() }
        .sheet(item: $editor) { target in
            SnippetEditorSheet(existing: target.existing, starter: target.starter) {
                editor = nil
                snippets = SnippetStore.load()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Snippets")
                .font(.manrope(22, .medium))
                .tracking(-0.33)
                .foregroundStyle(Palette.warmInk)
            // The old tip card (say the trigger exactly…) folded in here.
            Text("Say a phrase anywhere in a dictation, and Murmur pastes your saved text in its place.")
                .font(.manrope(12.5))
                .foregroundStyle(Palette.warmInkFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The empty page: one white card (the orange hero card is Home's
    /// alone) whose examples are real starting points — "Use" opens the
    /// sheet already filled in, to adjust before saving.
    private var introCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Say it once, never type it again")
                .font(.manrope(15, .semibold))
                .foregroundStyle(Palette.warmInk)
            Text("Links, addresses, a sign-off: anything you’d otherwise type the same way every time. Start from "
                 + "one of these. You can edit it before it’s saved.")
                .font(.manrope(12.5))
                .lineSpacing(2)
                .foregroundStyle(Palette.warmInkSoft)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 0) {
                SnippetColumnLabels()
                ForEach(Array(Self.starters.enumerated()), id: \.offset) { index, starter in
                    SnippetRow(
                        trigger: starter.trigger, expansion: starter.expansion, useCount: 0,
                        isFirst: index == 0,
                        trailing: .use { editor = EditorTarget(starter: starter) })
                }
            }
            .padding(.top, 18)
            Button { editor = EditorTarget() } label: {
                PrimaryActionLabel(title: "Add your own")
            }
            .buttonStyle(PressScaleButtonStyle(scale: 0.97))
            .padding(.top, 20)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// Search (placeholder carries the count; only once there's something
    /// to search) and the primary add action.
    private var toolbar: some View {
        HStack(spacing: 12) {
            if !snippets.isEmpty {
                HStack(spacing: 8) {
                    MurmurIconView(icon: .search)
                        .frame(width: 13, height: 13)
                        .foregroundStyle(Palette.warmInkFaint)
                    TextField("Search \(snippets.count) \(snippets.count == 1 ? "snippet" : "snippets")",
                              text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.manrope(12.5))
                        .foregroundStyle(Palette.warmInk)
                }
                .padding(.horizontal, 10)
                .frame(width: 240, height: 32)
                .background(Palette.panel, in: RoundedRectangle(cornerRadius: Radius.sm))
                .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Palette.warmRowBorder, lineWidth: 1))
            }
            Spacer()
            Button { editor = EditorTarget() } label: {
                PrimaryActionLabel(title: "Add snippet")
            }
            .buttonStyle(PressScaleButtonStyle(scale: 0.97))
        }
    }

    private var listCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SnippetColumnLabels()
            if visible.isEmpty && !snippets.isEmpty {
                Text("No snippets match \u{201c}\(searchText)\u{201d}.")
                    .font(.manrope(12.5))
                    .italic()
                    .foregroundStyle(Palette.warmInkFaint)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            }
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, snippet in
                SnippetRow(
                    trigger: snippet.trigger, expansion: snippet.expansion, useCount: snippet.useCount,
                    isFirst: index == 0,
                    trailing: .edit(
                        onEdit: { editor = EditorTarget(existing: snippet) },
                        onDelete: {
                            snippets.removeAll { $0.id == snippet.id }
                            save()
                        }))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var relatedLink: some View {
        HStack(spacing: 4) {
            Text("Need to reshape what you said, not paste fixed text?")
                .font(.manrope(12))
                .foregroundStyle(Palette.warmInkSoft)
            Button { page = .templates } label: {
                Text("Templates")
                    .font(.manrope(12, .medium))
                    .foregroundStyle(Palette.sunsetDeep)
            }
            .buttonStyle(.plain)
            Text("do that.")
                .font(.manrope(12))
                .foregroundStyle(Palette.warmInkSoft)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var visible: [Snippet] {
        let term = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !term.isEmpty else { return snippets }
        return snippets.filter {
            $0.trigger.lowercased().contains(term) || $0.expansion.lowercased().contains(term)
        }
    }

    private func save() {
        SnippetStore.save(snippets.filter {
            !$0.trigger.trimmingCharacters(in: .whitespaces).isEmpty
        })
    }
}

/// "YOU SAY" / "MURMUR PASTES" over the two columns — the Dictionary's
/// label style.
private struct SnippetColumnLabels: View {
    var body: some View {
        HStack(spacing: 16) {
            Text("YOU SAY").frame(width: 150, alignment: .leading)
            Color.clear.frame(width: 12, height: 1)
            Text("MURMUR PASTES").frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: 60, height: 1)
        }
        .font(.manrope(10, .semibold))
        .kerning(0.9)
        .foregroundStyle(Palette.warmInkSoft)
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
    }
}

/// Trigger (in the accent — it's the thing you say) → what gets pasted,
/// up to two lines. The trailing slot is either a starter's "Use" button
/// or, for a saved snippet, its use count with edit/delete on hover. The
/// count stays visible: it's what says whether a snippet earns its keep.
private struct SnippetRow: View {
    enum Trailing {
        case use(() -> Void)
        case edit(onEdit: () -> Void, onDelete: () -> Void)
    }

    let trigger: String
    let expansion: String
    let useCount: Int
    var isFirst: Bool = false
    let trailing: Trailing

    @State private var hovering = false

    /// The saved text as it reads in the list: its lines as lines (two at most), and today's date shown as the date
    /// it would be today, with a quiet note that it changes.
    private var shownExpansion: Text {
        let dateOnly = expansion.trimmingCharacters(in: .whitespaces) == SnippetStore.Value.date.token
        if dateOnly {
            return Text(SnippetStore.fill(expansion)).foregroundColor(Palette.warmInk)
                + Text("  ·  always today’s").foregroundColor(Palette.warmInkFaint)
        }
        return Text(expansion).foregroundColor(Palette.warmInk)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Text(trigger)
                .font(.manrope(13, .semibold))
                .foregroundStyle(Palette.sunsetDeep)
                .frame(width: 150, alignment: .leading)
            MurmurIconView(icon: .arrowRight)
                .frame(width: 12, height: 12)
                .foregroundStyle(Palette.warmInkFainter)
            shownExpansion
                .font(.manrope(13))
                .lineSpacing(2)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                switch trailing {
                case .use(let action):
                    Button(action: action) {
                        Text("Use")
                            .font(.manrope(12.5, .semibold))
                            .foregroundStyle(Palette.warmInk)
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .background(Palette.panel, in: RoundedRectangle(cornerRadius: Radius.sm))
                            .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Palette.warmDivider, lineWidth: 1))
                    }
                    .buttonStyle(PressScaleButtonStyle(scale: 0.96))
                case .edit(let onEdit, let onDelete):
                    ZStack(alignment: .trailing) {
                        if useCount > 0 {
                            Text("\(useCount) \(useCount == 1 ? "use" : "uses")")
                                .font(.manrope(11))
                                .foregroundStyle(Palette.warmInkFaint)
                                .opacity(hovering ? 0 : 1)
                        }
                        HStack(spacing: 4) {
                            IconButton(icon: .edit, size: 24, iconSize: 12, hoverFill: Palette.hoverWash,
                                       help: "Edit", action: onEdit)
                            IconButton(icon: .trash, size: 24, iconSize: 12, hoverFill: Palette.hoverWash,
                                       help: "Delete", action: onDelete)
                        }
                        .opacity(hovering ? 1 : 0)
                    }
                }
            }
            .frame(width: 60, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .frame(minHeight: 52)
        .background(
            RoundedRectangle(cornerRadius: Radius.sm)
                .fill(hovering ? Palette.hoverWash : Color.clear))
        .overlay(alignment: .top) {
            if !isFirst {
                Rectangle().fill(Palette.warmRowBorder).frame(height: 1)
                    .padding(.horizontal, 10)
                    .opacity(hovering ? 0 : 1)
            }
        }
        // See HomeView.swift's history row for why this is needed: a .clear
        // background makes SwiftUI treat the row's empty space as outside
        // the hoverable region until this forces the whole padded frame to
        // count, regardless of what's actually drawn there.
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.1), value: hovering)
    }
}
