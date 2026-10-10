import harper

/// A fast, local, deterministic grammar pass — [Harper](https://github.com/Automattic/harper),
/// vendored as a small Rust static library (`Vendor/harper-ffi`, built into
/// `Vendor/harper.xcframework`). Runs *after* the Apple Intelligence edit
/// pass in `RewriteEngine`, not instead of it: the LLM handles filler
/// removal and restructuring rambling speech into sentences, which Harper's
/// rule-based linting doesn't do; Harper catches a few mechanical errors
/// (repeated words, then/than, its/it's, could-of, "backup" the verb) at
/// millisecond speed, as a final polish.
///
/// It is deliberately a *narrow* pass: the Rust side allow-lists a handful
/// of rules that were vetted for zero false positives (see the doc comment
/// on `ALLOWED_RULES` in `Vendor/harper-ffi/src/lib.rs`). Applying Harper's
/// full default rule set to dictation measurably made word error worse — it
/// rewrote brand names, expanded "config" to "configuration", and
/// Americanized British spelling — so everything else is off, including any
/// rule a future Harper release adds.
///
/// Pure, synchronous, local Rust — no model to download, no warm-up, no
/// network. Unlike every other engine in this app, there's nothing to be
/// "ready" for.
enum HarperChecker {
    /// Lints `text` and applies the vetted fixes (one edit per stretch of
    /// text; overlapping suggestions are dropped, never stacked). Empty
    /// input returns empty output; never throws — a malformed C string
    /// round-trip degrades to returning `text` unchanged rather than losing
    /// the dictation.
    ///
    /// `vocabulary` is Murmur's own known words — pass
    /// `LearnedStore.biasTerms()`, the same list fed to ASR vocabulary
    /// biasing — so any rule that consults Harper's dictionary treats them
    /// as known words. It mattered most when Harper's spell-checker was on
    /// (it turned every correctly-transcribed "Supabase" into "Separate");
    /// that rule is now off, so brand names are safe with or without the
    /// list, but passing it stays cheap insurance. Defaults to empty for
    /// callers (tests, `--harper-fix`) that don't have a term list handy.
    static func fix(_ text: String, vocabulary: [String] = []) -> String {
        guard !text.isEmpty else { return text }
        let vocabularyText = vocabulary.joined(separator: "\n")
        guard let resultPtr = text.withCString({ textPtr in
            vocabularyText.withCString { vocabPtr in
                harper_fix_text(textPtr, vocabPtr)
            }
        }) else {
            return text
        }
        defer { harper_free_string(resultPtr) }
        let fixed = String(cString: resultPtr)
        return fixed.isEmpty ? text : fixed
    }

    /// True if `word` is a real, ordinary English word in Harper's own
    /// dictionary — false for proper nouns, brand names, and acronyms.
    ///
    /// Used by `LearnedStore.isUsefulMapping` to refuse learning a
    /// pronunciation correction whose *entire* trigger is one ordinary
    /// word: auditing one real user's accumulated corrections found
    /// `team → theme`, `there → they`, `whisper → Wispr`, and others,
    /// apparently learned by mistake — the underlying diff extraction
    /// misattributing an edit made elsewhere in a correction round-trip to
    /// a short common word it happened to land near. A proper noun like
    /// "Giannis" isn't in this dictionary, so genuine name/brand
    /// corrections are unaffected.
    static func isKnownEnglishWord(_ word: String) -> Bool {
        word.withCString { harper_is_known_word($0) }
    }

    /// Exercises the real compiled library (not a mock): text a speaker
    /// really said must survive untouched, and the few mechanical errors
    /// the allow-list covers must still be fixed. Every "untouched" line
    /// below was rewritten by Harper's full default rule set before it was
    /// restricted to an allow-list.
    static func runSelfTest() -> Bool {
        var passed = true
        func check(_ ok: Bool, _ label: String) {
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): \(label)")
        }

        let untouched = [
            "I need to back up the Supabase database before deploying to production.",
            "Please open a pull request and ask Claude to review the Kubernetes config.",
            "Send me the env file and the roadmap before the double check.",
            "It uses 8 GB of RAM and takes 200 ms per request.",
            "He said the superbase project is ready.",
            "We use pnpm and Vite with Prisma on Vercel.",
            "The colour and the organisation of the page look better.",
            "I went there yesterday and put it over there.",
            "That is what I had had to do before the release.",
            "Open it in an Xcode project.",
            "The backup is ready and the login page works.",
        ]
        for sentence in untouched {
            check(fix(sentence) == sentence, "Harper leaves \(sentence.debugDescription) untouched")
        }

        let fixed: [(String, String)] = [
            ("I went there yesterday and their was a problem with it.",
             "I went there yesterday and there was a problem with it."),
            ("I went to the the store yesterday.", "I went to the store yesterday."),
            ("This is faster then before.", "This is faster than before."),
            ("I could of finished it.", "I could have finished it."),
            ("The API returns it's result.", "The API returns its result."),
            ("I need to backup the database first.", "I need to back up the database first."),
            ("I will refactor the type script code.", "I will refactor the typescript code."),
            ("Please update the change log before release.", "Please update the changelog before release."),
        ]
        for (input, expected) in fixed {
            check(fix(input) == expected, "Harper still fixes \(input.debugDescription)")
        }
        return passed
    }
}
