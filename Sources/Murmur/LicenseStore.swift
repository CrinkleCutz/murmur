import CryptoKit
import Foundation
import OSLog
import Security
import SystemConfiguration

private let licenseLog = Logger(subsystem: "local.murmur", category: "license")

// MARK: - Storage

/// Where the license file and the trial's start date live. In the app that's the Keychain: it survives deleting and
/// reinstalling Murmur (so doing that doesn't restart the trial), and it isn't a loose file to copy between Macs —
/// though a copied license file wouldn't verify on another Mac anyway (`LicenseFile.Payload.machineHash`).
protocol LicenseStorage: AnyObject {
    func read(_ name: String) -> String?
    func write(_ name: String, _ value: String?)
}

final class KeychainLicenseStorage: LicenseStorage {
    private let service = "local.murmur.licensing"

    private func query(_ name: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: name]
    }

    func read(_ name: String) -> String? {
        var query = query(name)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status != errSecSuccess, status != errSecItemNotFound {
            licenseLog.error("keychain read failed: \(status, privacy: .public)")
        }
        return (result as? Data).flatMap { String(data: $0, encoding: .utf8) }
    }

    func write(_ name: String, _ value: String?) {
        SecItemDelete(query(name) as CFDictionary)
        guard let value else { return }
        var item = query(name)
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess { licenseLog.error("keychain write failed: \(status, privacy: .public)") }
    }
}

/// For the self-test — never touches the real Keychain.
final class MemoryLicenseStorage: LicenseStorage {
    var items: [String: String] = [:]
    func read(_ name: String) -> String? { items[name] }
    func write(_ name: String, _ value: String?) { items[name] = value }
}

// MARK: - The licensing server

/// Murmur's licensing server on murmurmac.com. Three JSON POSTs — activate, check, deactivate — spelled out in
/// docs/licensing-api.md, which is the contract the website implements.
struct LicenseServer {
    /// Sends a request and hands back the body and HTTP status. Swapped out in the self-test.
    typealias Transport = (URLRequest) async throws -> (Data, Int)

    enum Reply: Equatable {
        /// A fresh license file.
        case license(String)
        /// Done, nothing to hand back (deactivate).
        case done
        /// The server said no, with a reason code from the contract.
        case refused(code: String, message: String?)
        /// Offline, timed out, or a server-side failure. Never the buyer's fault, so never held against them.
        case unreachable
    }

    var baseURL: URL
    var transport: Transport

    static let live = LicenseServer(
        baseURL: URL(string: (Bundle.main.object(forInfoDictionaryKey: "MurmurLicenseServer") as? String)
                     ?? "https://www.murmurmac.com")!,
        transport: { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        })

    func post(_ path: String, _ body: [String: String]) async -> Reply {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, status) = try? await transport(request) else { return .unreachable }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if (200..<300).contains(status) {
            return (object?["license"] as? String).map(Reply.license) ?? .done
        }
        // A 4xx with a reason is an answer; anything else (a 5xx, an HTML error page) is the server having a bad day,
        // which counts the same as being offline.
        if (400..<500).contains(status), let code = object?["error"] as? String {
            return .refused(code: code, message: object?["message"] as? String)
        }
        return .unreachable
    }
}

// MARK: - The license on this Mac

/// This Mac's license: the free trial, the license file, and keeping it confirmed.
///
/// Only an official release build does anything here — in a source build `start()` returns straight away, so it
/// never reads or writes the Keychain or talks to the server, and `dictationAllowed` is always true.
///
/// The rhythm, the same as Flit's: activating a key fetches a license file for this Mac. The file says when to check in
/// again (a week) and how long to keep working if the server can't be reached (two weeks more). At each check-in the
/// server either hands back a fresh file or says why not — refunded, revoked, this Mac deactivated — and the app stops
/// at once with that reason. Offline, it keeps working through the grace days and confirms itself next time it's
/// online. Nothing is sent but the key, this Mac's hashed identity, its name (so the buyer can tell their Macs apart on
/// the manage page) and the app version.
@MainActor
final class LicenseStore: ObservableObject {
    static let shared = LicenseStore()

