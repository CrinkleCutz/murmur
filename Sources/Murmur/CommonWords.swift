import Foundation

/// The English words common enough that Murmur doesn't need to be told about them: every word wordfreq (Robyn Speer;
/// Wikipedia, subtitles, news, books and web text) counts at least once per million words — 28,827 of them, in
/// `Resources/Words/common-english.txt`. Being in the dictionary isn't the same as being common: "agentic",
/// "notarize" and "refactor" are real words a recogniser still mishears, so a word typed into a correction that isn't
/// on this list is learned (`LearnedStore.newUnusualWords`), while "deploy" or "app" never is.
enum CommonWords {
    private static let words: Set<String>? = {
        let url = Bundle.main.url(forResource: "common-english", withExtension: "txt", subdirectory: "Words")
            ?? Bundle.module.url(forResource: "common-english", withExtension: "txt", subdirectory: "Words")
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Set(text.split(separator: "\n").map(String.init))
    }()

    /// Whether the list loaded (a build without the file falls back to the dictionary alone).
    static var isAvailable: Bool { words != nil }

    /// `word` (any case) is one of the common ones. Without the list, every word the dictionary knows counts as common
    /// — the behaviour before the list existed.
    static func isCommon(_ word: String) -> Bool {
        let key = word.lowercased().replacingOccurrences(of: "’", with: "'")
        guard let words else { return HarperChecker.isKnownEnglishWord(key) }
        return words.contains(key)
    }

    static func runSelfTest() -> Bool {
        var passed = true
        func check(_ ok: Bool, _ label: String) {
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): common words: \(label)")
        }
        check(isAvailable, "the list is bundled")
        check(["the", "page", "app", "deploy", "server", "Monday"].allSatisfy(isCommon), "everyday and common technical words are common")
        check(!["agentic", "notarize", "refactor", "dictation", "planrify"].contains(where: isCommon),
              "rare real words and names are not")
        return passed
    }
}
