import AppKit
import ApplicationServices
import SwiftUI

// MARK: - Status HUD
//
// Dictation's whole point is that you're working in *another* app, so the recording indicator has to live over it: a
// small black pill at the bottom of the screen (or the notch itself, on a Mac that has one — NotchHUD.swift) that's
// there while a dictation is in flight and gone when it lands.
//
// Designed to feel like part of macOS, after Apple's guidance for the Dynamic Island and for motion and feedback, and
// after what the best dictation apps do:
// - The bars are your voice: they follow the microphone's real level and rest as dots in silence, so a flat line
//   honestly means Murmur isn't hearing you. (They used to loop the same whether you spoke or not.)
// - One object that grows: the pill springs out of the nav bar's spot under the screen (out of the bar itself, if it's
//   open), and shrinks back into it, fading away, when it's done — instead of one thing vanishing and another popping
//   up in its place.
// - Compact, with words only when there's something to read: the target app's icon and the bars while you talk; the
//   same bars, settled, with a light running across them while it transcribes; a check when it has pasted; and a short
//   reason, with a small shake, when it couldn't.
// - Hands-free adds Stop and Cancel, which can be clicked without taking focus from the app being dictated into; Esc
//   cancels any dictation (`EscapeInterceptor`).
// - Every animation is short and springy, and under Reduce Motion it all simply fades — the bars still show your level,
//   since that's information rather than decoration.
// No shadow on the pill, ever — it read as a box under it rather than the pill floating.

/// What the HUD is currently reporting.
enum HUDState: Equatable {
    case hidden
    case recording(handsFree: Bool)
    case processing(String)
    /// A short message instead of a dictation — "Trial over — dictation paused" — with a lock.
    case notice(String)
    /// The dictation landed: a check for a moment, then the pill goes.
    case done
    /// It didn't work, and this is why — "Didn't hear anything". Shown with a small shake.
    case failure(String)
    /// Something worth a word that isn't a failure — "Cancelled", "Copied — press ⌘V to paste".
    case info(String, symbol: String)

    /// Processing's usual message, which the bars already say — no need to spell it out.
    static let transcribing = "Transcribing"

    var label: String {
        switch self {
        case .hidden: return ""
        case .recording(let handsFree): return handsFree ? "Listening — hands-free" : "Listening"
        case .processing(let message): return message
        case .notice(let message): return message
        case .done: return "Done"
        case .failure(let message): return message
        case .info(let message, _): return message
        }
    }

    /// The words the pill shows, if any — while you talk, and while it transcribes, the bars say it all.
    var text: String? {
        switch self {
        case .hidden, .recording, .done: return nil
        case .processing(let message): return message == Self.transcribing ? nil : message
        case .notice(let message), .failure(let message), .info(let message, _): return message
        }
    }

    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }

    var isHandsFree: Bool {
        if case .recording(true) = self { return true }
        return false
    }

    var isProcessing: Bool {
        if case .processing = self { return true }
        return false
    }

    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}

/// Shared by `StatusHUDController` and `NavBarHUDController` — the two
/// panels dock at the identical screen spot (they're mutually exclusive,
/// never both visible), so both compute their origin the same way.
enum HUDDock {
    /// The screen the pointer is on — where the HUD shows, whichever form it takes there.
    static func screen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    /// Bottom-centre of whichever screen the pointer is on. Anchoring to the
    /// text caret would need an Accessibility round-trip per frame and jumps
    /// around as text reflows; a fixed spot is calmer and always findable.
    ///
    /// The gap above the bottom edge is a small fraction of screen height
    /// (0.8%, floored at 6pt) rather than one fixed number — a flat gap
    /// looks right on a laptop display but noticeably oversized floating
    /// under everything on a large external monitor; scaling it keeps the
    /// pill reading as "just above the edge" on both. `visibleFrame` already
    /// excludes the Dock and menu bar, so this is a gap above whichever of
    /// those is actually the nearest boundary, not a fixed screen coordinate.
    static func origin(for size: NSSize) -> NSPoint {
        guard let screen = screen() else { return .zero }
        return origin(for: size, on: screen)
    }

    static func origin(for size: NSSize, on screen: NSScreen) -> NSPoint {
        let frame = screen.visibleFrame
        let bottomGap = max(6, frame.height * 0.008)
        return NSPoint(x: frame.midX - size.width / 2, y: frame.minY + bottomGap)
    }
}

