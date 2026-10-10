import CryptoKit
import Foundation
import IOKit

// MARK: - Licensing: what a license says, whether it's genuine, and what it allows
//
// The shape follows the one Flit ships (a static read of Flit 1.0.9, 2026-09-23): a small signed JSON "license file"
// the server issues when a key is activated on a Mac. It is bound to that Mac, says which updates it covers, and
// tells the app when to check in again and how long it may keep working if the server can't be reached. Checking it
// needs no network at all — the app carries the server's Ed25519 public key, the way it carries its own code
// signature. Refunds, revocations and the per-license Mac limit are the server's business; the app learns about them
// when it checks in (`LicenseStore`, not written yet), and until then this file is what it goes by.
//
// Everything here only ever acts on an official release build (`BuildChannel.release`).

/// Which kind of build this is. Only an official release — the signed build sold from murmurmac.com — asks for a
/// license. Anything built from source, including every development build, never does: that's the MIT promise, and
/// it's what guarantees this can never lock a build that wasn't sold. The release script sets the Info.plist key
/// `MurmurBuildChannel` to `release`; without it a build is `source`. (Flit marks its builds the same way.)
enum BuildChannel: String {
    case source, release

    static var current: BuildChannel {
        (Bundle.main.object(forInfoDictionaryKey: "MurmurBuildChannel") as? String).flatMap(BuildChannel.init) ?? .source
    }

    /// When this build was released (Info.plist `MurmurReleaseDate`, ISO 8601, set by the release script alongside the
    /// channel). A license covers the versions released before its updates ended — so a build released after that
    /// doesn't dictate on it, even if it was downloaded by hand rather than through the updater. nil (a build without
    /// the key) is treated as covered: a packaging slip must never lock out someone who paid.
    static var releaseDate: Date? {
        (Bundle.main.object(forInfoDictionaryKey: "MurmurReleaseDate") as? String).flatMap(LicenseVerifier.date(from:))
    }
}

/// A license file as the server issues it.
struct LicenseFile: Equatable {
    struct Payload: Codable, Equatable {
        var licenseKey: String
        var email: String
        /// For Settings: "Murmur", "Murmur with updates", later perhaps "Team · 5 Macs".
        var plan: String
        /// `MachineIdentity.hash()` of the Mac it was issued to. A file copied to another Mac doesn't verify there.
        var machineHash: String
        /// How many Macs the key may be active on at once. The server enforces this; it's here to be shown.
        var maxActivations: Int
        var issuedAt: Date
        /// Versions released on or before this date are the buyer's to keep; nil means every update, forever. The
        /// one-time plan sets it to the purchase date plus a year ("a year of updates, then keep the app"); the
        /// Lifetime plan leaves it out. A renewal or an upgrade is just the server issuing a file with a later date,
        /// or none.
        var maintenanceUntil: Date?
        /// When the app should next confirm the license with the server.
        var recheckAfter: Date
        /// How many days past `recheckAfter` the app keeps working if it can't reach the server — a flight, a hotel,
        /// a dead router. A refund or revocation takes effect the moment the app does reach the server; this is only
        /// how long an unconfirmed license is trusted.
        var graceDays: Int
    }

    var payload: Payload

    /// The last moment this file works without being confirmed again.
    var worksUntil: Date { payload.recheckAfter.addingTimeInterval(TimeInterval(payload.graceDays) * 86_400) }

    func status(at now: Date = Date()) -> LicenseStatus {
        if now < payload.recheckAfter { return .current }
        if now < worksUntil {
            return .confirmDue(daysLeft: max(1, Int((worksUntil.timeIntervalSince(now) / 86_400).rounded(.up))))
        }
        return .lapsed
    }

    /// Whether an update released on `releaseDate` is included in this license.
    func covers(releaseDate: Date) -> Bool {
        payload.maintenanceUntil.map { releaseDate <= $0 } ?? true
    }
}

enum LicenseStatus: Equatable {
    /// Confirmed recently.
    case current
    /// Due to be confirmed; keeps working meanwhile, and confirms itself next time the Mac is online.
    case confirmDue(daysLeft: Int)
    /// Not confirmed for longer than the grace period allows.
    case lapsed
}

