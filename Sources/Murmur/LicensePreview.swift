import Foundation
import SwiftUI

// MARK: - License preview (source builds)
//
// A build from source never asks for a license — that's the promise that keeps the founder's own build, and anyone's
// self-built copy, free for good. So its Settings has no License tile. The preview puts the real one there anyway, to
// see and try what a buyer gets: the same `LicenseSection`, the same `LicenseStore`, talking to a pretend server that
// answers exactly as the real one will (docs/licensing-api.md, signed license files and all) on a pretend clock that
// can be moved on a week at a time.
//
// It lives only in memory: it never touches the Keychain, never goes on the network, and never pauses anything —
// dictation in a source build runs on `LicenseStore.shared`, which this doesn't touch. Turned on and off from
// General (the `licensePreview` default); an official release build has the real tile and never shows it.

/// The preview's clock: now, plus however far it's been moved on.
final class PreviewClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _offset: TimeInterval = 0

    var offset: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return _offset }
        set { lock.lock(); _offset = newValue; lock.unlock() }
    }

    func now() -> Date { Date().addingTimeInterval(offset) }
}

@MainActor
final class LicensePreview: ObservableObject {
    static let shared = LicensePreview()

    static let defaultsKey = "licensePreview"

    /// A fresh one at "Start over" — Settings watches the new instance.
    @Published private(set) var store: LicenseStore
    @Published var serverOnline = true
    @Published var newerVersionOut = false

    let clock = PreviewClock()
    private let signer = Curve25519Fixture()
    private var storage = MemoryLicenseStorage()
    /// The pretend server's memory: which key is active here, when it was bought, and whether it was refunded.
    private var activeKey: String?
    private var purchasedAt: Date?
    private var refunded = false

    init() {
        store = LicenseStore(channel: .release, storage: storage, server: LicenseServer(baseURL: URL(string: "https://preview.local")!,
                                                                                       transport: { _ in throw URLError(.cancelled) }),
                             publicKey: "", machineHash: nil)
        startOver()
    }

    /// A newer version the license doesn't include, while "A newer version is out" is on.
    var notIncluded: SparkleUpdater.NotIncluded? {
        guard newerVersionOut, let license = store.license, let until = license.payload.maintenanceUntil else { return nil }
        return SparkleUpdater.NotIncluded(version: "2.6", releaseDate: until.addingTimeInterval(30 * 86_400))
    }

    /// What the HUD would say if dictation were paused right now (or the trial-over line when it isn't).
    var hudNotice: String { store.pausedNotice ?? LicensePanelState.PausedReason.trialEnded.hudNotice }

    var todayText: String { LicenseFormat.day(clock.now()) }

    // MARK: Controls

    /// The first launch of an official build: a 7-day trial and nothing else.
    func startOver() {
        clock.offset = 0
        serverOnline = true
        newerVersionOut = false
        activeKey = nil
        purchasedAt = nil
        refunded = false
        storage = MemoryLicenseStorage()
        storage.items["trial-started"] = ISO8601DateFormatter().string(from: clock.now())
        let server = LicenseServer(baseURL: URL(string: "https://preview.local")!, transport: { [weak self] request in
            guard let self else { throw URLError(.cancelled) }
            return try self.respond(to: request)
        })
        let clock = self.clock
        let fresh = LicenseStore(channel: .release, storage: storage, server: server, publicKey: signer.publicKey,
                                 machineHash: MachineIdentity.hash(), now: { clock.now() })
        fresh.load()
        store = fresh
    }

    /// A week goes by — and, like the real app, it checks in when its license is due.
    func skipWeek() async {
        clock.offset += 7 * 86_400
        store.objectWillChange.send()
        objectWillChange.send()
        await store.checkInIfDue()
    }

    /// The purchase is refunded on the website; the app finds out at its next check-in, done now.
    func refund() async {
        refunded = true
        await store.confirmNow()
    }

    // MARK: The pretend server

