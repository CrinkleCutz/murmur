import AppKit
import Speech
import SwiftUI

// MARK: - Nav bar
//
// Nothing at all while you're not using it. Rest the pointer on its spot at the bottom of the screen and a small black
// line appears and grows into a bar of four buttons — dictate, language, transforms, more — and, when one of those is
// clicked, its menu grows up out of the bar itself. Leave, and it folds away and fades out. One object the whole way,
// the same black and the same spring as the recording pill, which grows out of the same spot. (Like Wispr Flow's bar,
// which is hidden at rest unless you ask for it.)
//
// Built after Apple's guidance for popovers and menus, and after what Wispr Flow's Flow Bar learned the hard way:
// - Menus open on a click, never on hover; one at a time; a click on another button switches in one go. On hover, the
//   path the pointer happened to take decided what opened — crossing a neighbouring button swapped the menu, and
//   moving up slowly lost it in the gap between button and menu. Grown out of the bar, there's no gap to cross.
// - It only takes clicks where it's drawn. At rest, nowhere: it opens after a short pause on the line, so passing
//   through on the way to the Dock (or down to the screen below) doesn't open it. Open, only the black shape takes
//   clicks — everything around it goes to whatever is underneath. (It used to be an invisible 191×56 box that ate them.)
// - It never covers the Dock. It sits just under the Dock's window level, and when an auto-hidden Dock slides up it
//   rides up on top of it, settling back once the Dock has gone — but never while you're using it.
// - It follows the screen the pointer is on.
// No shadow, ever — like the pill.

@MainActor
final class NavBarHUDController {
    private var panel: NSPanel?
    private let model = NavBarModel()
    private let escape = EscapeInterceptor()
    private var monitors: [Any] = []
    private var revealTask: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?
    private var dockTimer: Timer?
    private var lastMode: NavBarModel.Mode = .resting
    private(set) var isActive = false

    /// Room for the tallest menu, the widest label and a ride over a big Dock. Only the black shape in it takes clicks.
    static let panelSize = NSSize(width: 360, height: 520)
    /// Where a pause opens the bar: around its spot — generous, since nothing shows there at rest — but clear of the
    /// screen's edge, which is the Dock's own trigger.
    static let revealArea = CGSize(width: 200, height: 30)
    private static let revealPause: UInt64 = 150_000_000
    /// How long the bar waits for you to come back before folding into the line — and, with a menu open, longer.
    private static let barLinger: UInt64 = 400_000_000
    private static let menuLinger: UInt64 = 1_500_000_000
    /// Just after a pick, the pointer is still up where the menu was: a little longer to come back down to the bar.
    private static let afterMenuLinger: UInt64 = 1_000_000_000
    /// Never rides higher than this, so the tallest menu still fits in the panel above it.
    private static let maximumLift: CGFloat = 180

    init() {
        model.onModeChange = { [weak self] in self?.modeChanged() }
        escape.onEscape = { [weak self] in
            MainActor.assumeIsolated { self?.model.setMode(.bar) }
        }
    }

    /// What the bar looks like right now — the recording pill grows out of exactly this.
    var visibleSize: CGSize {
        guard isActive, model.mode != .resting else { return NavBarBody.restingSize }
        return NavBarBody.barSize
    }

    /// How far it has risen to clear the Dock — the recording pill appears at the same height.
    var lift: CGFloat { isActive ? model.lift : 0 }

    /// Whether anything of it is showing: at rest nothing is.
    var isShowing: Bool { isActive && model.mode != .resting }

    func setActive(_ active: Bool, app: AppDelegate) {
        guard active else {
            guard isActive else { return }
            isActive = false
            stopTracking()
            model.setMode(.resting, animated: false)
            panel?.orderOut(nil)
            return
        }
        let panel = existingOrNewPanel(app: app)
        if !isActive {
            isActive = true
            model.setMode(.resting, animated: false)
            dock(panel, on: HUDDock.screen())
            panel.ignoresMouseEvents = true
            startTracking()
        }
        panel.orderFrontRegardless()
    }

    /// Back to the bar if a menu is open — a dictation has just started.
    func closeMenu() {
        if model.menu != nil { model.setMode(.bar) }
    }

    // MARK: Pointer

