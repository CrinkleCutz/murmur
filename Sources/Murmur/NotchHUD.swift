import AppKit
import CoreGraphics
import SwiftUI

// MARK: - Notch HUD
//
// On a Mac whose built-in display has a notch, the recording HUD is the notch itself growing — in the notch's own true
// black, so it reads as the notch expanding rather than a window on top of it.
//
// It grows the way Apple's own Dynamic Island does in its compact form: sideways, at the notch's own height, with the
// target app's icon snug on the left of the sensor and the bars (your real voice level) snug on the right — nothing
// hangs down over the app you're dictating into. Only when there's something to read ("Didn't hear anything", a
// transform's progress) does it drop a row below the notch, like the island's expanded form. Hands-free adds a Stop
// button beside the bars.
//
// It is one more *presentation* of the state `StatusHUDController` already tracks: nothing about when the HUD shows,
// what it says or how the dictation runs is different, and it only exists while a dictation is in flight. A screen
// without a notch (an external display, a Mac that has none) keeps the pill at the bottom.

// MARK: - Geometry

/// Where the notch is and how big the pill that grows out of it is. Numbers in, numbers out — no screen needed, so it
/// can be tested. A screen's notch size depends on its scaling mode, so this is read again at every show.
enum NotchGeometry {
    /// Room on each side of the notch: the target app's icon on the left, the bars on the right.
    static let wing: CGFloat = 58
    /// Extra room each side while hands-free, for the Stop button beside the bars (both sides, so it stays centred).
    static let handsFreeExtra: CGFloat = 24
    /// The row under the notch that carries a message, when there is one.
    static let labelRow: CGFloat = 30
    /// The widest the pill ever gets beyond the notch on each side — a long message.
    static let maxWing: CGFloat = 170
    /// Slack around the pill inside its panel, for the flared top corners and a spring that overshoots.
    static let margin: CGFloat = 16

    struct Placement: Equatable {
        /// The notch, in global screen coordinates (bottom-left origin, like `NSScreen.frame`).
        let notch: CGRect
        /// The compact pill it grows into while you talk: the notch plus a wing each side, at the notch's own height.
        let pill: CGSize
        /// The panel that holds the pill in any state: centred on the notch and flush with the top of the screen.
        let panel: CGRect
    }

    /// nil when the screen has no notch. Only the *widths* of the two areas beside the notch are used, so it doesn't
    /// matter whether AppKit reports them in global or screen-local coordinates.
    static func placement(screenFrame: CGRect, safeTop: CGFloat, leftWidth: CGFloat?, rightWidth: CGFloat?) -> Placement? {
        guard safeTop > 0, let left = leftWidth, let right = rightWidth, left > 0, right > 0 else { return nil }
        let width = screenFrame.width - left - right
        // A notch is a couple of hundred points wide and sits well inside the screen.
        guard width > 60, width < screenFrame.width / 2 else { return nil }
        let notch = CGRect(x: screenFrame.minX + left, y: screenFrame.maxY - safeTop, width: width, height: safeTop)
        let pill = CGSize(width: width + 2 * wing, height: safeTop)
        let largest = CGSize(width: width + 2 * maxWing, height: safeTop + labelRow)
        let panel = CGRect(x: notch.midX - largest.width / 2 - margin, y: screenFrame.maxY - largest.height - margin,
                           width: largest.width + 2 * margin, height: largest.height + margin)
        return Placement(notch: notch, pill: pill, panel: panel)
    }

    /// How big the pill is for a state: compact while you talk and while it transcribes (a little wider hands-free),
    /// a row taller — and as wide as the words need — when there's a message.
    static func pillSize(for state: HUDState, placement: Placement, textWidth: CGFloat) -> CGSize {
        let notch = placement.notch.size
        if state.text != nil {
            let wing = min(maxWing, max(wing, (textWidth + 48 - notch.width) / 2))
            return CGSize(width: notch.width + 2 * wing, height: notch.height + labelRow)
        }
        let extra = state.isHandsFree ? handsFreeExtra : 0
        return CGSize(width: notch.width + 2 * (wing + extra), height: notch.height)
    }

