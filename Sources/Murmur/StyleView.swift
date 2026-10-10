import AppKit
import SwiftUI

// MARK: - Style
//
// Redesigned per the "Main" canvas (Style.dc.html): same `GlassPanelPage`
// shell as the other redesigned pages, warm palette instead of the shared
// dynamic `Palette`. Functionally unchanged from the previous pass — this
// page still owns only the *global* default; per-app tone lives on App
// Profiles, next to that app's own template.

struct StylePage: View {
    @ObservedObject var app: AppDelegate
    @Binding var page: Page
    @State private var defaultStyle: WritingStyle = StyleSettings.defaultStyle
    /// Independent of `defaultStyle` — how much Murmur may shorten or
    /// restructure, not what register it writes in. Global only, matching
    /// `StyleSettings.defaultCleanupLevel`'s own doc comment on why this
    /// doesn't join `AppProfileStore`'s per-app overrides.
    @State private var defaultCleanupLevel: CleanupLevel = StyleSettings.defaultCleanupLevel

    /// The one sample sentence every tone is previewed against, so the
    /// differences between them are directly comparable.
    private let sourceText =
        "um so i think we should send them the updated file when you get a chance"

    private func preview(for style: WritingStyle, cleanupLevel: CleanupLevel) -> String {
        guard style != .raw else { return sourceText }
        // What each tone really writes for this sentence (`Murmur --edit`, 2026-10-09; the same every time). Concise
        // gives the same: it shortens a wordy dictation ("I just wanted to quickly reach out and let you know that
        // basically the report is going to be a little bit late" → "I wanted to quickly let you know the report is
        // going to be a day late"), and this one has nothing to cut.
        switch style {
        case .none, .auto:
            return "So I think we should send them the updated file when you get a chance."
        case .casual:
            return "Think we should send them the updated file when you get a chance."
        case .formal:
            return "I believe we should send them the updated file at your earliest convenience."
        case .veryCasual:
            return "so i think we should send them the updated file when u get a min"
        case .raw:
            return sourceText
        }
    }

    /// The tone grid's width, so it can drop from three columns to two
    /// before the cards get too narrow to read.
    @State private var gridWidth: CGFloat = 0

    var body: some View {
        GlassPanelPage {
            // `ThinScrollView`, not a plain `ScrollView` — see
            // ScratchpadView.swift's own note on why: a bare
            // `.scrollIndicators(.hidden)` doesn't reliably suppress
            // macOS's native scroller by itself.
            ThinScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header

                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("YOU SAY")
                            .font(.manrope(10, .semibold))
                            .kerning(0.9)
                            .foregroundStyle(Palette.warmInkSoft)
                        Text("\u{201c}\(sourceText)\u{201d}")
                            .font(.manrope(13))
                            .italic()
                            .foregroundStyle(Palette.warmInkSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 24)

                    toneGrid
                        .padding(.top, 12)

                    cleanupCard
                        .padding(.top, 24)

                    if let note = app.rewriteEngine.availabilityNote {
                        PageTip(text: note)
                            .padding(.top, 12)
                    }

                    relatedLink
                        .padding(.top, 16)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Style")
                .font(.manrope(22, .medium))
                .tracking(-0.33)
                .foregroundStyle(Palette.warmInk)
            // The old tip card ("As spoken is your default tone
            // everywhere…") folded into the subtitle.
            Text("Your default tone everywhere. An app with its own profile in App Profiles uses that instead.")
                .font(.manrope(12.5))
                .foregroundStyle(Palette.warmInkFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Tones

    /// Every tone as a card showing its real output for the same sentence,
    /// so they compare at a glance — instead of a six-option segmented
    /// strip (past what a segmented control should hold) with one preview
    /// below that only ever showed the selected tone. Raw's and Auto's
    /// explanations, which used to be extra tip cards, are their cards'
    /// one-liners now.
    private var toneGrid: some View {
        let columns = gridWidth > 0 && gridWidth < 660 ? 2 : 3
        let styles = WritingStyle.allCases
        let rows = stride(from: 0, to: styles.count, by: columns).map {
            Array(styles[$0..<min($0 + columns, styles.count)])
        }
        return VStack(spacing: 12) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 12) {
                    ForEach(row) { style in
                        ToneCard(
                            name: style == .raw ? "Raw" : style.displayName,
                            line: toneLine(style),
                            example: style == .auto
                                ? "In chat, no full stop. In email, the greeting and sign-off get their own lines."
                                : preview(for: style, cleanupLevel: defaultCleanupLevel),
                            selected: style == defaultStyle
                        ) {
                            withAnimation(.murmurEase(0.15)) { defaultStyle = style }
                            StyleSettings.defaultStyle = style
                        }
                    }
                    // Keeps a short last row's cards the same width as the rest.
                    ForEach(0..<(columns - row.count), id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
    }

    private func toneLine(_ style: WritingStyle) -> String {
        switch style {
        case .none: return "Cleaned up, your words kept."
        case .auto: return "Adapts to the app — never changes a word."
        case .formal: return "Polished and professional."
        case .casual: return "Relaxed and friendly."
        case .veryCasual: return "Chat-style, short."
        case .raw: return "Exactly what you said — best for terminals and code."
        }
    }

    // MARK: Cleanup

    /// A white card like every other block on the page, with the same
    /// native segmented control as Insights. Disabled (not hidden) under
    /// Raw, which skips the rewrite this setting affects — the description
    /// says so.
    private var cleanupCard: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Cleanup")
                    .font(.manrope(13, .semibold))
                    .foregroundStyle(Palette.warmInk)
                Text("How much Murmur may shorten or restructure, on top of tone. Applies everywhere; Raw skips it.")
                    .font(.manrope(12.5))
                    .foregroundStyle(Palette.warmInkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            WarmSegmentedPicker(
                options: CleanupLevel.allCases,
                label: \.displayName,
                selection: Binding(
                    get: { defaultCleanupLevel },
                    set: { level in
                        withAnimation(.murmurEase(0.15)) { defaultCleanupLevel = level }
                        StyleSettings.defaultCleanupLevel = level
                    }))
                .opacity(defaultStyle == .raw ? 0.4 : 1)
                .allowsHitTesting(defaultStyle != .raw)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var relatedLink: some View {
        HStack(spacing: 4) {
            Text("Need a different tone in one particular app?")
                .font(.manrope(12))
                .foregroundStyle(Palette.warmInkSoft)
            Button { page = .appProfiles } label: {
                Text("App Profiles")
                    .font(.manrope(12, .medium))
                    .foregroundStyle(Palette.sunsetDeep)
            }
            .buttonStyle(.plain)
            Text("override this per app.")
                .font(.manrope(12))
                .foregroundStyle(Palette.warmInkSoft)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// One selectable tone: name, what it does, and its actual output for the
/// page's sample sentence. Selected = sunset outline and a check (orange
/// is for state); hover = a warmer hairline.
private struct ToneCard: View {
    let name: String
    let line: String
    let example: String
    let selected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(name)
                        .font(.manrope(13, .semibold))
                        .foregroundStyle(Palette.warmInk)
                    Spacer()
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
                Text(line)
                    .font(.manrope(12))
                    .foregroundStyle(Palette.warmInkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 3)
                Text(example)
                    .font(.manrope(13))
                    .lineSpacing(2)
                    .foregroundStyle(Palette.warmInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                    .padding(.top, 12)
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
