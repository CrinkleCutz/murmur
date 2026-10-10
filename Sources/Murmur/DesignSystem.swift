import SwiftUI

// MARK: - Glass panel page (the "Main" redesign's shared page chrome)

/// The frosted glass panel every full-bleed "Main"-redesign page (Home,
/// Insights, …) floats on top of `AppShellRoot.appBody`'s shared gradient
/// backdrop — factored out once both pages needed the identical
/// padding/material/shadow stack, rather than copy-pasting it per page.
///
/// A page using this opts out of `AppShellRoot`'s generic pane padding (see
/// the `page == .home` — extend that check for any new page adopting this)
/// so this can paint edge-to-edge and float on the *shared* gradient
/// instead of a second, independently-scaled copy of its own (the seam
/// that produced, before `homeGradient` moved to `appBody`).
///
/// Margin was trimmed back from Main.dc.html's own 34/38 to 18/20 by
/// request — the panel reads as "floating" just as well with a narrower
/// gradient border, and the narrower margin buys real content (Home's
/// history list, Insights' chart) more room. Every page adopting this
/// shell should match, not re-introduce the mockup's wider margin.
///
/// Follows `AppearanceSetting` like the rest of the app now that `Palette`'s
/// warm tokens have real dark values (previously pinned to `.light` here,
/// since none of these pages had anything to adapt to yet). `.ultraThin
/// Material` already adapts to dark mode on its own; the stroke/shadow
/// below stay theme-neutral by design — a white glass-edge highlight and a
/// dark depth shadow both still read correctly regardless of the page
/// behind them, the same as real frosted glass would.
struct GlassPanelPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(26)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.6), lineWidth: 1))
            .shadow(color: .black.opacity(0.03), radius: 1, y: 1)
            .shadow(color: .black.opacity(0.05), radius: 30, y: 20)
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Page header

/// `<h3>` + `.pane-sub` — every page in the mockup opens with these two.
struct PageHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.manrope(22, .medium))
                .tracking(-0.33)
                .foregroundStyle(Palette.ink)
            if let subtitle {
                Text(subtitle)
                    .font(.manrope(12.5))
                    .foregroundStyle(Palette.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 560, alignment: .leading)
            }
        }
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// `.section-head` — a small bold label above a list.
struct SectionHead: View {
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack {
            Text(title)
                .font(.manrope(14, .semibold))
                .foregroundStyle(Palette.ink)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.manrope(11.5))
                    .foregroundStyle(Palette.inkFaint)
            }
        }
        .padding(.top, 26)
        .padding(.bottom, 8)
    }
}

/// `.dict-related` — the trailing "related feature" pointer each page ends
/// with, so no page is a dead end.
struct RelatedLink: View {
    let prefix: String
    let linkTitle: String
    let suffix: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(prefix)
                .font(.manrope(12))
                .foregroundStyle(Palette.inkSoft)
            Button(action: action) {
                Text(linkTitle)
                    .font(.manrope(12, .medium))
                    .foregroundStyle(Palette.accentText)
            }
            .buttonStyle(.plain)
            Text(suffix)
                .font(.manrope(12))
                .foregroundStyle(Palette.inkSoft)
        }
        .padding(.top, 14)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// `.dict-search` — the search field used on Dictionary and Snippets.
struct SearchField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            MurmurIconView(icon: .search)
                .frame(width: 13, height: 13)
                .foregroundStyle(Palette.inkFaint)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.manrope(12.5))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: Radius.sm))
        .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Palette.border, lineWidth: 1))
        .frame(maxWidth: 260)
    }
}

/// `.icon-btn` — 26×26, transparent at rest, `--card-hover` fill and
/// `--ink` icon on hover, 0.9 scale while pressed. The hover fill and the
/// press-scale are what make it read as a real control. `hoverFill` lets a
/// button sitting on an already-highlighted surface (Home's lit history
/// row) use a wash that still shows on top of it.
struct IconButton: View {
    let icon: MurmurIcon
    var size: CGFloat = 26
    var iconSize: CGFloat = 14
    var rotated: Bool = false
    var tint: Color? = nil
    var hoverFill: Color = Palette.cardHover
    var help: String? = nil
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            MurmurIconView(icon: icon)
                .frame(width: iconSize, height: iconSize)
                .rotationEffect(.degrees(rotated ? 45 : 0))
                .foregroundStyle(tint ?? (hovering ? Palette.ink : Palette.inkSoft))
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(hovering ? hoverFill : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleButtonStyle(scale: 0.9))
        .onHover { hovering = $0 }
        .murmurTooltip(help ?? "")
    }
}

