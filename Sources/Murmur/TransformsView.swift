import AppKit
import SwiftUI

// MARK: - Transforms
//
// Select text anywhere, press a shortcut, rewritten in place. Laid out like
// Templates: a grid of white cards (click one to choose it; its shortcut
// sits at the card's foot the way a template's spoken phrase does), then
// one "Try it on some text" card whose single Transform button runs the
// chosen transform, with the result inside the same card.

struct TransformsPage: View {
    @ObservedObject var app: AppDelegate
    @Binding var page: Page
    @State private var tryText = ""
    @State private var result = ""
    /// Shown as a red line, never as a result — the result has a Paste
    /// button, and "Failed: …" is not something to paste into Mail.
    @State private var errorText: String?
    @State private var running = false
    @State private var selectedID = Transform.all[0].id
    @State private var gridWidth: CGFloat = 0
    /// Set once the text box's corner has been dragged — from then on it
    /// keeps that height instead of following its text.
    @State private var draggedEditorHeight: CGFloat?
    @State private var shownEditorHeight: CGFloat = 90
    @State private var dragStartHeight: CGFloat?

    @State private var customTransforms: [CustomTransform] = CustomTransformStore.load()
    @State private var editingCustomID: UUID?
    @State private var showingEditor = false
    @State private var draftName = ""
    @State private var draftInstructions = ""
    @State private var draftShortcut: String?

    /// Built-ins plus every custom transform, in the exact order/slot
    /// assignment the global ⌥3…9 hotkeys actually use — see
    /// `Transform.merging(_:)`'s own doc comment for why this reads the
    /// page's own `@State` mirror rather than the store directly.
    private var displayTransforms: [Transform] { Transform.merging(customTransforms) }

    private var selectedTransform: Transform? {
        displayTransforms.first { $0.id == selectedID }
    }

    /// The shortcut a new transform would get, asked of `Transform.merging`
    /// itself so it can't drift from the real slot assignment; nil once
    /// ⌥3…⌥9 are all taken.
    private var nextShortcut: String? {
        Transform.merging(customTransforms + [CustomTransform(name: "", instructions: "")])
            .last.flatMap(Self.shortcut(of:))
    }