    @MainActor
    static func placement(of screen: NSScreen) -> Placement? {
        placement(screenFrame: screen.frame, safeTop: screen.safeAreaInsets.top,
                  leftWidth: screen.auxiliaryTopLeftArea?.width, rightWidth: screen.auxiliaryTopRightArea?.width)
    }
}

// MARK: - Shape

/// The HUD's silhouette. Flush with the top edge of the screen, flared where it meets that edge the way the notch's own
/// corners are, rounded at the bottom. `progress` 0 is exactly the notch — invisible, black on black — and 1 the full
/// pill; in between it grows smoothly, so the pill looks like the notch expanding. The pill's size animates too, so
/// going hands-free or showing a message grows it rather than jumping. Compact, it keeps the notch's own corner radius
/// (a wider notch); with a message row it rounds out like the island's expanded form.
struct NotchPillShape: Shape {
    var collapsed: CGSize
    var expanded: CGSize
    var progress: CGFloat

    static let earRadius: CGFloat = 10
    static let bottomRadius: CGFloat = 22
    /// Bigger than the notch's own corners, so the closed shape never pokes out of the cutout.
    static let closedBottomRadius: CGFloat = 14

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(progress, AnimatablePair(expanded.width, expanded.height)) }
        set {
            progress = newValue.first
            expanded = CGSize(width: newValue.second.first, height: newValue.second.second)
        }
    }

    func path(in rect: CGRect) -> Path {
        let t = progress
        let width = collapsed.width + (expanded.width - collapsed.width) * t
        let height = collapsed.height + (expanded.height - collapsed.height) * t
        let tall = min(max((expanded.height - collapsed.height) / NotchGeometry.labelRow, 0), 1)
        let target = Self.closedBottomRadius + (Self.bottomRadius - Self.closedBottomRadius) * tall
        let radius = min(Self.closedBottomRadius + (target - Self.closedBottomRadius) * t, height / 2, width / 2)
        let ear = Self.earRadius * max(0, min(t, 1.2))
        let body = CGRect(x: rect.midX - width / 2, y: rect.minY, width: width, height: height)

        var path = UnevenRoundedRectangle(
            topLeadingRadius: 0, bottomLeadingRadius: radius, bottomTrailingRadius: radius, topTrailingRadius: 0,
            style: .continuous).path(in: body)
        guard ear > 0.5 else { return path }

        // The flare: black that fills the corner between the top edge and each side, so the silhouette widens into the
        // screen edge instead of meeting it at a right angle. Each overlaps the body by a point, then the union
        // removes the seam.
        var left = Path()
        left.move(to: CGPoint(x: body.minX - ear, y: body.minY))
        left.addQuadCurve(to: CGPoint(x: body.minX, y: body.minY + ear), control: CGPoint(x: body.minX, y: body.minY))
        left.addLine(to: CGPoint(x: body.minX + 1, y: body.minY + ear))
        left.addLine(to: CGPoint(x: body.minX + 1, y: body.minY))
        left.closeSubpath()
        var right = Path()
        right.move(to: CGPoint(x: body.maxX + ear, y: body.minY))
        right.addQuadCurve(to: CGPoint(x: body.maxX, y: body.minY + ear), control: CGPoint(x: body.maxX, y: body.minY))
        right.addLine(to: CGPoint(x: body.maxX - 1, y: body.minY + ear))
        right.addLine(to: CGPoint(x: body.maxX - 1, y: body.minY))
        right.closeSubpath()
        path = path.union(left).union(right)
        return path
    }
}

// MARK: - Content

/// What the notch presentation is showing, separate from `HUDModel` (what the dictation is doing).
@MainActor
final class NotchPresentation: ObservableObject {
    @Published var placement: NotchGeometry.Placement
    /// The pill is open (or opening). False collapses it back into the notch.
    @Published var expanded = false
    /// Reduce Motion: no growing, just a fade.
    @Published var reduceMotion = false
    /// The app icon to keep drawing while the pill shrinks back, after `HUDModel` has already let go of it.
    @Published var frozenIcon: NSImage?

    init(placement: NotchGeometry.Placement) {
        self.placement = placement
    }
}

struct NotchHUDView: View {
    @ObservedObject var model: HUDModel
    @ObservedObject var presentation: NotchPresentation
    var onStop: () -> Void = {}

    @State private var textWidth: CGFloat = 0

