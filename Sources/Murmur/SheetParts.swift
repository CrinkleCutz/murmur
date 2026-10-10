import AppKit
import SwiftUI

/// The pieces every "New …" sheet is built from (New template, New snippet), so they share one spacing scale and
/// read like Apple's own sheets: 28 pt edges, 24 pt between questions, 8 pt from a question to its field, 12 pt to the
/// buttons under a field, 8 pt between buttons, a two-button footer of equal height. Approved mockup
/// `build/mockups/snippets-v2.html` (2026-10-01), which replaced spacing that varied from 4 to 20 pt in the same sheet.
enum SheetMetrics {
    static let width: CGFloat = 540
    static let margin: CGFloat = 28
    static let sectionGap: CGFloat = 24
    static let labelGap: CGFloat = 8
    static let helperGap: CGFloat = 12
    static let noteGap: CGFloat = 8
    static let chipGap: CGFloat = 8
    static let fieldHeight: CGFloat = 36
    static let fieldRadius: CGFloat = 10
    static let smallButtonHeight: CGFloat = 28
    static let footerButtonHeight: CGFloat = 32

    /// A sheet's height: what its content needs, but never taller than the window it hangs from (the main window can
    /// be as short as 600 pt) — the content scrolls instead.
    @MainActor static func height(fitting ideal: CGFloat) -> CGFloat {
        guard let window = NSApp.mainWindow ?? NSApp.keyWindow else { return ideal }
        return max(440, min(ideal, window.contentLayoutRect.height - 32))
    }
}

/// The sheet's title and the sentence under it.
struct SheetHeader: View {
    let title: String
    let lede: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.manrope(18, .semibold))
                .tracking(-0.1)
                .foregroundStyle(Palette.warmInk)
            Text(lede)
                .font(.manrope(13))
                .lineSpacing(2)
                .foregroundStyle(Palette.warmInkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A question over its field: "When I say…", with an optional quieter aside next to it or at the far right.
struct SheetQuestion: View {
    let title: String
    var aside: String?
    var trailingAside: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(.manrope(13, .semibold)).foregroundStyle(Palette.warmInk)
            if let aside { Text(aside).font(.manrope(12)).foregroundStyle(Palette.warmInkFaint) }
            if let trailingAside {
                Spacer(minLength: 8)
                Text(trailingAside).font(.manrope(12)).foregroundStyle(Palette.warmInkFaint)
            }
        }
        .padding(.bottom, SheetMetrics.labelGap)
    }
}

/// The filled, hairline-bordered surface every field in a sheet sits on.
struct SheetFieldBackground: ViewModifier {
    var fill: Color = Palette.warmRowBorder
    var radius: CGFloat = SheetMetrics.fieldRadius

    func body(content: Content) -> some View {
        content
            .background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Palette.warmDivider, lineWidth: 1))
    }
}

extension View {
    func sheetField(fill: Color = Palette.warmRowBorder, radius: CGFloat = SheetMetrics.fieldRadius) -> some View {
        modifier(SheetFieldBackground(fill: fill, radius: radius))
    }
}

/// The one-line phrase field: the phrase in the accent (it's what you say), a faint hint at the right.
struct SheetPhraseField: View {
    @Binding var text: String
    let placeholder: String
    let hint: String
    var focused: FocusState<Bool>.Binding?

    var body: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .leading) {
                // Drawn here, faint: AppKit's own placeholder takes the field's text colour.
                if text.isEmpty {
                    Text(placeholder).foregroundStyle(Palette.warmInkFainter).allowsHitTesting(false)
                }
                if let focused {
                    TextField("", text: $text).textFieldStyle(.plain).foregroundStyle(Palette.sunset).focused(focused)
                } else {
                    TextField("", text: $text).textFieldStyle(.plain).foregroundStyle(Palette.sunset)
                }
            }
            Text(hint).font(.manrope(12)).foregroundStyle(Palette.warmInkFaint).fixedSize()
        }
        .font(.manrope(14, .semibold))
        .padding(.horizontal, 12)
        .frame(height: SheetMetrics.fieldHeight)
        .sheetField()
    }
}

/// A plain one-line field (a name).
struct SheetTextField: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        ZStack(alignment: .leading) {
            if text.isEmpty {
                Text(placeholder).foregroundStyle(Palette.warmInkFainter).allowsHitTesting(false)
            }
            TextField("", text: $text).textFieldStyle(.plain).foregroundStyle(Palette.warmInk)
        }
        .font(.manrope(13.5, .medium))
        .padding(.horizontal, 12)
        .frame(height: SheetMetrics.fieldHeight)
        .sheetField()
    }
}