    /// A transform's shortcut label, or nil for an 8th+ custom one.
    static func shortcut(of transform: Transform) -> String? {
        transform.keyCode == .max ? nil : transform.keyLabel
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

                    // Nothing on this page works without the model, so
                    // the reason sits right under the title.
                    if let note = app.rewriteEngine.availabilityNote {
                        tipBanner(note).padding(.top, 24)
                    }

                    Text("YOUR TRANSFORMS")
                        .font(.manrope(10, .semibold))
                        .kerning(0.9)
                        .foregroundStyle(Palette.warmInkSoft)
                        .padding(.top, 24)
                        .padding(.bottom, 10)
                    transformGrid

                    tryItCard
                        .padding(.top, 24)

                    relatedLink
                        .padding(.top, 16)
                }
            }
        }
        .onAppear(perform: consumePendingText)
        .onChange(of: app.pendingTransformText) { _, _ in consumePendingText() }
        .sheet(isPresented: $showingEditor) {
            CustomTransformEditor(
                isNew: editingCustomID == nil, name: $draftName, instructions: $draftInstructions,
                shortcut: draftShortcut, onSave: saveDraft)
        }
    }

    /// Picks up a Scratchpad note sent here via "Send to Transforms" —
    /// mirrors `TemplatesView`'s own `consumePendingText`.
    private func consumePendingText() {
        guard let pending = app.pendingTransformText else { return }
        tryText = pending
        result = ""
        errorText = nil
        app.pendingTransformText = nil
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Transforms")
                .font(.manrope(22, .medium))
                .tracking(-0.33)
                .foregroundStyle(Palette.warmInk)
            // The old tip card folded into the subtitle, undo included.
            Text("Select text in any app and press a transform's shortcut — Murmur rewrites it "
                 + "in place. ⌥⇧Z undoes the last one.")
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

    /// Three columns (two below 660pt), rows of equal height — the same
    /// grid as Style's tones and Templates, with "New transform" last.
    private var transformGrid: some View {
        let columns = gridWidth > 0 && gridWidth < 660 ? 2 : 3
        let items: [Transform?] = displayTransforms.map { Optional($0) } + [nil]
        let rows = stride(from: 0, to: items.count, by: columns).map {
            Array(items[$0..<min($0 + columns, items.count)])
        }
        return VStack(spacing: 12) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 12) {
                    ForEach(row, id: \.?.id) { item in
                        if let transform = item {
                            transformCard(transform)
                        } else {
                            NewTransformTile(shortcut: nextShortcut, action: beginCreate)
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

    private func transformCard(_ transform: Transform) -> some View {
        TransformCard(
            transform: transform,
            shortcut: Self.shortcut(of: transform),
            selected: selectedID == transform.id,
            onSelect: { withAnimation(.murmurEase(0.15)) { selectedID = transform.id } },
            onEdit: transform.isCustom ? { beginEdit(transform) } : nil,
            onDelete: transform.isCustom ? { delete(transform) } : nil)
    }

    // MARK: Custom transform CRUD

    private func customID(from transform: Transform) -> UUID? {
        guard transform.isCustom, transform.id.hasPrefix("custom-") else { return nil }
        return UUID(uuidString: String(transform.id.dropFirst("custom-".count)))
    }

    private func beginCreate() {
        editingCustomID = nil
        draftName = ""
        draftInstructions = ""
        draftShortcut = nextShortcut
        showingEditor = true
    }

    private func beginEdit(_ transform: Transform) {
        guard let id = customID(from: transform),
              let existing = customTransforms.first(where: { $0.id == id })
        else { return }
        editingCustomID = id
        draftName = existing.name
        draftInstructions = existing.instructions
        draftShortcut = Self.shortcut(of: transform)
        showingEditor = true
    }

    private func delete(_ transform: Transform) {
        guard let id = customID(from: transform) else { return }
        customTransforms.removeAll { $0.id == id }
        CustomTransformStore.save(customTransforms)
        if selectedID == transform.id { selectedID = Transform.all[0].id }
    }

    private func saveDraft() {
        let name = draftName.trimmingCharacters(in: .whitespaces)
        let instructions = draftInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !instructions.isEmpty else { return }
        if let editingCustomID, let index = customTransforms.firstIndex(where: { $0.id == editingCustomID }) {
            customTransforms[index].name = name
            customTransforms[index].instructions = instructions
        } else {
            let created = CustomTransform(name: name, instructions: instructions)
            customTransforms.append(created)
            // Chosen straight away, so "Try it" runs what you just wrote.
            selectedID = "custom-\(created.id.uuidString)"
        }
        CustomTransformStore.save(customTransforms)
        editingCustomID = nil
    }

    // MARK: Try it

    /// The manual tool, in one card like Templates' "Try it on a
    /// transcript": the header names the chosen transform, one Transform
    /// button shows its real state (grey until there's text, sunset when
    /// it can run — the old row of always-orange per-transform buttons
    /// looked clickable while disabled), and the result lands inside.
    private var tryItCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .lastTextBaseline) {
                Text("Try it on some text")
                    .font(.manrope(13, .semibold))
                    .foregroundStyle(Palette.warmInk)
                Spacer()
                Text(selectedTransform.map { "uses \($0.name)" } ?? "pick a transform above")
                    .font(.manrope(11.5))
                    .foregroundStyle(Palette.warmInkFaint)
                    .lineLimit(1)
            }
            tryEditor
                .padding(.top, 12)
            HStack(spacing: 12) {
                Button(action: runSelected) {
                    HStack(spacing: 7) {
                        if running {
                            ProgressView().controlSize(.small)
                        } else {
                            MurmurIconView(icon: .trans).frame(width: 13, height: 13)
                        }
                        Text(running ? "Transforming…" : "Transform")
                            .font(.manrope(13, .semibold))
                    }
                    .foregroundStyle(canRun ? .white : Palette.warmInkFainter)
                    .padding(.horizontal, 16)
                    .frame(height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.md)
                            .fill(canRun ? Palette.sunset : Palette.warmRowBorder))
                    .animation(.murmurEase(0.15), value: canRun)
                }
                .buttonStyle(PressScaleButtonStyle(scale: 0.97))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canRun)
                if canRun {
                    Text("⌘↩")
                        .font(.manrope(11.5, .medium))
                        .foregroundStyle(Palette.warmInkFaint)
                }
                Spacer()
                if !tryText.isEmpty {
                    Button("Clear") {
                        tryText = ""
                        result = ""
                        errorText = nil
                    }
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

    /// Grows with its text up to 240pt, then scrolls; dragging the corner
    /// grip sets any height from 90 to 480pt, which it then keeps.
    /// `TextEditor` reports no height of its own, so an invisible copy of
    /// the text — one spare line longer, so typing never scrolls it —
    /// sizes the box and the editor fills it. The copy's 13pt inset is the
    /// editor's 8pt padding plus the text view's 5pt line-fragment padding.
    private var tryEditor: some View {
        Text(tryText + "\n ")
            .font(.manrope(13))
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: draggedEditorHeight ?? 90,
                   maxHeight: draggedEditorHeight ?? 240, alignment: .topLeading)
            .opacity(0)
            .overlay {
                TextEditor(text: $tryText)
                    .font(.manrope(13))
                    .foregroundStyle(Palette.warmInk)
                    .scrollContentBackground(.hidden)
                    .padding(8)
            }
            .overlay(alignment: .topLeading) {
                if tryText.isEmpty {
                    Text("Paste or type some text, or send a note here from Scratchpad…")
                        .font(.manrope(13))
                        .italic()
                        .foregroundStyle(Palette.warmInkFaint)
                        .padding(.top, 8)
                        .padding(.leading, 13)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                ResizeGrip()
                    .frame(width: 14, height: 14)
                    .padding(3)
                    .contentShape(Rectangle())
                    .pointerStyle(.frameResize(position: .bottom))
                    .gesture(
                        // Global space: the grip moves with the box it
                        // resizes, which would feed back into a local drag.
                        DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { value in
                                let start = dragStartHeight ?? shownEditorHeight
                                dragStartHeight = start
                                draggedEditorHeight = min(max(90, start + value.translation.height), 480)
                            }
                            .onEnded { _ in dragStartHeight = nil })
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { shownEditorHeight = $0 }
            .background(Palette.warmRowBorder, in: RoundedRectangle(cornerRadius: Radius.sm))
            .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Palette.warmDivider, lineWidth: 1))
    }

    private var relatedLink: some View {
        HStack(spacing: 4) {
            Text("Want tone applied automatically as you dictate instead?")
                .font(.manrope(12))
                .foregroundStyle(Palette.warmInkSoft)
            Button { page = .style } label: {
                Text("Style")
                    .font(.manrope(12, .medium))
                    .foregroundStyle(Palette.sunsetDeep)
            }
            .buttonStyle(.plain)
            Text("does it per app, with no shortcut.")
                .font(.manrope(12))
                .foregroundStyle(Palette.warmInkSoft)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var canRun: Bool {
        !running && !tryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && selectedTransform != nil && app.rewriteEngine.isAvailable
    }

    private func runSelected() {
        guard canRun, let transform = selectedTransform else { return }
        running = true
        result = ""
        errorText = nil
        Task {
            defer { running = false }
            do {
                let output = try await app.transformManager.apply(transform, to: tryText)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if output.isEmpty {
                    errorText = "\(transform.name) came back empty — try again."
                } else {
                    result = output
                }
            } catch {
                errorText = "\(transform.name) failed: \(error.localizedDescription)"
            }
        }
    }
}

/// The three diagonal lines in the text box's corner that mark it as
/// draggable to resize.
private struct ResizeGrip: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            let inset: CGFloat = 2
            let spacing: CGFloat = 3.5
            for i in 0..<3 {
                let offset = CGFloat(i) * spacing
                path.move(to: CGPoint(x: size.width - inset - offset, y: size.height - inset))
                path.addLine(to: CGPoint(x: size.width - inset, y: size.height - inset - offset))
            }
            context.stroke(path, with: .color(Palette.warmInkFainter), lineWidth: 1.2)
        }
    }
}

