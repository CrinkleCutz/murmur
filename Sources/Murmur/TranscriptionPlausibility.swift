import AVFoundation
import Foundation

/// A plausibility gate against a real, observed failure mode: an
/// attention-based decode (confirmed on Canary; the Whisper-family engines
/// share the same architectural risk) fabricating fluent-sounding content
/// that was never said, rather than admitting uncertainty — the same
/// underlying tendency `HallucinationFilter` already guards a narrower
/// case of: a Whisper model hallucinating a sign-off phrase when fed
/// silence. That filter catches a small, specific, known set of phrases on
/// near-silent audio; this one is broader and engine-agnostic, catching an
/// output that doesn't look like a plausible transcription of audio this
/// long, on any engine, with real speech in it — the shape of failure this
/// session hit live on Canary (an inserted phrase, two reordered clauses).
///
/// Two cheap checks, not a second ASR opinion or a ground-truth comparison
/// — there's no way to know individual *words* are wrong from the output
/// text alone, only that the output as a whole is implausible:
/// - Implied speaking rate over a hard ceiling real speech can't produce.
///   Fabricated content tends to run disproportionately long relative to
///   the actual audio, since the model is generating language, not
///   transcribing a weak signal.
/// - Immediate pathological repetition — the other classic attention-
///   hallucination shape, the same short span looping instead of the
///   decode terminating.
///
/// Deliberately has no *lower* bound: normal speech pauses constantly and
/// produces short, sparse output all the time, and a lower bound would
/// reject far more good transcriptions than bad ones. This also won't
/// catch a same-length substitution (wrong words swapped in for right
/// ones, word count and pacing both unchanged) — that's invisible from the
/// output text alone without knowing what was actually said. It only
/// catches the egregious cases, which is still real protection: an
/// implausible result never reaching you beats a fluent-sounding
/// fabrication you don't notice.
///
/// `confidence`, when a caller has one, closes exactly that same-length-
/// substitution gap the text-only checks above admit they can't: it's the
/// engine's own per-token softmax probability, not a heuristic on the
/// rendered text, so a confidently-wrong word (e.g. Parakeet swapping in
/// "database" for "Supabase" — same length, same pacing) can still show up
/// as low-confidence even though the text alone looks completely normal.
/// Optional and additive — a `nil` (an engine that doesn't expose this yet)
/// leaves every existing text-only check exactly as it was.
enum TranscriptionPlausibility {
    /// Below this, a result is rejected regardless of what the text-only
    /// checks below think of it. Every engine that reports a confidence
    /// puts it on this one 0–1 scale:
    /// - Parakeet: its own `ASRResult.confidence`, documented as "average
    ///   of token-level softmax probabilities," clamped to `[0.1, 1.0]` —
    ///   0.1 its floor for empty/failed output, 0.5 its fallback when
    ///   something has gone wrong internally.
    /// - WhisperKit / whisper.cpp: `exp` of the mean per-token log-prob
    ///   (the geometric-mean token probability). On that scale OpenAI's own
    ///   reference retry line — `logprob_threshold = -1.0`, which WhisperKit
    ///   applies internally — is `exp(-1.0)` ≈ 0.368, so 0.35 sits just
    ///   *under* the point where Whisper itself already calls a decode
    ///   failed: a result below it has, in WhisperKit's case, already
    ///   exhausted its temperature fallbacks.
    ///
    /// Deliberately a catastrophic-failure floor, not a tight filter —
    /// measured, not guessed (2026-09-19: 28 TTS clips, 14 voices/accents
    /// × 2 jargon-heavy sentences, word error scored against the known
    /// text). Real errors sit at 0.5–0.98 on every engine and overlap
    /// heavily with correct output (Parakeet: errors' median 0.944 vs
    /// 0.970+ for exact matches), so no whole-utterance threshold
    /// separates them. And a rejection falls back to Apple's engine, which
    /// was far worse on the same clips (mean WER 0.384 vs 0.119 for
    /// whisper.cpp large-v3-turbo): raising this above ~0.6 *increased*
    /// total error for whisper.cpp (at 0.80 the rejected clips went from
    /// 0.21 to 0.61 WER), and above ~0.90 for Parakeet. Don't raise it to
    /// "catch more" without re-running that engine-vs-Apple comparison.
    /// Caveat: TTS is cleaner than real speech, so this bounds the
    /// false-positive risk from below only.
    static let lowConfidenceThreshold: Float = 0.35

