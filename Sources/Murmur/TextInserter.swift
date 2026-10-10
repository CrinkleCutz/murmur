import AppKit
import Carbon.HIToolbox
import Foundation
import OSLog

private let pasteLog = Logger(subsystem: "local.murmur", category: "paste")

/// Inserts text at the cursor of the frontmost app: puts it on the clipboard, synthesizes ⌘V, then gives the user's
/// previous clipboard back.
///
/// The hand-back used to be a fixed 0.6 s timer. An app that is slow to look at the clipboard (Electron apps under
/// load, a remote desktop, a busy browser tab) then pasted the user's OLD clipboard instead of the dictation, and a
/// copy the user made in that window was overwritten. When Murmur's main thread has been running smoothly, the text
/// now goes on the pasteboard as a promise (`NSPasteboardItemDataProvider`), which tells us the moment another app asks
/// for it, and the clipboard is handed back only after that. A promise is answered by the main thread, so when the
/// main thread has been busy — or the mechanism is switched off (`defaults write local.murmur reliablePaste -bool
/// false`) — the text is written the traditional way instead, which can never be slowed by Murmur.
enum TextInserter {

    typealias SavedClipboard = [[String: Data]]

    /// What happened to a paste, reported once it has settled.
    enum PasteOutcome: Equatable {
        /// The frontmost app read the text from the clipboard: the paste happened.
        case consumed
        /// The text was written the traditional way, so nobody can say whether the app has read it yet.
        case unconfirmed
        /// Nothing read it in time — a target that doesn't paste, a paste that was blocked, or an app so slow it
        /// hadn't looked yet. Don't act on the assumption that the text landed.
        case notObserved
        /// A newer paste took over the clipboard before this one settled.
        case superseded
    }

    /// When the user's clipboard is handed back. It is never sooner than the old fixed timer, so every app that
    /// worked before behaves exactly as it did; the waiting only ever gets longer, and only for apps that need it.
    struct PasteTiming {
        /// Never hand the clipboard back sooner than this (the old fixed delay).
        var floor: TimeInterval = 0.6
        /// Reads that stopped this long ago mean the app is done with the text.
        var quiet: TimeInterval = 0.25
        /// Nothing read the text within this long: the paste didn't happen, or not in a way we can see.
        var noRead: TimeInterval = 2.0
        /// However chatty the reads, hand the clipboard back by now.
        var ceiling: TimeInterval = 4.0
        /// Traditional mode: how long after ⌘V the paste is reported as unconfirmed.
        var unconfirmedAfter: TimeInterval = 0.4
        /// After the app's own Paste menu item was pressed (nothing read the ⌘V), how much longer to wait for a read.
        var retryWindow: TimeInterval = 1.0
    }
    static var timing = PasteTiming()