    static let trialDays = 7

    @Published private(set) var license: LicenseFile?
    @Published private(set) var trialEndsAt: Date?
    /// Why the license was withdrawn or couldn't be read — shown in Settings.
    @Published private(set) var problem: String?
    /// What the last activate / deactivate from Settings ran into; nil when it went through.
    @Published private(set) var lastMessage: String?
    /// Talking to the server on Settings' behalf.
    @Published private(set) var busy = false

    let channel: BuildChannel
    private let storage: LicenseStorage
    private let server: LicenseServer
    private let publicKey: String
    private let machineHash: String?
    private let now: () -> Date
    private var timer: Timer?

    private enum Item {
        static let license = "license-file"
        static let trialStarted = "trial-started"
    }

    init(channel: BuildChannel = .current, storage: LicenseStorage = KeychainLicenseStorage(),
         server: LicenseServer = .live, publicKey: String = LicenseVerifier.productionPublicKey,
         machineHash: String? = MachineIdentity.hash(), now: @escaping () -> Date = Date.init) {
        self.channel = channel
        self.storage = storage
        self.server = server
        self.publicKey = publicKey
        self.machineHash = machineHash
        self.now = now
    }

    var dictationAllowed: Bool {
        LicenseGate.dictationAllowed(channel: channel, license: license, trialEndsAt: trialEndsAt, at: now())
    }

    /// What Settings' License tile shows. Always agrees with `dictationAllowed` (the self-test checks it).
    func panelState(buildReleaseDate: Date? = BuildChannel.releaseDate) -> LicensePanelState {
        LicensePanelState.derive(channel: channel, license: license, trialEndsAt: trialEndsAt, problem: problem,
                                 buildReleaseDate: buildReleaseDate, at: now())
    }

    /// For each place that stops because of the license — dictation, Notetaker, Transforms, Ask Murmur — what
    /// happened and where to go. nil whenever nothing is paused.
    var pausedExplanation: String? {
        guard case .paused(let reason) = panelState() else { return nil }
        return "Dictation is paused: \(reason.message) Open Settings → License."
    }

    /// The HUD's few words for it.
    var pausedNotice: String? {
        guard case .paused(let reason) = panelState() else { return nil }
        return reason.hudNotice
    }

    // MARK: Settings' actions

    /// true when the key is now active on this Mac.
    @discardableResult
    func activateFromSettings(key: String) async -> Bool {
        busy = true
        defer { busy = false }
        lastMessage = await activate(key: key)
        return lastMessage == nil
    }

    func deactivateFromSettings() async {
        busy = true
        defer { busy = false }
        lastMessage = await deactivate()
    }

    func confirmNow() async {
        busy = true
        defer { busy = false }
        await checkInIfDue(force: true)
    }

    /// Whether an update released on `releaseDate` may be installed. An undated update can't be placed inside a
    /// license's updates window, so only Lifetime or a running trial takes one.
    func updateAllowed(releaseDate: Date?) -> Bool {
        LicenseGate.updateAllowed(channel: channel, license: license, trialEndsAt: trialEndsAt,
                                  releaseDate: releaseDate ?? .distantFuture, at: now())
    }

