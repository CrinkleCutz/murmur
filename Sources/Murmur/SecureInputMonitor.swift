import AppKit
import Carbon.HIToolbox
import Darwin
import Foundation
import IOKit
import OSLog

private let secureInputLog = Logger(subsystem: "local.murmur", category: "secure-input")

/// Whether macOS "secure event input" is on, and who is holding it.
///
/// Password fields and Terminal's "Secure Keyboard Entry" turn it on so no other app can watch the keystrokes. While
/// it is on, Murmur's key-based shortcuts (profile hotkeys, Transform hotkeys, Notetaker, Scratchpad) can't hear the
/// keyboard — with nothing on screen to say why. An app that forgets to turn it off again breaks them everywhere
/// until it quits.
struct SecureInputStatus: Equatable {
    var isOn = false
    /// The process holding it, when the window server says which.
    var holderPID: Int32?
    var holderName: String?
    /// The holder is the app in front — a focused password field or Terminal's secure entry, which is expected —
    /// rather than something quietly running in the background.
    var holderIsFrontmost = false
    /// When it was first seen on (this stretch).
    var since: Date?
}

enum SecureInputProbe {
    static func isEnabled() -> Bool { IsSecureEventInputEnabled() }

    /// The process holding secure input, from the console-session records the window server publishes in the I/O
    /// Registry (the same place `ioreg` shows `kCGSSessionSecureInputPID`).
    static func holderPID() -> Int32? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        guard let property = IORegistryEntrySearchCFProperty(
            root, kIOServicePlane, "IOConsoleUsers" as CFString, kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively)),
              let users = property as? [[String: Any]]
        else { return nil }
        return holderPID(inConsoleUsers: users)
    }

    /// The secure-input PID out of the `IOConsoleUsers` records.
    static func holderPID(inConsoleUsers users: [[String: Any]]) -> Int32? {
        for user in users {
            if let pid = user["kCGSSessionSecureInputPID"] as? Int, pid > 0 { return Int32(pid) }
        }
        return nil
    }

    /// The app name for a PID: the running application's, else the bare process name (a command-line tool).
    static func name(ofPID pid: Int32) -> String? {
        if let name = NSRunningApplication(processIdentifier: pid)?.localizedName { return name }
        var buffer = [CChar](repeating: 0, count: 256)
        return proc_name(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : nil
    }

    static func runSelfTest() -> Bool {
        var passed = true
        func check(_ ok: Bool, _ label: String) {
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): secure input: \(label)")
        }
        check(holderPID(inConsoleUsers: [["kCGSSessionUserIDKey": 501], ["kCGSSessionSecureInputPID": 4242]]) == 4242,
              "finds the holder among several console-session records")
        check(holderPID(inConsoleUsers: [["kCGSSessionUserIDKey": 501]]) == nil, "no record, no holder")
        check(holderPID(inConsoleUsers: [["kCGSSessionSecureInputPID": 0]]) == nil, "a zero PID is not a holder")
        check(holderPID(inConsoleUsers: [["kCGSSessionSecureInputPID": "4242"]]) == nil, "a malformed record is ignored")
        check(holderPID(inConsoleUsers: []) == nil, "an empty registry has no holder")
        check(name(ofPID: getpid()) != nil, "this process can be named")
        check(SecureInputStatus() == SecureInputStatus(isOn: false), "the initial status is off")
        return passed
    }
}

/// Watches secure event input. Publishes what is happening; it puts nothing on screen itself.
@MainActor
final class SecureInputMonitor: ObservableObject {
    static let shared = SecureInputMonitor()

    @Published private(set) var status = SecureInputStatus()
    /// Long enough to be worth telling the user: password fields switch it on for a few seconds at a time, which is
    /// normal and needs no warning.
    @Published private(set) var isWorthWarning = false
    static let persistence: TimeInterval = 3

    private var timer: Timer?

    /// The one line to show while secure input is worth mentioning; nil otherwise.
    var notice: String? {
        guard isWorthWarning else { return nil }
        let holder = status.holderName.map { " (\($0))" } ?? ""
        return "Secure input is on\(holder) \u{2014} some shortcuts may not respond."
    }

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        var next = SecureInputStatus()
        if SecureInputProbe.isEnabled() {
            next.isOn = true
            next.since = status.isOn ? status.since : Date()
            let pid = SecureInputProbe.holderPID()
            next.holderPID = pid
            next.holderName = pid.flatMap(SecureInputProbe.name(ofPID:))
            next.holderIsFrontmost = pid != nil && pid == NSWorkspace.shared.frontmostApplication?.processIdentifier
        }
        if next != status {
            if next.isOn != status.isOn {
                secureInputLog.info("secure input \(next.isOn ? "on" : "off", privacy: .public); frontmost holder: \(next.holderIsFrontmost, privacy: .public)")
            }
            status = next
        }
        let warn = next.isOn && Date().timeIntervalSince(next.since ?? Date()) >= Self.persistence
        if warn != isWorthWarning { isWorthWarning = warn }
    }
}