    /// The switch behind `reliablePaste`: on unless the user turned it off.
    static var reliablePasteEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "reliablePaste") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "reliablePaste") }
    }

    /// The promise is only used while the main thread has been running smoothly.
    static func shouldUsePromise() -> Bool { reliablePasteEnabled && !MainThreadHealth.isBusy }

    /// Pastes `text` into the frontmost app. `completion` runs on the main thread once the paste has settled.
    /// `restoring`: the clipboard to hand back afterwards, when the caller already replaced it (a Transform copies the
    /// selection first); otherwise what's on the clipboard now.
    /// `leaveOnClipboard`: the text stays on the clipboard once the paste has settled, instead of the user's own
    /// clipboard coming back — for an edit of a selection that may not be typeable-over, so it can be pasted by hand.
    static func insert(_ text: String, restoring: SavedClipboard? = nil, leaveOnClipboard: Bool = false,
                       then completion: ((PasteOutcome) -> Void)? = nil) {
        beginPaste(text: text, on: .general, promise: shouldUsePromise(), restoring: restoring,
                   leaveOnClipboard: leaveOnClipboard,
                   press: { sendKeystroke(ShortcutKeys.paste, flags: .maskCommand) },
                   retry: { MenuPaste.pressPasteMenuItem() }, then: completion)
    }

    /// `insert` with the pasteboard and the keystroke injectable, so the self-test can exercise the clipboard handling
    /// on a private pasteboard without pressing ⌘V into whatever app happens to be in front.
    static func beginPaste(
        text: String, on pasteboard: NSPasteboard, promise: Bool, restoring: SavedClipboard? = nil,
        leaveOnClipboard: Bool = false, press: () -> Void,
        retry: (() -> Void)? = nil, then completion: ((PasteOutcome) -> Void)?
    ) {
        // A paste that hasn't handed the clipboard back yet is holding the USER's clipboard — what is on the
        // pasteboard now is our previous transcript. Keep the original instead of saving that.
        let earlier = PasteSession.current
        earlier?.supersede()
        let saved = earlier?.saved ?? restoring ?? saveClipboard(from: pasteboard)
        let session = PasteSession(
            text: text, saved: saved, pasteboard: pasteboard, usesPromise: promise, timing: timing, retry: retry,
            completion: completion)
        session.leaveOnClipboard = leaveOnClipboard
        PasteSession.current = session
        session.begin(press: press)
    }

    /// Copies the current selection in the frontmost app by synthesizing ⌘C.
    /// Returns the selected text, or nil if nothing was copied in time.
    static func copySelection() async -> String? {
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        sendKeystroke(ShortcutKeys.copy, flags: .maskCommand)
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if pasteboard.changeCount != changeCount {
                return pasteboard.string(forType: .string)
            }
        }
        return nil
    }

    /// macOS can ask before an app reads what another app copied ("Murmur would like to paste from…"). Saving the
    /// user's clipboard to hand back after a dictation is exactly that kind of read, so it's skipped when macOS would
    /// ask or refuse: the dictation then simply stays on the clipboard instead of a prompt on every dictation.
    static func mayReadClipboard(_ pasteboard: NSPasteboard) -> Bool {
        guard pasteboard.name == .general else { return true }
        if #available(macOS 15.4, *) {
            let behavior = NSPasteboard.general.accessBehavior
            return behavior != .ask && behavior != .alwaysDeny
        }
        return true
    }

    static func saveClipboard(from pasteboard: NSPasteboard = .general) -> SavedClipboard {
        guard mayReadClipboard(pasteboard) else { return [] }
        return pasteboard.pasteboardItems?.compactMap { item -> [String: Data]? in
            var copy: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy[type.rawValue] = data
                }
            }
            return copy.isEmpty ? nil : copy
        } ?? []
    }

    static func restoreClipboard(_ saved: SavedClipboard, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        let items = saved.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        }
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }

    /// Waits, up to `limit`, until no Option, Shift or Control key is physically held: one still down from a hotkey
    /// can turn ⌘V into a different command ("Paste and Match Style") in some apps. Returns at once when none is —
    /// the usual case.
    static func waitForModifierRelease(limit: TimeInterval = 0.4) async {
        let held: CGEventFlags = [.maskAlternate, .maskShift, .maskControl]
        let deadline = Date().addingTimeInterval(limit)
        while !CGEventSource.flagsState(.combinedSessionState).intersection(held).isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    static func sendKeystroke(_ key: Int, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(
            keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: true)
        let keyUp = CGEvent(
            keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: false)
        keyDown?.flags = flags
        keyUp?.flags = flags
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    // MARK: - One paste in flight

    /// The dictation on the pasteboard — as a promise until the app that pastes it has read it, or written straight
    /// out in the traditional mode — until the user's clipboard goes back.
    private final class PasteSession: NSObject, NSPasteboardItemDataProvider {
        /// The paste still holding the user's clipboard, if any. Main thread only.
        static var current: PasteSession?
        /// Superseded promises must stay alive until the pasteboard has let go of them.
        static var retiring: Set<PasteSession> = []
        /// The convention clipboard managers (Paste, Maccy, Raycast, Alfred…) follow to skip recording a change: a
        /// dictation shouldn't sit in someone's clipboard history.
        static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

        let text: String
        let saved: SavedClipboard
        private let pasteboard: NSPasteboard
        private let usesPromise: Bool
        private let timing: PasteTiming
        /// Tried once when nothing read the ⌘V: the app's own Paste menu item (some apps ignore a synthetic ⌘V).
        private let retry: (() -> Void)?
        private var retried = false
        /// The text stays on the clipboard when the paste has settled; the user's own doesn't come back.
        var leaveOnClipboard = false
        private var completion: ((PasteOutcome) -> Void)?
        private var timer: DispatchSourceTimer?
        private var startedAt = Date()
        private var changeCountAfterWrite = 0

        // Written by the pasteboard's request handling.
        private let lock = NSLock()
        private var reads = 0
        private var firstReadAt: Date?
        private var lastReadAt: Date?
        private var providerFinished = false

        init(text: String, saved: SavedClipboard, pasteboard: NSPasteboard, usesPromise: Bool, timing: PasteTiming,
             retry: (() -> Void)? = nil, completion: ((PasteOutcome) -> Void)?) {
            self.retry = retry
            self.text = text
            self.saved = saved
            self.pasteboard = pasteboard
            self.usesPromise = usesPromise
            self.timing = timing
            self.completion = completion
        }

        func begin(press: () -> Void) {
            let item = NSPasteboardItem()
            if usesPromise {
                item.setDataProvider(self, forTypes: [.string])
            } else {
                item.setString(text, forType: .string)
            }
            item.setData(Data(), forType: Self.transientType)
            pasteboard.clearContents()
            pasteboard.writeObjects([item])
            changeCountAfterWrite = pasteboard.changeCount
            startedAt = Date()
            press()
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + 0.025, repeating: 0.025)
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }

        /// Another app asked for the text: that is the paste happening.
        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
            item.setString(text, forType: type)
            let now = Date()
            lock.lock()
            reads += 1
            if firstReadAt == nil { firstReadAt = now }
            lastReadAt = now
            lock.unlock()
        }

        /// Something else took over the pasteboard (or we handed it back).
        func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
            lock.lock()
            providerFinished = true
            lock.unlock()
            DispatchQueue.main.async { Self.retiring.remove(self) }
        }

        private func snapshot() -> (reads: Int, firstReadAt: Date?, lastReadAt: Date?, finished: Bool) {
            lock.lock()
            defer { lock.unlock() }
            return (reads, firstReadAt, lastReadAt, providerFinished)
        }

        private func tick() {
            let now = Date()
            let elapsed = now.timeIntervalSince(startedAt)
            guard usesPromise else {
                // Traditional mode: nothing to watch. Report, and hand the clipboard back on the old schedule.
                if elapsed >= timing.unconfirmedAfter { report(.unconfirmed) }
                if elapsed >= timing.floor { finish() }
                return
            }
            let state = snapshot()
            let quiet = state.lastReadAt.map { now.timeIntervalSince($0) >= timing.quiet } ?? false
            if state.reads > 0, quiet { report(.consumed) }
            // Nothing read the ⌘V in all this time: the app ignored it (it would have read by now — a slow app was
            // measured reading after 1.5 s, the wait is 2). Press its own Paste menu item once, and wait a little
            // longer; only a read after that counts, so a paste can never land twice.
            if state.reads == 0, !retried, let retry, elapsed >= timing.noRead {
                retried = true
                pasteLog.info("paste: nothing read the keystroke; pressing the app's Paste menu item")
                retry()
                return
            }
            let noReadDeadline = timing.noRead + (retried ? timing.retryWindow : 0)
            let settled = (state.reads > 0 && quiet) || (state.reads == 0 && elapsed >= noReadDeadline) || state.finished
            guard elapsed >= timing.floor, settled || elapsed >= timing.ceiling else { return }
            finish()
        }

        private func finish() {
            timer?.cancel()
            timer = nil
            // Counted before the restore: checking what is on the clipboard can itself ask for the text.
            let state = snapshot()
            if leaveOnClipboard {
                // As plain text, in place of the promise: there for ⌘V, and for a clipboard manager to keep.
                if pasteboard.changeCount == changeCountAfterWrite || pasteboard.string(forType: .string) == text {
                    pasteboard.clearContents()
                    pasteboard.setString(text, forType: .string)
                }
            } else {
                restoreIfStillOurs()
            }
            if Self.current === self { Self.current = nil }
            if usesPromise {
                if let first = state.firstReadAt {
                    let milliseconds = Int(first.timeIntervalSince(self.startedAt) * 1000)
                    pasteLog.info("paste: text read \(milliseconds, privacy: .public) ms after the keystroke")
                } else {
                    pasteLog.info("paste: text never read")
                }
                report(state.reads > 0 ? .consumed : .notObserved)
            } else {
                pasteLog.info("paste: written the traditional way")
                report(.unconfirmed)
            }
        }

        /// A newer paste is taking over; it inherits the user's clipboard from us.
        func supersede() {
            timer?.cancel()
            timer = nil
            if usesPromise, !snapshot().finished { Self.retiring.insert(self) }
            report(.superseded)
        }

        /// Hands the user's clipboard back — unless the clipboard now holds something that isn't our dictation (the
        /// user copied something new in the meantime; that is worth more than what they had before).
        private func restoreIfStillOurs() {
            // Nothing was saved because macOS would have asked first: leave the dictation where it is.
            guard TextInserter.mayReadClipboard(pasteboard) else { return }
            let untouched = pasteboard.changeCount == changeCountAfterWrite
            guard untouched || pasteboard.string(forType: .string) == text else { return }
            TextInserter.restoreClipboard(saved, to: pasteboard)
        }

        private func report(_ outcome: PasteOutcome) {
            guard let completion else { return }
            self.completion = nil
            completion(outcome)
        }
    }

    // MARK: - Self test

    /// Exercises the clipboard handling on a PRIVATE pasteboard — the user's clipboard is never touched — reading it
    /// from another thread the way another app would, without pressing any key.
    @MainActor
    static func runSelfTest() -> Bool {
        var passed = true
        func check(_ ok: Bool, _ label: String) {
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): paste: \(label)")
        }
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        let previousTiming = timing
        timing = PasteTiming(floor: 0.15, quiet: 0.1, noRead: 0.5, ceiling: 1.2, unconfirmedAfter: 0.1)
        defer { timing = previousTiming }

        func setClipboard(_ string: String) {
            pb.clearContents()
            pb.setString(string, forType: .string)
        }
        func clipboard() -> String? { pb.string(forType: .string) }
        /// Runs the main run loop, where the pasteboard's requests and our timer are handled.
        func pump(_ seconds: TimeInterval) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        }
        func pump(timeout: TimeInterval, until done: () -> Bool) {
            let end = Date().addingTimeInterval(timeout)
            while !done(), Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        }
        /// What another app sees when it pastes: a read from a different thread, while the main run loop keeps turning.
        func readElsewhere() -> String? {
            var result: String?
            var finished = false
            DispatchQueue.global().async {
                result = pb.string(forType: .string)
                finished = true
            }
            pump(timeout: 3) { finished }
            return result
        }
        func paste(_ text: String, promise: Bool = true, then completion: @escaping (PasteOutcome) -> Void) {
            beginPaste(text: text, on: pb, promise: promise, press: {}, then: completion)
        }

        // A slow app reads long after the old fixed timer (0.15 s at this scale) would have handed the clipboard back.
        setClipboard("USER-CLIP")
        var outcome: PasteOutcome?
        paste("DICTATED") { outcome = $0 }
        pump(0.3)   // well past the old fixed timer, still inside the no-read window (0.5 s)
        check(readElsewhere() == "DICTATED", "a slow app still gets the dictation, not the old clipboard")
        pump(timeout: 3) { outcome != nil }
        pump(0.1)
        check(outcome == .consumed, "…and the paste is reported as consumed")
        check(clipboard() == "USER-CLIP", "…and the user's clipboard comes back afterwards")

        // A fast app.
        setClipboard("USER-CLIP")
        outcome = nil
        paste("DICTATED") { outcome = $0 }
        pump(0.03)
        check(readElsewhere() == "DICTATED", "a fast app gets the dictation")
        pump(timeout: 3) { outcome != nil }
        pump(0.3)
        check(outcome == .consumed && clipboard() == "USER-CLIP", "…and the clipboard comes back")

        // Nobody reads it: no paste happened, so nothing may act as if it had.
        setClipboard("USER-CLIP")
        outcome = nil
        paste("DICTATED") { outcome = $0 }
        pump(timeout: 3) { outcome != nil }
        pump(0.1)
        check(outcome == .notObserved, "no read within the window is reported as not observed")
        check(clipboard() == "USER-CLIP", "…and the clipboard still comes back")

        // The user copies something new while the paste is settling: that copy must survive.
        setClipboard("USER-CLIP")
        outcome = nil
        paste("DICTATED") { outcome = $0 }
        pump(0.05)
        setClipboard("USER-NEW")
        pump(timeout: 3) { outcome != nil }
        pump(0.1)
        check(clipboard() == "USER-NEW", "a copy made during the paste is not overwritten")

        // Two dictations back to back: the second must give back the user's clipboard, not the first dictation.
        setClipboard("USER-CLIP")
        var first: PasteOutcome?, second: PasteOutcome?
        paste("FIRST") { first = $0 }
        pump(0.05)
        paste("SECOND") { second = $0 }
        pump(timeout: 3) { second != nil }
        pump(0.1)
        check(first == .superseded, "a paste taken over by a newer one is reported as superseded")
        check(clipboard() == "USER-CLIP", "the original clipboard survives two pastes in a row")

        // The traditional mode: the text is there at once, whatever the main thread is doing.
        setClipboard("USER-CLIP")
        outcome = nil
        paste("DICTATED", promise: false) { outcome = $0 }
        let readStart = Date()
        let readLock = NSLock()
        var stalledRead: String?
        var readFinishedAt: Date?
        DispatchQueue.global().async {
            let value = pb.string(forType: .string)
            readLock.lock(); stalledRead = value; readFinishedAt = Date(); readLock.unlock()
        }
        Thread.sleep(forTimeInterval: 0.15)      // the main thread is busy, as during a heavy SwiftUI update
        readLock.lock()
        let readTook = readFinishedAt.map { $0.timeIntervalSince(readStart) }
        let readValue = stalledRead
        readLock.unlock()
        check(readValue == "DICTATED", "traditional mode puts the text on the clipboard at once")
        check(readTook != nil && readTook! < 0.1, "…and another app's paste finishes while the main thread is still stalled")
        pump(timeout: 3) { outcome != nil }
        pump(0.1)
        check(outcome == .unconfirmed && clipboard() == "USER-CLIP", "…reported as unconfirmed, and the clipboard comes back")

        // The choice between the two modes.
        let savedSwitch = UserDefaults.standard.object(forKey: "reliablePaste")
        defer { UserDefaults.standard.set(savedSwitch, forKey: "reliablePaste") }
        reliablePasteEnabled = true
        MainThreadHealth.start()
        pump(0.5)
        MainThreadHealth.window = 0.3
        DispatchQueue.main.async { Thread.sleep(forTimeInterval: 0.08) }
        pump(0.15)
        check(!shouldUsePromise(), "a main thread that just stalled is not trusted with a promise")
        pump(0.5)
        check(shouldUsePromise(), "…and is trusted again once it has been quiet")
        MainThreadHealth.window = 2
        reliablePasteEnabled = false
        check(!shouldUsePromise(), "the reliablePaste switch turns the promise off")
        return passed
    }
}