    private func startTracking() {
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        let presses: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        // Global monitors see the pointer over other apps, local ones over Murmur's own windows (this panel included).
        monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: moves) { [weak self] _ in
                MainActor.assumeIsolated { self?.pointerMoved() }
            },
            NSEvent.addLocalMonitorForEvents(matching: moves) { [weak self] event in
                MainActor.assumeIsolated { self?.pointerMoved() }
                return event
            },
            NSEvent.addGlobalMonitorForEvents(matching: presses) { [weak self] _ in
                MainActor.assumeIsolated { self?.clickedElsewhere() }
            },
            NSEvent.addLocalMonitorForEvents(matching: presses) { [weak self] event in
                MainActor.assumeIsolated {
                    if let self, event.window !== self.panel { self.clickedElsewhere() }
                }
                return event
            },
        ].compactMap { $0 }
        pointerMoved()
    }

    private func stopTracking() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        revealTask?.cancel()
        revealTask = nil
        collapseTask?.cancel()
        collapseTask = nil
        dockTimer?.invalidate()
        dockTimer = nil
        escape.stop()
    }

    private func pointerMoved() {
        guard isActive, let panel else { return }
        let point = NSEvent.mouseLocation
        // At rest, it moves to whichever screen the pointer goes to.
        if model.mode == .resting, revealTask == nil, let screen = panel.screen, !NSMouseInRect(point, screen.frame, false),
           let next = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) {
            dock(panel, on: next)
        }
        evaluate(point)
        watchDock(near: point)
    }

    /// Clicks go to the bar only where it's drawn; open or close it depending on where the pointer is.
    private func evaluate(_ point: NSPoint, barLinger: UInt64 = NavBarHUDController.barLinger) {
        guard let panel else { return }
        let takesClicks = clickableRect.map { NSPointInRect(point, $0) } ?? false
        if panel.ignoresMouseEvents == takesClicks { panel.ignoresMouseEvents = !takesClicks }
        switch model.mode {
        case .resting:
            if NSPointInRect(point, revealRect), NSEvent.pressedMouseButtons == 0 { scheduleReveal() } else { cancelReveal() }
        case .bar:
            linger(point, barLinger)
        case .menu:
            linger(point, Self.menuLinger)
        }
    }

    private func scheduleReveal() {
        guard revealTask == nil else { return }
        revealTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.revealPause)
            guard let self, !Task.isCancelled else { return }
            self.revealTask = nil
            guard self.isActive, self.model.mode == .resting,
                  NSPointInRect(NSEvent.mouseLocation, self.revealRect), NSEvent.pressedMouseButtons == 0 else { return }
            self.model.setMode(.bar)
        }
    }

    private func cancelReveal() {
        revealTask?.cancel()
        revealTask = nil
    }

    /// Stays while the pointer is on it (or near); folds away once it's been gone for a moment.
    private func linger(_ point: NSPoint, _ nanoseconds: UInt64) {
        if let keep = keepOpenRect, NSPointInRect(point, keep) {
            collapseTask?.cancel()
            collapseTask = nil
            return
        }
        guard collapseTask == nil else { return }
        collapseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard let self, !Task.isCancelled else { return }
            self.collapseTask = nil
            if let keep = self.keepOpenRect, NSPointInRect(NSEvent.mouseLocation, keep) { return }
            self.model.setMode(.resting)
        }
    }

    /// A click anywhere but the bar closes it — and still goes through to what was clicked.
    private func clickedElsewhere() {
        guard isActive, model.mode != .resting else { return }
        model.setMode(.resting)
    }

    private func modeChanged() {
        let closedMenu: Bool
        if case .menu = lastMode, model.mode == .bar { closedMenu = true } else { closedMenu = false }
        lastMode = model.mode
        collapseTask?.cancel()
        collapseTask = nil
        if model.menu != nil { escape.start() } else { escape.stop() }
        evaluate(NSEvent.mouseLocation, barLinger: closedMenu ? Self.afterMenuLinger : Self.barLinger)
        // Back at rest, catch up with a Dock that came or went while the bar was open.
        if model.mode == .resting { dockTick() }
    }

    // MARK: Geometry (screen coordinates)

    private var lineBottom: CGFloat { (panel?.frame.minY ?? 0) + NavBarBody.bottomInset + model.lift }

    private var revealRect: NSRect {
        guard let panel else { return .zero }
        let area = Self.revealArea
        return NSRect(x: panel.frame.midX - area.width / 2, y: lineBottom - NavBarBody.bottomInset,
                      width: area.width, height: area.height)
    }

    private var barRect: NSRect {
        guard let panel else { return .zero }
        let size = NavBarBody.barSize
        return NSRect(x: panel.frame.midX - size.width / 2, y: lineBottom, width: size.width, height: size.height)
    }

    /// The black shape as last laid out (the view reports it), in screen coordinates.
    private var shapeRect: NSRect {
        guard let panel, model.shapeFrame.width > 0 else { return barRect }
        let frame = model.shapeFrame
        return NSRect(x: panel.frame.minX + frame.minX, y: panel.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
    }

    /// Where a click lands on the bar rather than going through: nowhere at rest.
    private var clickableRect: NSRect? {
        switch model.mode {
        case .resting: return nil
        case .bar: return barRect.insetBy(dx: -2, dy: -2)
        case .menu: return shapeRect.union(barRect).insetBy(dx: -2, dy: -2)
        }
    }

    /// A little more room than it takes up, so an unsteady hand doesn't fold it away.
    private var keepOpenRect: NSRect? {
        clickableRect.map { $0.insetBy(dx: -14, dy: -14).union(revealRect) }
    }

    // MARK: Screens and the Dock

    private func dock(_ panel: NSPanel, on screen: NSScreen?) {
        guard let screen else { return }
        let origin = HUDDock.origin(for: Self.panelSize, on: screen)
        panel.setFrame(NSRect(origin: origin, size: Self.panelSize), display: false, animate: false)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            model.lift = min(Self.maximumLift, DockGeometry.lift(on: screen, bottom: origin.y + NavBarBody.bottomInset))
        }
    }

    /// Watches the Dock only while it matters: the pointer is near the bottom of the screen, or the bar is riding on it.
    private func watchDock(near point: NSPoint) {
        guard dockTimer == nil, let screen = panel?.screen else { return }
        let nearBottom = point.y < screen.frame.minY + 180
        guard (nearBottom && DockGeometry.autohides) || model.lift > 0 else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.dockTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        dockTimer = timer
        dockTick()
    }

    private func dockTick() {
        guard isActive, let panel, let screen = panel.screen else { return }
        let bottom = panel.frame.minY + NavBarBody.bottomInset
        let target = min(Self.maximumLift, DockGeometry.lift(on: screen, bottom: bottom))
        // Never moves out from under you: it holds still while it's open, or about to open.
        if model.mode == .resting, revealTask == nil, abs(target - model.lift) > 0.5 {
            withAnimation(NavBarBody.animation) { model.lift = target }
        }
        let nearBottom = NSEvent.mouseLocation.y < screen.frame.minY + 180
        if !nearBottom, target == 0, model.lift == 0 {
            dockTimer?.invalidate()
            dockTimer = nil
        }
    }

    // MARK: Panel

    private func existingOrNewPanel(app: AppDelegate) -> NSPanel {
        if let panel { return panel }

        let hosting = FirstClickHostingView(rootView: NavBarView(app: app, model: model))
        hosting.frame = NSRect(origin: .zero, size: Self.panelSize)
        // Without this AppKit keeps the panel at least as big as the SwiftUI content wants — which is how the old
        // "tiny" resting panel was really 191×56.
        hosting.sizingOptions = []
        // The bar is black whatever the Mac's appearance, so its colours are resolved for a dark surface.
        hosting.appearance = NSAppearance(named: .darkAqua)

        let newPanel = NSPanel(
            contentRect: hosting.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        newPanel.contentView = hosting
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = false
        // Just under the Dock: if the Dock ever slides up over it, the Dock wins — its icons always take the click.
        newPanel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) - 1)
        newPanel.ignoresMouseEvents = true
        newPanel.hidesOnDeactivate = false
        newPanel.isReleasedWhenClosed = false
        // Clicking the bar never takes focus from the app you're in — that's where dictation and transforms go.
        newPanel.becomesKeyOnlyIfNeeded = true
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel = newPanel
        return newPanel
    }
}

