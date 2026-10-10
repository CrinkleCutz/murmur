import AVFAudio
import FluidAudio
import Foundation

/// A third "Precise" recognition engine, alongside `WhisperEngine` and
/// `WhisperCppEngine`: NVIDIA's Parakeet TDT model, run locally via FluidAudio
/// (CoreML on the Neural Engine). Independent benchmarking has shown it
/// transcribing noticeably faster than both Apple's built-in engine and the
/// Whisper-family engines here, with comparable accuracy.
///
/// Vocabulary biasing works differently here than in the Whisper-family
/// engines. Parakeet's transducer architecture has no decoder-prompt
/// mechanism equivalent to Whisper's, so `biasTerms` can't nudge the main
/// decode itself — instead this runs FluidAudio's separate CTC-based
/// vocabulary-boosting pass (`CustomVocabularyContext`; see
/// `Documentation/ASR/CustomVocabulary.md` in the FluidAudio checkout)
/// after the decode: a second, small CTC encoder listens to the same audio
/// for acoustic evidence of a bias term, and rescoring swaps in that term
/// only where the evidence clears FluidAudio's own confidence thresholds.
/// This is the mechanism prompt-based biasing could not be — testing this
/// against `DeveloperVocabulary`'s "Supabase" case showed a Whisper prompt
/// containing the term verbatim was still not enough on its own, because
/// prompt biasing only ever nudges token probabilities; it never checks a
/// candidate replacement against the actual audio the way CTC rescoring
/// does.
///
/// Boosted transcription runs on `UnifiedAsrManager` (FluidAudio's offline
/// batch manager), not `SlidingWindowAsrManager` (its live-transcript one)
/// — the latter was tried first and had a real, reproduced bug: its
/// confirm/promote logic, needed to stabilize a *streaming* view, could
/// inject spurious text at a chunk boundary on longer recordings once
/// Murmur zeroed its confirmation thresholds (required to make rescoring
/// apply to a short dictation at all). Filed upstream as
/// github.com/FluidInference/FluidAudio/issues/912. `UnifiedAsrManager`'s
/// overlap-merge (`collapseSeamWordDuplicates`) doesn't have this failure
/// mode in testing, and needs no duration cap to avoid it — the real
/// trade is that its model (`parakeet-unified-en-0.6b`) is English-only,
/// so boosting is now gated on English dictation instead of on recording
/// length. `v2`/`v3` above still handle the plain (non-boosted) decode for
/// every other language exactly as before; this only changes what happens
/// when boosting is requested.
///
/// Falls back to the plain one-shot decode (no boosting) whenever the
/// caller doesn't request boosting (see `transcribe`'s `boostVocabulary`),
/// the dictation isn't English, the CTC model isn't downloaded/loaded yet,
/// there are no bias terms, or the boosted path fails for any reason —
/// boosting must never be the reason a dictation comes back empty.
///
/// Model files are cached in FluidAudio's own default location
/// (`~/Library/Application Support/FluidAudio/Models/`) rather than under
/// Murmur's own support directory like the other two engines — there's no
/// reason to fight a sensible library default just for consistency.
@MainActor
final class ParakeetEngine {

    static let availableModels: [(id: String, label: String)] = [
        ("v2", "Parakeet v2 — English, highest recall, ~600 MB"),
        ("v3", "Parakeet v3 — multilingual (\(v3LanguageCodes.count) languages), ~600 MB"),
        ("nemotron", "Nemotron 0.6B — English, no developer vocabulary boosting, ~530 MB"),
    ]

