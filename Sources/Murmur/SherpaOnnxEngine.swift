import AVFAudio
import CMurmurSherpa
import Foundation
import FluidAudio

/// A fifth recognition engine, alongside `WhisperEngine`, `WhisperCppEngine`,
/// and `ParakeetEngine`: currently four selectable models, all run via
/// k2-fsa's sherpa-onnx C API (`Vendor/sherpa-onnx.xcframework`, vendored
/// from the official `sherpa-onnx` PyPI wheel — see NOTICE.md). SenseVoice
/// (Alibaba's Apache-2.0 multilingual model) was screened first as a
/// benchmark-only candidate (`scripts/benchmark_engines.py`,
/// `scripts/_sherpa_onnx_worker.py`) — tied the other four engines at 3.2%
/// WER on a saturated synthetic test set but ran roughly 6x faster,
/// CPU-only with no Neural Engine acceleration at all. Canary (NVIDIA's
/// 180M "flash" model, genuinely multilingual: en/es/de/fr) was added
/// alongside it once sherpa-onnx itself had cleared the "does this actually
/// work as a real Swift engine" bar SenseVoice's screening was for.
///
/// FunASR Nano and Qwen3-ASR are a different shape from every other model
/// here: instead of a direct CTC/transducer decode, both feed an encoder
/// into a small LLM decoder (Qwen3-0.6B) that generates the transcript
/// token-by-token, the same kind of generative decode the on-device rewrite
/// model already does for Styles/Transforms — fully local, no network
/// call, just a different (heavier) architecture than SenseVoice/Canary's
/// single-pass decode. Genuinely large next to everything else here
/// (~1 GB and ~980 MB respectively, vs. 70–285 MB for the others) and
/// slower to load (~1.5–2s), but both cleared the bar that actually
/// matters — the user's own real dictation, not just the synthetic-audio
/// taste test every model gets first (see the class-level lesson on
/// Zipformer/Moonshine below, which passed that same synthetic test and
/// then failed on real speech). Confirmed accurate, same standing as
/// SenseVoice/Canary now.
///
/// **Two other families — Zipformer and Moonshine — were built, tried, and
/// pulled from `availableModels`.** Real dictation testing (not just the
/// synthetic `say`-generated audio every model was screened on) found both
/// made noticeably more transcription errors than SenseVoice/Canary, which
/// were accurate throughout — Zipformer on a whole sentence, Moonshine
/// (even after upgrading "tiny" → "base") on a single longer word
/// ("transcribes" → "trans citesmy", a boundary/segmentation miss). Neither
/// had a further lever to pull once found: Zipformer's "medium" and "large"
/// LibriHeavy punct-case checkpoints are byte-identical in encoder size
/// (259.8 MB fp32, both — different training runs of the same capacity,
/// not bigger models), and Moonshine "base" is Useful Sensors' own largest
/// size — there's no bigger Moonshine checkpoint to try. Both are pulled
/// from `availableModels` the same way `ParakeetEngine` hides its "flash"
/// model — the working code paths (`family`, `directoryName`,
/// `createRecognizer`, `download`) are untouched and still reachable via
/// `--engine sherpa --sherpa-model zipformer-en` / `moonshine-base-en` on
/// the CLI, in case better checkpoints show up later; they're just not
/// offered as choices.
///
/// A fifth family, Zipformer CTC (would've been an even-faster CTC variant
/// of the Zipformer architecture), was evaluated and never added at all:
/// its only available English checkpoint has the identical flat-uppercase,
/// no-punctuation problem the plain Zipformer transducer checkpoint had —
/// confirmed against the Python reference bindings — and unlike the
/// transducer, no properly-cased alternative checkpoint exists in the
/// sherpa-onnx model zoo to swap in.
///
/// Unlike WhisperKit/whisper.cpp/Parakeet, sherpa-onnx runs entirely on CPU
/// via ONNX Runtime — there's no CoreML/ANE backend for it, so its speed
/// advantage over the ANE-accelerated engines is real architecture, not a
/// measurement artifact, even though the benchmark's WER tie isn't yet a
/// meaningful accuracy signal (see the memory this was screened under).
///
/// The huge, deeply-nested `SherpaOnnxOfflineRecognizerConfig` C struct
/// (~20 alternate model-family sub-configs) is deliberately never touched
/// from Swift directly — `CMurmurSherpa` (`Sources/CMurmurSherpa`) does the
/// zero-init and per-family field selection in C, and hands back a plain
/// opaque handle plus a few functions, one constructor per model family.
/// Mirrors `WhisperCppEngine`'s shape closely (same synchronous-C-API-via-
/// `Task.detached` structure) so the five engines stay interchangeable at
/// the call site.
@MainActor
final class SherpaOnnxEngine {