    private static let spring = Animation.spring(response: 0.34, dampingFraction: 0.8)

    var body: some View {
        let placement = presentation.placement
        let open = presentation.expanded
        let reduce = presentation.reduceMotion
        let size = NotchGeometry.pillSize(for: model.state, placement: placement, textWidth: textWidth)
        ZStack(alignment: .top) {
            // True black, no outline, no shadow: the same colour as the notch it grows out of, so the two are one
            // shape. (The bottom pill's hairline would show a seam here.)
            NotchPillShape(collapsed: placement.notch.size, expanded: size, progress: (open || reduce) ? 1 : 0)
                .fill(Palette.hudBlack)
                .opacity(reduce && !open ? 0 : 1)
                .animation(reduce ? .easeOut(duration: 0.15) : Self.spring, value: open)
                .animation(reduce ? .easeOut(duration: 0.15) : Self.spring, value: size)
            content(placement, size: size)
                .frame(width: size.width, height: size.height, alignment: .top)
                .opacity(open ? 1 : 0)
                .animation(.easeOut(duration: open ? 0.18 : 0.1).delay(open && !reduce ? 0.1 : 0), value: open)
                .animation(reduce ? .easeOut(duration: 0.15) : Self.spring, value: size)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .background(alignment: .top) {
            // Measures the message, so the pill can be exactly as wide as it needs.
            Text(model.state.text ?? "")
                .font(.manrope(12.5, .semibold))
                .fixedSize()
                .hidden()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.state.label)
    }

    /// The icon and the bars either side of the notch, snug against it; a message on the row under it. Nothing sits
    /// where the notch is.
    private func content(_ placement: NotchGeometry.Placement, size: CGSize) -> some View {
        let wing = max(0, (size.width - placement.notch.width) / 2)
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                leftWing
                    .padding(.trailing, 14)
                    .frame(width: wing, alignment: .trailing)
                Color.clear
                    .frame(width: placement.notch.width)
                rightWing
                    .padding(.leading, 14)
                    .frame(width: wing, alignment: .leading)
            }
            .frame(height: placement.notch.height)
            if let text = model.state.text {
                Text(text)
                    .font(.manrope(12.5, .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.top, 3)
                    .frame(maxWidth: .infinity, minHeight: NotchGeometry.labelRow, maxHeight: NotchGeometry.labelRow,
                           alignment: .top)
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder private var leftWing: some View {
        switch model.state {
        case .notice:
            HUDLockGlyph(size: 16)
        case .failure:
            Image(systemName: "mic.slash.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.danger)
        case .info(_, let symbol):
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
        default:
            if let icon = model.targetAppIcon ?? presentation.frozenIcon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 22, height: 22)
            }
        }
    }

    @ViewBuilder private var rightWing: some View {
        let state = model.state
        HStack(spacing: 8) {
            if state.isRecording || state.isProcessing {
                LevelBars(model: model, count: 7, barWidth: 2.5, spacing: 2, maxHeight: 16)
            }
            if state == .done {
                HUDCheck(size: 18)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
            if state.isHandsFree {
                Button(action: onStop) {
                    ZStack {
                        Circle().fill(.white)
                        RoundedRectangle(cornerRadius: 1.5).fill(Palette.hudBlack).frame(width: 6, height: 6)
                    }
                    .frame(width: 18, height: 18)
                    .contentShape(Circle())
                }
                .buttonStyle(PressScaleButtonStyle(scale: 0.88))
                .accessibilityLabel("Stop and paste")
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
    }
}

// MARK: - Panel

/// A panel that is allowed to sit in the menu bar — AppKit otherwise pushes a window's frame down below it.
private final class NotchPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class NotchHUDController {
    private var panel: NotchPanel?
    private var presentation: NotchPresentation?
    private var model: HUDModel?
    private var collapseTask: Task<Void, Never>?

    /// Settings → Dictation → "Show recording in the notch" (`notchHUD`); off is the way back to the bottom pill on every screen.
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: "notchHUD") as? Bool ?? true }

    /// Hands-free's Stop button.
    var onStop: () -> Void = {}

    /// `--hud-check`: the panel stays fully transparent, and motion is off so the pill is open at once.
    var isInvisibleForCheck = false
    var panelForCheck: NSPanel? { panel }

    var isShowing: Bool { panel?.isVisible ?? false }

    func show(model: HUDModel, placement: NotchGeometry.Placement) {
        collapseTask?.cancel()
        collapseTask = nil
        let isNew = panel == nil
        let panel = existingOrNewPanel(model: model, placement: placement)
        let presentation = self.presentation!
        if presentation.placement != placement { presentation.placement = placement }
        if panel.frame != placement.panel { panel.setFrame(placement.panel, display: true, animate: false) }
        presentation.frozenIcon = nil
        presentation.reduceMotion = isInvisibleForCheck || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = isInvisibleForCheck ? 0 : 1
        // Clickable only while there's something to click (hands-free's Stop); click-through otherwise.
        panel.ignoresMouseEvents = !model.state.isHandsFree
        // `orderFrontRegardless` rather than `makeKeyAndOrderFront`, exactly like the bottom pill: the HUD must never
        // take key status, or the dictation would paste into Murmur instead of the app being dictated into.
        panel.orderFrontRegardless()
        guard !presentation.expanded else { return }
        if isNew {
            // The first frame has to be drawn closed for the growth to be seen.
            Task { @MainActor [weak presentation] in
                try? await Task.sleep(nanoseconds: 30_000_000)
                presentation?.expanded = true
            }
        } else {
            presentation.expanded = true
        }
    }

    /// Shrinks back into the notch, then takes the panel off screen. Safe to call when nothing is showing.
    func hide(animated: Bool = true) {
        guard let panel, panel.isVisible, let presentation else { return }
        if !animated {
            collapseTask?.cancel()
            collapseTask = nil
            presentation.expanded = false
            panel.orderOut(nil)
            return
        }
        guard collapseTask == nil else { return }
        presentation.frozenIcon = model?.targetAppIcon
        panel.ignoresMouseEvents = true
        presentation.expanded = false
        let delay: UInt64 = presentation.reduceMotion ? 200_000_000 : 380_000_000
        collapseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self else { return }
            self.collapseTask = nil
            self.panel?.orderOut(nil)
            self.presentation?.frozenIcon = nil
        }
    }

    private func existingOrNewPanel(model: HUDModel, placement: NotchGeometry.Placement) -> NotchPanel {
        if let panel { return panel }
        self.model = model
        let presentation = NotchPresentation(placement: placement)
        self.presentation = presentation

        let hosting = FirstClickHostingView(rootView: NotchHUDView(
            model: model, presentation: presentation, onStop: { [weak self] in self?.onStop() }))
        hosting.frame = NSRect(origin: .zero, size: placement.panel.size)
        // Black whatever the Mac's appearance, so its colours are resolved for a dark surface.
        hosting.appearance = NSAppearance(named: .darkAqua)
        // The view hangs from the top edge of the screen, which is the notch's safe area: don't let SwiftUI inset it,
        // and don't let its size push on the window's.
        hosting.safeAreaRegions = []
        hosting.sizingOptions = []

        let newPanel = NotchPanel(
            contentRect: placement.panel,
            // .nonactivatingPanel is the load-bearing flag — without it, showing this window activates Murmur and
            // breaks the paste.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        newPanel.contentView = hosting
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = false
        newPanel.level = .statusBar
        newPanel.ignoresMouseEvents = true
        newPanel.hidesOnDeactivate = false
        newPanel.isReleasedWhenClosed = false
        newPanel.becomesKeyOnlyIfNeeded = true
        // Follow the user across Spaces and sit over full-screen apps, where the menu bar (and so the notch's
        // surroundings) is black anyway.
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel = newPanel
        return newPanel
    }
}

// MARK: - Self test

extension NotchGeometry {
    static func runSelfTest() -> Bool {
        var passed = true
        func check(_ ok: Bool, _ label: String) {
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): notch HUD: \(label)")
        }
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.5 }

        // The built-in display this was designed on: 2056 x 1329 points, a 220 x 38 notch.
        let mac = placement(screenFrame: CGRect(x: 0, y: 0, width: 2056, height: 1329), safeTop: 38, leftWidth: 918, rightWidth: 918)
        check(mac?.notch == CGRect(x: 918, y: 1291, width: 220, height: 38), "finds the notch of the built-in display")
        check(mac?.pill == CGSize(width: 336, height: 38), "the pill is the notch plus a wing each side, at the notch's own height")
        if let mac {
            check(near(mac.panel.midX, 1028) && near(mac.panel.maxY, 1329), "the panel is centred on the notch and flush with the screen's top edge")
            check(mac.panel.width >= mac.pill.width + 2 * NotchPillShape.earRadius, "the panel has room for the flared corners")
            let message = pillSize(for: .failure("Didn’t hear anything"), placement: mac, textWidth: 140)
            check(message.height == 38 + labelRow && message.width >= mac.pill.width, "a message adds a row below the notch")
            let long = pillSize(for: .failure("x"), placement: mac, textWidth: 2000)
            check(mac.panel.width >= long.width + 2 * NotchPillShape.earRadius && mac.panel.height >= long.height,
                  "the panel has room for the longest message")
            let handsFree = pillSize(for: .recording(handsFree: true), placement: mac, textWidth: 0)
            check(handsFree.height == 38 && handsFree.width > mac.pill.width, "hands-free is wider, still the notch's height")
        }

        // A display arranged elsewhere, with another notch size: positions follow the screen's own origin.
        let other = placement(screenFrame: CGRect(x: 2056, y: 100, width: 1512, height: 982), safeTop: 32, leftWidth: 660, rightWidth: 660)
        check(other?.notch == CGRect(x: 2716, y: 1050, width: 192, height: 32), "follows a screen that isn't at the origin")
        check(other.map { near($0.panel.maxY, 1082) && near($0.pill.height, 32) } ?? false, "and adapts to a shorter notch")

        // A notch that isn't centred: the panel follows the notch, not the middle of the screen.
        let lopsided = placement(screenFrame: CGRect(x: 0, y: 0, width: 2056, height: 1329), safeTop: 38, leftWidth: 900, rightWidth: 940)
        check(lopsided.map { near($0.notch.midX, 1008) && near($0.panel.midX, 1008) } ?? false, "centres on the notch itself")

        // No notch, no notch HUD.
        let frame = CGRect(x: 0, y: 0, width: 2880, height: 1620)
        check(placement(screenFrame: frame, safeTop: 0, leftWidth: nil, rightWidth: nil) == nil, "an external display has none")
        check(placement(screenFrame: frame, safeTop: 38, leftWidth: nil, rightWidth: 918) == nil, "half a notch is none")
        check(placement(screenFrame: frame, safeTop: 0, leftWidth: 918, rightWidth: 918) == nil, "no safe area, no notch")
        check(placement(screenFrame: frame, safeTop: 38, leftWidth: 1440, rightWidth: 1440) == nil, "areas that leave no notch are none")
        check(placement(screenFrame: frame, safeTop: 38, leftWidth: 500, rightWidth: 500) == nil, "a \"notch\" wider than half the screen is none")

        // The shape: exactly the notch when closed, the pill when open, growing in between.
        let notchSize = CGSize(width: 220, height: 38), pillSize = CGSize(width: 336, height: 68)
        let rect = CGRect(x: 0, y: 0, width: 392, height: 84)
        func bounds(_ progress: CGFloat) -> CGRect {
            NotchPillShape(collapsed: notchSize, expanded: pillSize, progress: progress).path(in: rect).boundingRect
        }
        let closed = bounds(0), half = bounds(0.5), open = bounds(1)
        check(near(closed.width, 220) && near(closed.height, 38) && near(closed.midX, 196) && near(closed.minY, 0),
              "closed, the shape is exactly the notch")
        check(near(open.height, 68) && near(open.width, 336 + 2 * NotchPillShape.earRadius) && near(open.midX, 196) && near(open.minY, 0),
              "open, it is the pill plus its flared top corners, flush with the top")
        check(closed.width < half.width && half.width < open.width && closed.height < half.height && half.height < open.height,
              "in between it grows steadily")
        let overshoot = bounds(1.06)
        check(overshoot.minX >= rect.minX && overshoot.maxX <= rect.maxX && overshoot.maxY <= rect.maxY,
              "a spring that overshoots still fits in the panel")
        return passed
    }
}

// MARK: - Live check (`Murmur --hud-check <directory>`)

/// Puts the notch pill on the real notch — fully transparent, click-through, never activating, for about a second — and
/// reports what the window server did with it, plus a picture of what the pill draws. Nothing is visible on screen.
@MainActor
enum NotchHUDCheck {
    static func run(outputDirectory: String) async -> Bool {
        var passed = true
        func report(_ ok: Bool, _ label: String) {
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): notch HUD live: \(label)")
        }
        func pump(_ seconds: TimeInterval) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        }

