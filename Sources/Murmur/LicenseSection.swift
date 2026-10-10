import AppKit
import SwiftUI

// MARK: - What the License tile shows

/// The License tile's state, worked out from `LicenseStore`. It always agrees with `LicenseGate.dictationAllowed` —
/// `.paused` exactly when dictation is refused — and the self-test checks that across every combination.
enum LicensePanelState: Equatable {
    /// A build from source: licensing doesn't apply, and Settings doesn't show the tile.
    case notRequired
    case trial(daysLeft: Int)
    case licensed(LicenseFile, LicenseStatus)
    case paused(PausedReason)

    enum PausedReason: Equatable {
        /// The free trial is over and there's no license.
        case trialEnded
        /// The server took the license back — refunded, revoked, this Mac deactivated — with its reason.
        case withdrawn(String)
        /// Couldn't confirm the license for longer than its grace days.
        case unconfirmed
        /// This build came out after the license's updates ended (the date they ended).
        case notCovered(Date)

        /// The full sentence: Settings, and the error line in the main window.
        var message: String {
            switch self {
            case .trialEnded: return "Your free trial has ended. Everything you set up is still here."
            case .withdrawn(let reason): return reason
            case .unconfirmed:
                return "Murmur couldn't confirm its license for over two weeks. Connect to the internet and it confirms itself."
            case .notCovered(let until):
                return "This version came out after your updates ended on \(LicenseFormat.day(until)). "
                    + "Renew, or reinstall a version from before then."
            }
        }

        /// The HUD's few words, short enough for the bottom pill.
        var hudNotice: String {
            switch self {
            case .trialEnded: return "Trial over — dictation paused"
            case .withdrawn: return "No license — dictation paused"
            case .unconfirmed: return "License unconfirmed — paused"
            case .notCovered: return "Update not included — paused"
            }
        }
    }

    static func derive(channel: BuildChannel, license: LicenseFile?, trialEndsAt: Date?, problem: String?,
                       buildReleaseDate: Date?, at now: Date) -> LicensePanelState {
        guard channel == .release else { return .notRequired }
        if let license {
            let status = license.status(at: now)
            if status == .lapsed { return .paused(.unconfirmed) }
            if let buildReleaseDate, !license.covers(releaseDate: buildReleaseDate),
               let until = license.payload.maintenanceUntil {
                return .paused(.notCovered(until))
            }
            return .licensed(license, status)
        }
        if let trialEndsAt, now < trialEndsAt {
            return .trial(daysLeft: max(1, Int((trialEndsAt.timeIntervalSince(now) / 86_400).rounded(.up))))
        }
        return .paused(problem.map(PausedReason.withdrawn) ?? .trialEnded)
    }

    /// The tile's one-line summary, under its title.
    var summary: String {
        switch self {
        case .notRequired: return "Built from source — no license needed"
        case .trial(let days): return "Free trial · \(LicenseFormat.days(days)) left"
        case .licensed(let file, _):
            guard let until = file.payload.maintenanceUntil else { return "\(file.payload.plan) · every update" }
            return "\(file.payload.plan) · updates until \(LicenseFormat.day(until))"
        case .paused: return "Dictation paused"
        }
    }
}

enum LicenseFormat {
    static func day(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .omitted) }
    static func days(_ count: Int) -> String { count == 1 ? "1 day" : "\(count) days" }

    /// "MRMR-7KQ2P-X4M9D-B3HTV" → "MRMR-7KQ2P-•••••-B3HTV": enough to recognise, not enough to use.
    static func maskedKey(_ key: String) -> String {
        var groups = key.split(separator: "-").map(String.init)
        guard groups.count >= 4 else { return key }
        groups[2] = String(repeating: "•", count: groups[2].count)
        return groups.joined(separator: "-")
    }
}