    /// Zipformer and Moonshine stay out of this list — see the class doc
    /// comment — but are still fully functional; pass `--sherpa-model
    /// zipformer-en` or `moonshine-base-en` on the CLI to reach them
    /// directly.
    static let availableModels: [(id: String, label: String)] = [
        ("sense-voice-small", "SenseVoice Small — English only, ~155 MB"),
        ("canary-180m-flash", "Canary 180M Flash — NVIDIA, English only, ~155 MB"),
        ("funasr-nano", "FunASR Nano — LLM-backed, English only, ~1 GB"),
        ("qwen3-asr", "Qwen3-ASR — LLM-backed, English only, ~980 MB"),
    ]

    /// SenseVoice and Canary are both natively multilingual (SenseVoice:
    /// zh/en/ja/ko/yue; Canary: en/es/de/fr), but only English has actually
    /// been measured against Murmur's own test material — the rest are
    /// unverified here, same as every other engine's language list. Mirrors
    /// `ParakeetEngine.supportedLanguageCodes`'s own rule: only offer a
    /// language once WER data backs it, not just because the model
    /// nominally supports it. Zipformer and Moonshine aren't a policy
    /// restriction the same way — both are English-only models with no
    /// other language to weigh offering.
    static func supportedLanguageCodes(for model: String) -> [String] {
        ["en"]
    }

    /// Status line for the UI (loading/downloading/transcribing); nil clears.
    var onStatus: ((String?) -> Void)?

    // UnsafeMutableRawPointer? doesn't conform to Sendable, so the compiler
    // can't see that access here is safe — but it is: both are only ever
    // touched from `pipeline(model:)`, which is itself actor-isolated, so
    // there's no concurrent access to prove. Same reasoning as
    // `WhisperCppEngine`'s matching `OpaquePointer` properties.
    nonisolated(unsafe) private var recognizer: MurmurSherpaRecognizer?
    nonisolated(unsafe) private var loadTask: Task<MurmurSherpaRecognizer, Error>?
    private var loadedModel: String?
    /// Set only after the recognizer has fully loaded.
    private var readyModel: String?

    /// The six model families this engine can build a recognizer for —
    /// each has its own file layout and download source, so every
    /// per-model switch below dispatches on this rather than on the raw
    /// `model` id string directly.
    private enum ModelFamily {
        case senseVoice, zipformerEn, moonshineBaseEn, canary180mFlash
        case funasrNano, qwen3Asr
    }

    nonisolated private static func family(for model: String) -> ModelFamily {
        switch model {
        case "zipformer-en": return .zipformerEn
        case "moonshine-base-en": return .moonshineBaseEn
        case "canary-180m-flash": return .canary180mFlash
        case "funasr-nano": return .funasrNano
        case "qwen3-asr": return .qwen3Asr
        default: return .senseVoice
        }
    }

    private var modelsDirectory: URL {
        AppPaths.supportDirectory.appendingPathComponent(
            "sherpa-onnx-models", isDirectory: true)
    }

