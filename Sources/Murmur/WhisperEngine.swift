import AVFAudio
import Foundation
import WhisperKit

/// Murmur's optional "Precise" recognition engine: OpenAI's Whisper model
/// running locally via WhisperKit (CoreML on the Neural Engine). Slower to
/// warm up than Apple's engine but stronger on accents and jargon, and it
/// supports vocabulary biasing through the decoder prompt — the user's
/// dictionary, snippets and learned terms are fed in before recognition.
/// The model downloads once into Application Support; recognition is offline.
@MainActor
final class WhisperEngine {

    static let availableModels: [(id: String, label: String)] = [
        ("base", "Base — fastest, ~150 MB"),
        ("small", "Small — balanced, recommended, ~500 MB"),
        ("distil-whisper_distil-large-v3_turbo",
         "Distil Large v3 — fast + precise, English only, ~600 MB"),
        ("large-v3-v20240930_turbo", "Large v3 Turbo — most precise, slow, ~1.6 GB"),
    ]

    /// True for model variants that drop Whisper's multilingual capacity
    /// for speed — Distil-Whisper's large-v3 distillation is English-only,
    /// so offering another language for it in the Settings/HUD pickers
    /// would just set up a silent mistranscription.
    static func isEnglishOnly(_ model: String) -> Bool {
        model == "distil-whisper_distil-large-v3_turbo"
    }

    /// The Whisper family's full trained-language set, as ISO 639-1 codes.
    /// Shared with `WhisperCppEngine`, which runs the same underlying
    /// models through a different backend — sourced from WhisperKit's own
    /// token table (`Constants.languages` maps display name to code, with
    /// a few name aliases pointing at the same code) rather than hand-kept
    /// in sync with it.
    static var supportedLanguageCodes: [String] {
        Array(Set(Constants.languages.values))
    }

    /// Status line for the UI (loading/downloading/transcribing); nil clears.
    var onStatus: ((String?) -> Void)?

    private var loadTask: Task<WhisperKit, Error>?
    private var loadedModel: String?
    /// Set only after the pipeline has fully loaded and prewarmed.
    private var readyModel: String?

    private var modelsDirectory: URL {
        AppPaths.supportDirectory.appendingPathComponent(
            "whisper-models", isDirectory: true)
    }

    /// True once the pipeline is loaded in memory and can transcribe now.
    func isReady(model: String) -> Bool {
        readyModel == model
    }

    /// Where WhisperKit unpacks its CoreML repos.
    private var repoDirectory: URL {
        modelsDirectory.appendingPathComponent(
            "models/argmaxinc/whisperkit-coreml", isDirectory: true)
    }

    /// Models confirmed present on disk. Only *positive* results are cached:
    /// a model can finish downloading later, but a complete one never
    /// becomes incomplete, so a `true` can never go stale.
    private var downloadedModels: Set<String> = []

    /// True once all three CoreML components exist locally (no download
    /// needed).
    ///
    /// This is called from `whisperModelDetail` in the Settings view body,
    /// which SwiftUI re-evaluates on every state change. The previous
    /// implementation answered it with `subpathsOfDirectory` — a *deep*
    /// enumeration of the whole model tree (~300 files, ~6ms of main-thread
    /// I/O) — so simply having Settings open re-walked several gigabytes'
    /// worth of directory entries continuously. This checks the three exact
    /// paths instead, and remembers the answer.
    func isModelDownloaded(_ model: String) -> Bool {
        if downloadedModels.contains(model) { return true }

        let fileManager = FileManager.default
        // WhisperKit prefixes most repo folders ("base" → "openai_whisper-base")
        // but not all ("distil-whisper_distil-large-v3_turbo" is verbatim), so
        // match on suffix rather than trying to reproduce the naming scheme.
        guard let folders = try? fileManager.contentsOfDirectory(
            atPath: repoDirectory.path),
            let folder = folders.first(where: { $0 == model || $0.hasSuffix(model) })
        else { return false }

        let base = repoDirectory.appendingPathComponent(folder, isDirectory: true)
        let complete = ["AudioEncoder", "TextDecoder", "MelSpectrogram"]
            .allSatisfy { component in
                fileManager.fileExists(atPath: base
                    .appendingPathComponent("\(component).mlmodelc", isDirectory: true)
                    .appendingPathComponent("coremldata.bin").path)
            }
        if complete { downloadedModels.insert(model) }
        return complete
    }

    /// Kicks off model load/download in the background.
    func preload(model: String) {
        Task { _ = try? await self.pipeline(model: model) }
    }

    private func pipeline(model: String) async throws -> WhisperKit {
        if loadedModel == model, let loadTask {
            return try await loadTask.value
        }
        loadTask?.cancel()
        loadedModel = model
        readyModel = nil

        let needsDownload = !isModelDownloaded(model)
        onStatus?(needsDownload
            ? "Downloading Whisper model (one-time)"
            : "Loading Whisper model")
        let directory = modelsDirectory
        let task = Task { () -> WhisperKit in
            let config = WhisperKitConfig(
                model: model,
                downloadBase: directory,
                verbose: false,
                logLevel: .error,
                prewarm: true,
                load: true,
                download: true)
            return try await WhisperKit(config)
        }
        loadTask = task
        defer { onStatus?(nil) }
        let pipe = try await task.value
        if loadedModel == model {
            readyModel = model
        }
        return pipe
    }