    /// Release builds only. Reads what's stored, starts the trial on the very first launch, checks in if it's due, and
    /// looks again every few hours.
    func start() {
        guard channel == .release, timer == nil else { return }
        load()
        if storage.read(Item.trialStarted) == nil {
            let started = now()
            storage.write(Item.trialStarted, ISO8601DateFormatter().string(from: started))
            trialEndsAt = started.addingTimeInterval(TimeInterval(Self.trialDays) * 86_400)
        }
        Task { await checkInIfDue() }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                // Time alone moves the trial's countdown and the grace days — let Settings redraw.
                self?.objectWillChange.send()
                await self?.checkInIfDue()
            }
        }
    }

    func load() {
        trialEndsAt = storage.read(Item.trialStarted).flatMap(LicenseVerifier.date(from:))
            .map { $0.addingTimeInterval(TimeInterval(Self.trialDays) * 86_400) }
        guard let raw = storage.read(Item.license) else { license = nil; return }
        switch LicenseVerifier.verify(raw, publicKeyBase64: publicKey, machineHash: machineHash) {
        case .success(let file):
            license = file
            problem = nil
        case .failure(let refusal):
            // Kept in storage — a key rotation or a restore from another Mac is fixed by activating again, which
            // overwrites it.
            license = nil
            problem = refusal.message
        }
    }

    // MARK: Activate, check in, deactivate

    /// nil when the key is activated on this Mac; otherwise what to tell the buyer.
    func activate(key rawKey: String) async -> String? {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !key.isEmpty else { return "Enter your license key." }
        guard let machineHash else { return "This Mac couldn't be identified, so it can't be activated." }
        let reply = await server.post("api/license/activate", [
            "licenseKey": key, "machineHash": machineHash, "machineName": Self.machineName, "appVersion": Self.appVersion])
        switch reply {
        case .license(let raw): return accept(raw)
        case .refused(let code, let message): return Self.message(for: code, fallback: message)
        case .done, .unreachable: return Self.unreachableMessage
        }
    }

    /// Confirms the license with the server when it's due (or now, if `force`). A refusal withdraws it on the spot with
    /// the server's reason; no answer at all changes nothing — the grace days are for exactly that.
    func checkInIfDue(force: Bool = false) async {
        guard channel == .release, let license, let machineHash else { return }
        guard force || now() >= license.payload.recheckAfter else { return }
        let reply = await server.post("api/license/check", [
            "licenseKey": license.payload.licenseKey, "machineHash": machineHash, "appVersion": Self.appVersion])
        switch reply {
        case .license(let raw):
            // A reply that doesn't verify never costs a buyer the license they already have.
            if let refusal = accept(raw) { licenseLog.error("check-in reply refused: \(refusal, privacy: .public)") }
        case .refused(let code, let message) where Self.withdrawingCodes.contains(code):
            licenseLog.notice("license withdrawn by the server: \(code, privacy: .public)")
            removeLicense()
            problem = Self.message(for: code, fallback: message)
        case .refused(let code, _):
            licenseLog.notice("check-in refused without withdrawing: \(code, privacy: .public)")
        case .done, .unreachable:
            licenseLog.notice("check-in got no answer; keeping the license through its grace days")
        }
    }

    /// Frees this Mac's seat. nil on success — the Mac then goes back to the trial (usually long over).
    func deactivate() async -> String? {
        guard let license, let machineHash else { return nil }
        let reply = await server.post("api/license/deactivate", [
            "licenseKey": license.payload.licenseKey, "machineHash": machineHash])
        switch reply {
        case .done, .license, .refused("not_activated", _), .refused("not_found", _):
            removeLicense()
            problem = nil
            return nil
        case .refused(let code, let message):
            return Self.message(for: code, fallback: message)
        case .unreachable:
            return "Couldn't reach the licensing server, so this Mac is still activated. Try again when you're online, "
                + "or free it later at murmurmac.com/manage with just your key."
        }
    }

    private func accept(_ raw: String) -> String? {
        switch LicenseVerifier.verify(raw, publicKeyBase64: publicKey, machineHash: machineHash) {
        case .success(let file):
            storage.write(Item.license, raw)
            license = file
            problem = nil
            return nil
        case .failure(let refusal):
            return refusal.message
        }
    }

    private func removeLicense() {
        storage.write(Item.license, nil)
        license = nil
    }

    // MARK: Words

    /// Server answers that mean the license no longer belongs on this Mac.
    static let withdrawingCodes: Set<String> = ["refunded", "revoked", "not_found", "expired", "not_activated"]

    static let unreachableMessage = "Couldn't reach the licensing server. Check your connection and try again."

    static func message(for code: String, fallback: String?) -> String {
        switch code {
        case "not_found": return "That license key wasn't found. Check it for typos."
        case "refunded": return "This license was refunded, so it no longer works."
        case "revoked": return "This license has been revoked. If you think that's wrong, reply to your receipt and a person will look."
        case "expired": return "This license has expired."
        case "seats_full":
            return "This key is already active on all the Macs it covers. Deactivate one first — in Murmur's Settings on "
                + "that Mac, or at murmurmac.com/manage with just your key."
        case "not_activated": return "This Mac was deactivated for this key. Activate it again to keep using Murmur."
        default: return fallback ?? "The licensing server couldn't accept this key right now. Try again in a moment."
        }
    }

    static var machineName: String { (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac" }
    static var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    // MARK: - Self test

    /// The whole lifecycle against an in-memory Keychain and a scripted server — nothing real is touched.
    static func runSelfTest() async -> Bool {
        var passed = true
        func check(_ ok: Bool, _ label: String) {
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): license store: \(label)")
        }

        let key = Curve25519Fixture()
        let machine = MachineIdentity.hash(platformUUID: "11111111-2222-3333-4444-555555555555")!
        var clock = LicenseVerifier.date(from: "2026-10-01T09:00:00Z")!
        var replies: [String: (Int, String)] = [:]
        var sent: [String] = []
        let server = LicenseServer(baseURL: URL(string: "https://license.test")!, transport: { request in
            let path = request.url!.path
            sent.append(path)
            guard let (status, body) = replies[path] else { throw URLError(.notConnectedToInternet) }
            return (Data(body.utf8), status)
        })
        func file(recheckAfter: String) -> String {
            let raw = key.sign("""
                {"licenseKey":"MRMR-AAAAA-BBBBB-CCCCC","email":"fixture@example.com","plan":"Murmur",\
                "machineHash":"\(machine)","maxActivations":2,"issuedAt":"2026-10-01T09:00:00.000Z",\
                "maintenanceUntil":"2027-10-01T09:00:00.000Z","recheckAfter":"\(recheckAfter)","graceDays":14}
                """)
            return "{\"license\":\"\(raw)\"}"
        }
        let storage = MemoryLicenseStorage()
        func store(_ channel: BuildChannel = .release) -> LicenseStore {
            LicenseStore(channel: channel, storage: storage, server: server, publicKey: key.publicKey,
                         machineHash: machine, now: { clock })
        }

        // A source build does nothing at all.
        let source = store(.source)
        source.start()
        check(storage.items.isEmpty && source.dictationAllowed, "a source build never touches the Keychain and always dictates")

        // First launch of a release build: the trial.
        var app = store()
        app.start()
        check(app.trialEndsAt == clock.addingTimeInterval(7 * 86_400) && app.dictationAllowed, "the first launch starts a 7-day trial")
        clock = clock.addingTimeInterval(8 * 86_400)
        check(!app.dictationAllowed, "dictation pauses once the trial is over")
        app = store()
        app.load()
        check(app.trialEndsAt != nil && !app.dictationAllowed, "reinstalling doesn't restart the trial")

        // Activating.
        replies["/api/license/activate"] = (404, "{\"error\":\"not_found\"}")
        check(await app.activate(key: "MRMR-TYPO") == message(for: "not_found", fallback: nil), "a mistyped key says so")
        replies["/api/license/activate"] = (409, "{\"error\":\"seats_full\"}")
        check(await app.activate(key: "MRMR-AAAAA") == message(for: "seats_full", fallback: nil), "a key already on all its Macs says so")
        replies["/api/license/activate"] = (200, file(recheckAfter: "2026-10-16T09:00:00Z"))
        check(await app.activate(key: " mrmr-aaaaa-bbbbb-ccccc ") == nil && app.dictationAllowed, "a real key activates this Mac")
        check(storage.items["license-file"] != nil, "the license file is kept")
        app = store()
        app.load()
        check(app.license?.payload.licenseKey == "MRMR-AAAAA-BBBBB-CCCCC", "…and read back on the next launch")

        // Checking in.
        sent.removeAll()
        await app.checkInIfDue()
        check(sent.isEmpty, "no check-in before it's due")
        clock = LicenseVerifier.date(from: "2026-10-17T09:00:00Z")!
        await app.checkInIfDue()
        check(app.license != nil && app.dictationAllowed, "offline when due: keeps working through the grace days")
        replies["/api/license/check"] = (503, "<html>bad gateway</html>")
        await app.checkInIfDue()
        check(app.license != nil, "a server error is treated like being offline, not like a refusal")
        replies["/api/license/check"] = (200, file(recheckAfter: "2026-10-24T09:00:00Z"))
        await app.checkInIfDue()
        check(app.license?.status(at: clock) == .current, "a successful check-in moves the next one a week on")
        replies["/api/license/check"] = (200, "{\"license\":\"forged.file\"}")
        clock = LicenseVerifier.date(from: "2026-10-25T09:00:00Z")!
        await app.checkInIfDue()
        check(app.license != nil, "a reply that doesn't verify never costs the buyer their license")
        replies["/api/license/check"] = (403, "{\"error\":\"refunded\"}")
        await app.checkInIfDue()
        check(app.license == nil && !app.dictationAllowed && app.problem == message(for: "refunded", fallback: nil),
              "a refund stops it at the next check-in, with the reason")
        check(storage.items["license-file"] == nil, "…and the file is gone")

        // Deactivating.
        replies["/api/license/activate"] = (200, file(recheckAfter: "2026-11-01T09:00:00Z"))
        _ = await app.activate(key: "MRMR-AAAAA-BBBBB-CCCCC")
        replies["/api/license/deactivate"] = nil
        check(await app.deactivate() != nil && app.license != nil, "deactivating offline keeps the Mac activated, and says why")
        replies["/api/license/deactivate"] = (200, "{}")
        check(await app.deactivate() == nil && app.license == nil, "deactivating frees this Mac and returns it to the (ended) trial")
        return passed
    }
}