    /// The on-disk folder name for a model — the upstream archive/repo name
    /// for SenseVoice, Moonshine, and Canary (all extracted from a
    /// `.tar.bz2`), a short name of its own for Zipformer, which downloads
    /// its handful of files individually rather than from one archive (see
    /// `download`).
    ///
    /// Moonshine downloads the "base" checkpoint, not "tiny" — direct
    /// real-speech dictation testing (not the clean synthetic `say` audio
    /// every model was screened on) found "tiny" made noticeably more
    /// errors than SenseVoice/Canary; "base" is a genuinely larger model
    /// (61M vs 27M params — confirmed via real file-size differences across
    /// all four ONNX stages, not just a differently-trained same-size
    /// checkpoint), so it's a real accuracy lever, unlike Zipformer's
    /// "medium" vs "large" (see the class doc comment).
    nonisolated private static func directoryName(for model: String) -> String {
        switch family(for: model) {
        case .senseVoice: return "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17"
        case .zipformerEn: return "zipformer-en-libriheavy-punct-case-2023"
        case .moonshineBaseEn: return "sherpa-onnx-moonshine-base-en-int8"
        case .canary180mFlash: return "sherpa-onnx-nemo-canary-180m-flash-en-es-de-fr-int8"
        case .funasrNano: return "sherpa-onnx-funasr-nano-int8-2025-12-30"
        case .qwen3Asr: return "sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25"
        }
    }

    private func modelDirectory(_ model: String) -> URL {
        modelsDirectory.appendingPathComponent(Self.directoryName(for: model), isDirectory: true)
    }

    /// True once the recognizer is loaded in memory and can transcribe now.
    func isReady(model: String) -> Bool {
        readyModel == model
    }

    /// Models confirmed present on disk. Mirrors `WhisperCppEngine`'s cache:
    /// only positive results are remembered, since a downloaded model never
    /// becomes un-downloaded.
    private var downloadedModels: Set<String> = []

    func isModelDownloaded(_ model: String) -> Bool {
        if downloadedModels.contains(model) { return true }
        let exists = FileManager.default.fileExists(
            at: modelDirectory(model), containsAllOf: Self.requiredFiles(for: model))
        if exists { downloadedModels.insert(model) }
        return exists
    }

    /// Kicks off model load/download in the background.
    func preload(model: String) {
        Task { _ = try? await self.pipeline(model: model) }
    }

    deinit {
        if let recognizer {
            MurmurSherpaDestroyRecognizer(recognizer)
        }
    }

    private func pipeline(model: String) async throws -> MurmurSherpaRecognizer {
        if loadedModel == model, let loadTask {
            return try await loadTask.value
        }
        loadTask?.cancel()
        let previousRecognizer = recognizer
        loadedModel = model
        readyModel = nil
        recognizer = nil

        let needsDownload = !isModelDownloaded(model)
        onStatus?(needsDownload
            ? "Downloading sherpa-onnx model (one-time)"
            : "Loading sherpa-onnx model")

        let dir = modelDirectory(model)
        let task = Task.detached(priority: .userInitiated) { () -> MurmurSherpaRecognizer in
            if needsDownload {
                try await Self.download(model: model, to: dir)
            }
            guard let handle = Self.createRecognizer(model: model, dir: dir)
            else { throw SherpaOnnxError.loadFailed }
            return handle
        }
        loadTask = task
        defer { onStatus?(nil) }
        let handle = try await task.value
        // A newer call already superseded this one (model switched again
        // mid-load) — free what we just built instead of leaking it.
        guard loadedModel == model else {
            MurmurSherpaDestroyRecognizer(handle)
            throw CancellationError()
        }
        recognizer = handle
        readyModel = model
        // Freed only now that the new recognizer is fully in place, so a
        // transcription already in flight against the old one isn't pulled
        // out from under it.
        if let previousRecognizer { MurmurSherpaDestroyRecognizer(previousRecognizer) }
        return handle
    }