/// What the bar is doing, shared by its controller (which decides when it opens and closes) and its view.
@MainActor
final class NavBarModel: ObservableObject {
    enum Mode: Equatable {
        case resting
        case bar
        case menu(NavMenu)
    }

    @Published private(set) var mode: Mode = .resting
    /// How far it has risen to clear a Dock that has slid up.
    @Published var lift: CGFloat = 0
    /// "Copy last dictation" has just copied — its row says so for a moment.
    @Published var copied = false
    /// The black shape's frame in the panel (top-left origin), as laid out — where clicks land.
    var shapeFrame: CGRect = .zero
    var onModeChange: () -> Void = {}

    var menu: NavMenu? {
        if case .menu(let menu) = mode { return menu }
        return nil
    }

    func setMode(_ new: Mode, animated: Bool = true) {
        guard new != mode else { return }
        if animated {
            withAnimation(NavBarBody.animation) { mode = new }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { mode = new }
        }
        onModeChange()
    }

    /// A button's own menu: opens it — or, if it's the one already open, closes it again.
    func toggle(_ menu: NavMenu) {
        if self.menu?.button == menu.button { setMode(.bar) } else { setMode(.menu(menu)) }
    }
}

enum NavButton: CaseIterable {
    case dictate, language, transforms, more
}

enum NavMenu: Equatable {
    case language, allLanguages, engine, translate, transforms, more

    var button: NavButton {
        switch self {
        case .language, .allLanguages, .engine, .translate: return .language
        case .transforms: return .transforms
        case .more: return .more
        }
    }
}

// MARK: - Languages

enum NavBarLanguages {
    /// "en" for "en", "en-GB" or "en_GB".
    static func code(_ id: String) -> String {
        String(id.prefix { $0 != "-" && $0 != "_" }).lowercased()
    }

    /// The offered identifier that stands for the language in use: itself if offered, else the first with its language.
    static func current(in options: [String], current: String) -> String? {
        options.first { $0 == current } ?? options.first { code($0) == code(current) }
    }

    /// The Mac's own languages (System Settings → Language & Region), in its order, that the engine offers — then the
    /// one in use, if it isn't among them. What a bilingual person switches between, one click away.
    static func yours(preferred: [String], options: [String], current: String) -> [String] {
        var result: [String] = []
        for language in preferred.prefix(4) {
            let match = options.first { $0 == language }
                ?? options.first { $0 == code(language) }
                ?? options.first { code($0) == code(language) }
            if let match, !result.contains(match) { result.append(match) }
        }
        if let inUse = self.current(in: options, current: current), !result.contains(inUse) { result.append(inUse) }
        return result
    }
}

// MARK: - The live bar

/// `NavBarBody` fed from the app: what it shows, and what its buttons and rows do.
private struct NavBarView: View {
    @ObservedObject var app: AppDelegate
    @ObservedObject var model: NavBarModel
    @State private var appleLocaleIDs: [String] = []
    @State private var voiceProfileOn = Settings.useVoiceProfile

    var body: some View {
        NavBarBody(model: model, content: content, actions: actions)
            .task {
                let locales = await SpeechTranscriber.supportedLocales
                appleLocaleIDs = locales.map { $0.identifier(.bcp47) }
            }
            .onChange(of: model.menu) { _, menu in
                // Voice Profile can be switched on its own page too.
                if menu == .more { voiceProfileOn = Settings.useVoiceProfile }
            }
    }

    /// Mirrors `SettingsPage.pickerLocaleIDs`: what's on offer depends on the recognition engine (and its model).
    private var languageOptions: [String] {
        var ids = (app.supportedLanguageIDs() ?? appleLocaleIDs).sorted { name($0) < name($1) }
        if NavBarLanguages.current(in: ids, current: app.localeID) == nil { ids.insert(app.localeID, at: 0) }
        return ids
    }

    private func name(_ id: String) -> String {
        Locale.current.localizedString(forIdentifier: id) ?? id
    }

    private var content: NavBarContent {
        var content = NavBarContent()
        let options = languageOptions
        let selected = NavBarLanguages.current(in: options, current: app.localeID)
        func choice(_ id: String) -> NavBarContent.Choice {
            NavBarContent.Choice(id: id, title: name(id), selected: id == selected)
        }
        let code = NavBarLanguages.code(app.localeID)
        content.languageCode = code.uppercased()
        content.languageName = Locale.current.localizedString(forLanguageCode: code) ?? code
        content.yourLanguages = NavBarLanguages.yours(preferred: Locale.preferredLanguages, options: options,
                                                      current: app.localeID).map(choice)
        content.allLanguages = options.map(choice)
        content.engines = ["apple", "parakeet", "sherpa", "whisper", "whispercpp"].map {
            NavBarContent.Choice(id: $0, title: AppProfilesPage.engineDisplayName($0), selected: $0 == app.engine)
        }
        content.engineName = AppProfilesPage.engineDisplayName(app.engine)
        // Translate into: Off, then every language but the one spoken — see `TranslateInto`.
        let target = app.translateInto.flatMap { $0 == code ? nil : $0 }
        content.translateTarget = target.map(TranslateInto.chip)
        content.translateName = target.map(TranslateInto.name)
        content.translateChoices = [NavBarContent.Choice(id: "off", title: "Off", selected: target == nil)]
            + TranslateInto.languages.filter { $0 != code }.map {
                NavBarContent.Choice(id: $0, title: TranslateInto.name($0), selected: $0 == target)
            }
        // Read from disk only while the menu that lists them is open.
        if model.menu == .transforms {
            content.transforms = Transform.allIncludingCustom.map {
                NavBarContent.Command(id: $0.id, name: $0.name, key: $0.keyLabel == "—" ? nil : $0.keyLabel)
            }
        }
        content.newNoteKey = KeyComboLabel.compact(modifiers: Settings.scratchpadHotkeyModifiers,
                                                   keyCode: Settings.scratchpadHotkeyKeyCode)
        content.canCopyLast = !(app.entries.first?.text.isEmpty ?? true)
        content.voiceProfileOn = voiceProfileOn
        content.isRecording = app.uiState == .recording
        content.hotkey = app.hotkey == .fn ? "fn" : "right \(app.hotkey.shortSymbol)"
        return content
    }