enum LicenseLinks {
    static var site: String {
        (Bundle.main.object(forInfoDictionaryKey: "MurmurLicenseServer") as? String) ?? "https://www.murmurmac.com"
    }
    static var buy: URL { URL(string: site + "/#pricing")! }
    static var manage: URL { URL(string: site + "/manage")! }

    /// The key in the receipt email's link, `murmurmac://activate?key=MRMR-…`. The scheme is `murmurmac`, not
    /// `murmur`: several other Mac dictation apps are called Murmur, and a link has to open this one.
    static func activationKey(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "murmurmac", url.host?.lowercased() == "activate",
              let key = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "key" })?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty
        else { return nil }
        return key
    }
}

// MARK: - The tile's rows

/// The body of Settings' License tab — only ever shown in an official release build. Built from the page's own
/// pieces (SettingsComponents.swift): the same rows, the same "Granted"-style status, the same filled pill for the
/// one thing that matters and the same soft buttons for the rest. Whether a newer version exists lives in General,
/// next to the version number; this tab says what the license covers.
struct LicenseSection: View {
    @ObservedObject var store: LicenseStore
    /// A newer version the license doesn't include (`SparkleUpdater.notIncluded`).
    var notIncluded: SparkleUpdater.NotIncluded?
    var buildReleaseDate: Date? = BuildChannel.releaseDate

    @State private var key = ""
    @State private var confirmingDeactivate = false