    /// Builds the right `CMurmurSherpa` recognizer for a model's family —
    /// the one place that knows which shim constructor and which file names
    /// (within `dir`, already downloaded by this point) go with which model.
    nonisolated private static func createRecognizer(
        model: String, dir: URL
    ) -> MurmurSherpaRecognizer? {
        func path(_ name: String) -> String { dir.appendingPathComponent(name).path }

        switch family(for: model) {
        case .senseVoice:
            return path("model.int8.onnx").withCString { modelPtr in
                path("tokens.txt").withCString { tokensPtr in
                    "en".withCString { langPtr in
                        MurmurSherpaCreateSenseVoiceRecognizer(
                            modelPtr, tokensPtr, langPtr, /* use_itn */ 1,
                            /* num_threads */ 4)
                    }
                }
            }
        case .zipformerEn:
            return path("encoder-epoch-50-avg-15.int8.onnx").withCString { encoderPtr in
                path("decoder-epoch-50-avg-15.int8.onnx").withCString { decoderPtr in
                    path("joiner-epoch-50-avg-15.int8.onnx").withCString { joinerPtr in
                        path("tokens.txt").withCString { tokensPtr in
                            path("bpe.model").withCString { bpePtr in
                                MurmurSherpaCreateZipformerRecognizer(
                                    encoderPtr, decoderPtr, joinerPtr, tokensPtr, bpePtr,
                                    /* num_threads */ 4)
                            }
                        }
                    }
                }
            }
        case .moonshineBaseEn:
            return path("preprocess.onnx").withCString { preprocessorPtr in
                path("encode.int8.onnx").withCString { encoderPtr in
                    path("uncached_decode.int8.onnx").withCString { uncachedPtr in
                        path("cached_decode.int8.onnx").withCString { cachedPtr in
                            path("tokens.txt").withCString { tokensPtr in
                                MurmurSherpaCreateMoonshineRecognizer(
                                    preprocessorPtr, encoderPtr, uncachedPtr, cachedPtr,
                                    tokensPtr, /* num_threads */ 4)
                            }
                        }
                    }
                }
            }
        case .canary180mFlash:
            return path("encoder.int8.onnx").withCString { encoderPtr in
                path("decoder.int8.onnx").withCString { decoderPtr in
                    path("tokens.txt").withCString { tokensPtr in
                        "en".withCString { srcLangPtr in
                            "en".withCString { tgtLangPtr in
                                MurmurSherpaCreateCanaryRecognizer(
                                    encoderPtr, decoderPtr, tokensPtr,
                                    srcLangPtr, tgtLangPtr, /* num_threads */ 4)
                            }
                        }
                    }
                }
            }
        case .funasrNano:
            return path("encoder_adaptor.int8.onnx").withCString { encoderAdaptorPtr in
                path("llm.int8.onnx").withCString { llmPtr in
                    path("embedding.int8.onnx").withCString { embeddingPtr in
                        path("Qwen3-0.6B").withCString { tokenizerDirPtr in
                            MurmurSherpaCreateFunAsrNanoRecognizer(
                                encoderAdaptorPtr, llmPtr, embeddingPtr, tokenizerDirPtr,
                                /* num_threads */ 4)
                        }
                    }
                }
            }
        case .qwen3Asr:
            return path("conv_frontend.onnx").withCString { convFrontendPtr in
                path("encoder.int8.onnx").withCString { encoderPtr in
                    path("decoder.int8.onnx").withCString { decoderPtr in
                        path("tokenizer").withCString { tokenizerDirPtr in
                            MurmurSherpaCreateQwen3AsrRecognizer(
                                convFrontendPtr, encoderPtr, decoderPtr, tokenizerDirPtr,
                                /* num_threads */ 4)
                        }
                    }
                }
            }
        }
    }