    private var actions: NavBarActions {
        let app = self.app
        func open(_ page: Page) {
            app.pendingNavigateToPage = page
            app.showMainWindow()
        }
        return NavBarActions(
            dictate: { app.toggleDictationFromBar() },
            setLanguage: { app.setLocale($0) },
            setEngine: { app.setEngine($0) },
            setTranslateInto: { app.setTranslateInto($0 == "off" ? nil : $0) },
            runTransform: { id in
                guard let transform = Transform.allIncludingCustom.first(where: { $0.id == id }) else { return }
                app.transformManager.run(transform)
            },
            editTransforms: { open(.transforms) },
            newNote: { app.openScratchpadPanel() },
            copyLast: {
                guard let text = app.entries.first?.text, !text.isEmpty else { return }
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            },
            ask: { open(.ask) },
            setVoiceProfile: { on in
                voiceProfileOn = on
                Settings.useVoiceProfile = on
            },
            openMurmur: { app.showMainWindow() },
            settings: { open(.settings) })
    }
}

/// Everything the bar shows, read from the app — or, for `Murmur --navbar-check`, made up.
struct NavBarContent {
    struct Choice: Identifiable, Equatable {
        let id: String
        let title: String
        var selected = false
    }

    struct Command: Identifiable, Equatable {
        let id: String
        let name: String
        var key: String?
    }

    var languageCode = "EN"
    var languageName = "English"
    var yourLanguages: [Choice] = []
    var allLanguages: [Choice] = []
    var engines: [Choice] = []
    var engineName = ""
    /// Translate into: the target's two letters for the button ("EN"), its name for the row, and the choices — nil
    /// when it's off.
    var translateTarget: String?
    var translateName: String?
    var translateChoices: [Choice] = []
    var transforms: [Command] = []
    var newNoteKey: String?
    var canCopyLast = false
    var voiceProfileOn = true
    var isRecording = false
    /// The dictation key, as the mic's label names it: "fn", "right ⌥"…
    var hotkey = "fn"
}

/// What the bar's buttons and rows do.
struct NavBarActions {
    var dictate: () -> Void = {}
    var setLanguage: (String) -> Void = { _ in }
    var setEngine: (String) -> Void = { _ in }
    var setTranslateInto: (String) -> Void = { _ in }
    var runTransform: (String) -> Void = { _ in }
    var editTransforms: () -> Void = {}
    var newNote: () -> Void = {}
    var copyLast: () -> Void = {}
    var ask: () -> Void = {}
    var setVoiceProfile: (Bool) -> Void = { _ in }
    var openMurmur: () -> Void = {}
    var settings: () -> Void = {}
}

// MARK: - Drawing

/// The line, the bar and its menus — one black shape that changes size, bottom-anchored where the recording pill grows.
struct NavBarBody: View {
    @ObservedObject var model: NavBarModel
    let content: NavBarContent
    let actions: NavBarActions

    /// The resting line — the recording pill grows out of exactly this.
    static let restingSize = StatusHUDView.restingSize
    /// Four 28pt buttons and a divider — the recording pill's own height.
    static let barSize = CGSize(width: 141, height: StatusHUDView.height)
    static let menuWidth: CGFloat = 256
    /// The bar's own half-height, kept when it grows into a menu, so the corners never change.
    static let radius: CGFloat = 18
    static let bottomInset = StatusHUDView.bottomInset
    static let rowHeight: CGFloat = 30
    /// Longer lists scroll, this many rows at a time.
    static let visibleRows = 7