/// The page-level primary action ("Start new note", "Add word"): a dark
/// near-black fill — the same ink as the selected rail row — with white
/// text and an optional leading icon, 36pt tall. Dark rather than sunset so
/// orange stays reserved for data and state.
struct PrimaryActionLabel: View {
    let title: String
    var icon: MurmurIcon? = .plus

    var body: some View {
        HStack(spacing: 8) {
            if let icon { MurmurIconView(icon: icon).frame(width: 12, height: 12) }
            Text(title).font(.manrope(13, .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(height: 36)
        .background(Palette.navActivePill, in: RoundedRectangle(cornerRadius: Radius.md))
    }
}

/// Shared press feedback: the mockup scales controls down on `:active`
/// (0.9 for icon buttons, 0.96–0.98 for larger ones) rather than only
/// changing color, so a click feels physical.
struct PressScaleButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.murmurEase(0.09), value: configuration.isPressed)
    }
}

/// `.add-row` — dashed border, `--ink-soft` at rest, both border and text
/// turning `--accent-text` on hover.
struct AddRowButton: View {
    let title: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                MurmurIconView(icon: .plus).frame(width: 13, height: 13)
                Text(title).font(.manrope(12.5, .semibold))
            }
            .foregroundStyle(hovering ? Palette.accentText : Palette.inkSoft)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Radius.sm)
                    .strokeBorder(
                        style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .foregroundStyle(hovering ? Palette.accentText : Palette.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleButtonStyle(scale: 0.98))
        .onHover { hovering = $0 }
        .animation(.murmurEase(0.12), value: hovering)
    }
}

/// `.seg` — the segmented tone picker: hairline-bordered strip, selected
/// segment filled `--ink` with `--on-ink` text.
struct SegmentedPicker<T: Hashable>: View {
    let options: [T]
    let label: (T) -> String
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                SegmentButton(
                    title: label(option),
                    selected: selection == option,
                    isLast: index == options.count - 1
                ) { selection = option }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
        .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Palette.border, lineWidth: 1))
        .fixedSize()
    }
}

private struct SegmentButton: View {
    let title: String
    let selected: Bool
    let isLast: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.manrope(12, selected ? .medium : .regular))
                .foregroundStyle(selected ? Palette.onInk : Palette.inkSoft)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    selected ? Palette.ink : (hovering ? Palette.cardHover : Color.clear))
                .overlay(alignment: .trailing) {
                    if !isLast {
                        Rectangle().fill(Palette.border).frame(width: 1)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.murmurEase(0.12), value: hovering)
    }
}

// MARK: - Field select

/// `.field-select` — a real dropdown (unlike `.field-control`, which the
/// mockup only ever uses for two rows it never bothered wiring up as
/// interactive). Every row in Settings needs an actual working picker.
///
/// This is a plain `Button` + `.popover`, not `Menu` — `Menu` combined with
/// `.menuStyle(.borderlessButton)` silently drops the label's custom
/// background/border on this build (confirmed against a freshly-built
/// binary, not a stale one), collapsing to a bare system caret with no
/// chrome at all. A hand-rolled button is exactly how every other control
/// in this file already works, so it renders precisely what's specified
/// instead of fighting Menu's own system styling.
struct FieldSelect<T: Hashable>: View {
    let options: [T]
    let label: (T) -> String
    @Binding var selection: T
    /// Defaults match the normal light/dark `Palette` trigger; overridable
    /// for the one place this sits on a surface that's a fixed color
    /// regardless of the app's own appearance (Home's capture zone), where
    /// the theme-reactive defaults would go dark-on-dark in dark mode.
    var tint: Color = Palette.inkSoft
    var background: Color = Palette.panel
    var borderColor: Color = Palette.border
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
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(background, in: RoundedRectangle(cornerRadius: Radius.sm))
            .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(borderColor, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            FieldSelectList(options: options, label: label, selection: $selection, isOpen: $isOpen)
        }
    }
}