/// Where the Dock is, for the HUDs that share the bottom of the screen with it — so they can ride above an auto-hidden
/// Dock that has slid up, instead of sitting on its icons. Read through Accessibility (which dictation needs anyway):
/// the Dock's icon list reports its frame — just below the screen while it's hidden, sliding up into view when shown.
@MainActor
enum DockGeometry {
    private static var iconList: (pid: pid_t, element: AXUIElement)?
    private static var autohideCache: (value: Bool, readAt: Date)?

    /// Whether the Dock hides itself (System Settings → Desktop & Dock) — read again every few seconds at most.
    static var autohides: Bool {
        if let cache = autohideCache, Date().timeIntervalSince(cache.readAt) < 5 { return cache.value }
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
        let value = CFPreferencesCopyAppValue("autohide" as CFString, "com.apple.dock" as CFString) as? Bool ?? false
        autohideCache = (value, Date())
        return value
    }

    /// How far something whose bottom edge is at `bottom` on `screen` has to rise to sit clear above the Dock right now.
    static func lift(on screen: NSScreen, bottom: CGFloat) -> CGFloat {
        guard let primary = NSScreen.screens.first else { return 0 }
        return lift(dock: iconListFrame(), primaryHeight: primary.frame.height, screen: screen.frame, bottom: bottom)
    }

    /// The same, from the Dock's frame as Accessibility reports it (top-left origin, y down from the primary screen's
    /// top): 0 unless the Dock lies along this screen's bottom edge and is showing, or sliding up — in which case the
    /// rise is to `gap` above where its top will end up, so the two move together.
    nonisolated static func lift(dock: CGRect?, primaryHeight: CGFloat, screen: CGRect, bottom: CGFloat,
                                 gap: CGFloat = 8) -> CGFloat {
        guard let dock, dock.width > dock.height, dock.height > 0 else { return 0 }
        let frame = CGRect(x: dock.minX, y: primaryHeight - dock.maxY, width: dock.width, height: dock.height)
        guard frame.minX < screen.midX, frame.maxX > screen.midX,   // on this screen, under the middle
              frame.minY < screen.minY + 24,                        // along its bottom edge
              frame.maxY > screen.minY + 1                          // and showing, or on its way up
        else { return 0 }
        let top = max(screen.minY + frame.height, frame.maxY)
        return max(0, top + gap - bottom)
    }

    private static func iconListFrame() -> CGRect? {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return nil }
        let pid = dock.processIdentifier
        if iconList?.pid != pid { iconList = findIconList(pid: pid).map { (pid, $0) } }
        guard let element = iconList?.element else { return nil }
        guard let frame = frame(of: element) else {
            iconList = nil  // the Dock restarted, say — find it again next time
            return nil
        }
        return frame
    }

    private static func findIconList(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else { return nil }
        let list = children.first { child in
            var role: CFTypeRef?
            return AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role) == .success
                && (role as? String) == kAXListRole
        }
        if let list { AXUIElementSetMessagingTimeout(list, 0.1) }
        return list
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size,
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }
}