    static var animation: Animation {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .easeOut(duration: 0.15) : StatusHUDController.spring
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered: NavButton?
    @State private var labelled: NavButton?
    @State private var labelTask: Task<Void, Never>?
    /// Which way a page slides: in from the right going into a list, back from the left; nil just crossfades.
    @State private var slide: Edge?

    init(model: NavBarModel, content: NavBarContent, actions: NavBarActions, previewLabel: NavButton? = nil) {
        self.model = model
        self.content = content
        self.actions = actions
        _labelled = State(initialValue: previewLabel)
        _hovered = State(initialValue: previewLabel)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            shape
            if let labelled, model.mode == .bar {
                label(labelled)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, Self.bottomInset + model.lift)
        .onChange(of: model.mode) { _, mode in
            // Folded away, nothing is under the pointer any more — even if the last hover never got its "exit".
            if mode == .resting {
                hovered = nil
                closeLabel()
            }
        }
    }

    // MARK: Shape

    private var size: CGSize {
        switch model.mode {
        case .resting: return Self.restingSize
        case .bar: return Self.barSize
        case .menu(let menu): return CGSize(width: Self.menuWidth, height: Self.height(of: items(menu)))
        }
    }

    /// A menu's rows, plus its padding, the rule above the bar, and the bar.
    static func height(of items: [Item]) -> CGFloat {
        items.reduce(0) { $0 + $1.height } + 12 + 1 + barSize.height
    }

    private var shape: some View {
        let size = self.size
        let outline = RoundedRectangle(cornerRadius: min(Self.radius, size.height / 2), style: .continuous)
        let open = model.mode != .resting
        return ZStack(alignment: .bottom) {
            outline.fill(Palette.hudBlack)
                .overlay(outline.stroke(Color.white.opacity(0.14), lineWidth: 1))
            VStack(spacing: 0) {
                if let menu = model.menu {
                    ZStack(alignment: .bottom) {
                        page(menu)
                            .id(menu)
                            .transition(pageTransition)
                    }
                    .frame(width: Self.menuWidth)
                    .transition(.opacity)
                    Rectangle()
                        .fill(Color.white.opacity(0.10))
                        .frame(width: Self.menuWidth - 24, height: 1)
                        .transition(.opacity)
                }
                barRow
                    .opacity(open ? 1 : 0)
                    .animation(.easeOut(duration: open ? 0.16 : 0.08).delay(open && !reduceMotion ? 0.06 : 0), value: open)
            }
            .frame(width: size.width, height: size.height, alignment: .bottom)
            .clipShape(outline)
        }
        // At rest, nothing: the line only shows as it grows into the bar, and fades as the bar folds away.
        .opacity(open ? 1 : 0)
        .frame(width: size.width, height: size.height)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.shapeFrame = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Murmur")
    }

    private var pageTransition: AnyTransition {
        guard let slide, !reduceMotion else { return .opacity }
        let away: Edge = slide == .trailing ? .leading : .trailing
        return .asymmetric(insertion: .move(edge: slide).combined(with: .opacity),
                           removal: .move(edge: away).combined(with: .opacity))
    }

    // MARK: Bar

    private var barRow: some View {
        HStack(spacing: 2) {
            button(.dictate) {
                closeLabel()
                actions.dictate()
            }
            button(.language) { toggle(.language) }
            Rectangle().fill(Color.white.opacity(0.16)).frame(width: 1, height: 16).padding(.horizontal, 6)
            button(.transforms) { toggle(.transforms) }
            button(.more) { toggle(.more) }
        }
        .padding(.horizontal, 4)
        .frame(width: Self.barSize.width, height: Self.barSize.height)
    }

    private func button(_ kind: NavButton, action: @escaping () -> Void) -> some View {
        let isOpen = model.menu?.button == kind
        let isHot = hovered == kind
        return Button(action: action) {
            ZStack {
                Circle().fill(Color.white.opacity(isOpen ? 0.17 : isHot ? 0.10 : 0))
                glyph(kind).foregroundStyle(Color.white.opacity(isOpen || isHot ? 1 : 0.84))
            }
            .frame(width: 28, height: 28)
            .contentShape(Circle())
        }
        .buttonStyle(PressScaleButtonStyle(scale: 0.9))
        .onHover { hover(kind, $0) }
        .accessibilityLabel(labelText(kind))
    }

    @ViewBuilder private func glyph(_ kind: NavButton) -> some View {
        switch kind {
        case .dictate:
            if content.isRecording {
                // Dictating (the bar stays at the bottom while the notch shows it): the pill's own Stop.
                ZStack {
                    Circle().fill(.white)
                    RoundedRectangle(cornerRadius: 1.5).fill(Palette.hudBlack).frame(width: 7, height: 7)
                }
                .frame(width: 20, height: 20)
            } else {
                MurmurIconView(icon: .mic).frame(width: 15, height: 15)
            }
        case .language:
            if let target = content.translateTarget {
                // Translating: the language it's pasted in, after a sunset arrow — it fits the 28pt button.
                (Text("→").foregroundStyle(Palette.sunset) + Text(target))
                    .font(.manrope(10.5, .bold)).kerning(0.2)
            } else {
                Text(content.languageCode).font(.manrope(11, .bold)).kerning(0.3)
            }
        case .transforms:
            MurmurIconView(icon: .trans).frame(width: 15, height: 15)
        case .more:
            MurmurIconView(icon: .more).frame(width: 15, height: 15)
        }
    }

    private func toggle(_ menu: NavMenu) {
        closeLabel()
        slide = nil
        model.toggle(menu)
    }

    // MARK: Labels

    private func labelText(_ kind: NavButton) -> String {
        switch kind {
        case .dictate: return content.isRecording ? "Stop and paste" : "Click to dictate, or hold \(content.hotkey)"
        case .language:
            if let name = content.translateName { return "\(content.languageName) → \(name)" }
            return "Language: \(content.languageName)"
        case .transforms: return "Transforms"
        case .more: return "More"
        }
    }

    /// A button's name, after a moment's hover — only while no menu is open, so it never covers one.
    private func hover(_ kind: NavButton, _ inside: Bool) {
        if inside {
            hovered = kind
            labelTask?.cancel()
            labelTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 450_000_000)
                guard !Task.isCancelled, hovered == kind, model.menu == nil else { return }
                withAnimation(.easeOut(duration: 0.12)) { labelled = kind }
            }
        } else if hovered == kind {
            hovered = nil
            closeLabel()
        }
    }

    private func closeLabel() {
        labelTask?.cancel()
        labelTask = nil
        if labelled != nil { withAnimation(.easeOut(duration: 0.08)) { labelled = nil } }
    }

    private func label(_ kind: NavButton) -> some View {
        Text(labelText(kind))
            .font(.manrope(11.5, .medium))
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(Palette.hudBlack))
            .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
            .offset(x: Self.offset(of: kind), y: -(Self.barSize.height + 8))
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    /// Where each button's centre sits, from the bar's centre.
    static func offset(of kind: NavButton) -> CGFloat {
        switch kind {
        case .dictate: return -52.5
        case .language: return -22.5
        case .transforms: return 22.5
        case .more: return 52.5
        }
    }

    // MARK: Menus

    enum Item {
        case header(String)
        case back(String)
        case row(Row)
        case divider
        /// Scrolls when it's longer than `visibleRows`.
        case list([Row])

        var height: CGFloat {
            switch self {
            case .header: return 24
            case .back, .row: return NavBarBody.rowHeight
            case .divider: return 11
            case .list(let rows): return CGFloat(min(rows.count, NavBarBody.visibleRows)) * NavBarBody.rowHeight
            }
        }
    }

    struct Row: Identifiable {
        enum Trailing: Equatable {
            case plain, check
            case keycap(String)
            /// A value and a chevron: goes one step in.
            case value(String)
            case toggle(Bool)
        }

        let id: String
        let title: String
        var icon: MurmurIcon?
        var trailing: Trailing = .plain
        var enabled = true
        let action: () -> Void
    }

    func items(_ menu: NavMenu) -> [Item] {
        switch menu {
        case .language:
            var items: [Item] = [.header("Language")]
            items += content.yourLanguages.map { choice in
                .row(Row(id: choice.id, title: choice.title, trailing: choice.selected ? .check : .plain) {
                    pick { actions.setLanguage(choice.id) }
                })
            }
            if content.allLanguages.count > content.yourLanguages.count {
                items.append(.row(Row(id: "all-languages", title: "All languages", trailing: .value("")) {
                    go(to: .allLanguages)
                }))
            }
            items += [.divider,
                      .row(Row(id: "translate", title: "Translate into", trailing: .value(content.translateName ?? "Off")) {
                          go(to: .translate)
                      }),
                      .divider,
                      .row(Row(id: "engine", title: "Engine", trailing: .value(content.engineName)) {
                          go(to: .engine)
                      })]
            return items
        case .translate:
            return [.back("Translate into"), .list(content.translateChoices.map { choice in
                Row(id: choice.id, title: choice.title, trailing: choice.selected ? .check : .plain) {
                    pick { actions.setTranslateInto(choice.id) }
                }
            })]
        case .allLanguages:
            return [.back("All languages"), .list(content.allLanguages.map { choice in
                Row(id: choice.id, title: choice.title, trailing: choice.selected ? .check : .plain) {
                    pick { actions.setLanguage(choice.id) }
                }
            })]
        case .engine:
            return [.back("Engine")] + content.engines.map { choice in
                .row(Row(id: choice.id, title: choice.title, trailing: choice.selected ? .check : .plain) {
                    pick { actions.setEngine(choice.id) }
                })
            }
        case .transforms:
            let rows = content.transforms.map { command in
                Row(id: command.id, title: command.name, trailing: command.key.map { .keycap($0) } ?? .plain) {
                    pick { actions.runTransform(command.id) }
                }
            }
            let list: [Item] = rows.count > Self.visibleRows ? [.list(rows)] : rows.map { .row($0) }
            return [.header("Run on selected text")] + list + [.divider, .row(Row(id: "edit", title: "Edit transforms…") {
                leave { actions.editTransforms() }
            })]
        case .more:
            return [
                .row(Row(id: "note", title: "New note", icon: .scratch, trailing: content.newNoteKey.map { .keycap($0) } ?? .plain) {
                    leave { actions.newNote() }
                }),
                .row(Row(id: "copy", title: model.copied ? "Copied" : "Copy last dictation", icon: .copy,
                         trailing: model.copied ? .check : .plain, enabled: content.canCopyLast || model.copied) { copyLast() }),
                .row(Row(id: "ask", title: "Ask Murmur", icon: .ask) { leave { actions.ask() } }),
                .divider,
                .row(Row(id: "voice", title: "Voice profile", icon: .wave, trailing: .toggle(content.voiceProfileOn)) {
                    actions.setVoiceProfile(!content.voiceProfileOn)
                }),
                .divider,
                .row(Row(id: "open", title: "Open Murmur", icon: .home) { leave { actions.openMurmur() } }),
                .row(Row(id: "settings", title: "Settings", icon: .settings) { leave { actions.settings() } }),
            ]
        }
    }

    /// Picking something: it happens, and the menu folds back into the bar.
    private func pick(_ action: () -> Void) {
        action()
        slide = nil
        model.setMode(.bar)
    }

    /// Going somewhere else — a window, a page: the bar gets out of the way.
    private func leave(_ action: () -> Void) {
        slide = nil
        model.setMode(.resting)
        action()
    }

    private func go(to menu: NavMenu) {
        slide = .trailing
        model.setMode(.menu(menu))
    }

    private func back() {
        slide = .leading
        model.setMode(.menu(.language))
    }

    /// Copies, says so where you clicked, then folds away.
    private func copyLast() {
        guard !model.copied else { return }
        actions.copyLast()
        let model = self.model
        withAnimation(.easeOut(duration: 0.12)) { model.copied = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            if model.menu == .more { model.setMode(.bar) }
            try? await Task.sleep(nanoseconds: 350_000_000)
            model.copied = false
        }
    }

    private func page(_ menu: NavMenu) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items(menu).enumerated()), id: \.offset) { _, item in
                switch item {
                case .header(let text):
                    Text(text.uppercased())
                        .font(.manrope(10.5, .bold))
                        .kerning(0.7)
                        .foregroundStyle(.white.opacity(0.42))
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 19, alignment: .bottomLeading)
                        .padding(.bottom, 5)
                case .back(let title):
                    NavMenuRowView(row: Row(id: "back", title: title) { back() }, isBack: true)
                case .row(let row):
                    NavMenuRowView(row: row)
                case .divider:
                    Rectangle().fill(Color.white.opacity(0.10)).frame(height: 1)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                case .list(let rows):
                    NavMenuList(rows: rows)
                }
            }
        }
        .padding(6)
        .frame(width: Self.menuWidth, alignment: .top)
    }
}