    /// `confidence` is `exp` of the token-weighted mean of every segment's
    /// `avgLogprob` — the geometric-mean per-token probability, on the same
    /// 0–1 scale `TranscriptionPlausibility.isPlausible` expects. `nil`
    /// only when the decode produced no tokens at all.
    func transcribe(
        fileAt url: URL, model: String, localeID: String,
        biasTerms: [String]) async throws -> (text: String, confidence: Float?) {
        let pipe = try await pipeline(model: model)

        var options = DecodingOptions()
        options.language = String(localeID.prefix(while: { $0 != "-" })).lowercased()
        // Timestamps aren't needed for dictation — skipping them trims
        // decoding work. VAD chunking only pays off on long recordings.
        options.withoutTimestamps = true
        // Already WhisperKit's own default (0.6, matching OpenAI's
        // reference), but set explicitly rather than left implicit — this
        // is what a segment's `noSpeechProb` gets compared against below,
        // so the two numbers need to stay visibly in sync even if
        // WhisperKit's own default ever changes.
        options.noSpeechThreshold = Self.noSpeechThreshold
        // WhisperKit's own default is `false` — without this, segment text
        // comes back with literal `<|startoftranscript|>`/`<|en|>`/
        // `<|endoftext|>`-style tokens embedded in it, which then went
        // straight through to the user uncaught (TextFormatter doesn't
        // strip them either). Found via a benchmark run: every Whisper
        // transcription was otherwise correct, just wrapped in these.
        options.skipSpecialTokens = true
        if let audioFile = try? AVAudioFile(forReading: url),
           audioFile.fileFormat.sampleRate > 0 {
            let seconds = Double(audioFile.length) / audioFile.fileFormat.sampleRate
            options.chunkingStrategy = seconds > 25 ? .vad : nil
        } else {
            options.chunkingStrategy = .vad
        }

        // Vocabulary biasing: Whisper conditions on a decoder prompt, so
        // naming the user's terms makes it far likelier to spell them right.
        // The same one short sentence whisper.cpp gets (`WhisperPrompt`: the
        // user's own words first, all of them, then Murmur's built-in names)
        // — the old "Vocabulary: " list of up to 150 terms made whisper.cpp
        // put commas at pauses and was cut off at random. `tokens.prefix(200)`
        // below stays as the token-level safety net.
        if let tokenizer = pipe.tokenizer,
           let prompt = WhisperPrompt.text(for: biasTerms, personal: LearnedStore.personalTermKeys()) {
            let tokens = tokenizer.encode(text: " " + prompt)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            options.promptTokens = Array(tokens.prefix(200))
            options.usePrefillPrompt = true
        }

        onStatus?("Transcribing (Whisper)")
        defer { onStatus?(nil) }
        let results = try await pipe.transcribe(
            audioPath: url.path, decodeOptions: options)
        // `noSpeechThreshold` above only controls WhisperKit's internal
        // decoding fallback (whether to retry at a different temperature)
        // — nothing in WhisperKit itself drops a segment's text from
        // `results.map(\.text)` just because it decided the segment was
        // silence. A per-segment `noSpeechProb` filter used to be applied
        // here too, on the same reasoning as the whisper.cpp engine — and
        // removed for the same reason: measured unreliable against actual
        // hallucinations (a confident "Thank you." scores near-zero, not
        // uncertain), so a signal that weak had no safe margin left to
        // also spare real trailing speech, and it was silently truncating
        // genuine dictations. `HallucinationFilter` (whole-output phrase
        // matching) and `AudioRecorder`'s sustained-signal gate already
        // cover the silence case this was for.
        let segments = results.flatMap(\.segments)
        var text = segments
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // `avgLogprob` is per decode *window* — every segment cut from one
        // window carries that window's value (see WhisperKit's
        // `SegmentSeeker`) — so weighting each segment by its token count
        // counts each window once, in proportion to how much it said,
        // rather than letting a two-token segment outvote a fifty-token one.
        // This is the exact number WhisperKit itself compares against
        // `logProbThreshold` (-1.0, OpenAI's reference value) to decide
        // whether to retry at a higher temperature, so a result that still
        // scores below it here has already failed every fallback attempt.
        //
        // Not a fix for a *confidently* wrong decode: a hallucinated
        // sign-off on silence scores as high-confidence too (see the
        // `noSpeechProb` note above) — that stays `HallucinationFilter`'s
        // job. This catches the unsure-and-still-wrong case instead.
        let tokenCount = segments.reduce(0) { $0 + $1.tokens.count }
        let confidence: Float? = tokenCount == 0 ? nil : {
            let weightedLogProb = segments.reduce(0.0) {
                $0 + Double($1.avgLogprob) * Double($1.tokens.count)
            }
            return Float(exp(weightedLogProb / Double(tokenCount)))
        }()
        // A name the model was unsure of, checked against the user's names — see `UnsureWordFix`. Each token's own
        // log probability is already in the result, so this costs no extra decoding.
        if UnsureWordFix.isEnabled, options.language == "en", let tokenizer = pipe.tokenizer {
            let special = tokenizer.specialTokens.specialTokenBegin
            let pieces = segments.flatMap { segment in
                zip(segment.tokens, segment.tokenLogProbs).compactMap { id, logProbs -> (text: String, p: Float)? in
                    guard id < special, let logProb = logProbs[id] else { return nil }
                    return (tokenizer.decode(tokens: [id]), exp(logProb))
                }
            }
            if let fixed = UnsureWordFix.fix(text, words: UnsureWordFix.words(fromTokens: pieces), terms: biasTerms) {
                dictationLog.info("WhisperKit: fixed \(fixed.changes.count) unsure name(s)")
                NameFixLog.record(fixed.changes, engine: "WhisperKit")
                text = fixed.text
            }
        }
        return (text, confidence)
    }

    /// OpenAI's own reference default — the value most is known about not
    /// causing regressions on ordinary quiet-but-real speech.
    private static let noSpeechThreshold: Float = 0.6
}