    /// "flash" (Parakeet EOU) is deliberately not in `availableModels` yet
    /// — the engine support below is real and tested, but direct
    /// measurement found it slower than v2 for Murmur's batch usage (not
    /// the live-streaming case it's built for), and a reproducible bug:
    /// a 21s test recording consistently lost its last two words
    /// ("write up") through `finish()`'s zero-padded final chunk. Not
    /// listed here until one of those is actually fixed, so nobody can
    /// select a model with a known, repeatable accuracy regression from
    /// the Settings picker. Left in the engine rather than deleted since
    /// the download/load/transcribe path itself is confirmed working —
    /// see `eouAsrManager()`/`transcribeWithEou(fileAt:)`.
    ///
    /// "nemotron" (`StreamingNemotronAsrManager`, not the separate,
    /// untested `StreamingNemotronMultilingualAsrManager`) *is* listed:
    /// the same tail-truncation probe that broke "flash" came back
    /// complete across three different recordings (5-21s), with correct
    /// punctuation/capitalization the model produces on its own — no
    /// known correctness gap. Speed is a wash rather than a win, measured
    /// warm-process against v2 on the same three clips: faster on the
    /// shortest (~5s), roughly 2x slower on both longer ones (~15s, ~21s)
    /// — sequential 2.24s cache-aware chunks have more overhead per call
    /// than v2's one-shot full-context decode. Offered anyway on request,
    /// not for a speed claim this doesn't clearly back. Same vocabulary-
    /// boosting gap as "flash" — no `configureVocabularyBoosting` exposed
    /// on this manager either.
    ///
    /// BCP-47 language codes each model can actually transcribe: `v2`,
    /// `flash`, and `nemotron` are treated as English-only here — `v2` and
    /// `flash` genuinely are; `nemotron` (`StreamingNemotronAsrManager`)
    /// has no language-routing code at all in FluidAudio (unlike the
    /// separate Multilingual manager, which does), and every test of it
    /// so far has been English, so English is what's actually verified,
    /// not a claim about what the model can or can't do beyond that. `v3`
    /// is NVIDIA's documented 25-language European set, narrowed to the
    /// ones FluidAudio's own FLEURS benchmark measured under
    /// `v3WEROfferThreshold` word error rate — see `v3WordErrorRates`.
    /// Drives the Settings/HUD language pickers, which otherwise have no
    /// way to know these models don't cover the same languages — or that
    /// "supported" and "actually accurate" aren't the same thing for
    /// several of v3's 25.
    static func supportedLanguageCodes(for model: String) -> [String] {
        model == "v3" ? v3LanguageCodes : ["en"]
    }

    /// Parakeet TDT v3's per-language word error rate, as measured by
    /// FluidAudio's own FLEURS benchmark (`fluidaudiocli fleurs-benchmark`,
    /// see FluidAudioCLI's `FleursBenchmark.swift`) against NVIDIA's
    /// documented 25-language set. Portuguese is absent from NVIDIA's set
    /// entirely here, not just filtered out below — that benchmark file
    /// only measured `pt_br` (Brazilian) as a separate, non-European
    /// addition alongside Arabic/Japanese/Mandarin/Korean/Vietnamese, with
    /// no comparable WER logged for it, so there's nothing here to vouch
    /// for either way.
    private static let v3WordErrorRates: [String: Double] = [
        "it": 3.00, "es": 3.45, "de": 5.04, "en": 4.85, "fr": 5.15,
        "ru": 5.51, "uk": 6.79, "pl": 7.31, "nl": 7.48, "sk": 8.82,
        "cs": 11.01, "ro": 12.44, "hr": 12.46, "bg": 12.64, "fi": 13.21,
        "sv": 15.08, "hu": 15.72, "et": 17.73, "da": 18.41, "mt": 20.46,
        "lt": 20.35, "el": 20.70, "lv": 22.84, "sl": 24.03,
    ]

    /// Above this measured word error rate, Murmur doesn't offer the
    /// language at all — wrong roughly one word in ten (or worse) isn't
    /// the fast, accurate dictation the app promises, and silently
    /// offering it as an equal alongside English/German/French/etc. sets
    /// an expectation the model can't meet. Chosen, not measured: there's
    /// no natural cutoff in the data (see the jump from Slovak's 8.82% to
    /// Czech's 11.01%), so this is a deliberate quality bar, not a
    /// statistical one — revisit if a Parakeet update changes the numbers.
    private static let v3WEROfferThreshold = 10.0

    private static let v3LanguageCodes: [String] =
        v3WordErrorRates
            .filter { $0.value < v3WEROfferThreshold }
            .keys
            .sorted()

    /// Status line for the UI (loading/downloading/transcribing); nil clears.
    var onStatus: ((String?) -> Void)?

    private var loadTask: Task<AsrModels, Error>?
    private var loadedModel: String?
    /// Set only after the pipeline has fully loaded.
    private var readyModel: String?

    /// The two CTC models available for vocabulary-boosting rescoring —
    /// independent of which TDT model (v2/v3) is actually transcribing.
    /// `.ctc06b` is the variant FluidAudio's docs pair with Parakeet TDT
    /// 0.6B ("Approach 2: Separate CTC Encoder"), which both v2 and v3
    /// are, and stays the default so existing behavior doesn't shift under
    /// anyone. `.ctc110m` is smaller/faster — a comparable open-source
    /// dictation app (FluidVoice) uses it for this exact purpose — offered
    /// alongside rather than replacing `.ctc06b`, since it hasn't been
    /// tuned against the same false-positive collisions here yet.
    static let availableCtcVariants: [(id: String, label: String)] = [
        ("ctc06b", "Precise — larger vocabulary-boosting model, default"),
        ("ctc110m", "Fast — smaller vocabulary-boosting model"),
    ]