/// A shortcut as keycaps ("⌥" "3"), or a note once ⌥3…⌥9 are all taken.
private struct TransformShortcut: View {
    let shortcut: String?

    var body: some View {
        if let shortcut {
            HStack(spacing: 3) {
                ForEach(Array(shortcut.enumerated()), id: \.offset) { _, key in
                    WarmKeycap(label: String(key))
                }
            }
        } else {
            Text("No shortcut left · run it here")
                .font(.manrope(11.5, .medium))
                .foregroundStyle(Palette.warmInkFaint)
                .frame(minHeight: 20)
        }
    }
}

/// White, like Templates' cards: selected = sunset outline + check; the
/// shortcut at the foot; a custom transform shows edit/delete on hover
/// (and in its right-click menu).
private struct TransformCard: View {
    let transform: Transform
    let shortcut: String?
    let selected: Bool
    let onSelect: () -> Void
    let onEdit: (() -> Void)?
    let onDelete: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(transform.name)
                        .font(.manrope(13, .semibold))
                        .foregroundStyle(Palette.warmInk)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if hovering, let onEdit, let onDelete {
                        IconButton(icon: .edit, size: 22, iconSize: 11, hoverFill: Palette.hoverWash,
                                   help: "Edit", action: onEdit)
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
                Text(transform.description)
                    .font(.manrope(12))
                    .foregroundStyle(Palette.warmInkSoft)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 3)
                Spacer(minLength: 12)
                TransformShortcut(shortcut: shortcut)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .frame(minHeight: 118)
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
        .contextMenu {
            if let onEdit { Button("Edit…", action: onEdit) }
            if let onDelete { Button("Delete", role: .destructive, action: onDelete) }
        }
    }
}

