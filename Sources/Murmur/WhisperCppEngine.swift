import AVFAudio
import Foundation
import whisper

/// A second "Precise" recognition engine, alongside `WhisperEngine`: the same
/// Whisper models, run through whisper.cpp's Metal backend instead of
/// WhisperKit/CoreML. Benchmarking on this machine showed whisper.cpp
/// transcribing 2.9–4.3× faster, likely because it runs on the GPU rather
/// than the power-efficient Neural Engine — a speed/battery tradeoff worth
/// letting the user pick for themselves rather than deciding for them.
///
/// Mirrors `WhisperEngine`'s public shape closely so the two are
/// interchangeable at the call site. The one structural difference:
/// whisper.cpp's C API is synchronous and blocking, where WhisperKit's is
/// already async — so every call into it here goes through `Task.detached`
/// rather than a plain inherited `Task`, which would otherwise block this
/// actor (and the UI) for the duration of the call.
@MainActor
final class WhisperCppEngine {

    static let availableModels: [(id: String, label: String)] = [
        ("tiny", "Tiny — fastest, ~75 MB"),
        ("base", "Base — fast, ~140 MB"),
        ("small", "Small — balanced, ~465 MB"),
        ("large-v3-turbo", "Large v3 Turbo — precise and fast, ~1.5 GB"),
        // The full model (32 decoder layers to Turbo's 4). Measured 2026-09-30 on 150 realistic English recordings:
        // accented voices 5.8% → 4.6% errors, short dictations 8.6% → 5.3%, but native voices 0.9% → 1.6%, long ones
        // 1.8% → 2.2%, and 1.6–2.5× slower — so a choice for accented speakers, not the default.
        ("large-v3", "Large v3 — best for accents, slower, ~3.1 GB"),
        ("large-v3-lv", "Large v3 (Latvian fine-tune) — Latvian only, ~1.7 GB"),
    ]

    /// The one language a fine-tuned model is actually good for, if it's
    /// restricted to one — `nil` for the general multilingual models above.
    /// `large-v3-lv` (University of Latvia AiLab's Interspeech 2025
    /// fine-tune of whisper-large-v3, trained on Common Voice 19 + the
    /// LATE-Media broadcast corpus) measures 3.2% WER on Latvian versus
    /// Parakeet v3's 22.84% — but it's fine-tuned purely on Latvian audio,
    /// with no published data on retained multilingual competence, so
    /// unlike the general models it shouldn't be offered as a substitute
    /// for them on any other language. Mirrors `WhisperEngine.isEnglishOnly`
    /// in spirit, just specialized toward a different single language.
    static func restrictedLanguage(for model: String) -> String? {
        model == "large-v3-lv" ? "lv" : nil
    }

    /// Status line for the UI (loading/downloading/transcribing); nil clears.
    var onStatus: ((String?) -> Void)?

    /// The decode in flight, if any. whisper.cpp's context runs one decode at a time, and since a long dictation is
    /// decoded while it's spoken (`LiveChunkSession`), a stretch can still be running when that dictation is
    /// cancelled and the next one starts — so every decode waits for the one before it.
    private var decodeInFlight: Task<Void, Never>?

    // OpaquePointer doesn't conform to Sendable, so the compiler can't see
    // that access here is safe — but it is: both are only ever touched from
    // `pipeline(model:)`, which is itself actor-isolated, so there's no
    // concurrent access to prove. `nonisolated(unsafe)` says so explicitly
    // rather than leaving it as an unexplained warning.
    nonisolated(unsafe) private var context: OpaquePointer?
    nonisolated(unsafe) private var loadTask: Task<OpaquePointer, Error>?
    private var loadedModel: String?
    /// Set only after the context has fully loaded.
    private var readyModel: String?

    private var modelsDirectory: URL {
        AppPaths.supportDirectory.appendingPathComponent(
            "whispercpp-models", isDirectory: true)
    }

    private func modelFileURL(_ model: String) -> URL {
        modelsDirectory.appendingPathComponent("ggml-\(model).bin")
    }

    /// True once the context is loaded in memory and can transcribe now.
    func isReady(model: String) -> Bool {
        readyModel == model
    }

    /// Models confirmed present on disk. Mirrors `WhisperEngine`'s cache:
    /// only positive results are remembered, since a downloaded model file
    /// never becomes un-downloaded.
    private var downloadedModels: Set<String> = []