/// Why a license file was refused. The messages are what Settings will show.
enum LicenseProblem: Error, Equatable {
    case unreadable, badSignature, otherMac

    var message: String {
        switch self {
        case .unreadable: return "That license file could not be read."
        case .badSignature: return "This license doesn't match its signature. Activate it again with your key."
        case .otherMac: return "This license was issued to a different Mac. Activate it on this one with your key."
        }
    }
}

// MARK: - This Mac

/// A stable, private identifier for this Mac: a SHA-256 of its hardware UUID, prefixed with the product name so the
/// value Murmur's server sees can't be matched with any other app's. The same Mac always gives the same hash, and
/// reinstalling macOS or Murmur doesn't change it.
enum MachineIdentity {
    static func hash(platformUUID: String? = MachineIdentity.platformUUID()) -> String? {
        guard let uuid = platformUUID, !uuid.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data("murmur-license:\(uuid.uppercased())".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func platformUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }
}

// MARK: - Verifying

/// Checks a license file: that it's the server's, that it hasn't been edited, and that it belongs to this Mac.
enum LicenseVerifier {
    // TODO(license-launch): a THROWAWAY development key. Its matching private half has never existed outside this
    // placeholder — replace it with the real production public key (base64 of the raw 32-byte Ed25519 key; the server
    // keeps the private half) before any release build is sold, or no genuine license will verify.
    static let productionPublicKey = "rbn+pz0heNC0PeJcSx576UO40b4Jp/kK/y+FwMRRRDY="

    /// `raw` is `base64(payload JSON).base64(signature)`: the signature covers the exact payload bytes, so the server
    /// can use any language and any JSON layout without both sides agreeing on a canonical form. Dates are ISO 8601
    /// (what JavaScript's `toISOString()` writes, fractional seconds or not).
    static func verify(_ raw: String, publicKeyBase64: String = productionPublicKey,
                       machineHash: String? = MachineIdentity.hash()) -> Result<LicenseFile, LicenseProblem> {
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, let payloadData = Data(base64Encoded: parts[0]),
              let signature = Data(base64Encoded: parts[1])
        else { return .failure(.unreadable) }
        guard let keyData = Data(base64Encoded: publicKeyBase64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              key.isValidSignature(signature, for: payloadData)
        else { return .failure(.badSignature) }
        guard let payload = try? decoder.decode(LicenseFile.Payload.self, from: payloadData)
        else { return .failure(.unreadable) }
        guard let machineHash, payload.machineHash == machineHash else { return .failure(.otherMac) }
        return .success(LicenseFile(payload: payload))
    }

    /// ISO 8601, with or without fractional seconds.
    static func date(from text: String) -> Date? {
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return precise.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = LicenseVerifier.date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not an ISO 8601 date"))
        }
        return decoder
    }()

    // MARK: Self test

    static func runSelfTest() -> Bool {
        var passed = true
        func check(_ ok: Bool, _ label: String) {
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): license file: \(label)")
        }

        // A throwaway key made fresh for this run — it tests the format, not any real key.
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey.rawRepresentation.base64EncodedString()
        let thisMac = MachineIdentity.hash(platformUUID: "11111111-2222-3333-4444-555555555555")!
        let otherMac = MachineIdentity.hash(platformUUID: "99999999-2222-3333-4444-555555555555")!

        func payloadJSON(machine: String, maintenance: String? = "\"2026-09-22T10:00:00.000Z\"") -> String {
            """
            {"licenseKey":"MRMR-TEST1-TEST2-TEST3","email":"fixture@example.com","plan":"Murmur",\
            "machineHash":"\(machine)","maxActivations":2,"issuedAt":"2026-09-22T10:00:00.000Z",\
            "maintenanceUntil":\(maintenance ?? "null"),"recheckAfter":"2026-09-29T10:00:00Z","graceDays":14}
            """
        }
        func sign(_ json: String) -> String {
            let data = Data(json.utf8)
            return data.base64EncodedString() + "." + (try! privateKey.signature(for: data)).base64EncodedString()
        }
        func verified(_ raw: String, machine: String? = thisMac) -> Result<LicenseFile, LicenseProblem> {
            verify(raw, publicKeyBase64: publicKey, machineHash: machine)
        }

