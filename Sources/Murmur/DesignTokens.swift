import AppKit
import CoreText
import SwiftUI

// MARK: - Manrope

/// Registers the bundled Manrope static-weight fonts (extracted from the
/// variable font used in the design mockup) so `Font.manrope` resolves.
/// Must run once, before any view renders — called from
/// `AppDelegate.applicationDidFinishLaunching`.
enum FontLoader {
    private static let weights = [
        "ExtraLight", "Light", "Regular", "Medium", "SemiBold", "Bold", "ExtraBold",
    ]

    static func registerManrope() {
        for weight in weights {
            let name = "Manrope-\(weight)"
            // Packaged .app: files live under Contents/Resources/Fonts —
            // Bundle.main resolves that correctly. SwiftPM's Bundle.module
            // accessor instead looks for a `Murmur_Murmur.bundle` at the
            // app's top level, which trips codesign's resource sealing, so
            // the shipped app doesn't use it. `swift run` during
            // development has no such Resources folder, so it falls back
            // to Bundle.module there.
            let url = Bundle.main.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts")
                ?? Bundle.module.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts")
            guard let url else { continue }
            var error: Unmanaged<CFError>?
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        }
    }
}

enum ManropeWeight {
    case extraLight, light, regular, medium, semibold, bold, extraBold

    fileprivate var postScriptName: String {
        switch self {
        case .extraLight: return "Manrope-ExtraLight"
        case .light: return "Manrope-Light"
        case .regular: return "Manrope-Regular"
        case .medium: return "Manrope-Medium"
        case .semibold: return "Manrope-SemiBold"
        case .bold: return "Manrope-Bold"
        case .extraBold: return "Manrope-ExtraBold"
        }
    }
}

extension Font {
    /// Manrope at the given size/weight. Falls back to the system font
    /// automatically if registration ever fails — `Font.custom` degrades
    /// gracefully rather than crashing on a missing PostScript name.
    static func manrope(_ size: CGFloat, _ weight: ManropeWeight = .regular) -> Font {
        .custom(weight.postScriptName, size: size)
    }
}

// MARK: - Palette (Murmur: black/cream/lime, sampled from the approved design)