    static func isPlausible(
        _ text: String, audioDurationSeconds: Double, confidence: Float? = nil
    ) -> Bool {
        let words = text.split(separator: " ").filter { !$0.isEmpty }
        guard !words.isEmpty, audioDurationSeconds > 0 else { return true }

        if let confidence, confidence < lowConfidenceThreshold { return false }

        // 400 WPM is far past even fast competitive speech (Flit.fyi's own
        // published measurement across 500+ real dictations was 124 WPM) —
        // high enough that no genuine dictation should ever trip it, low
        // enough to catch real runaway generation.
        let impliedWordsPerMinute = Double(words.count) / audioDurationSeconds * 60
        guard impliedWordsPerMinute <= 400 else { return false }

        // The same 1-3 word span repeating 5+ times back to back with no
        // other words between repeats — "the the the the the" or a longer
        // phrase looping.
        let lowercased = words.map { $0.lowercased() }
        for spanLength in 1...3 where lowercased.count >= spanLength * 5 {
            var index = 0
            while index + spanLength * 5 <= lowercased.count {
                let span = lowercased[index..<(index + spanLength)]
                var repeats = 1
                var cursor = index + spanLength
                while cursor + spanLength <= lowercased.count,
                      lowercased[cursor..<(cursor + spanLength)].elementsEqual(span) {
                    repeats += 1
                    cursor += spanLength
                }
                if repeats >= 5 { return false }
                index += 1
            }
        }
        return true
    }

    /// A cheap header-only read — no decode, no channel data — just to get
    /// a recording's real duration for `isPlausible`'s speaking-rate
    /// check. `nil` (never thrown) on any failure, which the caller treats
    /// as "unknown," not "reject": a duration lookup failing is never a
    /// reason to block a whole dictation.
    static func audioDurationSeconds(of url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0
        else { return nil }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    static func runSelfTest() -> Bool {
        var passed = true
        func check(_ ok: Bool, _ label: String) {
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): \(label)")
        }

        // A real dictation this session, timed and word-counted precisely.
        let realSentence = "I found this other speech to text app that is " +
            "similar to our app, alternative to wispr flow and local macOS. " +
            "Here is the website link."
        check(isPlausible(realSentence, audioDurationSeconds: 8.16),
              "a real ~124-WPM dictation is plausible")

        check(isPlausible("Okay.", audioDurationSeconds: 0.45),
              "a short, fast single word is plausible")

        check(isPlausible("This has some pauses in it here and there.", audioDurationSeconds: 30),
              "sparse/slow speech (well under 400 WPM) is never rejected — no lower bound")

        // 40 words in 2 seconds = 1200 WPM, three times the ceiling.
        let runaway = Array(repeating: "word", count: 40).joined(separator: " ")
        check(!isPlausible(runaway, audioDurationSeconds: 2),
              "runaway word count relative to duration is rejected")

        check(!isPlausible("the the the the the the", audioDurationSeconds: 3),
              "single-word repetition loop is rejected")
        check(!isPlausible("go on go on go on go on go on and then stop", audioDurationSeconds: 5),
              "multi-word phrase repetition loop is rejected")
        check(isPlausible("the cat sat on the mat and the the dog watched", audioDurationSeconds: 4),
              "a normal, non-consecutive repeat of a common word isn't flagged")

        check(isPlausible("", audioDurationSeconds: 5), "empty text is never rejected (nothing to gate)")
        check(isPlausible("A perfectly normal sentence.", audioDurationSeconds: 0),
              "unknown/zero duration fails open rather than rejecting")

        check(isPlausible("I need to back up the database.", audioDurationSeconds: 2, confidence: nil),
              "nil confidence (engine doesn't expose it) leaves text-only checks unchanged")
        check(isPlausible("I need to back up the database.", audioDurationSeconds: 2, confidence: 0.9),
              "normal text with high confidence is plausible")
        check(!isPlausible("I need to back up the database.", audioDurationSeconds: 2, confidence: 0.2),
              "low confidence rejects even when the text itself looks completely normal — the same-length-substitution case text-only checks admit they can't see")
        check(isPlausible("I need to back up the database.", audioDurationSeconds: 2,
                           confidence: lowConfidenceThreshold),
              "confidence exactly at the threshold is not rejected (strict less-than)")

        return passed
    }
}