private struct NavMenuRowView: View {
    let row: NavBarBody.Row
    var isBack = false
    @State private var hovering = false

    var body: some View {
        Button(action: row.action) {
            HStack(spacing: isBack ? 7 : 9) {
                if isBack {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .bold))
                } else if let icon = row.icon {
                    MurmurIconView(icon: icon).frame(width: 14, height: 14).foregroundStyle(.white.opacity(0.72))
                }
                Text(row.title)
                    .font(isBack ? .manrope(12.5, .semibold) : .manrope(13, .medium))
                    .lineLimit(1)
                Spacer(minLength: 10)
                trailing
            }
            .foregroundStyle(.white.opacity(isBack ? 0.55 : 0.94))
            .padding(.horizontal, 10)
            .frame(height: NavBarBody.rowHeight)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(hovering && row.enabled ? 0.11 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!row.enabled)
        .opacity(row.enabled ? 1 : 0.38)
        .onHover { hovering = $0 }
        .accessibilityLabel(row.title)
    }

    @ViewBuilder private var trailing: some View {
        switch row.trailing {
        case .plain:
            EmptyView()
        case .check:
            MurmurIconView(icon: .check).frame(width: 12, height: 12).foregroundStyle(Palette.sunset)
        case .keycap(let key):
            Text(key)
                .font(.manrope(11, .semibold))
                .foregroundStyle(.white.opacity(0.62))
                .padding(.horizontal, 5)
                .frame(minWidth: 20, minHeight: 20)
                .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .fixedSize()
        case .value(let value):
            HStack(spacing: 6) {
                if !value.isEmpty {
                    Text(value).font(.manrope(12.5, .medium)).foregroundStyle(.white.opacity(0.5))
                }
                Image(systemName: "chevron.right").font(.system(size: 9.5, weight: .bold)).foregroundStyle(.white.opacity(0.4))
            }
        case .toggle(let on):
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule().fill(on ? Palette.sunset : Color.white.opacity(0.22))
                Circle().fill(Color.white).padding(2)
            }
            .frame(width: 28, height: 16)
            .animation(.murmurEase(0.18), value: on)
        }
    }
}