    func isModelDownloaded(_ model: String) -> Bool {
        if downloadedModels.contains(model) { return true }
        let exists = FileManager.default.fileExists(atPath: modelFileURL(model).path)
        if exists { downloadedModels.insert(model) }
        return exists
    }

    /// Kicks off model load/download in the background.
    func preload(model: String) {
        Task { _ = try? await self.pipeline(model: model) }
    }

    deinit {
        if let context {
            whisper_free(context)
        }
    }

    private func pipeline(model: String) async throws -> OpaquePointer {
        if loadedModel == model, let loadTask {
            return try await loadTask.value
        }
        loadTask?.cancel()
        let previousContext = context
        loadedModel = model
        readyModel = nil
        context = nil

        let needsDownload = !isModelDownloaded(model)
        onStatus?(needsDownload
            ? "Downloading whisper.cpp model (one-time)"
            : "Loading whisper.cpp model")

        let modelURL = modelFileURL(model)
        let task = Task.detached(priority: .userInitiated) { () -> OpaquePointer in
            if needsDownload {
                try await Self.download(model: model, to: modelURL)
            }
            var params = whisper_context_default_params()
            params.use_gpu = true
            guard let ctx = whisper_init_from_file_with_params(modelURL.path, params)
            else { throw WhisperCppError.loadFailed }
            return ctx
        }
        loadTask = task
        defer { onStatus?(nil) }
        let ctx = try await task.value
        // A newer call already superseded this one (model switched again
        // mid-load) — free what we just built instead of leaking it.
        guard loadedModel == model else {
            whisper_free(ctx)
            throw CancellationError()
        }
        context = ctx
        readyModel = model
        // Freed only now that the new context is fully in place, so a
        // transcription already in flight against the old one isn't pulled
        // out from under it.
        if let previousContext { whisper_free(previousContext) }
        return ctx
    }

    /// `confidence` is `exp` of the mean per-token log-probability over the
    /// decode's text tokens — the same geometric-mean statistic
    /// `WhisperEngine` reports, so both Whisper engines land on the same
    /// 0–1 scale `TranscriptionPlausibility.isPlausible` expects. `nil`
    /// only when the decode produced no text tokens at all.
    func transcribe(
        fileAt url: URL, model: String, localeID: String,
        biasTerms: [String], prompt promptOverride: String? = nil) async throws -> (text: String, confidence: Float?) {
        try await transcribe(
            samples: try Self.pcm16kMono(from: url), model: model, localeID: localeID, biasTerms: biasTerms,
            prompt: promptOverride)
    }