    private func respond(to request: URLRequest) throws -> (Data, Int) {
        guard serverOnline else { throw URLError(.notConnectedToInternet) }
        let body = (request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        let key = (body["licenseKey"] as? String ?? "").uppercased()
        let machine = body["machineHash"] as? String ?? ""
        func reply(_ status: Int, _ object: [String: Any]) -> (Data, Int) {
            ((try? JSONSerialization.data(withJSONObject: object)) ?? Data(), status)
        }
        switch request.url?.path {
        case "/api/license/activate":
            guard key.range(of: #"^MRMR-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}$"#, options: .regularExpression) != nil else {
                return reply(404, ["error": "not_found"])
            }
            if key.contains("FULL") { return reply(409, ["error": "seats_full"]) }
            if key != activeKey {
                activeKey = key
                purchasedAt = clock.now()
                refunded = false
            }
            return reply(200, ["license": licenseFile(key: key, machine: machine)])
        case "/api/license/check":
            if refunded { return reply(403, ["error": "refunded"]) }
            guard key == activeKey else { return reply(403, ["error": "not_activated"]) }
            return reply(200, ["license": licenseFile(key: key, machine: machine)])
        case "/api/license/deactivate":
            if key == activeKey { activeKey = nil }
            return reply(200, [:])
        default:
            return reply(404, ["error": "not_found"])
        }
    }

    /// A license file exactly as the website issues one (lib/licensing.js), signed with the preview's own key.
    private func licenseFile(key: String, machine: String) -> String {
        let now = clock.now()
        let iso = ISO8601DateFormatter()
        let lifetime = key.contains("LIFE")
        let bought = purchasedAt ?? now
        let payload: [String: Any] = [
            "licenseKey": key,
            "email": "you@example.com",
            "plan": lifetime ? "Murmur Lifetime" : "Murmur",
            "machineHash": machine,
            "maxActivations": 2,
            "issuedAt": iso.string(from: now),
            "maintenanceUntil": lifetime ? NSNull() : iso.string(from: Calendar.current.date(byAdding: .year, value: 1, to: bought)!),
            "recheckAfter": iso.string(from: now.addingTimeInterval(7 * 86_400)),
            "graceDays": 14,
        ]
        let json = (try? JSONSerialization.data(withJSONObject: payload)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return signer.sign(json)
    }

    // MARK: Self test

    static func runSelfTest() async -> Bool {
        var passed = true
        func check(_ ok: Bool, _ label: String) {
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): license preview: \(label)")
        }
        let preview = LicensePreview()
        func state() -> LicensePanelState { preview.store.panelState(buildReleaseDate: nil) }

        check(state() == .trial(daysLeft: 7), "starts as a first launch: a 7-day trial")
        check(await preview.store.activateFromSettings(key: "hello") == false
              && preview.store.lastMessage == LicenseStore.message(for: "not_found", fallback: nil), "a key that isn't one is refused")
        check(await preview.store.activateFromSettings(key: "MRMR-FULL1-ABCDE-FGHJK") == false
              && preview.store.lastMessage == LicenseStore.message(for: "seats_full", fallback: nil), "a key on all its Macs is refused")
        check(await preview.store.activateFromSettings(key: "mrmr-12345-abcde-fghjk"), "any key of the right shape activates")
        guard case .licensed(let year, .current) = state(), let until = year.payload.maintenanceUntil else {
            check(false, "…as a one-year plan")
            return false
        }
        check(year.payload.plan == "Murmur" && until.timeIntervalSince(preview.clock.now()) > 360 * 86_400, "…as a one-year plan")
        preview.newerVersionOut = true
        check(preview.notIncluded?.version == "2.6", "a newer version can be shown as not included")
        preview.newerVersionOut = false

        await preview.skipWeek()
        check(state() == .licensed(preview.store.license!, .current), "a week on, it has checked in again")
        preview.serverOnline = false
        await preview.skipWeek()
        await preview.skipWeek()
        if case .licensed(_, .confirmDue) = state() { check(true, "offline, it keeps working through its grace days") } else {
            check(false, "offline, it keeps working through its grace days")
        }
        await preview.skipWeek()
        await preview.skipWeek()
        check(state() == .paused(.unconfirmed), "offline for too long, it pauses")
        preview.serverOnline = true
        await preview.store.confirmNow()
        if case .licensed(_, .current) = state() { check(true, "back online, it confirms itself") } else {
            check(false, "back online, it confirms itself")
        }
        await preview.refund()
        check(state() == .paused(.withdrawn(LicenseStore.message(for: "refunded", fallback: nil))),
              "a refund withdraws it — the trial is long over, so it pauses")
        check(preview.hudNotice == "No license — dictation paused", "…and the HUD would say so")

        preview.startOver()
        check(state() == .trial(daysLeft: 7) && preview.store.problem == nil, "start over: a fresh first launch")
        _ = await preview.store.activateFromSettings(key: "MRMR-LIFE1-ABCDE-FGHJK")
        if case .licensed(let lifetime, _) = state() {
            check(lifetime.payload.plan == "Murmur Lifetime" && lifetime.payload.maintenanceUntil == nil, "a key with LIFE in it is Lifetime")
        } else {
            check(false, "a key with LIFE in it is Lifetime")
        }
        preview.newerVersionOut = true
        check(preview.notIncluded == nil, "Lifetime never has a version it doesn't include")
        await preview.store.deactivateFromSettings()
        check(preview.store.license == nil && state() == .trial(daysLeft: 7), "deactivating returns the Mac to its trial")

        check(LicenseStore.shared.channel == .source && LicenseStore.shared.dictationAllowed,
              "none of it touches this build's own license: a source build always dictates")
        return passed
    }
}

// MARK: - The switch in General, and the controls under the preview tile

/// General's second row in a build from source: turns the preview on and off.
struct LicensePreviewSwitchRow: View {
    let isOn: Bool
    let toggle: () -> Void

