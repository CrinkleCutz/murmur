//! Minimal C FFI around harper-core, built for Murmur.
//!
//! Exposes `harper_fix_text` (lint the input and apply a *vetted* subset of
//! Harper's fixes, returning corrected text), `harper_free_string` (frees
//! what it returns) and `harper_is_known_word`. No other surface — Murmur only
//! needs "fix this text", not the full lint/suggestion API.
//!
//! # Why an allow-list, not "everything Harper suggests"
//!
//! Harper is a grammar checker written for a person reviewing suggestions in
//! an editor. Murmur applies its first suggestion automatically to the output
//! of a speech recognizer whose text is already grammatical and punctuated,
//! and whose real mistakes (jargon, accents) a spell/grammar checker cannot
//! repair. Measured on real transcripts with known ground truth, applying all
//! 818 default rules made word error *worse* on every engine: `SpellCheck`
//! rewrote brand names ("Supabase" → "Separate", "superbase" → "supervise"),
//! `ExpandConfiguration` turned "config" into "configuration", `SplitWords`
//! split "superbase" into "super base", `RoadMap`, `DoubleCheckHyphen`,
//! `ExpandMemoryShorthands` and dozens of "expand this initialism" rules
//! rewrote words the speaker actually said, and `SpellCheck` Americanized
//! British spelling. So everything is switched OFF and only the rules named in
//! `ALLOWED_RULES` — each vetted for zero false positives on ~1,100 sentences
//! of real developer prose plus injected errors and hand-written negatives —
//! are switched back on. Anything not listed is denied by default, including
//! rules added by future Harper releases.

use harper_core::linting::{Lint, LintGroup};
use harper_core::parsers::PlainEnglish;
use harper_core::spell::{Dictionary, FstDictionary, MergedDictionary, MutableDictionary};
use harper_core::{DictWordMetadata, Dialect, Document};
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::sync::Arc;

/// The only Harper rules allowed to edit a dictation. Each fixes a mechanical
/// error a person would agree is wrong, and each was measured to change none
/// of ~1,100 already-correct developer sentences and to make no wrong fix.
///
/// Deliberately absent, with the measured reason:
/// - `SpellCheck` — 350 false positives on correct developer prose; its
///   suggestions never repair a recognition error (they turn garbled words
///   into unrelated ones) and it mangles every brand name it doesn't know.
/// - `AnA` — "an Xcode project" → "a Xcode project" (brand/acronym pronunciation).
/// - `SentenceCapitalization` — would capitalize "npm", "iOS", "macOS" at the
///   start of a sentence; recognizers already capitalize sentences.
/// - `CapitalizePersonalPronouns` — `TextFormatter` already does this, and a
///   dictated loop variable "i" is not the pronoun.
/// - `ThereToTheir` — rewrites a correct "I went there yesterday" to "their".
/// - `ExpandConfiguration`, `SplitWords`, `RoadMap`, `DoubleCheckHyphen`,
///   `MissingTo`, `Spaces`, `CommaFixes`, `OrthographicConsistency`,
///   `CompoundNouns`, `Expand*Shorthands`, `DisjointPrefixes`, … — each
///   rewrote words the speaker really said in the audit.
const ALLOWED_RULES: &[&str] = &[
    // homophones and confusions
    "ThenThan",
    "ItsPossessive",
    "ItsContraction",
    "PronounContraction",
    "TheirToThere",
    "TheirToTheyre",
    "Theres",
    "ThereOwn",
    "WereWhere",
    "NounVerbConfusion",
    // agreement and auxiliaries
    "PronounVerbAgreement",
    "PronounInflectionBe",
    "ModalOf",
    "DoubleModal",
    "SingleBe",
    "MultipleSequentialPronouns",
    // mechanics
    "RepeatedWords",
    // Rejoins a compound the recognizer split into two words ("type script" →
    // "typescript", "change log" → "changelog", "read me" → "readme"); WhisperKit
    // does this constantly. Harper only merges when the joined form is in its
    // dictionary, so real phrases ("pull request", "source code", "log in",
    // "set up") are left alone. Its one hit on ~1,100 correct developer
    // sentences was "file names" → "filenames", a spelling variant, not an error.
    "CompoundNouns",
    // "backup" the verb → "back up"; noun uses ("the backup", "a setup issue")
    // were left alone in every probe.
    "PhrasalVerbAsCompoundNoun",
];