/// The app that has keyboard focus. From the system-wide Accessibility element, which also sees a launcher panel
/// (Raycast, Spotlight) that holds focus without being the frontmost app; the frontmost app when that isn't available.
/// A short timeout, so a hung app can't stall a dictation.
enum FocusedApp {
    static func pid() -> pid_t? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.1)
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &value) == .success,
           let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
            var pid: pid_t = 0
            if AXUIElementGetPid(value as! AXUIElement, &pid) == .success, pid > 0 { return pid }
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier
    }
}

/// The app's own Paste menu item, for an app that ignores a synthetic ⌘V: the item whose shortcut is ⌘V — found by its
/// shortcut, not its title, so it works in every language — pressed through Accessibility.
enum MenuPaste {
    static func pressPasteMenuItem() {
        guard let pid = FocusedApp.pid() else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        func children(_ element: AXUIElement) -> [AXUIElement] {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success
            else { return [] }
            return value as? [AXUIElement] ?? []
        }
        func string(_ element: AXUIElement, _ attribute: String) -> String? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
            return value as? String
        }
        func number(_ element: AXUIElement, _ attribute: String) -> Int? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
            return (value as? NSNumber)?.intValue
        }
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &bar) == .success,
              let bar, CFGetTypeID(bar) == AXUIElementGetTypeID() else { return }
        for barItem in children(bar as! AXUIElement) {
            for menu in children(barItem) {
                for item in children(menu) where string(item, kAXMenuItemCmdCharAttribute)?.uppercased() == "V"
                    && (number(item, kAXMenuItemCmdModifiersAttribute) ?? -1) == 0 {
                    AXUIElementPerformAction(item, kAXPressAction as CFString)
                    return
                }
            }
        }
    }
}