private struct FieldSelectList<T: Hashable>: View {
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
                        .foregroundStyle(option == selection ? Palette.ink : Palette.inkSoft)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(hovered == option ? Palette.cardHover : Color.clear)
                }
                .buttonStyle(.plain)
                .onHover { inside in hovered = inside ? option : nil }
            }
        }
        .padding(.vertical, 4)
        .frame(minWidth: 160)
    }
}

/// `.switch` — 32×19 pill, `--accent` when on, with the knob sliding.
struct MurmurToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(.murmurEase(0.18)) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Palette.toggleOn : Palette.border)
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

/// `.trow` — one row in a flat card list, with hover-revealed actions.
struct ListRowBackground: ViewModifier {
    let isLast: Bool
    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            content
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
            if !isLast {
                Rectangle().fill(Palette.border).frame(height: 1)
            }
        }
    }
}

extension View {
    func listRow(isLast: Bool) -> some View {
        modifier(ListRowBackground(isLast: isLast))
    }
}

/// `.field-row` — a label/description on the left, a control on the right.
struct FieldRow<Control: View>: View {
    let label: String
    var detail: String? = nil
    var isLast = false
    @ViewBuilder var control: Control

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.manrope(12.5, .semibold))
                        .foregroundStyle(Palette.ink)
                    if let detail {
                        Text(detail)
                            .font(.manrope(11))
                            .foregroundStyle(Palette.inkSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 16)
                control
            }
            // `.field-row { padding: 10px 2px }` — rows in a flat list sit
            // flush on the pane, not inset as if they were inside a card.
            .padding(.horizontal, 2)
            .padding(.vertical, 10)
            if !isLast {
                Rectangle().fill(Palette.border).frame(height: 1)
            }
        }
    }
}

// MARK: - Card
//
// The mockup's `.pcard`: every page repeated this same padded, rounded,
// card-colored container inline. One reusable view instead of retyping
// `.padding(20).background(Palette.card, in: RoundedRectangle(cornerRadius: 16))`
// on every page.

struct Card<Content: View>: View {
    var flat = false
    /// `.stat-card` overrides `.pcard`'s padding with 18px / 20px.
    var statPadding = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.vertical, flat ? 0 : (statPadding ? 18 : 16))
            .padding(.horizontal, flat ? 0 : (statPadding ? 20 : 18))
            .frame(maxWidth: .infinity, alignment: .leading)
            // `.pcard.flat { background: none; border: none; padding: 0 }`
            // — a flat card is a *list on the pane*, with only hairline
            // dividers between rows. Painting the card fill here anyway is
            // what made those lists look boxed-in and cramped against the
            // container edge.
            .background {
                if !flat {
                    RoundedRectangle(cornerRadius: Radius.lg).fill(Palette.card)
                }
            }
    }
}

// MARK: - Page tip

/// `.page-tip` — a small callout, icon + one line, for a single
/// contextual hint (e.g. "Snippets match exact wording, not sound-alikes").
struct PageTip: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            MurmurIconView(icon: .help)
                .frame(width: 13, height: 13)
                .foregroundStyle(Palette.inkSoft)
                .opacity(0.7)
                .padding(.top, 1)
            Text(text)
                .font(.manrope(12.5))
                .foregroundStyle(Palette.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: Radius.md))
    }
}

// MARK: - Card link

/// `.card-link` — the small accent-colored text button used throughout
/// the mockup to jump to a related page ("See the trend in Insights →").
struct CardLink: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.manrope(11, .semibold))
                .foregroundStyle(Palette.accentText)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Chip

/// `.chip` — a small rounded tag, used for Voice Profile's trait pills.
struct Chip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.manrope(11.5))
            .foregroundStyle(Palette.inkSoft)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Palette.panel, in: Capsule())
            .overlay(Capsule().stroke(Palette.border, lineWidth: 1))
    }
}

struct ChipRow: View {
    let items: [String]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(items, id: \.self) { Chip(text: $0) }
        }
    }
}

// MARK: - Pulsing dot