        for (index, screen) in NSScreen.screens.enumerated() {
            let notch = NotchGeometry.placement(of: screen).map { "notch \($0.notch)" } ?? "no notch"
            print("screen \(index) \(screen.localizedName): \(notch)")
        }
        guard let screen = NSScreen.screens.first(where: { NotchGeometry.placement(of: $0) != nil }),
              let placement = NotchGeometry.placement(of: screen) else {
            print("no screen with a notch — nothing to check")
            return true
        }

        try? FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)
        let model = HUDModel()
        model.targetAppIcon = NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app")
        model.state = .recording(handsFree: false)
        let controller = NotchHUDController()
        controller.isInvisibleForCheck = true
        controller.show(model: model, placement: placement)
        pump(0.6)

        guard let panel = controller.panelForCheck, let hosting = panel.contentView else {
            report(false, "the panel exists")
            return false
        }
        report(panel.frame == placement.panel, "AppKit kept the frame where it was asked to (\(panel.frame))")
        report(panel.screen == screen, "the panel is on the notch screen")
        print("hosting view safe area: \(hosting.safeAreaInsets)")

        // What the window server says: its bounds (top-left origin, primary display first) and its level.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let expectedTop = primaryHeight - placement.panel.maxY
        let windows = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
        let mine = windows.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() && (($0[kCGWindowLayer as String] as? Int) ?? 0) != 0 }
        if let info = mine.first,
           let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
           let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary) {
            print("window server: bounds \(bounds), layer \(info[kCGWindowLayer as String] ?? "?")")
            report(abs(bounds.minY - expectedTop) < 0.5, "it sits flush with the top edge of the screen (y \(bounds.minY), expected \(expectedTop))")
            report((info[kCGWindowLayer as String] as? Int) == Int(CGWindowLevelForKey(.statusWindow)), "it is above the menu bar (status level)")
        } else {
            report(false, "the window server lists the panel")
        }

        // What it draws, in the three states of the mockup, over a menu-bar-coloured background.
        let states: [(String, HUDState)] = [
            ("listening", .recording(handsFree: false)),
            ("hands-free", .recording(handsFree: true)),
            ("transcribing", .processing(HUDState.transcribing)),
            ("processing-message", .processing("Applying Casual style")),
            ("done", .done),
            ("failure", .failure("Didn’t hear anything")),
            ("notice", .notice("Trial over — dictation paused")),
        ]
        for (name, state) in states {
            model.state = state
            pump(0.35)
            let path = (outputDirectory as NSString).appendingPathComponent("notch-\(name).png")
            report(snapshot(hosting, menuBarHeight: placement.notch.height + 1, to: path), "rendered \(name) to \(path)")
        }

        // It goes away again.
        controller.hide()
        pump(0.7)
        report(!controller.isShowing, "it is off screen after hiding")
        return passed
    }

    /// The view's own drawing, composited over a menu-bar-and-window backdrop so the black pill can be judged.
    private static func snapshot(_ view: NSView, menuBarHeight: CGFloat, to path: String) -> Bool {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let picture = rep.cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: picture.width, height: picture.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        let scale = CGFloat(picture.width) / view.bounds.width
        let full = CGRect(x: 0, y: 0, width: picture.width, height: picture.height)
        context.setFillColor(CGColor(red: 0.953, green: 0.945, blue: 0.925, alpha: 1))
        context.fill(full)
        context.setFillColor(CGColor(red: 0.839, green: 0.820, blue: 0.776, alpha: 1))
        context.fill(CGRect(x: 0, y: full.height - menuBarHeight * scale, width: full.width, height: menuBarHeight * scale))
        context.draw(picture, in: full)
        guard let composite = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: composite).representation(using: .png, properties: [:])
        else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }
}