    /// The same, for 16 kHz mono samples already in memory — one stretch of a longer dictation (`LiveChunkSession`).
    /// `reportsStatus` false for a stretch decoded while the speaker is still talking: the status line would say
    /// "Transcribing" in the middle of "Listening".
    func transcribe(
        samples: [Float], model: String, localeID: String, biasTerms: [String], reportsStatus: Bool = true,
        prompt promptOverride: String? = nil
    ) async throws -> (text: String, confidence: Float?) {
        let ctx = try await pipeline(model: model)
        let language = String(localeID.prefix(while: { $0 != "-" })).lowercased()
        // A little silence in front of the first word: Whisper hears it better when the audio doesn't open on speech.
        // Measured on the Deepgram test set (2026-09-29): 400 ms cut first-word errors 38 → 30 and all errors
        // 3.66% → 3.46%. Skipped when it would push the recording into another 30-second window, which costs a whole
        // extra decode. `MURMUR_WHISPERCPP_LEADPAD_MS` overrides it from the command line (0 = off).
        var samples = samples
        let lead = ProcessInfo.processInfo.environment["MURMUR_WHISPERCPP_LEADPAD_MS"].flatMap(Int.init)
            ?? Self.leadingSilenceMilliseconds
        let window = 30 * 16000
        if lead > 0, (samples.count + lead * 16 + window - 1) / window == (samples.count + window - 1) / window {
            samples = [Float](repeating: 0, count: lead * 16) + samples
        }

        // Vocabulary biasing: the direct whisper.cpp equivalent of
        // WhisperKit's decoder prompt tokens — prepended free-text context
        // rather than pre-encoded tokens, but the same intent. 150, not
        // 60 — see WhisperEngine's matching comment: `biasTerms()` now
        // leads with Murmur's ~110 built-in developer terms, and 60 was
        // tight enough that personal terms alone already crowded all of
        // them out. No secondary token-level cap here (unlike
        // WhisperEngine's `tokens.prefix(200)`) — whisper.cpp's own
        // `initial_prompt` handling truncates internally if this is ever
        // too long for its context window, so this doesn't risk a crash.
        // Names and unusual words only, the user's own first, one plain sentence, short enough never to be cut —
        // see `WhisperPrompt` for what the old 150-term "Vocabulary:" list did to punctuation and accuracy.
        // A shell gets an example of commands instead (`WhisperPrompt.shell`), so it writes `git rebase -i HEAD~3`.
        var prompt = promptOverride ?? WhisperPrompt.text(for: biasTerms, personal: LearnedStore.personalTermKeys())
        // Debug only, for comparing prompts on the same audio from the command line: "none" for no prompt.
        if let override = ProcessInfo.processInfo.environment["MURMUR_WHISPERCPP_PROMPT"] {
            prompt = override == "none" ? nil : override
        }
        if ProcessInfo.processInfo.environment["MURMUR_WHISPERCPP_SEGMENTS"] != nil {
            FileHandle.standardError.write(Data("PROMPT \(prompt ?? "(none)")\n".utf8))
        }
        dictationLog.info(
            "whisper.cpp prompt: terms=\(biasTerms.count) chars=\(prompt?.count ?? 0) preview=\(String((prompt ?? "").prefix(300)), privacy: .public)")

        if reportsStatus { onStatus?("Transcribing (whisper.cpp)") }
        defer { if reportsStatus { onStatus?(nil) } }

        let previous = decodeInFlight
        let decode = Task.detached(priority: .userInitiated) { () throws -> (text: String, confidence: Float?, words: [UnsureWordFix.Word]) in
            await previous?.value
            return try Self.runFull(ctx: ctx, samples: samples, language: language, prompt: prompt)
        }
        decodeInFlight = Task { _ = try? await decode.value }
        let started = Date()
        let decoded = try await decode.value
        var result = (text: decoded.text, confidence: decoded.confidence)
        // A name the model was unsure of, checked against the user's names — see `UnsureWordFix`.
        if UnsureWordFix.isEnabled, language == "en",
           let fixed = UnsureWordFix.fix(decoded.text, words: decoded.words, terms: biasTerms) {
            dictationLog.info("whisper.cpp: fixed \(fixed.changes.count) unsure name(s)")
            NameFixLog.record(fixed.changes, engine: "whisper.cpp")
            result.text = fixed.text
        }
        // Durations only. The real-time factor is what tells whether decode
        // is the bottleneck for a given dictation length.
        dictationLog.info(
            "whisper.cpp decode: \(Int(Date().timeIntervalSince(started) * 1000)) ms for \(String(format: "%.1f", Double(samples.count) / 16000)) s of audio")
        return result
    }

    /// OpenAI's own reference default — governs `no_speech_thold` below,
    /// whisper.cpp's own internal decoding-fallback signal. Not used as a
    /// post-hoc filter here (see `runFull`'s comment on why not).
    nonisolated private static let noSpeechThreshold: Float = 0.6

    /// Silence put in front of every decode — see `transcribe(samples:…)`.
    static let leadingSilenceMilliseconds = 400