    private static func ctcModelVariant(for id: String) -> CtcModelVariant {
        id == "ctc110m" ? .ctc110m : .ctc06b
    }

    private var loadedCtcVariant: String?
    private var ctcLoadTask: Task<(models: CtcModels, tokenizer: CtcTokenizer), Error>?

    /// The Unified offline model used for boosted transcription — a
    /// separate ~0.6B model from the regular v2/v3 TDT ones, downloaded
    /// and loaded once, independent of which TDT model is selected for
    /// plain decoding. See the class doc comment for why boosting uses
    /// this instead of the streaming sliding-window manager.
    private var unifiedLoadTask: Task<UnifiedAsrManager, Error>?

    /// "Flash" is a different model family entirely — NVIDIA's Parakeet EOU
    /// (`nvidia/parakeet_realtime_eou_120m-v1`), a small (120M-param),
    /// cache-aware *streaming* encoder, not the TDT 0.6B decode the rest of
    /// this file boosts. `.ms320` (NeMo's "320ms" chunk config) is fixed
    /// rather than exposed as its own setting: it isn't a live-latency knob
    /// here the way it is for a true streaming UI — Murmur always records
    /// first, then transcribes the complete file — so the only thing this
    /// choice actually affects is per-chunk throughput/accuracy, and
    /// FluidAudio's own doc comment on `StreamingChunkSize.ms320` documents
    /// it as the better throughput/accuracy tradeoff of the three (5.73%
    /// WER, 14x RTFx on LibriSpeech test-clean, vs. 160ms's lower accuracy
    /// and 1280ms's coarser update granularity).
    ///
    /// Has no CTC vocabulary-boosting integration at all — FluidAudio
    /// exposes `configureVocabularyBoosting` on `SlidingWindowAsrManager`/
    /// `UnifiedAsrManager` only, not on `StreamingEouAsrManager`. Selecting
    /// this model means developer vocabulary (`DeveloperVocabulary`,
    /// "Supabase" and friends) gets no acoustic-level help at all — only
    /// `LearnedStore`'s exact-phrase/fuzzy post-hoc corrections still
    /// apply, the same fallback non-English Parakeet dictation already
    /// relies on.
    private static let eouChunkSize: StreamingChunkSize = .ms320
    private static let eouRepo: Repo = .parakeetEou320
    private var eouManager: StreamingEouAsrManager?
    private var eouLoadTask: Task<StreamingEouAsrManager, Error>?

    /// `.ms2240` is `StreamingNemotronAsrManager`'s own default (nil
    /// `requestedChunkSize`) — "highest throughput" per
    /// `NemotronChunkSize`'s own doc comment, the same reasoning as EOU's
    /// `.ms320` choice above: Murmur transcribes a complete recording in
    /// one batch, so throughput/accuracy is what this choice actually
    /// affects here, not live-update latency.
    private static let nemotronRepo: Repo = .nemotronStreaming2240
    private var nemotronManager: StreamingNemotronAsrManager?
    private var nemotronLoadTask: Task<StreamingNemotronAsrManager, Error>?

    /// True once the pipeline is loaded in memory and can transcribe now.
    func isReady(model: String) -> Bool {
        readyModel == model
    }

    /// Models confirmed present on disk. Only *positive* results are cached:
    /// a model can finish downloading later, but a complete one never
    /// becomes incomplete, so a `true` can never go stale.
    private var downloadedModels: Set<String> = []

    func isModelDownloaded(_ model: String) -> Bool {
        if downloadedModels.contains(model) { return true }
        let exists: Bool
        switch model {
        case "flash":
            exists = Self.eouModelsExistOnDisk()
        case "nemotron":
            exists = Self.nemotronModelsExistOnDisk()
        default:
            let version = Self.version(for: model)
            let directory = AsrModels.defaultCacheDirectory(for: version)
            exists = AsrModels.modelsExist(at: directory, version: version)
        }
        if exists { downloadedModels.insert(model) }
        return exists
    }

