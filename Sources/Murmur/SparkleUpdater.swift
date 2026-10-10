import Foundation
import Sparkle

/// Updates for official release builds, through Sparkle — the updater Flit and most Mac apps sold outside the App
/// Store use. Every update is signed with Murmur's EdDSA key (Info.plist `SUPublicEDKey`; the private half lives only
/// in the Keychain of the Mac releases are made on) and Sparkle also checks Apple's code signature, so a tampered or
/// look-alike archive is refused — which the GitHub updater (`UpdateChecker`) never checked.
///
/// Everyone reads the same feed (Info.plist `SUFeedURL`, an appcast on murmurmac.com listing every release with its
/// date). The license decides which of those this Mac may install: `bestValidUpdate` offers the newest release the
/// license covers, and anything newer is left for Settings to show as "not included — renew or upgrade"
/// (`notIncluded`), never installed.
///
/// A source build doesn't start Sparkle at all and keeps the GitHub updater exactly as before — including this Mac's
/// own daily build. So does a release build that was packaged without a feed or a key: it simply doesn't update, it
/// never falls back to an unsigned updater.
@MainActor
final class SparkleUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = SparkleUpdater(license: LicenseStore.shared)

    struct NotIncluded: Equatable {
        let version: String
        let releaseDate: Date?
    }

    /// The newest release, when this license doesn't include it. nil when there's nothing newer, or it's included.
    @Published private(set) var notIncluded: NotIncluded?

    enum CheckResult: Equatable {
        /// Not checked yet this session — Sparkle checks on its own schedule.
        case unknown
        case upToDate
        /// A newer version this license includes (Sparkle has shown, or will show, its own window for it).
        case available(version: String)
    }

    /// Settings' General row reads this rather than guessing "Up to date" before anything has been checked.
    @Published private(set) var lastCheck: CheckResult = .unknown

    private var controller: SPUStandardUpdaterController?
    private let license: LicenseStore

    init(license: LicenseStore) {
        self.license = license
    }

    static var isConfigured: Bool {
        BuildChannel.current == .release
            && Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
            && Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil
    }

    func start() {
        guard Self.isConfigured, controller == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    }

    /// "Check for Updates…" — shows Sparkle's own window, found or not.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    var isRunning: Bool { controller != nil }

    // MARK: SPUUpdaterDelegate (main thread)

    func bestValidUpdate(in appcast: SUAppcast, for updater: SPUUpdater) -> SUAppcastItem? {
        let items = appcast.items
        let pick = UpdateSelection.best(Self.candidates(items), currentVersion: Self.currentVersion,
                                        allowed: license.updateAllowed(releaseDate:))
        return pick.map { items[$0] } ?? SUAppcastItem.empty()
    }

    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        let items = appcast.items
        guard let newest = UpdateSelection.newest(Self.candidates(items), currentVersion: Self.currentVersion),
              !license.updateAllowed(releaseDate: items[newest].date)
        else {
            notIncluded = nil
            return
        }
        notIncluded = NotIncluded(version: items[newest].displayVersionString, releaseDate: items[newest].date)
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        lastCheck = .available(version: item.displayVersionString)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        lastCheck = .upToDate
    }

    private static func candidates(_ items: [SUAppcastItem]) -> [UpdateSelection.Candidate] {
        items.map { .init(version: $0.versionString, date: $0.date) }
    }

    /// Sparkle compares the build number (`CFBundleVersion`), the same way `generate_appcast` writes the feed.
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }
}

/// Which release in the feed to offer, kept apart from Sparkle's own types so it can be tested on its own.
enum UpdateSelection {
    struct Candidate {
        let version: String
        let date: Date?
    }

    /// The newest release above the running build that `allowed` accepts (given its release date); nil if none.
    static func best(_ candidates: [Candidate], currentVersion: String, allowed: (Date?) -> Bool) -> Int? {
        newest(candidates, currentVersion: currentVersion, where: { allowed($0.date) })
    }

    /// The newest release above the running build.
    static func newest(_ candidates: [Candidate], currentVersion: String,
                       where include: (Candidate) -> Bool = { _ in true }) -> Int? {
        let comparator = SUStandardVersionComparator.default
        var best: Int?
        for (index, candidate) in candidates.enumerated()
        where comparator.compareVersion(candidate.version, toVersion: currentVersion) == .orderedDescending
            && include(candidate) {
            if let current = best,
               comparator.compareVersion(candidate.version, toVersion: candidates[current].version) != .orderedDescending {
                continue
            }
            best = index
        }
        return best
    }

    static func runSelfTest() -> Bool {
        var passed = true
        func check(_ ok: Bool, _ label: String) {
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): update selection: \(label)")
        }
        func day(_ iso: String) -> Date { LicenseVerifier.date(from: iso + "T12:00:00Z")! }
        // The feed as written — not in version order, as Sparkle warns it may not be.
        let feed = [
            Candidate(version: "12", date: day("2027-03-01")),
            Candidate(version: "10", date: day("2026-10-01")),
            Candidate(version: "14", date: day("2027-11-01")),
            Candidate(version: "11", date: day("2026-12-01")),
        ]
        let updatesUntil = day("2027-09-22")
        let yearPlan: (Date?) -> Bool = { $0.map { $0 <= updatesUntil } ?? false }

        check(best(feed, currentVersion: "10", allowed: { _ in true }) == 2, "Lifetime gets the newest release")
        check(best(feed, currentVersion: "10", allowed: yearPlan) == 0, "a year of updates gets the newest one inside the year")
        check(newest(feed, currentVersion: "10") == 2, "…while the newest overall is the one to show as not included")
        check(best(feed, currentVersion: "12", allowed: yearPlan) == nil, "nothing newer inside the year: no update")
        check(best(feed, currentVersion: "14", allowed: { _ in true }) == nil, "already on the newest: no update")
        check(best(feed, currentVersion: "10", allowed: { _ in false }) == nil, "a lapsed license takes nothing")
        check(best([Candidate(version: "2.10", date: nil), Candidate(version: "2.9", date: nil)], currentVersion: "2.8",
                   allowed: { _ in true }) == 0, "versions compare as versions (2.10 is newer than 2.9)")
        check(!yearPlan(nil), "an undated release can't be placed inside a year, so the year plan doesn't take it")
        return passed
    }
}