    /// The actual `whisper_full` call. Split out from `transcribe` so the
    /// `const char *` lifetimes (`language`, `initial_prompt`) stay scoped to
    /// `withCString`, rather than managed by hand with `strdup`/`free`.
    nonisolated private static func runFull(
        ctx: OpaquePointer, samples: [Float], language: String, prompt: String?
    ) throws -> (text: String, confidence: Float?, words: [UnsureWordFix.Word]) {
        try language.withCString { languagePtr in
            try withOptionalCString(prompt) { promptPtr in
                // Debug only, for comparing decoding strategies on the same audio from the command line: a beam
                // width (e.g. 5) instead of greedy decoding.
                let beamWidth = ProcessInfo.processInfo.environment["MURMUR_WHISPERCPP_BEAM"].flatMap { Int32($0) } ?? 1
                var params = whisper_full_default_params(
                    beamWidth > 1 ? WHISPER_SAMPLING_BEAM_SEARCH : WHISPER_SAMPLING_GREEDY)
                if beamWidth > 1 { params.beam_search.beam_size = beamWidth }
                params.language = languagePtr
                params.detect_language = false
                params.initial_prompt = promptPtr
                // Debug only (translation research, 2026-10-02): whisper's own speech → English translation.
                if ProcessInfo.processInfo.environment["MURMUR_WHISPERCPP_TRANSLATE"] != nil { params.translate = true }
                // OpenAI's own reference default — the value most is known
                // about not causing regressions on ordinary quiet-but-real
                // speech. Governs whisper.cpp's internal decoding fallback
                // (whether to retry at a different temperature) but does
                // NOT by itself drop a segment's text from the output —
                // `no_speech_prob` is checked directly below for that.
                params.no_speech_thold = noSpeechThreshold
                // Each dictation is a fresh, unrelated recording — the
                // context is reused across calls purely to avoid reloading
                // the model, so it must not carry decoder state from a
                // previous, unrelated dictation into this one.
                params.no_context = true
                params.single_segment = false
                params.print_progress = false
                params.print_special = false
                params.print_realtime = false
                params.print_timestamps = false

                let status = samples.withUnsafeBufferPointer { buffer in
                    whisper_full(ctx, params, buffer.baseAddress, Int32(buffer.count))
                }
                guard status == 0 else { throw WhisperCppError.transcribeFailed }

                // No per-segment no_speech_prob filter here — it used to
                // drop any segment scoring above noSpeechThreshold, meant
                // to catch hallucinated sign-offs on silence. In practice
                // it occasionally fired on genuine trailing speech
                // instead, silently truncating real dictations. A
                // confidently-hallucinated "Thank you." measured at
                // ~0.00002 (i.e. the model is sure about its own invented
                // completion, not uncertain) — a signal that weak against
                // its actual target has no safe margin left to also spare
                // real speech. `HallucinationFilter` (whole-output phrase
                // matching) and `AudioRecorder`'s sustained-signal gate
                // already cover the silence case this was for.
                // Per-*token* `plog`, not the per-segment `no_speech_prob`
                // above — a different, finer-grained signal than the one
                // that proved unreliable. Read from the same
                // `whisper_token_data` the decode already filled in, so it
                // costs nothing extra. Only text tokens count: ids at or
                // above `whisper_token_eot` are timestamp/special markers
                // whose log-probs say nothing about how sure the model was
                // of the words themselves.
                let endOfText = whisper_token_eot(ctx)
                let dumpSegments = ProcessInfo.processInfo.environment["MURMUR_WHISPERCPP_SEGMENTS"] != nil
                var segments: [(text: String, rms: Float, logProbs: [Double], tokens: [(text: String, p: Float)])] = []
                for i in 0..<whisper_full_n_segments(ctx) {
                    guard let segment = whisper_full_get_segment_text(ctx, i) else { continue }
                    let segmentText = String(cString: segment)
                    // whisper.cpp reports centiseconds; a span past the end of the audio (its zero padding) is silent.
                    let t0 = Double(whisper_full_get_segment_t0(ctx, i)) / 100
                    let t1 = Double(whisper_full_get_segment_t1(ctx, i)) / 100
                    let level = Self.rms(samples, from: t0, to: t1)
                    if dumpSegments {
                        FileHandle.standardError.write(Data(String(
                            format: "SEG %6.2f-%6.2f rms=%.4f %@\n", t0, t1, level, segmentText).utf8))
                    }
                    var logProbs: [Double] = []
                    var tokens: [(text: String, p: Float)] = []
                    for t in 0..<whisper_full_n_tokens(ctx, i) {
                        let token = whisper_full_get_token_data(ctx, i, t)
                        guard token.id < endOfText else { continue }
                        logProbs.append(Double(token.plog))
                        if let piece = whisper_full_get_token_text(ctx, i, t) { tokens.append((String(cString: piece), token.p)) }
                    }
                    segments.append((segmentText, level, logProbs, tokens))
                }
                // A sign-off over silence — the "Thank you." Whisper invents for the empty end of its last
                // 30-second window — is dropped; see `WhisperPrompt.keptSegments`.
                let kept = WhisperPrompt.keptSegments(segments.map { ($0.text, $0.rms) })
                if kept.count < segments.count {
                    dictationLog.info("whisper.cpp: dropped \(segments.count - kept.count) sign-off segment(s) over silence")
                }
                var text = ""
                var logProbSum = 0.0
                var tokenCount = 0
                var tokens: [(text: String, p: Float)] = []
                for index in kept {
                    text += segments[index].text
                    logProbSum += segments[index].logProbs.reduce(0, +)
                    tokenCount += segments[index].logProbs.count
                    tokens += segments[index].tokens
                }
                let confidence: Float? = tokenCount == 0
                    ? nil : Float(exp(logProbSum / Double(tokenCount)))
                return (text.trimmingCharacters(in: .whitespacesAndNewlines), confidence,
                        UnsureWordFix.words(fromTokens: tokens))
            }
        }
    }