/// Remote desktops and virtual machines: inside the session ⌘V isn't paste (it's the Windows or Linux key plus V), so
/// the text is left on the clipboard for the user to paste there.
enum RemoteSession {
    static let bundleIDs: Set<String> = [
        "com.microsoft.rdc.macos", "com.microsoft.rdc.mac", "com.microsoft.windowsapp", "com.citrix.receiver.icaviewer.mac",
        "com.citrix.receiver.nomas", "com.vmware.horizon", "com.vmware.fusion", "com.parallels.desktop.console",
        "com.p5sys.jump.mac.viewer", "com.teamviewer.TeamViewer", "com.utmapp.UTM", "com.realvnc.vncviewer",
        "com.anydesk.anydeskmacos", "com.philandro.anydesk", "com.google.chromeremotedesktop",
    ]
}

/// The few characters before the cursor in the focused text field, read through Accessibility with a short timeout
/// (a hung app can't stall a dictation), or nil when they can't be read — then nothing is adjusted. Never from a
/// password field.
enum CursorContext {
    private static var electronApps: Set<pid_t> = []

    static func textBeforeCaret(maxCharacters: Int = 3) -> String? {
        if let text = read(maxCharacters: maxCharacters) { return text }
        // Electron apps (Claude, ChatGPT, Slack, VS Code…) keep their Accessibility tree switched off until asked.
        guard let pid = FocusedApp.pid(), !electronApps.contains(pid),
              let url = NSRunningApplication(processIdentifier: pid)?.bundleURL,
              FileManager.default.fileExists(
                atPath: url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path)
        else { return nil }
        electronApps.insert(pid)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.12)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        return read(maxCharacters: maxCharacters)
    }

    /// The text selected in the field in front, through Accessibility — nil when nothing is selected, it's a password
    /// field, or the app doesn't say. The clipboard is never touched (unlike ⌘C, which in some editors copies the whole
    /// line when nothing is selected). For editing a selection by voice — see `SpokenCommand`.
    static func selectedText(maxCharacters: Int = 8_000) -> String? {
        if case .text(let text) = selection(maxCharacters: maxCharacters) { return text }
        return nil
    }

    /// What the field in front says about its selection. `unknown` is an app that doesn't say — not the same as
    /// nothing being selected: text highlighted on a web page, in a PDF or in an app without Accessibility support is
    /// there to be copied all the same (`AppDelegate.spokenCommandSelection`).
    enum Selection: Equatable { case text(String), nothing, unknown }

    static func selection(maxCharacters: Int = 8_000) -> Selection {
        func state(_ text: String?) -> Selection {
            guard let text else { return .unknown }
            return text.isEmpty ? .nothing : .text(text)
        }
        if let text = readSelection(maxCharacters: maxCharacters) { return state(text) }
        guard let pid = FocusedApp.pid(), !electronApps.contains(pid),
              let url = NSRunningApplication(processIdentifier: pid)?.bundleURL,
              FileManager.default.fileExists(
                atPath: url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path)
        else { return .unknown }
        electronApps.insert(pid)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.12)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        return state(readSelection(maxCharacters: maxCharacters))
    }

    /// Whether the thing in front can be typed into: a text field or an editor (true), text that can only be read — a
    /// web page, a PDF, someone else's message (false) — or an app that doesn't say (nil).
    static func focusedIsEditable() -> Bool? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.12)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.12)
        var role: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success, let role = role as? String,
           [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole, "AXSearchField"].contains(role) { return true }
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success {
            if settable.boolValue { return true }
            // It answered, and the selection can't be written: read-only text.
            return false
        }
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue {
            return true
        }
        return nil
    }

    /// Whether the field in front says outright that nothing is selected (not merely that it can't be read).
    static func nothingIsSelected() -> Bool { readSelection(maxCharacters: 8_000) == "" }

    /// "" when the field says nothing is selected, or is a password field; nil when it can't be read.
    private static func readSelection(maxCharacters: Int) -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.12)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.12)
        var subrole: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success,
           (subrole as? String) == (kAXSecureTextFieldSubrole as String) { return "" }
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success,
           let text = value as? String {
            return text.count <= maxCharacters ? text : nil
        }
        // Some fields only give the range: read the string for it.
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
        var selection = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &selection), selection.location >= 0 else { return nil }
        guard selection.length > 0 else { return "" }
        guard selection.length <= maxCharacters, let wantedValue = AXValueCreate(.cfRange, &selection) else { return nil }
        var text: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, wantedValue, &text) == .success
        else { return nil }
        return text as? String
    }

    private static func read(maxCharacters: Int) -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.12)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.12)
        var subrole: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success,
           (subrole as? String) == (kAXSecureTextFieldSubrole as String) { return nil }
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
        var selection = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &selection), selection.location >= 0 else { return nil }
        if selection.location == 0 { return "" }
        let start = max(0, selection.location - maxCharacters)
        var wanted = CFRange(location: start, length: selection.location - start)
        guard let wantedValue = AXValueCreate(.cfRange, &wanted) else { return nil }
        var text: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, wantedValue, &text) == .success
        else { return nil }
        return text as? String
    }
}