        let genuine = sign(payloadJSON(machine: thisMac))
        if case .success(let file) = verified(genuine) {
            check(file.payload.plan == "Murmur" && file.payload.maxActivations == 2 && file.payload.graceDays == 14,
                  "reads a genuine file issued to this Mac")
            check(file.payload.maintenanceUntil != nil, "reads fractional-second dates (JavaScript's own format)")
        } else {
            check(false, "a genuine file for this Mac verifies")
        }
        if case .success(let file) = verified(sign(payloadJSON(machine: thisMac, maintenance: nil))) {
            check(file.payload.maintenanceUntil == nil, "no maintenance date means every update")
        } else {
            check(false, "a lifetime file verifies")
        }

        check(verified(sign(payloadJSON(machine: otherMac))) == .failure(.otherMac), "refuses a file issued to another Mac")
        check(verified(genuine, machine: nil) == .failure(.otherMac), "refuses when this Mac can't be identified")
        let stranger = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        check(verify(genuine, publicKeyBase64: stranger, machineHash: thisMac) == .failure(.badSignature),
              "refuses a file signed by a key it doesn't trust")
        check(verify(genuine, machineHash: thisMac) == .failure(.badSignature),
              "the placeholder production key trusts nothing")
        // Edit one field of a genuine file and keep its signature.
        let edited = Data(payloadJSON(machine: thisMac, maintenance: nil).utf8).base64EncodedString()
            + "." + String(genuine.split(separator: ".")[1])
        check(verified(edited) == .failure(.badSignature), "refuses a file edited after signing, even by one field")
        check(verified("not a license") == .failure(.unreadable), "refuses garbage")
        check(verified("") == .failure(.unreadable), "refuses an empty file")
        check(verified(sign("{\"licenseKey\":\"MRMR\"}")) == .failure(.unreadable), "refuses a signed file with missing fields")

        // When it needs confirming, and for how long it keeps working.
        if case .success(let file) = verified(genuine) {
            func at(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }
            check(file.status(at: at("2026-09-25T10:00:00Z")) == .current, "confirmed before its recheck date")
            check(file.status(at: at("2026-09-30T10:00:00Z")) == .confirmDue(daysLeft: 13),
                  "keeps working past the recheck date, counting down the grace days")
            check(file.status(at: at("2026-10-13T09:00:00Z")) == .confirmDue(daysLeft: 1), "…down to the last day")
            check(file.status(at: at("2026-10-13T11:00:00Z")) == .lapsed, "lapses once the grace period has passed")
            check(file.covers(releaseDate: at("2026-09-01T00:00:00Z")), "covers a build released before the purchase")
            check(!file.covers(releaseDate: at("2026-10-01T00:00:00Z")),
                  "does not cover one released after it (the keep-this-version plan)")
        }

        // This Mac.
        let real = MachineIdentity.hash()
        check(real?.count == 64 && real == MachineIdentity.hash(), "this Mac has a stable 64-character identity")
        check(thisMac != otherMac && thisMac == MachineIdentity.hash(platformUUID: "11111111-2222-3333-4444-555555555555"),
              "different Macs hash differently, the same Mac the same")
        check(MachineIdentity.hash(platformUUID: "") == nil, "no hardware UUID, no identity")
        return passed
    }
}

// MARK: - What a license allows

/// The only two questions the rest of the app asks. Built around one rule: **a build from source is never gated.**
/// Every development build — including the one running on this Mac while it's being written — is `source`, and
/// behaves exactly as Murmur always has. Only an official release build asks for a license: during the free trial it
/// does everything; after that it needs a license that is still confirmed and that covers this build.
enum LicenseGate {
    static func dictationAllowed(channel: BuildChannel = .current, license: LicenseFile?, trialEndsAt: Date? = nil,
                                 buildReleaseDate: Date? = BuildChannel.releaseDate, at now: Date = Date()) -> Bool {
        guard channel == .release else { return true }
        if let license {
            guard license.status(at: now) != .lapsed else { return false }
            // "Versions released before this date are yours": a newer build, however it got here, isn't.
            if let buildReleaseDate, !license.covers(releaseDate: buildReleaseDate) { return false }
            return true
        }
        return trialEndsAt.map { now < $0 } ?? false
    }