    /// Root-mean-square level of `samples` (16 kHz) between two times; 0 for a span past the end of the audio.
    nonisolated static func rms(_ samples: [Float], from start: Double, to end: Double) -> Float {
        let lower = max(0, min(samples.count, Int(start * 16_000)))
        let upper = max(lower, min(samples.count, Int(end * 16_000)))
        guard upper > lower else { return 0 }
        var sum: Float = 0
        for i in lower..<upper { sum += samples[i] * samples[i] }
        return (sum / Float(upper - lower)).squareRoot()
    }

    nonisolated private static func withOptionalCString<T>(
        _ string: String?, _ body: (UnsafePointer<CChar>?) throws -> T
    ) rethrows -> T {
        if let string {
            return try string.withCString(body)
        }
        return try body(nil)
    }

    // MARK: - Audio

    /// Converts the recorder's `.caf` (whatever rate/channel layout the
    /// input device was actually running at — see `AudioRecorder`) into the
    /// 16kHz mono Float32 PCM `whisper_full` requires.
    nonisolated static func pcm16kMono(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let inputFormat = file.processingFormat
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16000,
            channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        else { throw WhisperCppError.audioConversionFailed }

        let inputFrameCount = AVAudioFrameCount(file.length)
        guard inputFrameCount > 0,
              let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: inputFormat, frameCapacity: inputFrameCount)
        else { throw WhisperCppError.audioConversionFailed }
        try file.read(into: inputBuffer)

        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 1024
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat, frameCapacity: outputCapacity)
        else { throw WhisperCppError.audioConversionFailed }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            // End of stream, not "no data now": the converter holds back its last few milliseconds until it is told
            // the input is over, so the end of the final word was left inside it.
            guard !suppliedInput else {
                outStatus.pointee = .endOfStream
                return nil
            }
            suppliedInput = true
            outStatus.pointee = .haveData
            return inputBuffer
        }
        guard status != .error else {
            throw conversionError ?? WhisperCppError.audioConversionFailed
        }
        guard let channelData = outputBuffer.floatChannelData else {
            throw WhisperCppError.audioConversionFailed
        }
        return Array(UnsafeBufferPointer(
            start: channelData[0], count: Int(outputBuffer.frameLength)))
    }

    // MARK: - Model download

    /// Where each model's GGML file actually lives. Everything downloads
    /// from ggerganov's own conversions except the Latvian fine-tune,
    /// which is a different upstream project (see `restrictedLanguage`)
    /// hosted under its own repo with its own filename — AiLab publishes
    /// several quantization levels; q8_0 is the one used here since
    /// accuracy is the entire point of offering this model at all, and
    /// q8_0 is close to full F16 quality without the full 3.1 GB download.
    nonisolated private static func downloadSource(for model: String) -> URL? {
        switch model {
        case "large-v3-lv":
            return URL(string:
                "https://huggingface.co/AiLab-IMCS-UL/whisper-large-v3-lv-late-cv19/resolve/main/ggml-model-q8_0.bin")
        default:
            return URL(string:
                "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-\(model).bin")
        }
    }

    nonisolated private static func download(model: String, to destination: URL) async throws {
        guard let source = downloadSource(for: model)
        else { throw WhisperCppError.downloadFailed }

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let (tempURL, response) = try await URLSession.shared.download(from: source)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { throw WhisperCppError.downloadFailed }

        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }
}

enum WhisperCppError: LocalizedError {
    case loadFailed, transcribeFailed, audioConversionFailed, downloadFailed

    var errorDescription: String? {
        switch self {
        case .loadFailed: return "whisper.cpp could not load the model."
        case .transcribeFailed: return "whisper.cpp transcription failed."
        case .audioConversionFailed: return "Could not convert the recording for whisper.cpp."
        case .downloadFailed: return "Could not download the whisper.cpp model."
        }
    }
}