/// The app's one "this is live" signal — a filled dot with a ring that
/// expands and fades around it, on loop. Used for recording, in the
/// floating `StatusHUDView` and Home's capture zone; both used to
/// implement their own plain opacity-fade independently, which also read
/// as a weaker, less immediate cue than the ring — a ring says "actively
/// broadcasting," a dimming dot just says "something changed."
///
/// `maxScale` is a parameter rather than a fixed constant because the two
/// call sites have very different padding around the dot before the ring
/// would visibly collide with the pill/HUD's own edge.
struct PulsingDot: View {
    let color: Color
    var size: CGFloat = 6
    var maxScale: CGFloat = 2.4
    var active: Bool = true

    @State private var expanded = false

    var body: some View {
        ZStack {
            if active {
                Circle()
                    .stroke(color, lineWidth: 1.5)
                    .scaleEffect(expanded ? maxScale : 1)
                    .opacity(expanded ? 0 : 0.55)
            }
            Circle()
                .fill(color)
                .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
        .onAppear { startPulse() }
        .onChange(of: active) { _, _ in startPulse() }
    }

    private func startPulse() {
        expanded = false
        guard active else { return }
        withAnimation(.easeOut(duration: 1.3).repeatForever(autoreverses: false)) {
            expanded = true
        }
    }
}

// MARK: - Capture waveform

/// Instrument-scale waveform for Home's capture zone — 17 bars, 76pt tall,
/// mirrored around a lime centre bar. Decorative, unlike the floating HUD's
/// `LevelBars` (StatusHUD.swift), which follow the microphone's real level;
/// this one is sized for the editorial capture surface.
///
/// Fixed size, not stretched to the card's own width — a width-filling
/// version was tried and looked worse, not better: dozens of bars with
/// large staggered delays read as mostly static rather than alive, and
/// "big element to match a big container" isn't actually how the
/// murmurmac.com reference composes it either — there, this stays compact
/// and the surrounding space is deliberate margin, not overflow to fill.
///
/// Each bar's resting height is pre-varied rather than a shared uniform
/// baseline, so the row doesn't start flat and ripple outward — the
/// mockup's own negative `.animation(.delay())` values don't work in
/// SwiftUI (negative delays clamp to zero); varying the rest state gets a
/// non-uniform first frame without fighting that clamp.
struct CaptureWaveform: View {
    var active: Bool = true
    var color: Color = .white

    @State private var tall = false

    private static let heights: [CGFloat] = [16, 28, 42, 57, 38, 68, 47, 31]
    private static let delays: [Double] = [0, 0.10, 0.25, 0.40, 0.55, 0.70, 0.85, 1.0]
    private static let resting: [CGFloat] = [0.9, 0.55, 0.75, 0.45, 0.85, 0.35, 0.65, 0.5]
    private static let centreHeight: CGFloat = 73

    private var bars: [(height: CGFloat, delay: Double, resting: CGFloat, lime: Bool)] {
        let left = (0..<Self.heights.count).map {
            (Self.heights[$0], Self.delays[$0], Self.resting[$0], false)
        }
        let centre = (Self.centreHeight, 0.35, CGFloat(0.7), true)
        return left + [centre] + left.reversed()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 5) {
            ForEach(Array(bars.enumerated()), id: \.offset) { _, bar in
                Capsule()
                    .fill(bar.lime ? Palette.accent : color.opacity(0.28))
                    .frame(width: 6, height: bar.height * (tall ? 1 : bar.resting))
                    // Direction-dependent, not a fixed curve: becoming
                    // active repeats forever (a breathing loop that never
                    // naturally ends), becoming inactive is a single
                    // settle — reusing the repeating curve for that would
                    // just start a new infinite loop toward the resting
                    // heights instead of calming down.
                    .animation(
                        tall
                            ? .easeInOut(duration: 1.15).repeatForever(autoreverses: true).delay(bar.delay)
                            : .easeOut(duration: 0.4),
                        value: tall)
            }
        }
        .frame(height: 76)
        .onAppear { tall = active }
        .onChange(of: active) { _, isActive in tall = isActive }
    }
}

// MARK: - Keycap & shortcut row

/// `.keycap` — a small monospaced key label, e.g. "⌥1".
///
/// `tint`/`background`/`borderColor` default to the normal light/dark
/// `Palette` tokens, but are overridable — needed for the one place this
/// sits on a surface that's a fixed color regardless of the app's own
/// appearance (Home's capture zone), where the theme-reactive defaults
/// would go dark-on-dark in dark mode.
struct Keycap: View {
    let text: String
    var tint: Color = Palette.ink
    var background: Color = Palette.panel
    var borderColor: Color = Palette.border

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(borderColor, lineWidth: 1))
    }
}