    static func updateAllowed(channel: BuildChannel = .current, license: LicenseFile?, trialEndsAt: Date? = nil,
                              releaseDate: Date, at now: Date = Date()) -> Bool {
        guard channel == .release else { return true }
        if let license { return license.status(at: now) != .lapsed && license.covers(releaseDate: releaseDate) }
        return trialEndsAt.map { now < $0 } ?? false
    }

    // MARK: Self test

    static func runSelfTest() -> Bool {
        var passed = true
        func check(_ ok: Bool, _ label: String) {
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): license gate: \(label)")
        }
        let now = Date()
        func file(recheckIn days: Double, grace: Int = 14, maintenance: Date?) -> LicenseFile {
            LicenseFile(payload: .init(
                licenseKey: "MRMR-TEST", email: "fixture@example.com", plan: "Murmur", machineHash: "x",
                maxActivations: 2, issuedAt: now, maintenanceUntil: maintenance,
                recheckAfter: now.addingTimeInterval(days * 86_400), graceDays: grace))
        }
        let older = now.addingTimeInterval(-30 * 86_400), newer = now.addingTimeInterval(30 * 86_400)
        let keepVersion = file(recheckIn: 7, maintenance: now)
        let everyUpdate = file(recheckIn: 7, maintenance: nil)
        let dueButGraced = file(recheckIn: -3, maintenance: nil)
        let lapsed = file(recheckIn: -20, maintenance: nil)

        // The rule everything else protects.
        check(BuildChannel.current == .source, "this build is a source build, so nothing here can gate it")
        check(dictationAllowed(channel: .source, license: nil) && dictationAllowed(channel: .source, license: lapsed),
              "a source build always dictates, license or not")
        check(updateAllowed(channel: .source, license: nil, releaseDate: newer), "a source build always takes updates")

        // An official release build.
        check(!dictationAllowed(channel: .release, license: nil), "a release build with no license asks for one")
        check(dictationAllowed(channel: .release, license: keepVersion, buildReleaseDate: older), "a current license dictates")
        check(dictationAllowed(channel: .release, license: dueButGraced, buildReleaseDate: older), "an unconfirmed license keeps working through its grace days")
        check(!dictationAllowed(channel: .release, license: lapsed, buildReleaseDate: older), "a lapsed license stops")
        check(updateAllowed(channel: .release, license: everyUpdate, releaseDate: newer), "the updates plan takes a newer build")
        check(!updateAllowed(channel: .release, license: keepVersion, releaseDate: newer), "the keep-this-version plan doesn't")
        check(updateAllowed(channel: .release, license: keepVersion, releaseDate: older),
              "…but can still reinstall the version it bought")
        check(!updateAllowed(channel: .release, license: lapsed, releaseDate: older), "a lapsed license takes no updates")
        check(!updateAllowed(channel: .release, license: nil, releaseDate: older), "nor does a release build with no license")

        // The trial.
        let trialLeft = now.addingTimeInterval(3 * 86_400), trialOver = now.addingTimeInterval(-86_400)
        check(dictationAllowed(channel: .release, license: nil, trialEndsAt: trialLeft), "the trial dictates")
        check(updateAllowed(channel: .release, license: nil, trialEndsAt: trialLeft, releaseDate: newer), "…and takes updates")
        check(!dictationAllowed(channel: .release, license: nil, trialEndsAt: trialOver), "an ended trial pauses dictation")

        // The running build's own release date.
        let yearPlan = file(recheckIn: 7, maintenance: now.addingTimeInterval(365 * 86_400))
        check(dictationAllowed(channel: .release, license: yearPlan, buildReleaseDate: older), "a build from within the updates year dictates")
        check(!dictationAllowed(channel: .release, license: keepVersion, buildReleaseDate: newer),
              "a build released after the updates ended doesn't, even downloaded by hand")
        check(dictationAllowed(channel: .release, license: everyUpdate, buildReleaseDate: newer), "Lifetime runs any build")
        check(dictationAllowed(channel: .release, license: keepVersion, buildReleaseDate: nil),
              "a build missing its release date is treated as covered — a packaging slip never locks out a buyer")
        return passed
    }
}