/// A hosting view whose buttons work on the first click, in a panel that never becomes key — so Stop and Cancel can
/// be clicked while the app being dictated into keeps its focus (and so gets the paste).
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class StatusHUDController {
    private var panel: NSPanel?
    private let model = HUDModel()
    /// The same HUD grown out of the notch, for a screen that has one.
    private let notchHUD = NotchHUDController()
    private var collapseTask: Task<Void, Never>?

    /// Hands-free's Stop button: finish and paste.
    var onStop: () -> Void = {} {
        didSet { notchHUD.onStop = onStop }
    }
    /// Hands-free's Cancel button: throw the recording away.
    var onCancel: () -> Void = {}
    /// The pill has shrunk back into the resting line and gone — the nav bar's own line takes over again from here.
    var onCollapsed: () -> Void = {}
    /// The nav bar as it is when the pill appears — the line, or the open bar — which the pill grows out of…
    var startSize: () -> CGSize = { StatusHUDView.restingSize }
    /// …at the height the bar is riding at, above a Dock that has slid up — and seen only if the bar was showing.
    var startLift: () -> CGFloat = { 0 }
    var startVisible: () -> Bool = { true }
    private var lift: CGFloat = 0

    /// Room for the widest message plus the spring's overshoot; the pill itself is drawn at its own size inside,
    /// anchored to the bottom where the nav bar's resting line is.
    private static let panelSize = NSSize(width: 460, height: 66)
    static let spring = Animation.spring(response: 0.32, dampingFraction: 0.8)

    func update(_ state: HUDState) {
        guard state != .hidden else {
            hide()
            return
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let startsFailure = state.isFailure && !model.state.isFailure
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : Self.spring) { model.state = state }
        show()
        if startsFailure, !reduceMotion {
            withAnimation(.linear(duration: 0.42)) { model.shakes += 1 }
        }
    }

    /// The microphone's level, 0…1, while recording — what the bars follow.
    func setLevel(_ level: Double) {
        model.level = level
    }

    /// Whether the HUD is up in the notch on the pointer's screen right now. The nav bar shares the bottom of the
    /// screen with the bottom pill, so it steps aside only for that one — with the HUD in the notch the bottom is
    /// free, and the nav bar stays where it is.
    var isInNotch: Bool {
        NotchHUDController.isEnabled && HUDDock.screen().flatMap { NotchGeometry.placement(of: $0) } != nil
    }

    /// Set once, from `AppDelegate.startRecording()`, to the frontmost
    /// app's own `NSRunningApplication.icon` at the moment recording
    /// starts — the icon shown in the HUD is *who this dictation is
    /// going to*, not Murmur's own icon. Only actually cleared once the
    /// pill has gone, so it stays put through processing and the check.
    func setTargetAppIcon(_ icon: NSImage?) {
        model.targetAppIcon = icon
    }

    private func show() {
        collapseTask?.cancel()
        collapseTask = nil
        // A screen with a notch: the notch grows into the pill. Any other screen keeps the pill at the bottom.
        if NotchHUDController.isEnabled, let screen = HUDDock.screen(),
           let placement = NotchGeometry.placement(of: screen) {
            panel?.orderOut(nil)
            model.expanded = false
            notchHUD.show(model: model, placement: placement)
            return
        }
        notchHUD.hide(animated: false)
        let wasVisible = panel?.isVisible ?? false
        let panel = existingOrNewPanel()
        if !wasVisible {
            lift = startLift()
            model.collapsedSize = startSize()
            model.collapsedVisible = startVisible()
        }
        var origin = HUDDock.origin(for: Self.panelSize)
        origin.y += lift
        panel.setFrame(NSRect(origin: origin, size: Self.panelSize), display: true, animate: false)
        // Clickable only while there's something to click (hands-free's Stop and Cancel); click-through otherwise.
        panel.ignoresMouseEvents = !model.state.isHandsFree
        // `orderFrontRegardless` rather than `makeKeyAndOrderFront`: the HUD
        // must never take key status. Dictation pastes into whatever app was
        // frontmost when recording started, so stealing focus here would
        // send the text to Murmur instead of the user's actual target.
        panel.orderFrontRegardless()
        guard !model.expanded else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if wasVisible {
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : Self.spring) { model.expanded = true }
        } else {
            // The first frame is the nav bar exactly as it was — the line, or the open bar — then it grows. It shrinks
            // back into the line.
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 16_000_000)
                withAnimation(reduceMotion ? .easeOut(duration: 0.15) : Self.spring) { self?.model.expanded = true }
                self?.model.collapsedSize = StatusHUDView.restingSize
                self?.model.collapsedVisible = false
            }
        }
    }

    private func hide() {
        notchHUD.hide()
        guard let panel, panel.isVisible else {
            // Nothing at the bottom to take down. The app icon stays: it's only let go of once a pill has actually
            // shrunk away (below) — a hide that arrives just as a new dictation starts must not take the icon that
            // dictation has just set. (The notch keeps its own copy while it shrinks.)
            model.state = .hidden
            onCollapsed()
            return
        }
        guard collapseTask == nil else { return }
        panel.ignoresMouseEvents = true
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : Self.spring) { model.expanded = false }
        collapseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: reduceMotion ? 180_000_000 : 300_000_000)
            guard !Task.isCancelled, let self else { return }
            self.collapseTask = nil
            self.panel?.orderOut(nil)
            self.model.targetAppIcon = nil
            self.model.state = .hidden
            self.onCollapsed()
        }
    }

    private func existingOrNewPanel() -> NSPanel {
        if let panel { return panel }

        let hosting = FirstClickHostingView(rootView: StatusHUDView(
            model: model,
            onStop: { [weak self] in self?.onStop() },
            onCancel: { [weak self] in self?.onCancel() }))
        hosting.frame = NSRect(origin: .zero, size: Self.panelSize)
        hosting.sizingOptions = []
        // The pill is black whatever the Mac's appearance, so its colours are resolved for a dark surface.
        hosting.appearance = NSAppearance(named: .darkAqua)

        let newPanel = NSPanel(
            contentRect: hosting.frame,
            // .nonactivatingPanel is the load-bearing flag — without it,
            // showing this window activates Murmur and breaks the paste.
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
        // Belt-and-braces with .nonactivatingPanel: dictation pastes into
        // whichever app was frontmost, so this window must never become key.
        newPanel.becomesKeyOnlyIfNeeded = true
        // Follow the user across Spaces and sit above full-screen apps —
        // otherwise the HUD is invisible in exactly the full-screen editors
        // people dictate into most.
        newPanel.collectionBehavior = [
            .canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle,
        ]
        panel = newPanel
        return newPanel
    }
}