/// `.trow` with a leading `.keycap` — one row of a global-shortcut list
/// (Transforms, Help).
struct ShortcutRow: View {
    let key: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Keycap(text: key)
            Text(text)
                .font(.manrope(13))
                .foregroundStyle(Palette.ink)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }
}

// MARK: - FAQ disclosure

/// The mockup's native `<details>` FAQ pattern — collapsed by default,
/// one question expanded to its answer at a time is not required, each
/// disclosure is independent (matches `<details>`'s default behavior).
struct FAQItem: View {
    let question: String
    let answer: String
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(answer)
                .font(.manrope(12.5))
                .foregroundStyle(Palette.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
                .padding(.bottom, 10)
        } label: {
            Text(question)
                .font(.manrope(13, .medium))
                .foregroundStyle(Palette.ink)
        }
        .tint(Palette.inkFaint)
        .padding(.vertical, 6)
    }
}

// MARK: - Thin scroll view

/// A scroll view with no visible scroll indicator.
///
/// macOS's own scroller is thick, sits flush against the content edge, and
/// collided with row dividers here — hidden entirely rather than replaced
/// with a thinner one. Scrolling itself (trackpad, scroll wheel) still
/// works exactly as normal; only the indicator is gone.
///
/// `.scrollIndicators(.hidden)` alone doesn't reliably suppress the native
/// `NSScroller` on macOS — confirmed empirically, it still rendered with
/// only that modifier in place — so `ScrollbarHider` reaches into the
/// underlying `NSScrollView` directly as a second, load-bearing layer.
///
/// Content fades out over the last `edgeFade` points at an edge that has
/// more to scroll to, instead of being sliced by a hard line mid-card —
/// the bottom while there's more below, the top once scrolled. At rest on
/// the first screen the top stays crisp (a page title never fades), and at
/// the very end the bottom does too.
struct ThinScrollView<Content: View>: View {
    var bottomInset: CGFloat = 0
    @ViewBuilder var content: Content

    static var edgeFade: CGFloat { 28 }

    @State private var edges = ScrollEdges()

    var body: some View {
        GeometryReader { outer in
            ScrollView(.vertical) {
                content
                    .padding(.bottom, bottomInset)
                    .background(ScrollbarHider().frame(width: 0, height: 0))
            }
            // `.never`, not `.hidden`: with System Settings' "Show scroll
            // bars: Always", `.hidden` still let AppKit reserve a legacy
            // scroller gutter on some pages — Insights' content sat ~16pt
            // short of the panel's right edge while its left edge was exact.
            .scrollIndicators(.never)
            .onScrollGeometryChange(for: ScrollEdges.self) { geo in
                ScrollEdges(
                    moreAbove: geo.contentOffset.y > 1,
                    moreBelow: geo.contentOffset.y + geo.containerSize.height < geo.contentSize.height - 1)
            } action: { _, new in
                edges = new
            }
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(edges.moreAbove ? 0 : 1), .black],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: Self.edgeFade)
                    Rectangle()
                    LinearGradient(colors: [.black, .black.opacity(edges.moreBelow ? 0 : 1)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: Self.edgeFade)
                }
                .animation(.easeOut(duration: 0.15), value: edges)
            }
            .environment(\.tooltipClipBounds, outer.frame(in: .global))
        }
    }
}

private struct ScrollEdges: Equatable {
    var moreAbove = false
    var moreBelow = false
}