/// A multi-line box. `height` fixes it (boxes that sit side by side stay the same size); otherwise it's at least
/// `minHeight`.
struct SheetTextEditor: View {
    @Binding var text: String
    var placeholder: String = ""
    var minHeight: CGFloat = 84
    var height: CGFloat?
    var fill: Color = Palette.warmRowBorder
    var corners: CGFloat = SheetMetrics.fieldRadius
    var bordered = true

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty, !placeholder.isEmpty {
                Text(placeholder)
                    .font(.manrope(13.5))
                    .foregroundStyle(Palette.warmInkFainter)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(.manrope(13.5))
                .lineSpacing(2)
                .foregroundStyle(Palette.warmInk)
                .scrollContentBackground(.hidden)
                // TextEditor insets its text by 5 pt itself: 7 + 5 lines the text up with the placeholder at 12.
                .padding(.horizontal, 7)
                .padding(.vertical, 8)
        }
        .frame(minHeight: height ?? minHeight, maxHeight: height)
        .background(fill, in: RoundedRectangle(cornerRadius: corners, style: .continuous))
        .overlay {
            if bordered {
                RoundedRectangle(cornerRadius: corners, style: .continuous).strokeBorder(Palette.warmDivider, lineWidth: 1)
            }
        }
    }
}

/// A capsule button under a field: a starter that writes the description, or "+ Today's date".
struct SheetChip: View {
    let label: String
    var selected = false
    var leadingPlus = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if leadingPlus {
                    Text("+").font(.manrope(13, .medium)).foregroundStyle(Palette.warmInkFainter)
                }
                Text(label).font(.manrope(12.5, selected ? .semibold : .regular))
            }
            .foregroundStyle(selected ? Palette.sunset : (hovering ? Palette.warmInk : Palette.warmInkSoft))
            .padding(.horizontal, 12)
            .frame(height: SheetMetrics.smallButtonHeight)
            .background(selected ? Palette.sunset.opacity(0.08) : (hovering ? Palette.warmRowBorder : Palette.panel),
                        in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? Palette.sunset : Palette.warmDivider, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(PressScaleButtonStyle(scale: 0.97))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.1), value: hovering)
    }
}

/// A short line under a field. `warn` turns it into a sunset-dot warning.
struct SheetNote: View {
    let text: String
    var warn = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            if warn {
                Circle().fill(Palette.sunset).frame(width: 7, height: 7).alignmentGuide(.firstTextBaseline) { $0.height }
            }
            Text(text)
                .font(.manrope(11.5))
                .lineSpacing(1.5)
                .foregroundStyle(warn ? Palette.sunsetDeep : Palette.warmInkFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, SheetMetrics.noteGap)
    }
}

/// One line of state at the left of the footer: green when it works, sunset when something's missing.
struct SheetStatus: View {
    let text: String
    var warn = false

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(warn ? Palette.sunset : Palette.trendUp).frame(width: 7, height: 7)
            Text(text)
                .font(.manrope(12))
                .foregroundStyle(Palette.warmInkSoft)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

/// The footer: state on the left, Cancel and Save on the right — two buttons of the same height, as in Apple's sheets.
/// Esc cancels, Return saves.
struct SheetFooter<Status: View>: View {
    let saveTitle: String
    let canSave: Bool
    let onCancel: () -> Void
    let onSave: () -> Void
    @ViewBuilder let status: () -> Status

    var body: some View {
        HStack(spacing: 16) {
            status()
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                SheetCancelButton(action: onCancel)
                Button(action: onSave) {
                    Text(saveTitle)
                        .font(.manrope(13, .semibold))
                        .foregroundStyle(canSave ? .white : Palette.warmInkFainter)
                        .padding(.horizontal, 20)
                        .frame(height: SheetMetrics.footerButtonHeight)
                        .background(canSave ? Palette.navActivePill : Palette.warmRowBorder,
                                    in: RoundedRectangle(cornerRadius: SheetMetrics.fieldRadius, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: SheetMetrics.fieldRadius, style: .continuous))
                }
                .buttonStyle(PressScaleButtonStyle(scale: 0.97))
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(.horizontal, SheetMetrics.margin)
        .padding(.vertical, 16)
        .overlay(alignment: .top) { Rectangle().fill(Palette.warmDivider).frame(height: 1) }
    }
}

/// A bordered Cancel the same height as Save, with a hover state.
struct SheetCancelButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text("Cancel")
                .font(.manrope(13, .medium))
                .foregroundStyle(Palette.warmInk)
                .padding(.horizontal, 16)
                .frame(height: SheetMetrics.footerButtonHeight)
                .background(hovering ? Palette.warmRowBorder : Palette.panel,
                            in: RoundedRectangle(cornerRadius: SheetMetrics.fieldRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: SheetMetrics.fieldRadius, style: .continuous)
                    .strokeBorder(Palette.warmDivider, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: SheetMetrics.fieldRadius, style: .continuous))
        }
        .buttonStyle(PressScaleButtonStyle(scale: 0.97))
        .keyboardShortcut(.cancelAction)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.1), value: hovering)
    }
}