/// Separate observable so the panel's SwiftUI content updates without the
/// controller having to rebuild the hosting view on every state change.
@MainActor
final class HUDModel: ObservableObject {
    @Published var state: HUDState = .hidden
    /// The target app's own icon — see `StatusHUDController.setTargetAppIcon`.
    @Published var targetAppIcon: NSImage?
    /// The microphone's level, 0…1, while recording.
    @Published var level: Double = 0
    /// The bottom pill is open, rather than the resting line it grows out of.
    @Published var expanded = false
    /// What it is when it isn't open: the resting line — or, for its first frame, the open nav bar it grows out of.
    @Published var collapsedSize = StatusHUDView.restingSize
    /// Whether that shows. The nav bar's line doesn't at rest, so the live pill grows out of nothing and fades away as it
    /// shrinks; it starts visible only when it takes over from a nav bar that was open.
    @Published var collapsedVisible = true
    /// Counts failures; each new one shakes the pill once.
    @Published var shakes = 0
}

/// The bottom pill: the nav bar's resting line, grown. The target app's icon and the bars while you talk (plus Stop and
/// Cancel, hands-free); the same bars, settled, while it transcribes; a check when it's pasted; a short line of text only
/// when there's something to read.
struct StatusHUDView: View {
    @ObservedObject var model: HUDModel
    var onStop: () -> Void = {}
    var onCancel: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var contentWidth: CGFloat = 0

    /// The nav bar's resting line — the pill grows out of exactly this.
    static let restingSize = CGSize(width: 48, height: 6)
    static let height: CGFloat = 36
    /// The nav bar's own inset from the bottom of its panel, so the line and the pill share a baseline.
    static let bottomInset: CGFloat = 8