/// Zero-size helper that walks up to `enclosingScrollView` once inserted
/// into the hierarchy and turns its scrollers off directly at the AppKit
/// level, bypassing whatever SwiftUI-level quirk leaves `.scrollIndicators`
/// unrespected.
///
/// `scrollerStyle` is forced to `.overlay` *before* disabling the scrollers:
/// under System Settings' "Show scroll bars: Always", `NSScrollView`
/// defaults to `.legacy` style, which reserves a fixed gutter for the
/// vertical scroller's width even once `hasVerticalScroller` is set to
/// false — this showed up as page content sitting a consistent ~15pt
/// short of the glass panel's right edge on a system with that setting.
/// Overlay-style scrollers float over content instead of reserving layout
/// space, so this closes the gap regardless of the user's system
/// preference or of any timing race with the async disable below.
private struct ScrollbarHider: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        Self.hideScrollers(around: view)
        return view
    }

    /// Re-applied on every update too, not just once: SwiftUI can
    /// reconfigure its scroll view after the first pass and hand back the
    /// legacy style (and its gutter).
    func updateNSView(_ nsView: NSView, context: Context) {
        Self.hideScrollers(around: nsView)
    }

    private static func hideScrollers(around view: NSView) {
        DispatchQueue.main.async {
            guard let scrollView = view.enclosingScrollView else { return }
            if scrollView.scrollerStyle != .overlay { scrollView.scrollerStyle = .overlay }
            if scrollView.hasVerticalScroller { scrollView.hasVerticalScroller = false }
            if scrollView.hasHorizontalScroller { scrollView.hasHorizontalScroller = false }
        }
    }
}

// MARK: - Tooltip

private struct TooltipClipBoundsKey: EnvironmentKey {
    static let defaultValue: CGRect? = nil
}

extension EnvironmentValues {
    /// Global-space bounds of the nearest scrolling container, so a tooltip
    /// can tell whether it has room to open upward before it gets clipped.
    var tooltipClipBounds: CGRect? {
        get { self[TooltipClipBoundsKey.self] }
        set { self[TooltipClipBoundsKey.self] = newValue }
    }
}

/// A small styled tooltip, replacing macOS's default `.help()` bubble.
///
/// The system tooltip uses the OS font at its own size and placement, so on
/// the hover-revealed row actions it appeared as an unstyled grey slab
/// offset away from the icon it described. This one uses the app's own type
/// and surface tokens and sits centered directly above the control.
struct MurmurTooltip: ViewModifier {
    let text: String
    var edge: VerticalEdge = .top

    @Environment(\.tooltipClipBounds) private var clipBounds
    @State private var hovering = false
    @State private var visible = false
    @State private var revealTask: Task<Void, Never>?
    @State private var controlFrame: CGRect = .zero

    /// Opening upward needs ~30pt of headroom. Inside a scroll view the
    /// first visible row has none — the container clips it — so the
    /// tooltip flips below rather than rendering half cut off.
    private var resolvedEdge: VerticalEdge {
        guard edge == .top else { return edge }
        guard let clipBounds, controlFrame != .zero else { return .top }
        return (controlFrame.minY - clipBounds.minY) < 30 ? .bottom : .top
    }

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { geo in
                    // Reads the control's current global frame only at the
                    // moment hover starts, rather than continuously tracking
                    // it via `.onChange` — that used to fire on every scroll
                    // frame for every icon on screen (each one's global Y
                    // shifts as its row scrolls), turning a list of hidden,
                    // rarely-shown tooltips into a steady stream of @State
                    // writes and made scrolling visibly laggy. A tooltip
                    // only needs to know where it is right before it opens
                    // (already gated 320ms behind `revealTask` below), not
                    // on every frame in between.
                    Color.clear
                        .onHover { inside in
                            hovering = inside
                            revealTask?.cancel()
                            if inside {
                                controlFrame = geo.frame(in: .global)
                                revealTask = Task {
                                    try? await Task.sleep(nanoseconds: 320_000_000)
                                    if !Task.isCancelled, hovering {
                                        withAnimation(.murmurEase(0.12)) { visible = true }
                                    }
                                }
                            } else {
                                visible = false
                            }
                        }
                })
            .overlay(alignment: resolvedEdge == .top ? .top : .bottom) {
                if visible, !text.isEmpty {
                    Text(text)
                        .font(.manrope(11, .medium))
                        .foregroundStyle(Palette.onInk)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Palette.ink, in: RoundedRectangle(cornerRadius: 6))
                        .shadow(color: .black.opacity(0.22), radius: 6, y: 2)
                        .offset(y: resolvedEdge == .top ? -26 : 26)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .accessibilityLabel(text)
    }
}

extension View {
    /// Styled hover tooltip. Pass an empty string to show none.
    func murmurTooltip(_ text: String, edge: VerticalEdge = .top) -> some View {
        modifier(MurmurTooltip(text: text, edge: edge))
    }
}