/// A throwaway signing key for the self-tests, standing in for the server's.
struct Curve25519Fixture {
    private let key = Curve25519.Signing.PrivateKey()
    var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }

    /// A license file in the server's envelope: `base64(payload).base64(signature)`.
    func sign(_ json: String) -> String {
        let data = Data(json.utf8)
        return data.base64EncodedString() + "." + (try! key.signature(for: data)).base64EncodedString()
    }
}

// MARK: - Live check (command line)

/// `Murmur --license-live-check <server URL> <key>`: runs this build's real activate → panel → check-in → deactivate
/// against a real licensing server, with the real Mac identity and the real public key, but an in-memory store — so
/// nothing touches the Keychain, a window or the live app. It is how the website's signed files are proven to verify
/// in the app before launch, and it frees the seat again at the end.
enum LicenseLiveCheck {
    @MainActor
    static func run(server baseURL: URL, key: String) async -> Bool {
        let store = LicenseStore(channel: .release, storage: MemoryLicenseStorage(),
                                 server: LicenseServer(baseURL: baseURL, transport: LicenseServer.live.transport))
        var ok = true
        func step(_ name: String, _ passed: Bool, _ detail: String = "") {
            print("\(passed ? "ok  " : "FAIL") \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            if !passed { ok = false }
        }
        print("server \(baseURL.absoluteString)  public key \(LicenseVerifier.productionPublicKey.prefix(8))…")
        store.start()
        step("fresh Mac starts on a trial", { if case .trial = store.panelState() { return true } else { return false } }(),
             String(describing: store.panelState()))
        let problem = await store.activate(key: key)
        step("activate", problem == nil, problem ?? "")
        if let file = store.license {
            let p = file.payload
            print("     plan \(p.plan), \(p.maxActivations) Macs, updates until \(p.maintenanceUntil.map { "\($0)" } ?? "every update")")
        }
        step("panel says licensed", { if case .licensed = store.panelState() { return true } else { return false } }(),
             String(describing: store.panelState()))
        step("dictation allowed", store.dictationAllowed)
        await store.checkInIfDue(force: true)
        step("check-in keeps the license", store.license != nil, store.problem ?? "")
        let freed = await store.deactivate()
        step("deactivate frees the seat", freed == nil && store.license == nil, freed ?? "")
        return ok
    }
}