/// Templates' "New template" tile, plus the shortcut the new one will get.
private struct NewTransformTile: View {
    let shortcut: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                HStack(spacing: 7) {
                    MurmurIconView(icon: .plus).frame(width: 13, height: 13)
                    Text("New transform").font(.manrope(13, .semibold))
                }
                .foregroundStyle(hovering ? Palette.warmInk : Palette.warmInkSoft)
                Text(shortcut.map { "Your own prompt, on \($0)" } ?? "Your own prompt — run it here")
                    .font(.manrope(11.5))
                    .foregroundStyle(Palette.warmInkFaint)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(minHeight: 118)
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

/// Create/edit sheet for a custom transform, in the same warm style as
/// Templates' "New template" sheet: labelled warm fields, the shortcut it
/// runs with, plain Cancel (Esc) and a dark Save (Return) that stays grey
/// until both fields are filled. `onSave` commits the draft and clears
/// `editingCustomID` on the caller's side; this view only owns the fields.
private struct CustomTransformEditor: View {
    @Environment(\.dismiss) private var dismiss
    let isNew: Bool
    @Binding var name: String
    @Binding var instructions: String
    /// What this transform runs with — nil past the seventh custom one.
    let shortcut: String?
    let onSave: () -> Void

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isNew ? "New transform" : "Edit transform")
                .font(.manrope(16, .semibold))
                .foregroundStyle(Palette.warmInk)

            label("Name").padding(.top, 18)
            TextField("e.g. \u{201c}Make it punchier\u{201d}", text: $name)
                .textFieldStyle(.plain)
                .font(.manrope(13))
                .foregroundStyle(Palette.warmInk)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(Palette.warmRowBorder, in: RoundedRectangle(cornerRadius: Radius.sm))
                .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Palette.warmDivider, lineWidth: 1))

            label("What it should do").padding(.top, 14)
            TextEditor(text: $instructions)
                .font(.manrope(13))
                .foregroundStyle(Palette.warmInk)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 120)
                .overlay(alignment: .topLeading) {
                    if instructions.isEmpty {
                        Text("e.g. Cut filler and hedging, lead with the point, keep it short.")
                            .font(.manrope(13))
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
                if shortcut != nil {
                    Text("Runs on selected text in any app with")
                        .font(.manrope(11.5))
                        .foregroundStyle(Palette.warmInkSoft)
                    TransformShortcut(shortcut: shortcut)
                } else {
                    Text("No shortcut left — run it from the Transforms page.")
                        .font(.manrope(11.5))
                        .foregroundStyle(Palette.warmInkSoft)
                }
            }
            .padding(.top, 12)

            HStack(spacing: 16) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.manrope(13, .medium))
                    .foregroundStyle(Palette.warmInkSoft)
                    .keyboardShortcut(.cancelAction)
                Button {
                    onSave()
                    dismiss()
                } label: {
                    Text("Save")
                        .font(.manrope(13, .semibold))
                        .foregroundStyle(canSave ? .white : Palette.warmInkFainter)
                        .padding(.horizontal, 18)
                        .frame(height: 34)
                        .background(canSave ? Palette.navActivePill : Palette.warmRowBorder,
                                    in: RoundedRectangle(cornerRadius: Radius.md))
                }
                .buttonStyle(PressScaleButtonStyle(scale: 0.97))
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding(.top, 20)
        }
        .padding(22)
        .frame(width: 440)
        .background(Palette.panel)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.manrope(11.5, .medium))
            .foregroundStyle(Palette.warmInkSoft)
            .padding(.bottom, 6)
    }
}