/// Fits a dictation to where the cursor is: a space when it continues right after a word or a sentence on the same
/// line, and an ordinary first word in lower case when it continues a sentence ("…and then" + "The rest" → "…and then
/// the rest"). Names, "I" and acronyms keep their capitals; nothing changes when the characters before the cursor
/// couldn't be read.
enum InsertionShaper {
    static func shape(_ text: String, before: String?, lowercaseContinuation: Bool,
                      isKnownWord: (String) -> Bool = HarperChecker.isKnownEnglishWord) -> String {
        guard let before, let last = before.last, let first = text.first else { return text }
        var result = text
        let opensSomething = "([{\"'“‘/-_@#".contains(last)
        if !last.isWhitespace, !opensSomething, first.isLetter || first.isNumber {
            result = " " + result
        }
        if lowercaseContinuation, !last.isNewline,
           let previous = before.last(where: { !$0.isWhitespace }), previous.isLetter || previous.isNumber || previous == ",",
           first.isUppercase {
            let word = String(text.prefix { $0.isLetter || $0 == "'" || $0 == "’" })
            let rest = word.dropFirst()
            if word.count > 1, rest.allSatisfy({ !$0.isUppercase }), word != "I'm", word != "I’m", word != "I'll",
               word != "I'd", word != "I've", isKnownWord(word.lowercased()) {
                let index = result.firstIndex(of: first)!
                result.replaceSubrange(index...index, with: String(first).lowercased())
            }
        }
        return result
    }

    static func runSelfTest() -> Bool {
        var passed = true
        func check(_ ok: Bool, _ label: String) {
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): at the cursor: \(label)")
        }
        let known: Set<String> = ["the", "and", "then", "we", "it", "send"]
        func run(_ text: String, _ before: String?) -> String {
            shape(text, before: before, lowercaseContinuation: true, isKnownWord: { known.contains($0) })
        }
        check(run("The rest.", "and") == " the rest.", "continuing a sentence: a space and a lower-case ordinary word")
        check(run("Send it.", "ok.") == " Send it.", "after a full stop: a space, the capital stays")
        check(run("Janis will call.", "and") == " Janis will call.", "a name keeps its capital")
        check(run("I think so.", "and") == " I think so.", "\"I\" stays")
        check(run("NASA called.", "and") == " NASA called.", "an acronym stays")
        check(run("The rest.", "and ") == "the rest.", "a space already there: none added")
        check(run("The rest.", "\n") == "The rest.", "a new line starts fresh")
        check(run("The rest.", "") == "The rest.", "an empty field: unchanged")
        check(run("The rest.", nil) == "The rest.", "nothing readable: unchanged")
        check(run("Hello.", "(") == "Hello.", "right after an opening bracket: no space")
        return passed
    }
}