/// Repeats that are correct English ("what I had had to do", "he said that
/// that was fine"), which `RepeatedWords` flags anyway.
const LEGITIMATE_DOUBLES: &[&str] = &["had", "that"];

/// Lints `input` and returns a newly-allocated corrected copy.
///
/// `vocabulary` is a newline-separated list of words/phrases Harper should
/// treat as known, correctly-spelled English (may be null or empty). With the
/// spell-checker off this rarely matters any more, but it keeps Murmur's own
/// terms known to every rule that consults the dictionary. Multi-word entries
/// are split on whitespace so each word is registered individually — Harper
/// tokenizes running text word by word, so a dictionary entry for the phrase
/// alone would never match anything.
///
/// The caller owns the result and must pass it to `harper_free_string` when
/// done. Never fails outward: a null/invalid/non-UTF8 input produces an
/// empty string rather than a null pointer, so Swift callers don't need a
/// separate null-check path on top of the usual empty-string check.
#[no_mangle]
pub extern "C" fn harper_fix_text(
    input: *const c_char,
    vocabulary: *const c_char,
) -> *mut c_char {
    let text = if input.is_null() {
        ""
    } else {
        unsafe { CStr::from_ptr(input) }.to_str().unwrap_or("")
    };
    let vocabulary_text = if vocabulary.is_null() {
        ""
    } else {
        unsafe { CStr::from_ptr(vocabulary) }.to_str().unwrap_or("")
    };

    let fixed = fix_text(text, vocabulary_text);
    CString::new(fixed)
        .unwrap_or_else(|_| CString::new("").unwrap())
        .into_raw()
}

/// Frees a string returned by `harper_fix_text`. Safe to call with null.
#[no_mangle]
pub extern "C" fn harper_free_string(s: *mut c_char) {
    if s.is_null() {
        return;
    }
    unsafe {
        drop(CString::from_raw(s));
    }
}

/// Reports whether `word` is a real, ordinary English word in Harper's own
/// curated dictionary (case-insensitive) — as opposed to a proper noun,
/// brand name, or acronym, none of which this dictionary carries. Null,
/// non-UTF8, or empty input returns false.
///
/// Built for `LearnedStore.isUsefulMapping` on the Swift side: a personal
/// pronunciation correction whose *entire* trigger is one ordinary word
/// ("team", "there", "whisper") is far more likely to be a diff-algorithm
/// artifact — an edit made elsewhere in a correction round-trip,
/// misattributed to a short word it happened to land near — than a genuine
/// mishearing, and unlike Harper's own lints it runs with no confidence
/// gate at all once learned. A proper noun like "Giannis" or "Versal"
/// won't be in this dictionary and so isn't blocked; a real dictionary
/// word like "team" or "whisper" will be.
#[no_mangle]
pub extern "C" fn harper_is_known_word(word: *const c_char) -> bool {
    if word.is_null() {
        return false;
    }
    let Ok(word) = unsafe { CStr::from_ptr(word) }.to_str() else {
        return false;
    };
    if word.is_empty() {
        return false;
    }
    FstDictionary::curated().contains_word_str(word)
}

/// Whether a lint produced by an allowed rule is still safe to apply.
fn keep_lint(rule: &str, lint: &Lint, chars: &[char]) -> bool {
    if lint.suggestions.is_empty() {
        return false;
    }
    let end = lint.span.end.min(chars.len());
    let start = lint.span.start.min(end);
    let covered: String = chars[start..end].iter().collect();
    match rule {
        "RepeatedWords" => {
            let first = covered
                .split_whitespace()
                .next()
                .unwrap_or("")
                .trim_matches(|c: char| !c.is_alphanumeric())
                .to_lowercase();
            !LEGITIMATE_DOUBLES.contains(&first.as_str())
        }
        // "their's" is handled properly by `Theres`; this rule would drop the
        // "'s" and leave "there no match".
        "TheirToThere" => !covered.contains('\'') && !covered.contains('’'),
        _ => true,
    }
}