    func transcribe(
        fileAt url: URL, model: String, localeID: String,
        biasTerms: [String], vadManager: VadManager? = nil) async throws -> String {
        let handle = try await pipeline(model: model)
        let (samples, sampleRate) = try Self.pcmMono(from: url)

        // No decoder-prompt/vocabulary-biasing mechanism in the offline C
        // API — `biasTerms` is accepted for call-site uniformity with the
        // other three engines and silently ignored, same as `ParakeetEngine`
        // ignores parameters that don't apply to its "flash"/"nemotron"
        // models.
        onStatus?("Transcribing (sherpa-onnx)")
        defer { onStatus?(nil) }

        // FunASR Nano's own documentation (its VAD-integration guide's
        // `max_single_segment_time: 30000`) says long audio needs
        // segmenting *before* decoding — this model was never meant to
        // take a whole recording in one call. sherpa-onnx's ONNX export
        // bakes that same ~20-30s ceiling in as a fixed 512-token
        // prompt+audio budget (see shim.c) with no runtime override,
        // unlike Qwen3-ASR's own fix just below in that file. Splitting on
        // real speech/silence boundaries first — using the model the way
        // its own creators built it to be used — turns "silently empty
        // past ~20s" into "correct at any length," rather than chasing a
        // ceiling that was never actually configurable. `vadManager` is
        // optional and this only ever narrows to the one family that
        // needs it — every other model here decodes exactly as before.
        if Self.family(for: model) == .funasrNano, let vadManager,
           let chunked = try? await Self.transcribeInSpeechChunks(
            handle: handle, samples: samples, sampleRate: sampleRate, vadManager: vadManager),
           !chunked.isEmpty {
            return chunked
        }

        let result = try await Task.detached(priority: .userInitiated) {
            try Self.runTranscribe(handle: handle, samples: samples, sampleRate: sampleRate)
        }.value
        // A name the model was unsure of, checked against the user's names — only for the models that report each
        // token's probability (see `runTranscribe`).
        let isEnglish = String(localeID.prefix(while: { $0 != "-" })).lowercased() == "en"
        if UnsureWordFix.isEnabled, isEnglish, let words = result.words,
           let fixed = UnsureWordFix.fix(result.text, words: words, terms: biasTerms) {
            dictationLog.info("sherpa-onnx: fixed \(fixed.changes.count) unsure name(s)")
            NameFixLog.record(fixed.changes, engine: "sherpa-onnx")
            return fixed.text
        }
        return result.text
    }

    /// Splits `samples` at real speech/silence boundaries (FluidAudio's
    /// Silero VAD — the same model already used for Murmur's pre-
    /// recognition silence gate, see `VadEngine`) and decodes each segment
    /// independently, joining the results with a space. `VadSegmentation
    /// Config.default`'s 14s max-segment length already sits with real
    /// margin under FunASR Nano's observed ~20-30s failure point — no
    /// custom tuning needed. Returns `""` (never throws past this point)
    /// if VAD found no speech at all, so the caller's own `!chunked
    /// .isEmpty` check falls back to the plain single-shot decode instead
    /// of returning nothing.
    nonisolated private static func transcribeInSpeechChunks(
        handle: MurmurSherpaRecognizer, samples: [Float], sampleRate: Int32,
        vadManager: VadManager
    ) async throws -> String {
        // VAD needs 16kHz mono input; this resampled copy exists only for
        // *detecting* segment boundaries. What actually gets decoded below
        // is sliced straight from the original native-rate `samples` —
        // never this copy — so sherpa-onnx still only resamples once,
        // internally, exactly as `pcmMono`'s own doc comment requires to
        // avoid the duplicated-syllable bug found earlier.
        let vadSamples = try resample16kForVAD(samples, from: sampleRate)
        let segments = try await vadManager.segmentSpeech(vadSamples)
        guard !segments.isEmpty else { return "" }

        var pieces: [String] = []
        for segment in segments {
            let start = max(0, min(segment.startSample(sampleRate: Int(sampleRate)), samples.count))
            let end = max(start, min(segment.endSample(sampleRate: Int(sampleRate)), samples.count))
            guard end > start else { continue }
            let clip = Array(samples[start..<end])
            if let text = try? runTranscribe(handle: handle, samples: clip, sampleRate: sampleRate).text,
               !text.isEmpty {
                pieces.append(text)
            }
        }
        return pieces.joined(separator: " ")
    }

