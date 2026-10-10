import SwiftUI

// MARK: - Dictionary
//
// Redesigned per the "Main" canvas (Dictionary.dc.html): same `GlassPanelPage`
// shell as Home/Insights/Scratchpad/Ask, warm palette instead of the shared
// dynamic `Palette`. Functionally unchanged from the previous pass: explains
// the mechanism up front, is searchable, shows a live count, and every row
// is genuinely editable/deletable.
//
// The tip banner, search field, add-row button, and related-link row are
// all bespoke to this page rather than the shared `PageTip`/`SearchField`/
// `AddRowButton`/`RelatedLink` components — those are still tuned for the
// old dynamic/lime palette and are shared with pages that haven't been
// redesigned yet, so forking them here (rather than editing them in place)
// keeps this page exact without changing how they look anywhere else.
// `EditPairRow`/`DictListRow` below aren't shared with anything else
// (checked: nothing outside this file references them despite an older
// comment claiming Style did too), so those are edited in place instead.

struct DictionaryPage: View {
    @Binding var page: Page
    @State private var rows: [DictionaryRow] = []
    @State private var searchText = ""
    @State private var editingID: UUID?
    @State private var draftFrom = ""
    @State private var draftTo = ""
    @State private var addingNew = false

    var body: some View {
        GlassPanelPage {
            // `ThinScrollView`, not a plain `ScrollView` — see
            // ScratchpadView.swift's own note on why: a bare
            // `.scrollIndicators(.hidden)` doesn't reliably suppress
            // macOS's native scroller by itself.
            ThinScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    if rows.isEmpty && !addingNew {
                        emptyCard
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
        .onAppear(perform: load)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Dictionary")
                .font(.manrope(22, .medium))
                .tracking(-0.33)
                .foregroundStyle(Palette.warmInk)
            // The old tip card ("say it roughly right…") folded into the
            // subtitle — it was a white card as heavy as real content.
            Text("Names and jargon Murmur should always write your way. Say them roughly "
                 + "right — it matches by sound, anywhere in a sentence.")
                .font(.manrope(12.5))
                .lineSpacing(2)
                .foregroundStyle(Palette.warmInkFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The first thing a new user sees: one card that says what this page
    /// is for, shows it with two real examples in the actual row layout,
    /// and offers the one action that matters — instead of a tip card, an
    /// empty search bar, an empty box and a dashed add row stacked up.
    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Teach Murmur your words")
                .font(.manrope(15, .semibold))
                .foregroundStyle(Palette.warmInk)
            Text("Add a name, a product, or a term it keeps getting wrong — every transcript "
                 + "from then on gets it right.")
                .font(.manrope(12.5))
                .lineSpacing(2)
                .foregroundStyle(Palette.warmInkSoft)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 0) {
                DictColumnLabels()
                DictListRow(from: "super base", to: "Supabase", isFirst: true, onEdit: {}, onDelete: {})
                DictListRow(from: "yanis", to: "Jānis", isFirst: false, onEdit: {}, onDelete: {})
            }
            .opacity(0.55)
            .allowsHitTesting(false)
            .padding(.top, 20)
            HStack(spacing: 12) {
                Button(action: startAdding) {
                    PrimaryActionLabel(title: "Add your first word")
                }
                .buttonStyle(PressScaleButtonStyle(scale: 0.97))
                Text("Examples — not saved")
                    .font(.manrope(11.5))
                    .foregroundStyle(Palette.warmInkFaint)
            }
            .padding(.top, 20)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// Search (its placeholder carries the count) and the primary add
    /// action. Search only exists once there's something to search.
    private var toolbar: some View {
        HStack(spacing: 12) {
            if !rows.isEmpty {
                HStack(spacing: 8) {
                    MurmurIconView(icon: .search)
                        .frame(width: 13, height: 13)
                        .foregroundStyle(Palette.warmInkFaint)
                    TextField("Search \(rows.count) \(rows.count == 1 ? "word" : "words")", text: $searchText)
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
            Button(action: startAdding) {
                PrimaryActionLabel(title: "Add word")
            }
            .buttonStyle(PressScaleButtonStyle(scale: 0.97))
            .disabled(addingNew)
        }
    }

    private var listCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            DictColumnLabels()
            // New words are typed in place, at the top of the list.
            if addingNew {
                EditPairRow(
                    fromPlaceholder: "Say this…",
                    toPlaceholder: "Get this instead",
                    from: $draftFrom, to: $draftTo,
                    onSave: { commitNew() },
                    onCancel: { addingNew = false })
            }
            if visibleRows.isEmpty && !rows.isEmpty {
                Text("No words match \u{201c}\(searchText)\u{201d}.")
                    .font(.manrope(12.5))
                    .italic()
                    .foregroundStyle(Palette.warmInkFaint)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            }
            ForEach(Array(visibleRows.enumerated()), id: \.element.id) { index, row in
                if editingID == row.id {
                    EditPairRow(
                        fromPlaceholder: "Say this…",
                        toPlaceholder: "Get this instead",
                        from: $draftFrom, to: $draftTo,
                        onSave: { commitEdit(row) },
                        onCancel: { editingID = nil })
                } else {
                    DictListRow(
                        from: row.spoken, to: row.replacement,
                        isFirst: index == 0 && !addingNew,
                        onEdit: {
                            draftFrom = row.spoken
                            draftTo = row.replacement
                            editingID = row.id
                        },
                        onDelete: {
                            rows.removeAll { $0.id == row.id }
                            save()
                        })
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func startAdding() {
        draftFrom = ""
        draftTo = ""
        editingID = nil
        addingNew = true
    }

    private var relatedLink: some View {
        HStack(spacing: 4) {
            Text("Mishearing your accent or a name, not a specific word?")
                .font(.manrope(12))
                .foregroundStyle(Palette.warmInkSoft)
            Button { page = .training } label: {
                Text("Voice Profile")
                    .font(.manrope(12, .medium))
                    .foregroundStyle(Palette.sunsetDeep)
            }
            .buttonStyle(.plain)
            Text(learnedCorrectionsCount > 0
                 ? "learns those automatically — \(learnedCorrectionsCount) so far."
                 : "learns those automatically.")
                .font(.manrope(12))
                .foregroundStyle(Palette.warmInkSoft)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var learnedCorrectionsCount: Int {
        LearnedStore.load().corrections.count
    }

    private var visibleRows: [DictionaryRow] {
        let term = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !term.isEmpty else { return rows }
        return rows.filter {
            $0.spoken.lowercased().contains(term) || $0.replacement.lowercased().contains(term)
        }
    }

    private func commitEdit(_ row: DictionaryRow) {
        guard let index = rows.firstIndex(where: { $0.id == row.id }) else { return }
        let from = draftFrom.trimmingCharacters(in: .whitespaces)
        guard !from.isEmpty else { editingID = nil; return }
        rows[index].spoken = from
        rows[index].replacement = draftTo.trimmingCharacters(in: .whitespaces)
        editingID = nil
        save()
    }

    private func commitNew() {
        let from = draftFrom.trimmingCharacters(in: .whitespaces)
        guard !from.isEmpty else { addingNew = false; return }
        rows.append(DictionaryRow(
            spoken: from, replacement: draftTo.trimmingCharacters(in: .whitespaces)))
        addingNew = false
        save()
    }

    private func load() {
        rows = TextFormatter.loadDictionary()
            .sorted { $0.key < $1.key }
            .map { DictionaryRow(spoken: $0.key, replacement: $0.value) }
    }

    private func save() {
        var dictionary: [String: String] = [:]
        for row in rows {
            let spoken = row.spoken.trimmingCharacters(in: .whitespaces)
            if !spoken.isEmpty { dictionary[spoken] = row.replacement }
        }
        if let data = try? JSONEncoder().encode(dictionary) {
            try? data.write(to: TextFormatter.dictionaryURL, options: .atomic)
        }
    }
}

struct DictionaryRow: Identifiable {
    let id = UUID()
    var spoken: String
    var replacement: String
}

// MARK: - Row views

/// "YOU SAY" / "MURMUR WRITES" over the two columns — the same small
/// uppercase label style as Home's day labels.
struct DictColumnLabels: View {
    var body: some View {
        HStack(spacing: 16) {
            Text("YOU SAY").frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: 12, height: 1)
            Text("MURMUR WRITES").frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: 54, height: 1)
        }
        .font(.manrope(10, .semibold))
        .kerning(0.9)
        .foregroundStyle(Palette.warmInkSoft)
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
    }
}

/// A "spoken → replacement" pair. Both sides share the width equally (the
/// spoken side used to be a fixed 140pt and cut longer phrases off); the
/// replacement is bold because it's what matters. Edit/delete on hover,
/// on the same translucent wash as every other list in the app.
struct DictListRow: View {
    let from: String
    let to: String
    var isFirst: Bool = false
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 16) {
            Text(from)
                .font(.manrope(13))
                .foregroundStyle(Palette.warmInkSoft)
                .frame(maxWidth: .infinity, alignment: .leading)
            MurmurIconView(icon: .arrowRight)
                .frame(width: 12, height: 12)
                .foregroundStyle(Palette.warmInkFainter)
            Text(to)
                .font(.manrope(13, .semibold))
                .foregroundStyle(Palette.warmInk)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                IconButton(icon: .edit, size: 24, iconSize: 12, hoverFill: Palette.hoverWash,
                           help: "Edit", action: onEdit)
                IconButton(icon: .trash, size: 24, iconSize: 12, hoverFill: Palette.hoverWash,
                           help: "Delete", action: onDelete)
            }
            .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 13)
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

/// The inline add/edit row — the same two columns as `DictListRow`, with
/// the first field focused as soon as it appears.
struct EditPairRow: View {
    let fromPlaceholder: String
    let toPlaceholder: String
    @Binding var from: String
    @Binding var to: String
    let onSave: () -> Void
    let onCancel: () -> Void

    @FocusState private var fromFocused: Bool

    var body: some View {
        HStack(spacing: 16) {
            field(fromPlaceholder, $from)
                .focused($fromFocused)
            MurmurIconView(icon: .arrowRight)
                .frame(width: 12, height: 12)
                .foregroundStyle(Palette.warmInkFainter)
            field(toPlaceholder, $to)
            HStack(spacing: 6) {
                IconButton(icon: .check, size: 24, iconSize: 12, hoverFill: Palette.hoverWash,
                           help: "Save", action: onSave)
                IconButton(icon: .plus, size: 24, iconSize: 12, rotated: true, hoverFill: Palette.hoverWash,
                           help: "Cancel", action: onCancel)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .onAppear { fromFocused = true }
        .onExitCommand(perform: onCancel)
    }

    private func field(_ placeholder: String, _ text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.manrope(13))
            .foregroundStyle(Palette.warmInk)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(Palette.warmRowBorder, in: RoundedRectangle(cornerRadius: Radius.sm))
            .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Palette.warmDivider, lineWidth: 1))
            .frame(maxWidth: .infinity)
            .onSubmit(onSave)
    }
}