    var body: some View {
        VStack(spacing: 0) {
            switch store.panelState(buildReleaseDate: buildReleaseDate) {
            case .notRequired: EmptyView()
            case .trial(let days): trial(days)
            case .licensed(let file, let status): licensed(file, status)
            case .paused(let reason): paused(reason)
            }
        }
        .alert("Deactivate this Mac?", isPresented: $confirmingDeactivate) {
            Button("Deactivate", role: .destructive) { Task { await store.deactivateFromSettings() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Murmur stops dictating on this Mac until you activate it again, and its seat is free for another Mac.")
        }
    }

    @ViewBuilder private func trial(_ days: Int) -> some View {
        SettingsFieldRow(label: "Free trial",
                         detail: "\(LicenseFormat.days(days)) left, every feature on. No card, no account.",
                         warning: store.problem) {
            attention("Buy Murmur", LicenseLinks.buy)
        }
        keyRow
    }

    @ViewBuilder private func licensed(_ file: LicenseFile, _ status: LicenseStatus) -> some View {
        let payload = file.payload
        SettingsFieldRow(label: payload.plan,
                         detail: "\(payload.email) · \(LicenseFormat.maskedKey(payload.licenseKey))",
                         warning: confirmNote(status)) {
            SettingsStatusLabel(title: "Active on this Mac")
        }
        SettingsFieldRow(label: "Updates included", detail: updatesDetail(payload)) {
            // Lifetime includes every version, so there's never anything to renew.
            if notIncluded != nil, payload.maintenanceUntil != nil { attention("Renew or upgrade", LicenseLinks.manage) }
        }
        SettingsFieldRow(label: "Macs",
                         detail: "Use this key on \(payload.maxActivations) Macs at the same time — enter it on each.",
                         warning: store.lastMessage, isLast: true) {
            Button(store.busy ? "Deactivating…" : "Deactivate this Mac") { confirmingDeactivate = true }
                .buttonStyle(WarmGhostButtonStyle())
                .disabled(store.busy)
        }
    }

    @ViewBuilder private func paused(_ reason: LicensePanelState.PausedReason) -> some View {
        // With a license on this Mac (unconfirmed, or a version it doesn't include) there's no key to type in.
        let hasLicense = store.license != nil
        SettingsFieldRow(label: "Dictation is paused", detail: reason.message, isLast: hasLicense) {
            switch reason {
            case .trialEnded, .withdrawn:
                attention("Buy Murmur", LicenseLinks.buy)
            case .unconfirmed:
                Button(store.busy ? "Checking…" : "Check now") { Task { await store.confirmNow() } }
                    .buttonStyle(WarmGhostButtonStyle())
                    .disabled(store.busy)
            case .notCovered:
                attention("Renew or upgrade", LicenseLinks.manage)
            }
        }
        if !hasLicense { keyRow }
    }

    private var keyRow: some View {
        SettingsFieldRow(label: "Already have a key?", detail: "Paste it from your receipt email.",
                         warning: store.lastMessage, isLast: true) {
            HStack(spacing: 8) {
                SettingsTextField(placeholder: "MRMR-XXXXX-XXXXX-XXXXX", text: $key, onSubmit: activate)
                Button(store.busy ? "Activating…" : "Activate", action: activate)
                    .buttonStyle(WarmGhostButtonStyle())
                    .disabled(store.busy || key.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    /// The page's filled pill, opening a page on murmurmac.com.
    private func attention(_ title: String, _ url: URL) -> some View {
        Button { NSWorkspace.shared.open(url) } label: { SettingsAttentionPill(title: title) }
            .buttonStyle(.plain)
    }

    private func activate() {
        let typed = key
        Task {
            if await store.activateFromSettings(key: typed) { key = "" }
        }
    }

    private func confirmNote(_ status: LicenseStatus) -> String? {
        guard case .confirmDue(let days) = status else { return nil }
        return "Couldn't reach the licensing server lately — it keeps working for \(days) more \(days == 1 ? "day" : "days"), "
            + "and confirms itself when you're online."
    }

    private func updatesDetail(_ payload: LicenseFile.Payload) -> String {
        guard let until = payload.maintenanceUntil else { return "Every update, forever." }
        var text = "Versions released before \(LicenseFormat.day(until)) are yours to keep."
        if let notIncluded { text += " Murmur \(notIncluded.version) came out after that." }
        return text
    }
}

// MARK: - Self test

extension LicensePanelState {
    @MainActor
    static func runSelfTest() -> Bool {
        var passed = true
        func check(_ ok: Bool, _ label: String) {
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): license tile: \(label)")
        }
        let now = LicenseVerifier.date(from: "2026-10-05T09:00:00Z")!
        func day(_ n: Double) -> Date { now.addingTimeInterval(n * 86_400) }
        func file(recheck: Double, maintenance: Date?) -> LicenseFile {
            LicenseFile(payload: .init(licenseKey: "MRMR-7KQ2P-X4M9D-B3HTV", email: "buyer@example.com", plan: "Murmur",
                                       machineHash: "x", maxActivations: 2, issuedAt: day(-1), maintenanceUntil: maintenance,
                                       recheckAfter: day(recheck), graceDays: 14))
        }
        func state(_ channel: BuildChannel = .release, license: LicenseFile? = nil, trial: Date? = nil,
                   problem: String? = nil, build: Date? = nil) -> LicensePanelState {
            derive(channel: channel, license: license, trialEndsAt: trial, problem: problem, buildReleaseDate: build, at: now)
        }

        // Every combination agrees with the gate that actually decides.
        let licenses: [LicenseFile?] = [nil, file(recheck: 5, maintenance: day(300)), file(recheck: -3, maintenance: day(300)),
                                        file(recheck: -20, maintenance: day(300)), file(recheck: 5, maintenance: nil)]
        var agreements = 0, cases = 0
        for channel in [BuildChannel.source, .release] {
            for license in licenses {
                for trial in [nil, day(3), day(-1)] {
                    for build in [nil, day(-30), day(400)] {
                        for problem in [nil, "This license was refunded, so it no longer works."] {
                            cases += 1
                            let paused: Bool
                            if case .paused = state(channel, license: license, trial: trial, problem: problem, build: build) {
                                paused = true
                            } else {
                                paused = false
                            }
                            let allowed = LicenseGate.dictationAllowed(channel: channel, license: license, trialEndsAt: trial,
                                                                       buildReleaseDate: build, at: now)
                            if paused != allowed { agreements += 1 }
                        }
                    }
                }
            }
        }
        check(agreements == cases, "the tile shows \"paused\" exactly when dictation is refused (\(agreements)/\(cases) combinations)")

        check(state(.source) == .notRequired, "a source build needs no license")
        check(state(trial: day(4.2)) == .trial(daysLeft: 5), "a running trial counts whole days left")
        check(state(trial: day(0.1)).summary == "Free trial · 1 day left", "…singular on the last day")
        check(state(trial: day(-1)) == .paused(.trialEnded), "an ended trial with no license pauses")
        check(state(trial: day(-1), problem: "Refunded.") == .paused(.withdrawn("Refunded.")), "a withdrawn license pauses with its reason")
        check(state(trial: day(3), problem: "Refunded.") == .trial(daysLeft: 3), "…though trial days still left still count")
        check(state(license: file(recheck: -20, maintenance: nil)) == .paused(.unconfirmed), "a lapsed license pauses as unconfirmed")
        check(state(license: file(recheck: -3, maintenance: nil)) == .licensed(file(recheck: -3, maintenance: nil), .confirmDue(daysLeft: 11)),
              "an unconfirmed one inside its grace days still works, counting down")
        check(state(license: file(recheck: 5, maintenance: day(300)), build: day(400)) == .paused(.notCovered(day(300))),
              "a build from after the updates ended pauses")
        check(state(license: file(recheck: 5, maintenance: nil), build: day(400)).summary == "Murmur · every update", "Lifetime runs any build")

        // Words.
        check(LicenseFormat.maskedKey("MRMR-7KQ2P-X4M9D-B3HTV") == "MRMR-7KQ2P-•••••-B3HTV", "the key is shown masked")
        check(PausedReason.allHudNotices.allSatisfy { $0.count <= 31 }, "every HUD notice fits the bottom pill")

        // The receipt email's link.
        func key(_ link: String) -> String? { URL(string: link).flatMap(LicenseLinks.activationKey(from:)) }
        check(key("murmurmac://activate?key=MRMR-7KQ2P-X4M9D-B3HTV") == "MRMR-7KQ2P-X4M9D-B3HTV", "reads the key from the email's link")
        check(key("MURMURMAC://Activate?key=%20MRMR-7KQ2P%20") == "MRMR-7KQ2P", "…whatever its case and spacing")
        check(key("murmur://activate?key=MRMR-7KQ2P") == nil, "ignores another app's murmur:// scheme")
        check(key("murmurmac://deactivate?key=MRMR-7KQ2P") == nil, "ignores anything but activate")
        check(key("murmurmac://activate") == nil && key("murmurmac://activate?key=") == nil, "ignores a link without a key")
        return passed
    }
}

extension LicensePanelState.PausedReason {
    static var allHudNotices: [String] {
        [Self.trialEnded, .withdrawn("x"), .unconfirmed, .notCovered(Date())].map(\.hudNotice)
    }
}

// MARK: - Seeing it without opening anything (`Murmur --license-ui-check <directory>`)

/// Draws the License tile in every state, whole Settings pages around it, General's row in its states and the bottom
/// HUD pill's paused notice — through a fully transparent, click-through panel that never activates (as `--hud-check`
/// does), so nothing appears on screen and nothing takes focus. Light appearance, as the app pins itself to. Every
/// license is a fixture signed with a throwaway key; the real Keychain and server are never touched.
@MainActor
enum LicenseUICheck {
    static func run(outputDirectory: String) async -> Bool {
        try? FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)
        // The app pins itself to light (`AppDelegate.setAppearance`); a bare command-line process follows the system.
        NSApp.appearance = NSAppearance(named: .aqua)
        var passed = true
        func report(_ ok: Bool, _ label: String) {
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): license ui: \(label)")
        }
        func save<V: View>(_ name: String, width: CGFloat = 700, height: CGFloat? = nil, _ view: V) {
            let path = (outputDirectory as NSString).appendingPathComponent("\(name).png")
            report(OffscreenRender.png(view.padding(20), width: width, height: height, backdrop: NSColor(Palette.shell), to: path),
                   "rendered \(name)")
        }

        let signer = Curve25519Fixture()
        let machine = MachineIdentity.hash(platformUUID: "11111111-2222-3333-4444-555555555555")!
        let now = LicenseVerifier.date(from: "2026-10-05T09:00:00Z")!
        let iso = ISO8601DateFormatter()
        func ago(_ days: Double) -> String { iso.string(from: now.addingTimeInterval(-days * 86_400)) }
        func later(_ days: Double) -> String { iso.string(from: now.addingTimeInterval(days * 86_400)) }
        func file(plan: String = "Murmur", maintenance: String? = "2027-10-01T09:00:00Z", recheck: String) -> String {
            signer.sign("""
                {"licenseKey":"MRMR-7KQ2P-X4M9D-B3HTV","email":"janis@example.com","plan":"\(plan)",\
                "machineHash":"\(machine)","maxActivations":2,"issuedAt":"\(ago(2))",\
                "maintenanceUntil":\(maintenance.map { "\"\($0)\"" } ?? "null"),"recheckAfter":"\(recheck)","graceDays":14}
                """)
        }
        func store(_ items: [String: String], replies: [String: (Int, String)] = [:]) -> LicenseStore {
            let storage = MemoryLicenseStorage()
            storage.items = items
            let server = LicenseServer(baseURL: URL(string: "https://license.test")!, transport: { request in
                guard let (status, body) = replies[request.url!.path] else { throw URLError(.notConnectedToInternet) }
                return (Data(body.utf8), status)
            })
            let store = LicenseStore(channel: .release, storage: storage, server: server, publicKey: signer.publicKey,
                                     machineHash: machine, now: { now })
            store.load()
            return store
        }

        let inTrial = ["trial-started": ago(2)]
        let trialOver = ["trial-started": ago(10)]
        let mistyped = store(inTrial, replies: ["/api/license/activate": (404, "{\"error\":\"not_found\"}")])
        _ = await mistyped.activateFromSettings(key: "MRMR-TYPO1-TYPO2-TYPO3")
        let refunded = store(trialOver.merging(["license-file": file(recheck: ago(1))]) { $1 },
                             replies: ["/api/license/check": (403, "{\"error\":\"refunded\"}")])
        await refunded.confirmNow()

        let released = LicenseVerifier.date(from: "2026-09-20T09:00:00Z")!
        let afterUpdatesEnded = LicenseVerifier.date(from: "2027-11-01T09:00:00Z")!
        let licensed = store(inTrial.merging(["license-file": file(recheck: later(5))]) { $1 })
        let trialOverStore = store(trialOver)
        let states: [(String, LicenseStore, SparkleUpdater.NotIncluded?, Date?)] = [
            ("1-trial", store(inTrial), nil, released),
            ("2-trial-mistyped-key", mistyped, nil, released),
            ("3-licensed", licensed, nil, released),
            ("4-licensed-offline-grace", store(inTrial.merging(["license-file": file(recheck: ago(3))]) { $1 }), nil, released),
            ("5-licensed-newer-not-included", licensed,
             SparkleUpdater.NotIncluded(version: "2.6", releaseDate: afterUpdatesEnded), released),
            ("6-lifetime", store(inTrial.merging(["license-file": file(plan: "Murmur Lifetime", maintenance: nil, recheck: later(5))]) { $1 }),
             nil, released),
            ("7-paused-trial-over", trialOverStore, nil, released),
            ("8-paused-refunded", refunded, nil, released),
            ("9-paused-version-not-included", store(trialOver.merging(["license-file": file(recheck: later(5))]) { $1 }),
             nil, afterUpdatesEnded),
            ("10-paused-unconfirmed", store(trialOver.merging(["license-file": file(recheck: ago(20))]) { $1 }), nil, released),
        ]
        func licenseTile(_ store: LicenseStore, _ notIncluded: SparkleUpdater.NotIncluded?, _ build: Date?) -> some View {
            SettingsCard {
                LicenseSection(store: store, notIncluded: notIncluded, buildReleaseDate: build)
            }
        }
        for (name, store, notIncluded, build) in states {
            save("license-\(name)", licenseTile(store, notIncluded, build))
        }

        // Whole pages: the License tab as it sits on the real page, under the header and the tab row.
        func page<Open: View>(paused: Bool, _ open: Open) -> some View {
            VStack(alignment: .leading, spacing: 0) {
                SettingsPageHeader(subtitle: SettingsPage.subtitle)
                UnderlineTabBar(tabs: SettingsTab.allCases, selected: .license,
                                attention: paused ? [.license] : [], title: \.title, select: { _ in })
                    .padding(.top, 20)
                open.padding(.top, 24)
            }
        }
        save("page-release-licensed", width: 760, page(paused: false, licenseTile(licensed, nil, released)))
        save("page-release-paused", width: 760, page(paused: true, licenseTile(trialOverStore, nil, released)))

        // General's top row, in each state it can be in.
        func general(_ version: String, source: Bool, _ status: SoftwareStatusRow.Status) -> some View {
            SettingsCard {
                SoftwareStatusRow(version: version, isSourceBuild: source, status: status, install: source ? nil : {})
            }
        }
        save("general-source-build", general("2.1.0", source: true, .upToDate))

        // A build from source with the preview on: the License tab is the buyer's own card, nothing added.
        let preview = LicensePreview()
        func previewTile() -> some View {
            SettingsCard {
                LicenseSection(store: preview.store, notIncluded: preview.notIncluded, buildReleaseDate: nil)
            }
        }
        save("preview-tile-trial", previewTile())
        _ = await preview.store.activateFromSettings(key: "MRMR-12345-ABCDE-FGHJK")
        save("preview-tile-licensed", previewTile())
        save("general-release-update-available", general("2.2.0", source: false, .updateAvailable))
        save("general-release-newer-not-included", general("2.2.0", source: false, .newerNotIncluded))
        save("general-release-up-to-date", general("2.2.0", source: false, .upToDate))
        save("general-release-not-checked-yet", general("2.2.0", source: false, .unknown))

        // The bottom pill's paused notice (the notch's is in `--hud-check`).
        let hud = HUDModel()
        hud.state = .notice("Trial over — dictation paused")
        hud.targetAppIcon = NSWorkspace.shared.icon(forFile: "/System/Applications/Notes.app")
        hud.expanded = true
        save("hud-bottom-notice", width: 360, height: 98, StatusHUDView(model: hud).frame(width: 320, height: 58))
        return passed
    }
}

/// Draws a SwiftUI view to a PNG through a fully transparent, click-through, never-activating panel — AppKit controls
/// (text fields) only draw inside a window, and this one can't be seen, clicked or focused.
@MainActor
enum OffscreenRender {
    static func png<V: View>(_ view: V, width: CGFloat, height: CGFloat? = nil, backdrop: NSColor, to path: String) -> Bool {
        let hosting = NSHostingView(rootView: view.frame(width: width).background(Color(nsColor: backdrop)))
        let fitting = hosting.fittingSize
        let size = NSSize(width: width, height: height ?? max(1, fitting.height))
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.appearance = NSApp.appearance
        panel.isReleasedWhenClosed = false
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.orderFrontRegardless()
        let end = Date().addingTimeInterval(0.35)
        while Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        hosting.layoutSubtreeIfNeeded()
        defer { panel.orderOut(nil) }
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return false }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }
}