    /// The text, and each word's certainty when the model reports its tokens' log probabilities ("ys_log_probs" in
    /// sherpa-onnx's result; nil for models that don't).
    nonisolated private static func runTranscribe(
        handle: MurmurSherpaRecognizer, samples: [Float], sampleRate: Int32
    ) throws -> (text: String, words: [UnsureWordFix.Word]?) {
        guard let cString = samples.withUnsafeBufferPointer({ buffer in
            MurmurSherpaTranscribeJSON(handle, buffer.baseAddress, Int32(buffer.count), sampleRate)
        }) else {
            throw SherpaOnnxError.transcribeFailed
        }
        defer { free(cString) }
        let json = String(cString: cString)
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let text = object["text"] as? String else { throw SherpaOnnxError.transcribeFailed }
        if ProcessInfo.processInfo.environment["MURMUR_SHERPA_JSON"] != nil {
            let tokenCount = (object["tokens"] as? [Any])?.count ?? -1
            let probCount = (object["ys_log_probs"] as? [Any])?.count ?? -1
            FileHandle.standardError.write(Data("SHERPA_JSON tokens=\(tokenCount) log_probs=\(probCount)\n".utf8))
        }
        var words: [UnsureWordFix.Word]?
        if let tokens = object["tokens"] as? [String], let logProbs = object["ys_log_probs"] as? [Double],
           tokens.count == logProbs.count, !tokens.isEmpty {
            words = UnsureWordFix.words(fromTokens: zip(tokens, logProbs).map {
                (text: $0.0.replacingOccurrences(of: "▁", with: " ").replacingOccurrences(of: "Ġ", with: " "),
                 p: Float(exp($0.1)))
            })
        }
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), words)
    }

    // MARK: - Audio

    /// Converts the recorder's `.caf` to mono Float32 PCM at its own native
    /// sample rate — unlike `WhisperCppEngine.pcm16kMono(from:)`, this
    /// does *not* resample to 16kHz first. sherpa-onnx's offline C API takes
    /// a `sample_rate` parameter and resamples internally
    /// (`SherpaOnnxAcceptWaveformOffline`), and direct A/B testing against
    /// the same audio file found a real, reproducible bug from doing it
    /// twice: pre-resampling with `AVAudioConverter` here first and then
    /// letting sherpa-onnx resample its already-resampled input again
    /// produced a duplicated syllable ("integrated" → "integratedrated")
    /// that wasn't there when sherpa-onnx did the one-and-only resample
    /// itself from the file's native rate — confirmed by cross-checking the
    /// identical file through `scripts/_sherpa_onnx_worker.py`, which never
    /// resamples client-side and came back clean.
    nonisolated private static func pcmMono(from url: URL) throws -> (samples: [Float], sampleRate: Int32) {
        let file = try AVAudioFile(forReading: url)
        let inputFormat = file.processingFormat
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: inputFormat.sampleRate,
            channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        else { throw SherpaOnnxError.audioConversionFailed }

        let inputFrameCount = AVAudioFrameCount(file.length)
        guard inputFrameCount > 0,
              let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: inputFormat, frameCapacity: inputFrameCount)
        else { throw SherpaOnnxError.audioConversionFailed }
        try file.read(into: inputBuffer)

        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 1024
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat, frameCapacity: outputCapacity)
        else { throw SherpaOnnxError.audioConversionFailed }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            guard !suppliedInput else {
                outStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            outStatus.pointee = .haveData
            return inputBuffer
        }
        guard status != .error else {
            throw conversionError ?? SherpaOnnxError.audioConversionFailed
        }
        guard let channelData = outputBuffer.floatChannelData else {
            throw SherpaOnnxError.audioConversionFailed
        }
        let samples = Array(UnsafeBufferPointer(
            start: channelData[0], count: Int(outputBuffer.frameLength)))
        return (samples, Int32(targetFormat.sampleRate))
    }

    /// A throwaway 16kHz copy of already-loaded native-rate samples, purely
    /// for `VadManager.segmentSpeech`'s own input requirement — never what
    /// actually gets decoded (see `transcribeInSpeechChunks`). Same
    /// `AVAudioConverter` mechanics as `pcmMono` above, just starting from
    /// an in-memory buffer instead of reading the file a second time.
    nonisolated private static func resample16kForVAD(
        _ samples: [Float], from sampleRate: Int32
    ) throws -> [Float] {
        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate),
            channels: 1, interleaved: false),
            let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        else { throw SherpaOnnxError.audioConversionFailed }

        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else { throw SherpaOnnxError.audioConversionFailed }
        inputBuffer.frameLength = inputBuffer.frameCapacity
        samples.withUnsafeBufferPointer { buffer in
            inputBuffer.floatChannelData![0].update(from: buffer.baseAddress!, count: samples.count)
        }

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(samples.count) * ratio) + 1024
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat, frameCapacity: outputCapacity)
        else { throw SherpaOnnxError.audioConversionFailed }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            guard !suppliedInput else {
                outStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            outStatus.pointee = .haveData
            return inputBuffer
        }
        guard status != .error else {
            throw conversionError ?? SherpaOnnxError.audioConversionFailed
        }
        guard let channelData = outputBuffer.floatChannelData else {
            throw SherpaOnnxError.audioConversionFailed
        }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength)))
    }

    // MARK: - Model download

    /// SenseVoice, Moonshine, and Canary all download as a single `.tar.bz2`
    /// release archive from GitHub; Zipformer downloads its five files
    /// individually straight from Hugging Face instead (see `download`
    /// below for why).
    nonisolated private static func archiveName(for model: String) -> String? {
        switch family(for: model) {
        // The int8-only release archive — k2-fsa also publishes a combined
        // archive with both the fp32 and int8 ONNX models together
        // (~1 GB); this one has just the int8 model actually used here
        // plus its tokenizer, at roughly a sixth of the download.
        case .senseVoice: return "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17"
        case .moonshineBaseEn: return "sherpa-onnx-moonshine-base-en-int8"
        // Also a dedicated int8-only archive, same reasoning.
        case .canary180mFlash: return "sherpa-onnx-nemo-canary-180m-flash-en-es-de-fr-int8"
        // Both already int8-only; also both genuinely ~1GB archives at
        // that — an LLM decoder (Qwen3-0.6B) doesn't shrink the way a
        // CTC/transducer head does.
        case .funasrNano: return "sherpa-onnx-funasr-nano-int8-2025-12-30"
        case .qwen3Asr: return "sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25"
        case .zipformerEn: return nil
        }
    }

    nonisolated private static func downloadSource(for model: String) -> URL? {
        guard let archiveName = archiveName(for: model) else { return nil }
        return URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/"
            + "\(archiveName).tar.bz2")
    }

    nonisolated private static func download(model: String, to destination: URL) async throws {
        if family(for: model) == .zipformerEn {
            try await downloadZipformerFiles(to: destination)
            return
        }

        guard let source = downloadSource(for: model)
        else { throw SherpaOnnxError.downloadFailed }

        let extractDir = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: extractDir, withIntermediateDirectories: true)

        let (tempURL, response) = try await URLSession.shared.download(from: source)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { throw SherpaOnnxError.downloadFailed }

        try? FileManager.default.removeItem(at: destination)

        // Shells out to `/usr/bin/tar` (bsdtar, built into macOS) for the
        // actual `.tar.bz2` extraction — Foundation has no bzip2/tar
        // support of its own, and the alternative (vendoring a
        // decompression library just for a one-time model download) isn't
        // worth it next to a system tool already on every Mac.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["xjf", tempURL.path, "-C", extractDir.path]
        try process.run()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: tempURL)

        guard process.terminationStatus == 0,
              FileManager.default.fileExists(at: destination, containsAllOf: requiredFiles(for: model))
        else { throw SherpaOnnxError.downloadFailed }
    }

    /// This specific checkpoint (LibriHeavy-trained, "punct-case" variant)
    /// rather than k2-fsa's plainer, older `zipformer-en-2023-06-26` —
    /// direct A/B testing found the plain checkpoint transcribes in flat
    /// uppercase with no punctuation at all (a real, trained characteristic
    /// of that older LibriSpeech recipe, confirmed identical against the
    /// Python reference bindings — not an integration bug), which would
    /// look broken sitting next to every other engine's natural casing.
    /// This one produces real sentence casing and punctuation instead, and
    /// happened to also fix a mis-hearing ("segment" → "said mend") the
    /// plainer checkpoint made on the same test audio. The tradeoff: it
    /// needs a fifth file, `bpe.model` (its BPE tokenizer), alongside the
    /// usual encoder/decoder/joiner/tokens.
    ///
    /// Zipformer's own GitHub release archive bundles both the fp32 and
    /// int8 ONNX weights together (~307 MB) with no int8-only variant the
    /// way SenseVoice/Moonshine have — but the same files are also mirrored
    /// individually on Hugging Face, so downloading just the five actually
    /// needed here (~70 MB total) beats fetching the combined archive and
    /// discarding half of it.
    nonisolated private static let zipformerBaseURL =
        "https://huggingface.co/csukuangfj/" +
        "sherpa-onnx-zipformer-en-libriheavy-20230830-medium-punct-case/resolve/main/"
    nonisolated private static let zipformerFiles = [
        "encoder-epoch-50-avg-15.int8.onnx", "decoder-epoch-50-avg-15.int8.onnx",
        "joiner-epoch-50-avg-15.int8.onnx", "tokens.txt", "bpe.model",
    ]

    nonisolated private static func downloadZipformerFiles(to destination: URL) async throws {
        try FileManager.default.createDirectory(
            at: destination, withIntermediateDirectories: true)
        for name in zipformerFiles {
            guard let source = URL(string: zipformerBaseURL + name)
            else { throw SherpaOnnxError.downloadFailed }
            let (tempURL, response) = try await URLSession.shared.download(from: source)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
            else { throw SherpaOnnxError.downloadFailed }
            let fileDestination = destination.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: fileDestination)
            try FileManager.default.moveItem(at: tempURL, to: fileDestination)
        }
    }

    /// Mirrors `isModelDownloaded`'s own per-family file list — kept
    /// separate rather than sharing one function since that one also reads
    /// `downloadedModels`/is instance-isolated, and this needs to run from
    /// a `nonisolated` download context.
    nonisolated private static func requiredFiles(for model: String) -> [String] {
        switch family(for: model) {
        case .senseVoice: return ["model.int8.onnx", "tokens.txt"]
        case .zipformerEn: return zipformerFiles
        case .moonshineBaseEn:
            return [
                "preprocess.onnx", "encode.int8.onnx",
                "uncached_decode.int8.onnx", "cached_decode.int8.onnx", "tokens.txt",
            ]
        case .canary180mFlash:
            return ["encoder.int8.onnx", "decoder.int8.onnx", "tokens.txt"]
        case .funasrNano:
            return [
                "encoder_adaptor.int8.onnx", "llm.int8.onnx", "embedding.int8.onnx",
                "Qwen3-0.6B/tokenizer.json",
            ]
        case .qwen3Asr:
            return [
                "conv_frontend.onnx", "encoder.int8.onnx", "decoder.int8.onnx",
                "tokenizer/tokenizer_config.json",
            ]
        }
    }
}

extension FileManager {
    fileprivate func fileExists(at directory: URL, containsAllOf names: [String]) -> Bool {
        names.allSatisfy { fileExists(atPath: directory.appendingPathComponent($0).path) }
    }
}

enum SherpaOnnxError: LocalizedError {
    case loadFailed, transcribeFailed, audioConversionFailed, downloadFailed

    var errorDescription: String? {
        switch self {
        case .loadFailed: return "sherpa-onnx could not load the model."
        case .transcribeFailed: return "sherpa-onnx transcription failed."
        case .audioConversionFailed: return "Could not convert the recording for sherpa-onnx."
        case .downloadFailed: return "Could not download the sherpa-onnx model."
        }
    }
}
