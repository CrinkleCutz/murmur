import Foundation

/// What tapping a logged notification does. Kept narrow and specific
/// rather than a generic "open this `Page`" field — `Page` isn't
/// `Codable`, and the two real notification sources below don't need
/// anything more general than this.
enum LoggedNotificationKind: String, Codable {
    case appProfileSuggestion
    case updateAvailable
    /// A name learned from a correction made right after a dictation (`EditLearner`); opens Voice Profile.
    case learnedFromEdit
}

struct LoggedNotification: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var title: String
    var message: String
    var kind: LoggedNotificationKind
}

/// A small history of the real notifications Murmur has sent — the app
/// profile suggestion (`AppDelegate.promptForAppProfile`) and, once
/// `UpdateChecker` finds one, an available update. Exists so the
/// titlebar bell has something real to show instead of just navigating
/// to Help, which is what it did before.
enum NotificationLog {
    private static var fileURL: URL {
        AppPaths.supportDirectory.appendingPathComponent("notifications.json")
    }
    /// Capped so this can't grow forever — old entries age out silently
    /// rather than needing an explicit "clear all".
    private static let limit = 30

    static func load() -> [LoggedNotification] {
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? JSONDecoder().decode([LoggedNotification].self, from: data)
        else { return [] }
        return entries
    }

    static func add(title: String, message: String, kind: LoggedNotificationKind) {
        var entries = load()
        entries.insert(
            LoggedNotification(title: title, message: message, kind: kind), at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