/// A long list — every language, lots of transforms: scrolls, with soft edges and no scroll bar, opening on the ticked row.
private struct NavMenuList: View {
    let rows: [NavBarBody.Row]

    var body: some View {
        ScrollViewReader { proxy in
            ThinScrollView {
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        NavMenuRowView(row: row).id(row.id)
                    }
                }
            }
            .onAppear {
                guard let ticked = rows.first(where: { $0.trailing == .check }) else { return }
                Task { @MainActor in proxy.scrollTo(ticked.id, anchor: .center) }
            }
        }
        .frame(height: CGFloat(min(rows.count, NavBarBody.visibleRows)) * NavBarBody.rowHeight)
    }
}

// MARK: - Self test

extension NavBarHUDController {
    static func runSelfTest() -> Bool {
        var passed = true
        func check(_ ok: Bool, _ label: String) {
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): nav bar: \(label)")
        }
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.5 }

        // Languages: the Mac's own first, in its order, then the one in use.
        let whisper = ["af", "de", "en", "lv", "zh"]
        check(NavBarLanguages.yours(preferred: ["en-GB", "lv-GB"], options: whisper, current: "en") == ["en", "lv"],
              "your languages come from the Mac's list, matched by language")
        check(NavBarLanguages.yours(preferred: ["en-GB", "lv-GB"], options: ["de", "en", "fr"], current: "en") == ["en"],
              "a language the engine doesn't offer isn't listed")
        check(NavBarLanguages.yours(preferred: ["en-GB", "lv-GB"], options: whisper, current: "de") == ["en", "lv", "de"],
              "the language in use is always there")
        check(NavBarLanguages.yours(preferred: ["en-GB"], options: ["en-GB", "en-US", "de-DE"], current: "en-US") == ["en-GB", "en-US"],
              "full locales match exactly first")
        check(NavBarLanguages.current(in: ["de", "en"], current: "en-US") == "en", "\"en-US\" in use ticks \"en\"")
        check(NavBarLanguages.current(in: ["en-GB", "en-US"], current: "en-US") == "en-US", "an exact match wins")

        // The Dock, as Accessibility reports it on a 2056 × 1329 MacBook (1666 × 85, auto-hidden at the bottom).
        let mac = CGRect(x: 0, y: 0, width: 2056, height: 1329)
        let bottom: CGFloat = 18.3  // the line's bottom edge at rest
        func lift(_ dockY: CGFloat, screen: CGRect = mac, bottom: CGFloat = bottom) -> CGFloat {
            DockGeometry.lift(dock: CGRect(x: 195, y: dockY, width: 1666, height: 85), primaryHeight: 1329, screen: screen, bottom: bottom)
        }
        check(lift(1329) == 0, "a hidden Dock leaves the bar where it is")
        check(near(lift(1244), 85 + 8 - bottom), "a Dock that's up lifts the line 8pt above it")
        check(near(lift(1294), lift(1244)), "a Dock on its way up lifts it to where the Dock will end up")
        check(lift(1244, screen: CGRect(x: 0, y: 1329, width: 2880, height: 1620), bottom: 1339) == 0,
              "the Dock on another screen doesn't move this one")
        check(lift(1244, bottom: 85 + 10 + 8) == 0, "a Dock that's always shown is already below the bar")
        check(DockGeometry.lift(dock: CGRect(x: 0, y: 400, width: 85, height: 600), primaryHeight: 1329, screen: mac, bottom: bottom) == 0,
              "a Dock on the side doesn't matter")
        check(DockGeometry.lift(dock: nil, primaryHeight: 1329, screen: mac, bottom: bottom) == 0, "no Dock, no lift")

        // Everything fits: the tallest menu, over a big Dock, inside the panel — and the mic's label beside it.
        let model = NavBarModel()
        let body = NavBarBody(model: model, content: NavBarContent(
            yourLanguages: [.init(id: "en", title: "English"), .init(id: "lv", title: "Latvian")],
            allLanguages: (0..<100).map { .init(id: "\($0)", title: "Language \($0)") },
            engines: (0..<5).map { .init(id: "\($0)", title: "Engine \($0)") },
            transforms: (0..<12).map { .init(id: "\($0)", name: "Transform \($0)", key: "⌥\($0)") }), actions: NavBarActions())
        let menus: [NavMenu] = [.language, .allLanguages, .engine, .transforms, .more]
        let tallest = menus.map { NavBarBody.height(of: body.items($0)) }.max() ?? 0
        check(tallest + maximumLift + NavBarBody.bottomInset <= panelSize.height,
              "the tallest menu (\(Int(tallest))pt) still fits over the highest ride")
        check(NavBarBody.height(of: body.items(.transforms)) <= 24 + 7 * 30 + 11 + 30 + 49, "a dozen transforms scroll")
        check(NavBarBody.menuWidth <= panelSize.width && panelSize.width / 2 >= 52.5 + 110,
              "the menu and the mic's label fit across the panel")
        check(revealArea.height - NavBarBody.bottomInset > NavBarBody.restingSize.height,
              "the reveal area covers the line and a little above it")
        check(revealArea.width > NavBarBody.barSize.width, "and, since nothing shows there at rest, all of the bar's width")
        return passed
    }
}