    /// Mirrors `AsrModels.modelsExist(at:version:)` for the EOU model,
    /// which has no equivalent library helper of its own — checks the same
    /// directory `StreamingEouAsrManager.loadModels(to: nil)` downloads
    /// into (its own default cache root, joined with `eouRepo.folderName`,
    /// same as its internal `loadModels(to:configuration:progressHandler:)`
    /// composes it) for every file `ModelNames.ParakeetEOU.requiredModels`
    /// lists.
    private static func eouModelsExistOnDisk() -> Bool {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let directory = appSupport
            .appendingPathComponent("FluidAudio/Models/parakeet-eou-streaming", isDirectory: true)
            .appendingPathComponent(eouRepo.folderName, isDirectory: true)
        return ModelNames.ParakeetEOU.requiredModels.allSatisfy {
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent($0).path)
        }
    }

    /// Same idea as `eouModelsExistOnDisk()`, but checked against the
    /// exact `requiredFiles` list `StreamingNemotronAsrManager.loadModels(
    /// to:configuration:progressHandler:)` passes to `ModelHub
    /// .loadWithRecovery` — not `ModelNames.NemotronStreaming.requiredModels`,
    /// which is a broader set (includes `preprocessorFile`, made obsolete
    /// by this manager's native-Swift mel front-end per its own class doc
    /// comment, and `decoderJointFile`/`metadata`, which that same call
    /// site's comment marks optional at load time). Checking the broader
    /// set would report a fully-working cache as incomplete.
    private static func nemotronModelsExistOnDisk() -> Bool {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let directory = appSupport
            .appendingPathComponent("FluidAudio/Models", isDirectory: true)
            .appendingPathComponent(nemotronRepo.folderName, isDirectory: true)
        let requiredFiles = [
            "encoder/encoder_int8.mlmodelc",
            ModelNames.NemotronStreaming.decoderFile,
            ModelNames.NemotronStreaming.jointFile,
            ModelNames.NemotronStreaming.tokenizer,
        ]
        return requiredFiles.allSatisfy {
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent($0).path)
        }
    }

    /// Kicks off model load/download in the background — the main TDT
    /// model, and separately the CTC vocabulary-boosting model. Dictation
    /// never waits on the latter: `transcribe` silently falls back to the
    /// plain decode if it isn't ready yet, so this has no status message of
    /// its own the way the main model's download does.
    func preload(model: String) {
        if model == "flash" {
            Task { _ = try? await self.eouAsrManager() }
            return
        }
        if model == "nemotron" {
            Task { _ = try? await self.nemotronAsrManager() }
            return
        }
        Task { _ = try? await self.asrModels(for: model) }
        Task { _ = try? await self.ctcResources(variantID: Settings.parakeetCtcVariant) }
        Task { _ = try? await self.unifiedManager() }
    }

    private func asrModels(for model: String) async throws -> AsrModels {
        if loadedModel == model, let loadTask {
            return try await loadTask.value
        }
        loadTask?.cancel()
        loadedModel = model
        readyModel = nil

        let version = Self.version(for: model)
        let needsDownload = !isModelDownloaded(model)
        onStatus?(needsDownload
            ? "Downloading Parakeet model (one-time)"
            : "Loading Parakeet model")
        let task = Task { () -> AsrModels in
            try await AsrModels.downloadAndLoad(version: version)
        }
        loadTask = task
        defer { onStatus?(nil) }
        let models = try await task.value
        if loadedModel == model {
            readyModel = model
        }
        return models
    }

    /// Loads (downloading if needed) the Parakeet EOU streaming model.
    /// Cached after first success, same `loaded*`-tracking shape as
    /// `asrModels(for:)` — there's only ever one variant here (no v2/v3
    /// choice), so `loadedModel == "flash"` doubles as the cache check.
    private func eouAsrManager() async throws -> StreamingEouAsrManager {
        if loadedModel == "flash", let eouLoadTask {
            return try await eouLoadTask.value
        }
        eouLoadTask?.cancel()
        loadedModel = "flash"
        readyModel = nil

        let needsDownload = !isModelDownloaded("flash")
        onStatus?(needsDownload
            ? "Downloading Parakeet Flash model (one-time)"
            : "Loading Parakeet Flash model")
        let task = Task { () -> StreamingEouAsrManager in
            let manager = StreamingEouAsrManager(chunkSize: Self.eouChunkSize)
            try await manager.loadModels()
            return manager
        }
        eouLoadTask = task
        defer { onStatus?(nil) }
        let manager = try await task.value
        if loadedModel == "flash" {
            readyModel = "flash"
        }
        eouManager = manager
        return manager
    }

    /// Loads (downloading if needed) the Nemotron 0.6B streaming model.
    /// Cached after first success, same `loaded*`-tracking shape as
    /// `eouAsrManager()`.
    private func nemotronAsrManager() async throws -> StreamingNemotronAsrManager {
        if loadedModel == "nemotron", let nemotronLoadTask {
            return try await nemotronLoadTask.value
        }
        nemotronLoadTask?.cancel()
        loadedModel = "nemotron"
        readyModel = nil

        let needsDownload = !isModelDownloaded("nemotron")
        onStatus?(needsDownload
            ? "Downloading Nemotron model (one-time)"
            : "Loading Nemotron model")
        let task = Task { () -> StreamingNemotronAsrManager in
            let manager = StreamingNemotronAsrManager()
            try await manager.loadModels()
            return manager
        }
        nemotronLoadTask = task
        defer { onStatus?(nil) }
        let manager = try await task.value
        if loadedModel == "nemotron" {
            readyModel = "nemotron"
        }
        nemotronManager = manager
        return manager
    }

    /// Loads (downloading if needed) the CTC model and its matching
    /// tokenizer used for vocabulary-boosting rescoring, per
    /// `Settings.parakeetCtcVariant`. Cached after the first success for a
    /// given variant, same `loaded*`-tracking pattern as `asrModels(for:)`
    /// — so switching the setting mid-session reloads instead of silently
    /// keeping the old variant. Must load the tokenizer from the same
    /// variant's own cache directory explicitly — `CtcTokenizer.load()`'s
    /// parameterless overload defaults to the *110m* model's directory
    /// regardless, which would hand back token IDs from the wrong
    /// vocabulary when `.ctc06b` is selected.
    private func ctcResources(variantID: String) async throws -> (models: CtcModels, tokenizer: CtcTokenizer) {
        if loadedCtcVariant == variantID, let ctcLoadTask {
            return try await ctcLoadTask.value
        }
        ctcLoadTask?.cancel()
        loadedCtcVariant = variantID
        let variant = Self.ctcModelVariant(for: variantID)
        let task = Task { () -> (models: CtcModels, tokenizer: CtcTokenizer) in
            let models = try await CtcModels.downloadAndLoad(variant: variant)
            let tokenizer = try await CtcTokenizer.load(
                from: CtcModels.defaultCacheDirectory(for: variant))
            return (models, tokenizer)
        }
        ctcLoadTask = task
        return try await task.value
    }

    /// Loads (downloading if needed) the Unified offline model used for
    /// boosted transcription. Cached after the first success, same pattern
    /// as `asrModels(for:)`/`ctcResources()` — the actor is safe to reuse
    /// across calls since its batch `transcribe(_:)` entry point recomputes
    /// everything from the passed audio each time (no carried decoder
    /// state between calls, unlike its separate streaming-conformance API,
    /// which this doesn't use).
    ///
    /// Tries the smaller/faster int8 encoder first; retries with fp16 on
    /// failure, since some A-series chips can't build an execution plan
    /// for the int8 variant on any compute unit even from an intact
    /// download (FluidAudio issue #828, documented on
    /// `UnifiedAsrManager.loadModels(from:)`).
    private func unifiedManager() async throws -> UnifiedAsrManager {
        if let unifiedLoadTask {
            return try await unifiedLoadTask.value
        }
        let task = Task { () -> UnifiedAsrManager in
            let manager = UnifiedAsrManager(encoderPrecision: .int8)
            do {
                try await manager.loadModels()
                return manager
            } catch {
                dictationLog.error(
                    "Unified int8 encoder failed to load, retrying fp16: \(error, privacy: .public)"
                )
                let fallback = UnifiedAsrManager(encoderPrecision: .fp16)
                try await fallback.loadModels()
                return fallback
            }
        }
        unifiedLoadTask = task
        return try await task.value
    }

    /// `boostVocabulary` gates the CTC rescoring pass below, separately
    /// from whether `biasTerms` happens to be non-empty. Measured cost
    /// when this ran on `SlidingWindowAsrManager`: ~0.65s for a plain
    /// decode vs. ~1.7s once boosting kicked in — nearly 3x, and it used
    /// to trigger on *any* non-empty bias list, which in practice was
    /// almost every dictation (even a handful of personal dictionary
    /// entries is enough; developer vocabulary alone is ~110 terms).
    /// That's a bad trade for most dictations: the terms most likely to
    /// actually collide acoustically with an ordinary word — "Supabase,"
    /// "Codex," "Claude" — are specifically the short, English-word-shaped
    /// brand names in `DeveloperVocabulary`, not generic personal
    /// vocabulary. So this only boosts when the caller says developer
    /// vocabulary is actually active for this app, restoring the fast
    /// path for everyone else. `UnifiedAsrManager` (see the class doc
    /// comment) adds its own gate on top: it's an English-only model, so
    /// boosting now also requires `isEnglishDictation` — a non-English
    /// dictation always uses the plain v2/v3 decode instead, same as if
    /// boosting weren't requested at all.
    /// `ctcVariant` defaults to the persisted setting rather than requiring
    /// every call site to pass it — evaluated per call, so it always picks
    /// up whatever `Settings.parakeetCtcVariant` is at the moment of the
    /// call. Overridable (e.g. `--ctc-variant` in `Main.swift`'s CLI) for
    /// comparing variants without writing to the same `UserDefaults` the
    /// real app reads, the way `--engine`/`--bundle-id` already work as
    /// plain call parameters rather than Settings mutations.
    /// `confidence` is `nil` whenever the underlying path doesn't expose
    /// one — Flash and Nemotron's streaming managers have no equivalent to
    /// `ASRResult.confidence`/`TokenTiming.confidence` today — never a
    /// signal to treat as "known to be low." Callers already handle `nil`
    /// as "no opinion" (see `TranscriptionPlausibility.isPlausible`).
    func transcribe(
        fileAt url: URL, model: String, localeID: String,
        biasTerms: [String], boostVocabulary: Bool,
        ctcVariant: String = Settings.parakeetCtcVariant
    ) async throws -> (text: String, confidence: Float?) {
        // A different model family entirely — see `eouAsrManager()`'s doc
        // comment. No TDT model, no CTC boosting; `biasTerms`/
        // `boostVocabulary` are accepted for call-site uniformity with the
        // other models and silently ignored, same as `WhisperEngine`
        // ignores parameters that don't apply to a given model.
        if model == "flash" {
            onStatus?("Transcribing (Parakeet Flash)")
            defer { onStatus?(nil) }
            return (try await transcribeWithEou(fileAt: url), nil)
        }
        if model == "nemotron" {
            onStatus?("Transcribing (Nemotron)")
            defer { onStatus?(nil) }
            let nemotron = try await transcribeWithNemotron(fileAt: url)
            // A name the model was unsure of, checked against the user's names — see `UnsureWordFix`.
            if UnsureWordFix.isEnabled, localeID.lowercased().hasPrefix("en"),
               let fixed = UnsureWordFix.fix(nemotron.text, words: nemotron.words, terms: biasTerms) {
                dictationLog.info("Nemotron: fixed \(fixed.changes.count) unsure name(s)")
                NameFixLog.record(fixed.changes, engine: "Nemotron")
                return (fixed.text, nil)
            }
            return (nemotron.text, nil)
        }

        let models = try await asrModels(for: model)

        // A script-bias hint FluidAudio only actually uses for the v3
        // (multilingual) model — harmlessly ignored for v2. Safe to compute
        // and pass unconditionally rather than branching on version here.
        let language = Language(rawValue:
            String(localeID.prefix(while: { $0 != "-" })).lowercased())
        let isEnglishDictation =
            String(localeID.prefix(while: { $0 != "-" })).lowercased() == "en"

        onStatus?("Transcribing (Parakeet)")
        defer { onStatus?(nil) }

        if boostVocabulary, isEnglishDictation, !biasTerms.isEmpty,
           let ctc = try? await ctcResources(variantID: ctcVariant) {
            do {
                return try await transcribeWithUnifiedVocabularyBoosting(
                    fileAt: url, biasTerms: biasTerms, ctc: ctc)
            } catch {
                dictationLog.error(
                    "Parakeet vocabulary boosting failed, falling back to plain decode: \(error, privacy: .public)"
                )
            }
        }

        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        // The URL overload does its own resampling to 16kHz mono internally
        // (FluidAudio's `AudioConverter`) — no manual PCM conversion needed,
        // unlike `WhisperCppEngine`.
        let result = try await manager.transcribe(
            url, decoderState: &decoderState, language: language)
        var text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A name the model was unsure of, checked against the user's names — see `UnsureWordFix`.
        if UnsureWordFix.isEnabled, isEnglishDictation, let timings = result.tokenTimings,
           let fixed = UnsureWordFix.fix(
            text, words: UnsureWordFix.words(fromPieces: timings.map { (text: $0.token, p: $0.confidence) }),
            terms: biasTerms) {
            dictationLog.info("Parakeet: fixed \(fixed.changes.count) unsure name(s)")
            NameFixLog.record(fixed.changes, engine: "Parakeet")
            text = fixed.text
        }
        return (text, result.confidence)
    }

    /// Runs `UnifiedAsrManager`'s offline batch decode with CTC-based
    /// vocabulary rescoring applied — one call, no manual chunking:
    /// `transcribe(_:)` handles windowing and overlap-merge internally
    /// (`collapseSeamWordDuplicates`), which is what avoids the seam bug
    /// `SlidingWindowAsrManager` had (see the class doc comment).
    /// `configureVocabularyBoosting` is cheap here — it wires up
    /// already-loaded CoreML model handles, not a fresh download — and is
    /// safe to call again on every transcription against the shared,
    /// cached `unifiedManager()` instance: it just replaces which
    /// vocabulary the next `transcribe(_:)` call rescores against.
    ///
    /// `minSimilarity: 0.85` is far stricter than FluidAudio's own default
    /// (0.52-0.60, size-tiered) — deliberately safe-by-default rather than
    /// tuned to fix any one term, because direct testing against
    /// synthesized audio (`say`) turned up a false-positive class the
    /// library default misses entirely: this vocabulary is full of short
    /// brand names built from ordinary English words ("Supabase" is
    /// "Supa" + "base", "Codex"/"Xcode" are both "code" plus an affix),
    /// and a floor loose enough to let the rescorer *fix* a mis-hearing of
    /// one of these is usually also loose enough to let it *corrupt* an
    /// unrelated, correctly-heard word into the same term. Confirmed, not
    /// theoretical: at a loose-enough-to-help floor, a clean "I need to
    /// back up the database..." came back "...back up the Supabase...",
    /// and a clean "I deployed the code to the cloud..." came back "...
    /// deployed the Xcode to the Claude...", with none of those brand
    /// names anywhere in the audio. 0.85 sits above every such collision
    /// found so far (database 0.63, cloud→Claude 0.67, code→Codex/Xcode
    /// 0.80). `DeveloperVocabulary.parakeetMinSimilarityOverrides` loosens
    /// this back down per-term, but only for a term with its own direct,
    /// positive test result — see its doc comment.
    ///
    /// `aliases` (below) catches what a looser floor can't: a mis-hearing
    /// close enough to a *known variant spelling* but not to the canonical
    /// term itself — "super bass" measures only 0.60 against "Supabase",
    /// below "database"'s own 0.63, so no floor shared with the canonical
    /// term can admit it safely. As an alias it's compared against
    /// directly, so this is a real match rather than a threshold escape
    /// hatch. Still a real, remaining gap: "Separate" (0.63) and
    /// "Supervise" (0.56) aren't registered as aliases *because* they're
    /// ordinary English words in their own right (unlike "super bass"),
    /// and both measure at or below "database"'s similarity to "Supabase"
    /// — admitting either, alias or not, would reopen that exact false
    /// positive.
    private func transcribeWithUnifiedVocabularyBoosting(
        fileAt url: URL, biasTerms: [String],
        ctc: (models: CtcModels, tokenizer: CtcTokenizer)
    ) async throws -> (text: String, confidence: Float?) {
        let terms = biasTerms.compactMap { term -> CustomVocabularyTerm? in
            let ctcTokenIds = ctc.tokenizer.encode(term)
            guard !ctcTokenIds.isEmpty else { return nil }
            let aliases = DeveloperVocabulary.parakeetAliases[term]
            return CustomVocabularyTerm(
                text: term, aliases: aliases, ctcTokenIds: ctcTokenIds,
                minSimilarity: DeveloperVocabulary.parakeetMinSimilarityOverrides[term])
        }
        guard !terms.isEmpty else {
            throw ASRError.processingFailed("No bias terms survived CTC tokenization")
        }
        var vocabulary = CustomVocabularyContext(terms: terms, minSimilarity: 0.85)
        // Debug only, for comparing boosting settings on the same audio from the command line:
        // "alpha,minCtcScore,minSimilarity,minCombinedConfidence" (FluidVoice ships 2.8,-2.2,0.72,0.64).
        if let values = ProcessInfo.processInfo.environment["MURMUR_PARAKEET_VOCAB"]?
            .split(separator: ",").compactMap({ Float($0) }), values.count == 4 {
            vocabulary = CustomVocabularyContext(
                terms: terms, alpha: values[0], minCtcScore: values[1],
                minSimilarity: values[2], minCombinedConfidence: values[3])
        }

        let unified = try await unifiedManager()
        try await unified.configureVocabularyBoosting(
            vocabulary: vocabulary, ctcModels: ctc.models)

        let audioFile = try AVAudioFile(forReading: url)
        let format = audioFile.processingFormat
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(audioFile.length))
        else {
            throw ASRError.processingFailed(
                "Could not allocate an audio buffer for \(url.lastPathComponent)")
        }
        try audioFile.read(into: buffer)

        // `transcribeWithTimings` (samples, not a buffer — no such overload
        // exists on `UnifiedAsrManager`) instead of the plain-`String`
        // `transcribe(_ buffer:)` above's underlying call, so this path
        // gets the same per-token confidence the plain decode gets from
        // `ASRResult` — the exact same public `AudioConverter` the
        // library's own `transcribe(_ buffer:)` uses internally, so the
        // resampling is identical either way.
        let samples = try AudioConverter().resampleBuffer(buffer)
        let result = try await unified.transcribeWithTimings(samples)
        // Mean of per-token confidences — the same "average of token-level
        // softmax probabilities" `ASRResult.confidence` itself is, so this
        // stays on a comparable scale to the plain decode's confidence
        // rather than needing its own separate threshold.
        let confidence: Float? = result.tokenTimings.isEmpty ? nil :
            result.tokenTimings.map(\.confidence).reduce(0, +) / Float(result.tokenTimings.count)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A name the model was unsure of, checked against the user's names — see `UnsureWordFix`. The confidences are
        // the decoder's, from before vocabulary boosting; a word the boosting already changed isn't in the text any
        // more, so it can't be matched and is left alone.
        if UnsureWordFix.isEnabled, let fixed = UnsureWordFix.fix(
            text, words: UnsureWordFix.words(fromPieces: result.tokenTimings.map { (text: $0.token, p: $0.confidence) }),
            terms: biasTerms) {
            dictationLog.info("Parakeet (boosted): fixed \(fixed.changes.count) unsure name(s)")
            NameFixLog.record(fixed.changes, engine: "Parakeet boosted")
            return (fixed.text, confidence)
        }
        return (text, confidence)
    }

    /// Feeds a complete recording through the EOU streaming pipeline as one
    /// batch: `appendAudio`/`processBufferedAudio` (resampling handled
    /// internally, same as the TDT managers' URL/buffer overloads) walk it
    /// chunk by chunk, then `finish()` flushes the final partial chunk
    /// (zero-padded) and returns the accumulated transcript. `reset()`
    /// first is required, not defensive: `eouAsrManager()` caches and
    /// reuses one actor instance across dictations the same way
    /// `unifiedManager()` does, but unlike `UnifiedAsrManager.transcribe(_:)`
    /// this one *is* stateful between calls (accumulated tokens, encoder
    /// loopback caches, EOU debounce timers) — built for a single
    /// continuous conversation, not stateless one-shot batches. Skipping
    /// this would leak the previous dictation's tokens into the next one.
    private func transcribeWithEou(fileAt url: URL) async throws -> String {
        let manager = try await eouAsrManager()
        await manager.reset()

        let audioFile = try AVAudioFile(forReading: url)
        let format = audioFile.processingFormat
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(audioFile.length))
        else {
            throw ASRError.processingFailed(
                "Could not allocate an audio buffer for \(url.lastPathComponent)")
        }
        try audioFile.read(into: buffer)

        try await manager.appendAudio(buffer)
        try await manager.processBufferedAudio()
        let text = try await manager.finish()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Same batch adaptation as `transcribeWithEou(fileAt:)` — `reset()`
    /// first for the same reason (this manager is stateful across calls
    /// too), then `appendAudio`/`processBufferedAudio`/`finish`. Unlike
    /// EOU, direct testing found no tail-truncation on any of three
    /// tested recordings (5-21s) — see `availableModels`'s doc comment for
    /// the actual measurements this is built on.
    private func transcribeWithNemotron(fileAt url: URL) async throws -> (text: String, words: [UnsureWordFix.Word]) {
        let manager = try await nemotronAsrManager()
        await manager.reset()

        let audioFile = try AVAudioFile(forReading: url)
        let format = audioFile.processingFormat
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(audioFile.length))
        else {
            throw ASRError.processingFailed(
                "Could not allocate an audio buffer for \(url.lastPathComponent)")
        }
        try audioFile.read(into: buffer)

        try await manager.appendAudio(buffer)
        try await manager.processBufferedAudio()
        // With each token's timing and confidence, for the unsure-word name fix — same text as `finish()`.
        let (text, timings) = try await manager.finishWithTokenTimings()
        return (text.trimmingCharacters(in: .whitespacesAndNewlines),
                UnsureWordFix.words(fromPieces: timings.map { (text: $0.token, p: $0.confidence) }))
    }

    private static func version(for model: String) -> AsrModelVersion {
        switch model {
        case "v2": return .v2
        default: return .v3
        }
    }
}