// MARK: - Elevation

extension View {
    /// The design's `--shadow`: `0 1px 2px` + `0 10px 28px`. CSS blur is
    /// roughly twice SwiftUI's radius, hence 1 and 14.
    func murmurShadow() -> some View {
        self
            .shadow(color: Palette.shadowNear, radius: 1, y: 1)
            .shadow(color: Palette.shadowFar, radius: 14, y: 10)
    }
}

// MARK: - Underlined tabs

/// The underlined tab row Insights, Settings and Help open with: the chosen tab in ink over a sunset underline, the
/// rest faint, a hairline under the whole row, and a sunset dot on a tab where something needs you. `selected` is nil
/// while nothing is chosen (Help while it shows search results).
struct UnderlineTabBar<Tab: Hashable>: View {
    let tabs: [Tab]
    let selected: Tab?
    var attention: Set<Tab> = []
    let title: (Tab) -> String
    let select: (Tab) -> Void

    var body: some View {
        HStack(spacing: 22) {
            ForEach(tabs, id: \.self) { tab in
                Button {
                    withAnimation(.murmurEase(0.15)) { select(tab) }
                } label: {
                    HStack(spacing: 5) {
                        Text(title(tab))
                            .font(.manrope(13.5, .semibold))
                            .foregroundStyle(selected == tab ? Palette.warmInk : Palette.warmInkFaint)
                            .lineLimit(1)
                            .fixedSize()
                        if attention.contains(tab) {
                            Circle().fill(Palette.sunset).frame(width: 6, height: 6)
                        }
                    }
                    .padding(.bottom, 10)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(selected == tab ? Palette.sunsetDeep : .clear)
                            .frame(height: 2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.warmDivider).frame(height: 1)
        }
    }
}

// MARK: - Keycaps

/// One key of a real shortcut ("⌥", "3", "Space") on a white card: a small warm-grey key with a hairline edge.
struct WarmKeycap: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.manrope(11, .semibold))
            .foregroundStyle(Palette.warmInk)
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 20)
            .background(Palette.warmRowBorder, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Palette.warmDivider, lineWidth: 0.5))
            .fixedSize()
    }
}

// MARK: - Card rows

/// One row of a white card that can lead somewhere (Help's answers, Legal's components): an optional small eyebrow, a
/// title, a line of text, and whatever sits on the right. With an `action` the whole row is a button with a hover wash
/// inset from the card's rules; the rule below is drawn unless it's the card's last row.
struct CardRow<Trailing: View>: View {
    let title: String
    let detail: String
    var eyebrow: String? = nil
    var isLast = false
    var action: (() -> Void)? = nil
    @ViewBuilder var trailing: Trailing

    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            if let action {
                Button(action: action) { content }
                    .buttonStyle(.plain)
                    .onHover { hovering = $0 }
            } else {
                content
            }
            if !isLast {
                Rectangle().fill(Palette.warmRowBorder).frame(height: 1)
            }
        }
    }

    private var content: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                if let eyebrow {
                    Text(eyebrow.uppercased())
                        .font(.manrope(9.5, .semibold))
                        .kerning(0.8)
                        .foregroundStyle(Palette.warmInkFaint)
                }
                Text(title)
                    .font(.manrope(13, .semibold))
                    .foregroundStyle(Palette.warmInk)
                Text(detail)
                    .font(.manrope(12))
                    .foregroundStyle(Palette.warmInkSoft)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 10)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(hovering ? Palette.hoverWash : .clear)
                .padding(.vertical, 4)
        }
        .padding(.horizontal, -10)
        .contentShape(Rectangle())
        .animation(.murmurEase(0.12), value: hovering)
    }
}

/// Where a `CardRow` leads: a quiet name and a chevron — or a ↗ when it opens a web page.
struct RowDestinationLabel: View {
    let title: String
    var external = false

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.manrope(12, .medium))
                .foregroundStyle(Palette.warmInkSoft)
            if external {
                Text("↗")
                    .font(.manrope(12, .medium))
                    .foregroundStyle(Palette.warmInkFaint)
            } else {
                MurmurIconView(icon: .caret)
                    .frame(width: 9, height: 9)
                    .foregroundStyle(Palette.warmInkFaint)
            }
        }
        .fixedSize()
    }
}