    var body: some View {
        SettingsFieldRow(label: "License preview",
                         detail: "See the License tab buyers get in an official build, and try it on a pretend server. "
                             + "Your own build stays free — nothing here affects dictation.",
                         isLast: true) {
            Button(isOn ? "Hide preview" : "Show preview", action: toggle)
                .buttonStyle(WarmGhostButtonStyle())
        }
    }
}

struct LicensePreviewControls: View {
    @ObservedObject var preview: LicensePreview
    /// Shows the HUD's paused notice, as a paused dictation key press would — without pausing anything.
    let showHUD: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Palette.warmRowBorder).frame(height: 1)
            VStack(alignment: .leading, spacing: 2) {
                Text("Preview controls")
                    .font(.manrope(12.5, .semibold))
                    .foregroundStyle(Palette.warmInk)
                Text("A pretend server and clock, to walk through what buyers see. Any key shaped like "
                     + "MRMR-12345-ABCDE-FGHJK activates a one-year plan; with LIFE in it, Lifetime; with FULL, a key "
                     + "already on all its Macs. Nothing here touches your own dictation.")
                    .font(.manrope(11))
                    .foregroundStyle(Palette.warmInkSoft)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Pretend today: \(preview.todayText) · server \(preview.serverOnline ? "online" : "offline")")
                    .font(.manrope(11, .medium))
                    .foregroundStyle(Palette.sunsetDeep)
            }
            .padding(.top, 12)
            HStack(spacing: 8) {
                Button("Start over") { preview.startOver() }
                Button("Skip a week") { Task { await preview.skipWeek() } }
                Button(preview.serverOnline ? "Take the server offline" : "Bring the server back") {
                    preview.serverOnline.toggle()
                }
            }
            .padding(.top, 10)
            HStack(spacing: 8) {
                Button("Refund it") { Task { await preview.refund() } }
                    .disabled(preview.store.license == nil)
                Button(preview.newerVersionOut ? "No newer version" : "A newer version is out") {
                    preview.newerVersionOut.toggle()
                }
                .disabled(preview.store.license?.payload.maintenanceUntil == nil)
                Button("Show the paused HUD") { showHUD(preview.hudNotice) }
            }
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .buttonStyle(WarmGhostButtonStyle())
    }
}