    var body: some View {
        let open = model.expanded
        ZStack(alignment: .bottom) {
            Capsule()
                .fill(Palette.hudBlack)
                .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 1))
                .frame(width: open ? max(contentWidth, 60) : model.collapsedSize.width,
                       height: open ? Self.height : model.collapsedSize.height)
                .opacity(open || (model.collapsedVisible && !reduceMotion) ? 1 : 0)
            content
                .padding(.horizontal, 12)
                .frame(height: Self.height)
                .fixedSize()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
                .opacity(open ? 1 : 0)
                .animation(.easeOut(duration: open ? 0.16 : 0.08).delay(open && !reduceMotion ? 0.06 : 0), value: open)
        }
        .modifier(ShakeEffect(shakes: CGFloat(model.shakes)))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, Self.bottomInset)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : StatusHUDController.spring, value: contentWidth)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.state.label)
    }

    private var content: some View {
        let state = model.state
        return HStack(spacing: 10) {
            leading
            // One view for both, so the bars settle into the transcribing shimmer rather than being swapped out.
            if state.isRecording || state.isProcessing {
                LevelBars(model: model, count: 11, barWidth: 3, spacing: 2.5, maxHeight: 18)
            }
            if state == .done {
                HUDCheck(size: 20)
                    .frame(width: 58)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
            if let text = state.text {
                Text(text)
                    .font(.manrope(12.5, .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
                    .transition(.opacity)
            }
            if state.isHandsFree {
                handsFreeButtons
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
    }

    @ViewBuilder private var leading: some View {
        switch model.state {
        case .notice:
            HUDLockGlyph(size: 14)
        case .failure:
            Image(systemName: "mic.slash.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.danger)
        case .info(_, let symbol):
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
        default:
            if let icon = model.targetAppIcon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 18, height: 18)
            }
        }
    }

    private var handsFreeButtons: some View {
        HStack(spacing: 6) {
            Button(action: onStop) {
                ZStack {
                    Circle().fill(.white)
                    RoundedRectangle(cornerRadius: 1.5).fill(Palette.hudBlack).frame(width: 7, height: 7)
                }
                .frame(width: 22, height: 22)
                .contentShape(Circle())
            }
            .buttonStyle(PressScaleButtonStyle(scale: 0.88))
            .accessibilityLabel("Stop and paste")
            Button(action: onCancel) {
                ZStack {
                    Circle().fill(.white.opacity(0.16))
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 22, height: 22)
                .contentShape(Circle())
            }
            .buttonStyle(PressScaleButtonStyle(scale: 0.88))
            .accessibilityLabel("Cancel")
        }
        .padding(.leading, 2)
    }
}

// MARK: - Pieces

/// The bars. While recording they follow the microphone's level — loudest in the middle, each with a little life of its
/// own — and rest as dots in silence. While transcribing they settle low and a light runs across them. Smoothed per
/// frame (a quick rise, a slower fall), since the level itself arrives about ten times a second.
struct LevelBars: View {
    @ObservedObject var model: HUDModel
    var count = 11
    var barWidth: CGFloat = 3
    var spacing: CGFloat = 2.5
    var maxHeight: CGFloat = 18

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var meter = LevelMeter()

    var body: some View {
        let listening = model.state.isRecording
        TimelineView(.animation(minimumInterval: 1.0 / 45, paused: model.state == .hidden)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let level = meter.step(toward: listening ? model.level : 0, at: time)
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<count, id: \.self) { index in
                    Capsule()
                        .fill(Palette.sunset)
                        .frame(width: barWidth,
                               height: listening ? barHeight(index, level: level, time: time) : barWidth + 1.5)
                        .opacity(listening ? 1 : shimmer(index, time: time))
                }
            }
            .frame(height: maxHeight)
        }
        .animation(.easeOut(duration: 0.25), value: listening)
    }

    private func barHeight(_ index: Int, level: Double, time: Double) -> CGFloat {
        let centre = Double(count - 1) / 2
        let distance = abs(Double(index) - centre) / max(centre, 1)
        let weight = 1 - 0.55 * distance * distance
        let life = reduceMotion ? 1 : 0.72 + 0.28 * sin(time * (8.5 + Double(index) * 0.6) + Double(index) * 1.9)
        return barWidth + (maxHeight - barWidth) * CGFloat(min(1, level * weight * life))
    }

    private func shimmer(_ index: Int, time: Double) -> Double {
        guard !reduceMotion else { return 0.6 }
        let phase = (time / 1.1).truncatingRemainder(dividingBy: 1) * 1.3 - 0.15
        let position = Double(index) / Double(max(1, count - 1))
        return 0.3 + 0.7 * max(0, 1 - abs(position - phase) * 3.2)
    }
}

/// Eases the displayed level towards the measured one each frame — a fast rise, a slower fall — so the bars move like a
/// voice rather than jumping ten times a second. A plain reference type: stepping it doesn't redraw anything by itself.
final class LevelMeter {
    private var value = 0.0
    private var lastTime = 0.0

    func step(toward target: Double, at time: Double) -> Double {
        let elapsed = lastTime == 0 ? 0 : min(0.1, max(0, time - lastTime))
        lastTime = time
        let rate = target > value ? 22.0 : 8.0
        value += (target - value) * (1 - exp(-rate * elapsed))
        return value
    }
}

/// A failed dictation's little shake, like a wrong password in the macOS login window: three quick, fading swings.
struct ShakeEffect: GeometryEffect {
    var shakes: CGFloat

    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let progress = shakes - shakes.rounded(.down)
        let offset = 6 * sin(progress * .pi * 6) * (1 - progress)
        return ProjectionTransform(CGAffineTransform(translationX: offset, y: 0))
    }
}

/// The pasted mark: a sunset disc with a white check.
struct HUDCheck: View {
    var size: CGFloat = 20

    var body: some View {
        ZStack {
            Circle().fill(Palette.sunset)
            MurmurIconView(icon: .check)
                .frame(width: size / 2, height: size / 2)
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

/// The HUD's "paused" mark: the app's own lock, in the bars' colour.
struct HUDLockGlyph: View {
    var size: CGFloat = 18

    var body: some View {
        MurmurIconView(icon: .lock)
            .frame(width: size, height: size)
            .foregroundStyle(Palette.sunset)
    }
}