// MARK: - Picture check (`Murmur --navbar-check <directory>`)

/// Draws the bar in each of its states, with made-up content, to PNGs over a desktop-grey backdrop — through an
/// invisible, click-through panel, so nothing shows on screen and nothing takes focus.
@MainActor
enum NavBarCheck {
    static func run(outputDirectory: String) async -> Bool {
        try? FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)
        var passed = true
        func report(_ ok: Bool, _ label: String) {
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): nav bar picture: \(label)")
        }
        let content = NavBarContent(
            languageCode: "EN", languageName: "English",
            yourLanguages: [.init(id: "en", title: "English", selected: true), .init(id: "lv", title: "Latvian")],
            allLanguages: ["Croatian", "Czech", "Danish", "Dutch", "English", "Estonian", "Finnish", "French", "German", "Latvian"]
                .map { .init(id: $0, title: $0, selected: $0 == "English") },
            engines: [("apple", "Apple"), ("parakeet", "Parakeet"), ("sherpa", "sherpa-onnx"), ("whisper", "Whisper"),
                      ("whispercpp", "whisper.cpp")].map { .init(id: $0.0, title: $0.1, selected: $0.0 == "whispercpp") },
            engineName: "whisper.cpp",
            transforms: [.init(id: "polish", name: "Polish", key: "⌥1"), .init(id: "prompt", name: "Prompt Engineer", key: "⌥2")],
            newNoteKey: "⌃⇧Space", canCopyLast: true)
        // Translate into, on: Latvian spoken, English pasted.
        var translating = content
        translating.languageCode = "LV"
        translating.languageName = "Latvian"
        translating.yourLanguages = [.init(id: "en", title: "English"), .init(id: "lv", title: "Latvian", selected: true)]
        translating.translateTarget = "EN"
        translating.translateName = "English"
        translating.translateChoices = [.init(id: "off", title: "Off")]
            + ["English", "German", "French", "Spanish", "Italian", "Portuguese", "Dutch", "Swedish"]
                .map { .init(id: $0, title: $0, selected: $0 == "English") }
        let states: [(String, NavBarModel.Mode, CGFloat, NavButton?, Bool)] = [
            ("1-resting", .resting, 0, nil, false),
            ("2-bar", .bar, 0, nil, false),
            ("3-bar-label", .bar, 0, .dictate, false),
            ("4-language", .menu(.language), 0, nil, false),
            ("5-all-languages", .menu(.allLanguages), 0, nil, false),
            ("6-engine", .menu(.engine), 0, nil, false),
            ("7-transforms", .menu(.transforms), 0, nil, false),
            ("8-more", .menu(.more), 0, nil, false),
            ("9-more-copied", .menu(.more), 0, nil, true),
            ("10-riding-the-dock", .resting, 75, nil, false),
            ("11-bar-translating", .bar, 0, nil, false),
            ("12-language-translating", .menu(.language), 0, nil, false),
            ("13-translate-into", .menu(.translate), 0, nil, false),
            ("14-bar-translating-label", .bar, 0, .language, false),
        ]
        for (name, mode, lift, label, copied) in states {
            let content = (Int(name.prefix(while: \.isNumber)) ?? 0) >= 11 ? translating : content
            let model = NavBarModel()
            model.setMode(mode, animated: false)
            model.lift = lift
            model.copied = copied
            let view = NavBarBody(model: model, content: content, actions: NavBarActions(), previewLabel: label)
            let path = (outputDirectory as NSString).appendingPathComponent("navbar-\(name).png")
            let drawn = render(view, to: path)
            report(drawn != nil, "rendered \(name) to \(path)")
            if let drawn {
                report(drawn == (mode != .resting), mode == .resting ? "\(name): nothing shows at rest" : "\(name): it shows")
            }
            // Where it reports itself is where clicks are let in — it has to be exactly where it's drawn: centred,
            // standing on the line's baseline (plus any ride over the Dock).
            let size: CGSize
            switch mode {
            case .resting: size = NavBarBody.restingSize
            case .bar: size = NavBarBody.barSize
            case .menu(let menu): size = CGSize(width: NavBarBody.menuWidth, height: NavBarBody.height(of: view.items(menu)))
            }
            let panel = NavBarHUDController.panelSize
            let expected = CGRect(x: (panel.width - size.width) / 2, y: panel.height - NavBarBody.bottomInset - lift - size.height,
                                  width: size.width, height: size.height)
            let reported = model.shapeFrame
            report(abs(reported.minX - expected.minX) < 0.5 && abs(reported.minY - expected.minY) < 0.5
                   && abs(reported.width - expected.width) < 0.5 && abs(reported.height - expected.height) < 0.5,
                   "\(name): clicks are let in exactly where it's drawn (\(reported) vs \(expected))")
        }
        return passed
    }

    /// Draws the view to `path`; nil if it couldn't, else whether it drew anything at all.
    private static func render<V: View>(_ view: V, to path: String) -> Bool? {
        let size = NavBarHUDController.panelSize
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.sizingOptions = []
        hosting.appearance = NSAppearance(named: .darkAqua)
        let panel = NSPanel(contentRect: hosting.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.contentView = hosting
        panel.orderFrontRegardless()
        let end = Date().addingTimeInterval(0.35)
        while Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        hosting.layoutSubtreeIfNeeded()
        defer { panel.orderOut(nil) }
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        var drewSomething = false
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) where !drewSomething {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                drewSomething = true
                break
            }
        }
        guard let picture = rep.cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: picture.width, height: picture.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let full = CGRect(x: 0, y: 0, width: picture.width, height: picture.height)
        context.setFillColor(CGColor(red: 0.74, green: 0.77, blue: 0.81, alpha: 1))
        context.fill(full)
        context.draw(picture, in: full)
        guard let composite = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: composite).representation(using: .png, properties: [:]),
              (try? png.write(to: URL(fileURLWithPath: path))) != nil
        else { return nil }
        return drewSomething
    }
}
