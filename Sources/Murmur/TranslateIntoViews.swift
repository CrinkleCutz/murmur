import SwiftUI

/// Settings ▸ Dictation's worked example under "Translate into": a sentence in the language you speak, and what the
/// translator in use actually made of it — two boxes of the same height, the arrow centred between them.
struct TranslationExample: View {
    let said: String
    /// nil while the translator is still working on it.
    let pasted: String?

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            box(caption: "YOU SAY", captionColor: Palette.warmInkFaint, fill: Palette.warmRowBorder, stroke: nil) {
                Text(said)
            }
            Text("→")
                .font(.manrope(14, .semibold))
                .foregroundStyle(Palette.sunset)
                .frame(width: 28)
            box(caption: "MURMUR PASTES", captionColor: Palette.sunsetDeep, fill: Palette.panel, stroke: Palette.sunset) {
                if let pasted {
                    Text(pasted)
                } else {
                    ProgressView().controlSize(.small).frame(height: 18)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(pasted.map { "You say: \(said). Murmur pastes: \($0)" } ?? "You say: \(said)")
    }

    private func box<Content: View>(caption: String, captionColor: Color, fill: Color, stroke: Color?,
                                    @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(caption)
                .font(.manrope(9.5, .bold))
                .kerning(0.8)
                .foregroundStyle(captionColor)
            content()
                .font(.manrope(13))
                .foregroundStyle(Palette.warmInk)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            if let stroke {
                RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(stroke, lineWidth: 1)
            }
        }
    }
}