fn fix_text(text: &str, vocabulary_text: &str) -> String {
    if text.is_empty() {
        return String::new();
    }

    let parser = PlainEnglish;

    // Harper's curated dictionary, plus Murmur's own vocabulary layered on
    // top — a `MergedDictionary` checks each child in order and treats a
    // word as known if *any* of them contain it, so this only ever adds
    // words Harper will leave alone; it can't remove or override Harper's
    // own.
    let mut user_dict = MutableDictionary::new();
    for term in vocabulary_text.lines() {
        for word in term.split_whitespace() {
            let cleaned: String = word
                .chars()
                .filter(|c| c.is_alphanumeric() || *c == '\'' || *c == '-')
                .collect();
            if !cleaned.is_empty() {
                user_dict.append_word_str(&cleaned, DictWordMetadata::default());
            }
        }
    }

    let mut dict = MergedDictionary::new();
    dict.add_dictionary(FstDictionary::curated());
    dict.add_dictionary(Arc::new(user_dict));
    let dict = Arc::new(dict);

    let document = Document::new(text, &parser, &*dict);
    let mut linter = LintGroup::new_curated(dict, Dialect::American);
    // Default-deny: switch every rule off, then re-enable only the vetted
    // ones. Disabled rules are never run, so this is also much cheaper.
    linter.set_all_rules_to(Some(false));
    for rule in ALLOWED_RULES {
        linter.config.set_rule_enabled(*rule, true);
    }

    let chars: Vec<char> = text.chars().collect();
    // Same order `LintGroup::lint` returns: rule name ascending, then in-rule order.
    let mut candidates: Vec<Lint> = Vec::new();
    for (rule, lints) in linter.organized_lints(&document) {
        for lint in lints {
            if keep_lint(&rule, &lint, &chars) {
                candidates.push(lint);
            }
        }
    }

    // One edit per stretch of text: earliest (then longest) wins and anything
    // overlapping it is dropped. Applying overlapping edits on top of each
    // other is what corrupted "went there yesterday and their was" before.
    candidates.sort_by(|a, b| {
        a.span
            .start
            .cmp(&b.span.start)
            .then((b.span.end - b.span.start).cmp(&(a.span.end - a.span.start)))
    });
    let mut chosen: Vec<Lint> = Vec::new();
    for lint in candidates {
        let overlaps = chosen
            .iter()
            .any(|c| lint.span.start < c.span.end && c.span.start < lint.span.end);
        if !overlaps {
            chosen.push(lint);
        }
    }

    // Apply in reverse span order so earlier edits don't shift the character
    // offsets every later lint's span is expressed in.
    chosen.sort_by(|a, b| b.span.start.cmp(&a.span.start));
    let mut out = chars;
    for lint in &chosen {
        if let Some(suggestion) = lint.suggestions.first() {
            suggestion.apply(lint.span, &mut out);
        }
    }

    out.into_iter().collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn leaves_correct_text_alone() {
        let input = "This is a correct sentence.";
        assert_eq!(fix_text(input, ""), input);
    }

    #[test]
    fn fixes_repeated_word() {
        assert_eq!(
            fix_text("I went to the the store.", ""),
            "I went to the store."
        );
    }

    #[test]
    fn empty_input_is_empty_output() {
        assert_eq!(fix_text("", ""), "");
    }

    #[test]
    fn unknown_brand_names_are_never_touched_even_without_a_vocabulary() {
        // The spell-checker used to turn "Supabase" into "Separate".
        for input in [
            "I set up the database using Supabase yesterday.",
            "Please deploy it to Vercel and open Kubernetes.",
            "We use pnpm and Vite with Prisma.",
        ] {
            assert_eq!(fix_text(input, ""), input, "changed: {input}");
        }
    }

    #[test]
    fn multi_word_vocabulary_entry_still_protects_each_word() {
        let fixed = fix_text("I opened Claude Code this morning.", "Claude Code");
        assert!(fixed.contains("Claude Code"), "got: {fixed}");
    }

    #[test]
    fn developer_words_the_speaker_said_are_not_rewritten() {
        // Every one of these was rewritten by the default rule set.
        for input in [
            "Please review the Kubernetes config before standup.",
            "Send me the env file and the roadmap.",
            "The double check on the config passed.",
            "It uses 8 GB of RAM and takes 200 ms per request.",
            "He said the superbase project is ready.",
        ] {
            assert_eq!(fix_text(input, ""), input, "changed: {input}");
        }
    }

    #[test]
    fn spelling_variants_are_left_alone() {
        let input = "The colour and the organisation of the page look better.";
        assert_eq!(fix_text(input, ""), input);
    }

    #[test]
    fn the_homophone_error_is_fixed_without_corrupting_the_correct_word() {
        assert_eq!(
            fix_text("I went there yesterday and their was a problem with it.", ""),
            "I went there yesterday and there was a problem with it."
        );
    }

    #[test]
    fn a_correct_there_is_never_rewritten() {
        let input = "I went there yesterday and put it over there.";
        assert_eq!(fix_text(input, ""), input);
    }

    #[test]
    fn a_legitimate_double_word_is_left_alone() {
        let input = "That is what I had had to do before the release.";
        assert_eq!(fix_text(input, ""), input);
    }

    #[test]
    fn the_verb_backup_is_split_but_the_noun_is_not() {
        assert_eq!(
            fix_text("I need to backup the database first.", ""),
            "I need to back up the database first."
        );
        let noun = "The backup is ready and the login page works.";
        assert_eq!(fix_text(noun, ""), noun);
    }

    #[test]
    fn a_split_compound_is_rejoined_but_real_phrases_are_not() {
        assert_eq!(
            fix_text("I will refactor the type script code.", ""),
            "I will refactor the typescript code."
        );
        assert_eq!(
            fix_text("Please update the change log before release.", ""),
            "Please update the changelog before release."
        );
        for phrase in [
            "Open a pull request and read the source code.",
            "We need to log in and set up the test case.",
            "Please back up the data and check out the branch.",
        ] {
            assert_eq!(fix_text(phrase, ""), phrase, "changed: {phrase}");
        }
    }

    #[test]
    fn a_brand_that_starts_with_a_vowel_sound_keeps_its_article() {
        let input = "Open it in an Xcode project.";
        assert_eq!(fix_text(input, ""), input);
    }

    #[test]
    fn common_mechanical_errors_are_still_fixed() {
        assert_eq!(fix_text("This is faster then before.", ""), "This is faster than before.");
        assert_eq!(fix_text("I could of finished it.", ""), "I could have finished it.");
        assert_eq!(fix_text("The API returns it's result.", ""), "The API returns its result.");
    }

    #[test]
    fn every_allowed_rule_exists_in_this_harper_version() {
        // A Harper upgrade that renames a rule would otherwise silently turn
        // it off (an unknown name in the config does nothing).
        let dict = FstDictionary::curated();
        let group = LintGroup::new_curated(dict, Dialect::American);
        for rule in ALLOWED_RULES {
            assert!(group.contains_key(rule), "unknown Harper rule: {rule}");
        }
    }

    #[test]
    fn ordinary_words_are_known() {
        for word in ["team", "there", "whisper", "weight", "tail", "wiser"] {
            assert!(
                FstDictionary::curated().contains_word_str(word),
                "expected {word:?} to be a known word"
            );
        }
    }

    #[test]
    fn proper_nouns_are_not_known() {
        for word in ["Giannis", "Versal", "Supabase", "Faipel"] {
            assert!(
                !FstDictionary::curated().contains_word_str(word),
                "expected {word:?} to be unknown"
            );
        }
    }
}