enum Palette {
    private static func dynamic(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? dark : light
        })
    }

    // Surfaces
    static let shell = dynamic(
        NSColor(red: 0.953, green: 0.953, blue: 0.953, alpha: 1),
        NSColor(red: 0.055, green: 0.059, blue: 0.071, alpha: 1))
    // Dark value corrected 2026-09-17: every redesigned page's own card/row
    // surface (`InsightsView`'s chart/fixes/category/top-apps cards,
    // `NotetakerView`, `SettingsView`'s tiles, ...) fills itself with
    // `Palette.panel` — a straight swap for the mockup's hardcoded
    // `Color.white`, since `panel` is the one existing token whose light
    // value already stays pure white. But `panel`'s own dark value had
    // never been updated to match: it was still this palette's old,
    // unrelated near-black (`#17181C`, cooler/bluer), while every one of
    // those same cards is `#282622` — `Palette.card`'s dark value,
    // byte-identical — in the actual `*Dark.dc.html` artboards. The fix is
    // this one value, not the ~60 call sites: `panel` dark now matches
    // `card` dark exactly, which is what the mockups already do.
    static let panel = dynamic(
        .white,
        NSColor(red: 0.157, green: 0.149, blue: 0.133, alpha: 1))
    static let card = dynamic(
        NSColor(red: 0.918, green: 0.933, blue: 0.922, alpha: 1),
        NSColor(red: 0.157, green: 0.149, blue: 0.133, alpha: 1))
    static let cardHover = dynamic(
        NSColor(red: 0.871, green: 0.886, blue: 0.867, alpha: 1),
        NSColor(red: 0.196, green: 0.184, blue: 0.161, alpha: 1))

    // Text
    static let ink = dynamic(.black, NSColor(red: 0.961, green: 0.961, blue: 0.961, alpha: 1))
    static let inkSoft = dynamic(
        NSColor(red: 0.416, green: 0.416, blue: 0.424, alpha: 1),
        NSColor(red: 0.659, green: 0.671, blue: 0.651, alpha: 1))
    static let inkFaint = dynamic(
        NSColor(red: 0.604, green: 0.620, blue: 0.608, alpha: 1),
        NSColor(red: 0.431, green: 0.443, blue: 0.424, alpha: 1))
    static let onInk = dynamic(.white, NSColor(red: 0.090, green: 0.094, blue: 0.110, alpha: 1))

    static let border = dynamic(
        NSColor(red: 0.871, green: 0.886, blue: 0.867, alpha: 1),
        NSColor.white.withAlphaComponent(0.1))

    // Accent (lime) — the fill itself doesn't shift between modes, only
    // the "text version" (accentText) and its soft wash do, so it keeps
    // reading as accent-colored text against either surface.
    //
    // This is deliberately the palest of the brand's three limes, not a
    // drift from the other two:
    //   - #F0FAA1 (here) — in-app UI fills: toggles, pills, highlighted
    //     nav text. Sits behind and beside body text constantly, so it
    //     has to stay calm; the saturated brand lime below reads as
    //     neon the moment it's a solid filled capsule next to prose.
    //   - #C8F137 — Resources/Murmur.svg's accent dots (the app icon).
    //     Icons are small, isolated, and looked at for a second, not
    //     read past — they can afford (and need) more punch to register
    //     at 16px in a menu bar.
    //   - #EAFF58 — murmurmac.com's --lime. A marketing page sells the
    //     brand itself, so its accent is the boldest of the three.
    // Each shade is scoped to a different kind of surface on purpose;
    // this isn't the one to converge on the other two.
    static let accent = Color(red: 0.941, green: 0.980, blue: 0.631)
    static let accentInk = Color.black
    static let accentText = dynamic(
        NSColor(red: 0.373, green: 0.431, blue: 0.157, alpha: 1),
        NSColor(red: 0.941, green: 0.980, blue: 0.631, alpha: 1))
    static let accentSoft = dynamic(
        NSColor(red: 190.0 / 255, green: 205.0 / 255, blue: 60.0 / 255, alpha: 0.22),
        NSColor(red: 0.941, green: 0.980, blue: 0.631, alpha: 0.16))

    static let danger = dynamic(
        NSColor(red: 0.678, green: 0.235, blue: 0.165, alpha: 1),
        NSColor(red: 0.878, green: 0.478, blue: 0.373, alpha: 1))
    // `--shadow` is two layers, and far stronger in dark mode (0.35/0.40)
    // than light (0.04/0.07) — a single faint shadow reads as flat on a
    // dark surface, which is what a naive port produces.
    static let shadowNear = dynamic(
        NSColor(srgbRed: 20 / 255, green: 19 / 255, blue: 17 / 255, alpha: 0.04),
        NSColor.black.withAlphaComponent(0.35))
    static let shadowFar = dynamic(
        NSColor(srgbRed: 20 / 255, green: 19 / 255, blue: 17 / 255, alpha: 0.07),
        NSColor.black.withAlphaComponent(0.40))

    /// `.stat-card-trend` — its own green, distinct from the chart mark.
    static let trendUp = dynamic(
        NSColor(red: 0.286, green: 0.443, blue: 0.224, alpha: 1),
        NSColor(red: 0.659, green: 0.851, blue: 0.494, alpha: 1))
    static let chartMark = dynamic(
        NSColor(red: 0.404, green: 0.463, blue: 0.165, alpha: 1),
        NSColor(red: 0.541, green: 0.600, blue: 0.220, alpha: 1))

    /// Toggle "on" track. The design's own CSS fills this with the raw
    /// `--accent` pastel, which reads fine as a thin text color or a small
    /// dot but turns neon as a solid filled capsule — and worse in dark
    /// mode, where that same light pastel sits directly on a near-black
    /// panel instead of a white one. Reuses `chartMark`'s already-toned,
    /// same-hue step instead of inventing a third green.
    static let toggleOn = chartMark

    /// Alias kept for pages not yet ported to the new design — the mockup
    /// uses the plain card surface for callouts (`.page-tip`, availability
    /// banners) rather than a separate tinted color.
    static let tint = card

    // MARK: - Home redesign (Sep 2026 "Main" canvas)
    //
    // Originally fixed colors sampled directly from Main.dc.html, with no
    // dark-mode variant — pages using them pinned `.environment(\.color
    // Scheme, .light)` specifically because there was nothing to adapt to
    // (see HomeView.swift and friends). Dark values below (2026-09-17) are
    // sampled directly, hex for hex, from the design canvas's own
    // `*Dark.dc.html` artboards (Main, Settings, and friends — a real,
    // already-designed dark mockup for every page, not just the light
    // one) — not derived, composited, or reasoned about independently. A
    // first pass at this got it wrong by deriving values from an unrelated
    // reference theme's abstract token system instead of these actual
    // mockups, which is what this replaces.
    //
    // The clearest finding from reading the real mockups: the sunset/
    // orange accent family (`sunset`, `sunsetDeep`) does not shift hue or
    // lightness between modes *at all* — every one of the ~135 uses of
    // `#EA6539` across all 16 dark artboards is the identical hex light
    // mode already uses. Dark adapts by wrapping it in opacity washes
    // (`sunsetSoft`'s icon-badge background is literally `sunset` at 15%,
    // sampled directly as `rgba(234,101,57,0.15)`), never by re-deriving
    // the color itself.
    // Second clearest finding: there is no dark-mode gradient at all —
    // `homeGradient`'s two light stops (`#DCE8E0`/`#F7F5F0`) both become
    // the same flat `#0C0B08`, not two different dark tones as a first
    // pass assumed a "diagonal structure" needed preserving.

    /// The app-body backdrop behind the floating rail and Home's glass
    /// panel: a soft sage-to-cream diagonal in light, `linear-gradient(
    /// 160deg, #DCE8E0 0%, #F7F5F0 55%)`. Both stops become the same flat
    /// `#0C0B08` in dark — every `*Dark.dc.html` artboard's own page
    /// background is one solid color, not a gradient.
    static let homeGradientTop = dynamic(
        NSColor(red: 0.863, green: 0.910, blue: 0.878, alpha: 1),
        NSColor(red: 0.047, green: 0.043, blue: 0.031, alpha: 1))
    static let homeGradientBottom = dynamic(
        NSColor(red: 0.969, green: 0.961, blue: 0.941, alpha: 1),
        NSColor(red: 0.047, green: 0.043, blue: 0.031, alpha: 1))
    static let homeGradient = LinearGradient(
        colors: [homeGradientTop, homeGradientBottom],
        startPoint: UnitPoint(x: 0.33, y: 0.03),
        endPoint: UnitPoint(x: 0.67, y: 0.97))
    /// The titlebar's own fill — a shade apart from `homeGradientTop` so
    /// the custom titlebar chrome reads as a distinct band rather than
    /// fusing invisibly with the body below it. Dark value is every dark
    /// artboard's own titlebar background, `#020302` — darker than the
    /// page itself, not lighter; a first pass had this backwards.
    static let homeTitlebar = dynamic(
        NSColor(red: 0.777, green: 0.819, blue: 0.790, alpha: 1),
        NSColor(red: 0.008, green: 0.012, blue: 0.008, alpha: 1))

    /// The brand accent, `#EA6539` — also Home's capture card, as a solid
    /// fill. Dark keeps the value byte-identical to light — sampled
    /// directly from the dark artboards, which reuse the exact same hex
    /// throughout.
    static let sunset = dynamic(
        NSColor(red: 0.918, green: 0.396, blue: 0.224, alpha: 1),
        NSColor(red: 0.918, green: 0.396, blue: 0.224, alpha: 1))
    /// `.stat-strip`'s link and a history row's newest timestamp — the
    /// deeper, more legible orange used for small text rather than fills.
    /// Dark artboards use plain `#EA6539` for this too (the "Templates →"/
    /// "Settings →" related-link rows, sampled directly) — identical to
    /// `sunset`, not a separate brightened step; the accent family simply
    /// doesn't have a "deep" variant once inverted onto a dark surface.
    static let sunsetDeep = dynamic(
        NSColor(red: 0.761, green: 0.271, blue: 0.122, alpha: 1),
        NSColor(red: 0.918, green: 0.396, blue: 0.224, alpha: 1))
    /// Ask Murmur's assistant-avatar circle (`#FBE9E0`) — a pale peach
    /// tint, distinct from `sunsetPale`. Dark uses the same treatment the
    /// Settings tiles' own icon badges sample directly: `sunset`'s own RGB
    /// at 15% opacity (`rgba(234,101,57,0.15)` in the artboards), not a
    /// separately-composited muted color.
    static let sunsetSoft = dynamic(
        NSColor(red: 0.984, green: 0.914, blue: 0.878, alpha: 1),
        NSColor(red: 0.918, green: 0.396, blue: 0.224, alpha: 0.15))

    /// Warm neutral ink scale for text on the new light surfaces (hero
    /// headline, stat strip, history rows) — a warmer-toned sibling of
    /// `ink`/`inkSoft`/`inkFaint`, not a replacement for them. Dark values
    /// are sampled directly from the dark artboards' own text colors:
    /// `#F2F0EA` (620 uses — the overwhelming majority of all body text),
    /// `#A8A398` (182 uses — section labels, secondary icon strokes),
    /// `#8A867C` (151 uses — the faint tier), `#6B675E` (47 uses — the
    /// faintest, disclosure-chevron tier).
    static let warmInk = dynamic(
        NSColor(red: 0.110, green: 0.110, blue: 0.106, alpha: 1),
        NSColor(red: 0.949, green: 0.941, blue: 0.918, alpha: 1))
    static let warmInkSoft = dynamic(
        NSColor(red: 0.471, green: 0.455, blue: 0.424, alpha: 1),
        NSColor(red: 0.659, green: 0.639, blue: 0.596, alpha: 1))
    static let warmInkFaint = dynamic(
        NSColor(red: 0.608, green: 0.592, blue: 0.561, alpha: 1),
        NSColor(red: 0.541, green: 0.525, blue: 0.486, alpha: 1))
    /// A step fainter still — Insights' chart axis labels (`#B0ACA3`).
    static let warmInkFainter = dynamic(
        NSColor(red: 0.690, green: 0.675, blue: 0.639, alpha: 1),
        NSColor(red: 0.420, green: 0.404, blue: 0.369, alpha: 1))

    /// Sampled directly from every plain divider line and bordered chip
    /// across all 16 dark artboards: `rgba(255,255,255,0.10)`, used 105+
    /// times with no variation — translucent, not a separately-composited
    /// opaque tone as a first pass built.
    static let warmDivider = dynamic(
        NSColor(red: 0.855, green: 0.839, blue: 0.800, alpha: 1),
        NSColor.white.withAlphaComponent(0.10))
    /// Opaque near-white fill for small chips sitting directly on the
    /// glass panel (the search field, the empty-state placeholder) — kept
    /// solid rather than translucent so they still read as distinct
    /// surfaces regardless of what's blurred behind them, in light mode.
    ///
    /// Dark value corrected 2026-09-17: this token is also the row-hover
    /// wash at ~90 call sites (`hovering ? Palette.warmRowBorder :
    /// .clear`) and the hairline/gridline/track color at dozens more
    /// (`Rectangle().fill(Palette.warmRowBorder).frame(height: 1)`,
    /// `TrendChart`'s gridlines, `UsageBarRow`'s progress track). An
    /// opaque `#282622` — the same value as `card` — made every one of
    /// those hover washes invisible against a card of the same color, and
    /// every divider/track/icon-chip render as a heavy solid square
    /// instead of a subtle line, instead of the translucent
    /// `rgba(255,255,255,0.10)` every *Dark.dc.html artboard actually
    /// uses for all of them. The earlier reasoning (sampled from a
    /// dropdown-trigger chip's own *background*) mixed up two different
    /// mockup elements: the opaque `#282622` there is `Palette.card`'s
    /// value, and the `rgba(255,255,255,0.10)` alongside it is this
    /// token's — not one value shared between both roles.
    static let warmRowBorder = dynamic(
        NSColor(red: 0.941, green: 0.933, blue: 0.906, alpha: 1),
        NSColor.white.withAlphaComponent(0.10))
    /// History-row hairlines now that they sit directly on the frosted
    /// glass panel instead of a solid white card: `warmDivider`'s fixed
    /// near-white tone nearly vanished against the gradient-tinted
    /// material, so this is translucent instead — it keeps working no
    /// matter what's blurred behind it, in either mode.
    static let glassDivider = dynamic(
        NSColor.black.withAlphaComponent(0.08),
        NSColor.white.withAlphaComponent(0.10))

    /// A subtle hover wash for rows with no other selected/hover treatment
    /// (the sidebar's own unselected-row and group-header hover states).
    /// The dark artboards are static exports with no visible `:hover`
    /// state to sample directly, so this is inferred, not sourced: white
    /// at roughly the same felt weight the light value's black 4% has,
    /// scaled up (13%) since white-on-dark-near-black needs more alpha to
    /// read at all. Previously hardcoded `Color.black.opacity(...)` at
    /// each call site, which this replaces — black-on-near-black in dark
    /// mode was invisible regardless of the exact number chosen here.
    static let hoverWash = dynamic(
        NSColor.black.withAlphaComponent(0.04),
        NSColor.white.withAlphaComponent(0.13))

    /// The sidebar's active-row pill, `#161615` — fixed rather than
    /// `railActive`'s dynamic value, since the rail itself now sits
    /// directly on `homeGradient` instead of the always-dark `rail` fill.
    ///
    /// Stays dark in both modes rather than inverting — corrected 2026-09-
    /// 17 twice over. First correction: an initial attempt inverted this to
    /// a light/cream solid (reasoning from an unrelated reference theme's
    /// own token system rather than Murmur's actual dark mockups), which
    /// broke every *other* use of this token — it's not just the sidebar
    /// highlight, it's also the solid fill behind white text/icons on
    /// "Done"/"Save"/"Create" buttons (AppProfilesView, NotetakerController,
    /// NotetakerView, ScratchpadPanelController, TransformsView, AskView)
    /// and the always-visible recording HUD pill (NavBarHUD, StatusHUD) —
    /// 8 of its 10 call sites need an opaque dark fill white text stays
    /// legible on, in *either* mode. Second correction: sampled the real
    /// value from `MainDark.dc.html` itself — the active "Home" row's own
    /// `background: #403D36`, with `color: #FFFFFF` (not `warmInk`) on the
    /// label — rather than reasoning about it from that same unrelated
    /// reference theme's `bg.selected` token.
    static let navActivePill = dynamic(
        NSColor(red: 0.086, green: 0.086, blue: 0.082, alpha: 1),
        NSColor(red: 0.251, green: 0.239, blue: 0.212, alpha: 1))

    /// The recording HUD — the pill at the bottom of the screen, the nav bar under it, and the pill that grows out of
    /// the notch — is true black, the exact colour of a MacBook's notch, so all of them match it and the notch pill
    /// reads as the notch itself expanding. (They used `navActivePill`, a near-black that showed as a seam next to the
    /// real notch; that token stays as it was for the buttons and the sidebar.) The same in both appearances.
    static let hudBlack = Color(red: 0, green: 0, blue: 0)
}

// MARK: - Radii & motion

enum Radius {
    static let sm: CGFloat = 9
    static let md: CGFloat = 12
    static let lg: CGFloat = 20
    static let xl: CGFloat = 28
}

extension Animation {
    /// Matches the mockup's cubic-bezier(0.4, 0, 0.2, 1) easing.
    static func murmurEase(_ duration: Double = 0.2) -> Animation {
        .timingCurve(0.4, 0, 0.2, 1, duration: duration)
    }
}
